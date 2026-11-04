# Offline checks of src/script.ps1 (no AI: Invoke-HubAI is replaced by canned replies): the prompt, reading Codex's
# reply, the timing checks, the brand facts and the writer's one retry.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/script.tests.ps1     (also run by tests/script.test.mjs)
# Prints one line per check; exits 1 when any fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/plan.ps1')
. (Join-Path $root 'src/script.ps1')

$script:Failed = 0
function Assert-That([string]$Name, [scriptblock]$Check) {
    try { $ok = & $Check; $why = '' } catch { $ok = $false; $why = " ($($_.Exception.Message))" }
    if ($ok) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name$why" }
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null; $script:Failed++; Write-Host "FAIL $Name (no error)" }
    catch { if ($_.Exception.Message -match $Pattern) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name ($($_.Exception.Message))" } }
}

# Shots as Get-RunPlan hands them on: 8 of 2.5 s.
$shots = @(1..8 | ForEach-Object { [pscustomobject]@{ Index = $_; Seconds = 2.5; Angle = @('as-photo', 'close-up', 'room-wide', 'detail', 'high', 'profile-left', 'medium', 'overhead')[$_ - 1]; MoveEn = "move $_"; MoveVi = "máy $_" } })
$brand = [pscustomobject]@{ name = 'GRENHEIM'; tagline = 'Nature''s beauty, shaped by artisan hands.'; website = 'https://grenheim.com/'; facts = @('Free shipping across the US and Puerto Rico', '1-year warranty against manufacturing defects'); voice = @('warm', 'natural') }
$product = 'Round solid wood dining table with twisted pedestal'

# --- New-ScriptPrompt ---
$prompt = New-ScriptPrompt $shots $brand $product 20
Assert-That 'Prompt: every shot with its times, view and move' {
    $prompt -match 'Shot 1, 0\.0-2\.5 s: The product photo''s own view; move 1\.' -and $prompt -match 'Shot 2, 2\.5-5\.0 s: Close-up; move 2\.' -and
    $prompt -match 'Shot 8, 17\.5-20\.0 s: Overhead / top-down; move 8\.' -and $prompt -match '20\.0-second'
}
Assert-That 'Prompt: the product, tagline, facts and voice' {
    $prompt.Contains($product) -and $prompt.Contains($brand.tagline) -and $prompt.Contains('- Free shipping across the US and Puerto Rico') -and
    $prompt.Contains('- 1-year warranty') -and $prompt -match 'Voice: warm, natural\.'
}
Assert-That 'Prompt: forbids made-up claims, prices, years, emojis and reading the URL; asks for JSON at 2.5 words/s' {
    $prompt -match 'ONLY claims allowed' -and $prompt -match 'Do NOT invent claims' -and $prompt -match 'No prices' -and $prompt -match 'years of experience' -and
    $prompt -match 'No emojis, hashtags' -and $prompt -match 'do not read out a URL' -and $prompt -match 'JSON only' -and $prompt -match '"speaker": "voice"' -and
    $prompt -match '2\.5 words per second' -and -not $prompt.Contains('grenheim.com')
}
Assert-That 'Prompt: voice mode has no presenter; presenter mode opens and closes on camera within one 6 s clip' {
    $p = New-ScriptPrompt $shots $brand $product 20 'presenter'
    $prompt -match 'voiceover only' -and $p -match 'FIRST line is spoken by the presenter' -and $p -match 'ends by 6\.0 s' -and $p -match 'no earlier than 14\.0 s'
}
Assert-That 'Prompt: no facts given, none invented' { (New-ScriptPrompt $shots ([pscustomobject]@{ tagline = 'x'; facts = @(); voice = @() }) $product 20) -match 'none: describe only what the shots show' }

# --- ConvertFrom-ScriptReply ---
$plain = '{ "lines": [ { "start": 0.3, "end": 2.4, "text": "Meet the round table.", "speaker": "voice" }, { "start": 3, "end": 5, "text": "Solid wood, twisted base." } ] }'
Assert-That 'Reply: plain JSON, numbers read, speaker voice when left out' {
    $l = ConvertFrom-ScriptReply $plain
    $l.Count -eq 2 -and $l[0].start -eq 0.3 -and $l[1].end -eq 5 -and $l[1].speaker -eq 'voice' -and $l[0].text -eq 'Meet the round table.'
}
Assert-That 'Reply: in ```json fences with words around it' {
    $l = ConvertFrom-ScriptReply "Here is the script:`n``````json`n$plain`n```````nHope it helps."
    $l.Count -eq 2 -and $l[1].text -eq 'Solid wood, twisted base.'
}
Assert-That 'Reply: one line stays a list of one' { @(ConvertFrom-ScriptReply '{"lines":[{"start":0,"end":2,"text":"Hi.","speaker":"presenter"}]}').Count -eq 1 }
Assert-Throws 'Reply: garbage is refused' { ConvertFrom-ScriptReply 'Sorry, I cannot help with that.' } 'không trả về JSON.*\[CAUSE:SCRIPT\]'
Assert-Throws 'Reply: broken JSON is refused' { ConvertFrom-ScriptReply '{ "lines": [ { "start": 0, ' } '\[CAUSE:SCRIPT\]'
Assert-Throws 'Reply: no lines is refused' { ConvertFrom-ScriptReply '{ "text": "hi" }' } 'thiếu mục "lines"'
Assert-Throws 'Reply: empty lines is refused' { ConvertFrom-ScriptReply '{ "lines": [] }' } 'rỗng'
Assert-Throws 'Reply: a line without times is refused' { ConvertFrom-ScriptReply '{ "lines": [ { "text": "hi" } ] }' } 'Câu 1.*thời điểm'
Assert-Throws 'Reply: an unknown speaker is refused' { ConvertFrom-ScriptReply '{ "lines": [ { "start": 0, "end": 2, "text": "hi", "speaker": "narrator" } ] }' } 'narrator'

# --- Test-ScriptTiming ---
function New-Line($Start, $End, $Text, $Speaker = 'voice') { [pscustomobject]@{ start = $Start; end = $End; text = $Text; speaker = $Speaker } }
Assert-That 'Timing: good lines have no problems' {
    $p = Test-ScriptTiming @((New-Line 0.3 2.4 'Meet the round table.'), (New-Line 2.6 5 'Solid wood, twisted base.')) 20
    $p.Count -eq 0
}
Assert-That 'Timing: overlap is found' { $p = @(Test-ScriptTiming @((New-Line 0 3 'One two.'), (New-Line 2.5 5 'Three four.')) 20); $p.Count -eq 1 -and $p[0] -match 'chồng lên' }
Assert-That 'Timing: too many words for the window' { $p = @(Test-ScriptTiming @(New-Line 0 2 'one two three four five six seven eight') 20); $p.Count -eq 1 -and $p[0] -match '8 từ.*tối đa khoảng 6' }
Assert-That 'Timing: out of range, end before start, empty text' {
    $p = @(Test-ScriptTiming @((New-Line -1 2 'Hi.'), (New-Line 18 21 'Bye now.'), (New-Line 6 5 'Back.'), (New-Line 8 9 '  ')) 20)
    ($p -match 'nằm ngoài').Count -eq 2 -and ($p -match 'không sau lúc bắt đầu').Count -eq 1 -and ($p -match 'không có chữ').Count -eq 1
}
Assert-That 'Timing: presenter lines over one clip, missing at the ends, or in a voice-only video' {
    $p = @(Test-ScriptTiming @((New-Line 0 7 'Hello there, this is our table.' 'presenter'), (New-Line 8 10 'Look closer.')) 20 -Mode 'presenter')
    $v = @(Test-ScriptTiming @(New-Line 0 3 'Hello there.' 'presenter') 20 -Mode 'voice')
    ($p -match 'quá một clip 6 s').Count -eq 1 -and ($p -match 'Câu kết').Count -eq 1 -and $v.Count -eq 1 -and $v[0] -match 'chỉ có lời đọc'
}

# --- Get-GrenheimBrand ---
$real = Join-Path $script:ScriptBrandProject 'project.md'
if (Test-Path -LiteralPath $real) {
    Assert-That 'Brand: tagline, website, facts and voice from the GRENHEIM notes' {
        $b = Get-GrenheimBrand
        $b.name -eq 'GRENHEIM' -and $b.tagline -eq 'Nature''s beauty, shaped by artisan hands.' -and $b.website -eq 'https://grenheim.com/' -and
        $b.facts -contains 'Natural wood furniture for the home' -and $b.facts -contains 'Free shipping across the US and Puerto Rico' -and
        $b.facts -contains '1-year warranty against manufacturing defects' -and @($b.facts -match 'skilled craftspeople').Count -eq 1 -and
        (@($b.voice) -join ', ') -match '^warm, natural'
    }
} else { Write-Host "skip Brand: the GRENHEIM notes are not on this machine ($real)" }
$temp = Join-Path ([IO.Path]::GetTempPath()) ("pv-script-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Assert-That 'Brand: an empty note drops its fact (no warranty, no shipping), nothing made up' {
        [IO.File]::WriteAllText((Join-Path $temp 'project.md'), "# X`r`n- Tên: ACME`r`n- Website: https://acme.test/`r`n- Tagline EN: Made well.`r`n- Bảo hành:`r`n- Giao hàng: tính phí`r`n", [Text.UTF8Encoding]::new($true))
        $b = Get-GrenheimBrand $temp
        $b.tagline -eq 'Made well.' -and $b.website -eq 'https://acme.test/' -and @($b.facts).Count -eq 0 -and @($b.voice).Count -eq 0
    }
    Assert-Throws 'Brand: no notes is refused' { Get-GrenheimBrand (Join-Path $temp 'none') } 'Không tìm thấy hồ sơ'

    # --- Invoke-ScriptWriter, Codex replaced by canned replies ---
    $script:Calls = @(); $script:Replies = @()
    function Invoke-HubAI {
        param([string]$Kind, [string]$Ai, [string]$Prompt, [string[]]$Images = @(), [string]$Output, [hashtable]$Options = @{})
        $script:Calls += [pscustomobject]@{ Kind = $Kind; Ai = $Ai; Prompt = $Prompt; Output = $Output; WorkDir = $Options.WorkDir }
        $script:Replies[$script:Calls.Count - 1]
    }
    $good = '```json' + "`n" + '{ "lines": [ { "start": 0.3, "end": 3, "text": "A round table for the whole family.", "speaker": "voice" }, { "start": 16, "end": 19.5, "text": "Nature''s beauty, shaped by artisan hands.", "speaker": "voice" } ] }' + "`n" + '```'
    $long = '{ "lines": [ { "start": 0, "end": 2, "text": "This round solid wood dining table with a twisted pedestal base is here", "speaker": "voice" } ] }'
    $out = Join-Path $temp 'run/loi-thoai.json'

    Assert-That 'Writer: too many words, then a good reply: two calls, the problems sent back, the good one saved' {
        $script:Calls = @(); $script:Replies = @($long, $good)
        $lines = Invoke-ScriptWriter $shots $brand $product 20 $out
        $saved = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Calls.Count -eq 2 -and $script:Calls[0].Kind -eq 'text' -and $script:Calls[0].Ai -eq 'codex' -and $script:Calls[0].WorkDir -eq (Split-Path $out -Parent) -and
        $script:Calls[1].Prompt -match 'YOUR PREVIOUS ANSWER' -and $script:Calls[1].Prompt -match 'quá nhiều cho 2\.0 s' -and
        @($lines).Count -eq 2 -and @($saved.lines).Count -eq 2 -and $saved.mode -eq 'voice' -and $saved.lines[1].text -match 'artisan hands' -and
        (Test-Path -LiteralPath "$out.prompt-2.txt")
    }
    Assert-That 'Writer: garbage, then a good reply: retried with why' {
        $script:Calls = @(); $script:Replies = @('no idea', $good)
        $lines = Invoke-ScriptWriter $shots $brand $product 20 $out
        $script:Calls.Count -eq 2 -and $script:Calls[1].Prompt -match 'không trả về JSON' -and @($lines).Count -eq 2
    }
    Assert-That 'Writer: a good first reply is one call' {
        $script:Calls = @(); $script:Replies = @($good)
        [void](Invoke-ScriptWriter $shots $brand $product 20 $out); $script:Calls.Count -eq 1
    }
    Assert-Throws 'Writer: two bad replies stop with the problems' {
        $script:Calls = @(); $script:Replies = @($long, $long)
        Invoke-ScriptWriter $shots $brand $product 20 (Join-Path $temp 'bad/loi-thoai.json')
    } 'sau 2 lần.*quá nhiều.*\[CAUSE:SCRIPT\]'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failed) { Write-Host "$($script:Failed) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
