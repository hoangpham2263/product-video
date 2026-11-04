# The words of a video: a voiceover (or an on-camera presenter's opening and closing) timed to the shots, English only
# for the US market. Codex writes them once from the shots and the brand's verifiable facts; the timing is checked
# here (no AI) and Codex gets one more try with what was wrong. Uses src/plan.ps1 (Get-ToolRoot, Read-JsonFile,
# Write-Utf8, Format-Seconds) and core/ai/ai.ps1 (Invoke-HubAI), dot-sourced by the caller.
#   Shots: { Index, Seconds, Angle, MoveEn, MoveVi } (video.ps1 Get-RunPlan), back to back from 0 s.
#   Lines: [ { start, end, text, speaker: voice | presenter } ], seconds of the video.

# Speech pace asked of Codex. The check allows a little more (2.8) so a line at the edge is not sent back for nothing.
$script:ScriptWordsPerSecond = 2.5
# A presenter line is spoken inside one Grok clip; the app films 6 s clips (data/video.json grokSeconds), and a line
# running past its clip is cut off mid-word.
$script:ScriptPresenterSeconds = 6
# Where the brand's own notes live (the GRENHEIM skills workspace); HUB_BRAND_PROJECT points elsewhere for another brand.
$script:ScriptBrandProject = if ($env:HUB_BRAND_PROJECT) { $env:HUB_BRAND_PROJECT } else { 'C:\hoangpq\vaniecom-workspace\grenheim\grenheim-skills\project' }

function Format-ScriptSeconds([double]$Value) { $Value.ToString('0.0#', [Globalization.CultureInfo]::InvariantCulture) }

# The English name of an angle, for Codex to picture the shot; the app's own labels ("as photo", "nhãn ứng dụng")
# mean nothing to it.
function Get-ScriptAngleNames {
    $names = @{}
    try {
        foreach ($angle in @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json')).angles)) {
            $names[[string]$angle.id] = ([string]$angle.label_en -replace '\s*\(.*?\)', '' -replace '\s*—.*$', '').Trim()
        }
    } catch { }
    $names['as-photo'] = 'The product photo''s own view'
    $names
}

# The shots on the video's timeline: each starts where the one before ends.
function Get-ScriptTimeline($Shots) {
    $names = Get-ScriptAngleNames
    $at = 0.0
    @(foreach ($shot in @($Shots)) {
        $length = [double]$shot.Seconds
        $angle = [string]$shot.Angle
        $view = if ($names.ContainsKey($angle) -and $names[$angle]) { $names[$angle] } else { $angle }
        $move = if ($shot.MoveEn) { [string]$shot.MoveEn } else { 'camera move not given' }
        [pscustomobject]@{ Index = [int]$shot.Index; Start = $at; End = $at + $length; View = $view; Move = $move }
        $at += $length
    })
}

# The request to Codex. Only the facts given may be said: the brand notes forbid founding years and experience
# numbers, and anything else (prices, "best", "solid oak" when nobody said so) would be a claim nobody checked.
function New-ScriptPrompt($Shots, $Brand, [string]$ProductName, [double]$Seconds, [string]$Mode = 'voice') {
    $timeline = Get-ScriptTimeline $Shots
    $shotLines = ($timeline | ForEach-Object { "- Shot $($_.Index), $(Format-ScriptSeconds $_.Start)-$(Format-ScriptSeconds $_.End) s: $($_.View); $($_.Move)." }) -join "`r`n"
    $facts = (@($Brand.facts) | Where-Object { $_ } | ForEach-Object { "- $_" }) -join "`r`n"
    if (-not $facts) { $facts = '- (none: describe only what the shots show)' }
    $voice = (@($Brand.voice) | Where-Object { $_ }) -join ', '
    $name = if ($Brand.name) { [string]$Brand.name } else { 'the brand' }
    $wps = Format-ScriptSeconds $script:ScriptWordsPerSecond
    $end = Format-ScriptSeconds $Seconds
    $presenter = Format-ScriptSeconds $script:ScriptPresenterSeconds
    $speakers = if ($Mode -eq 'presenter') {
        @"
SPEAKERS: one on-camera presenter and a voiceover.
- The FIRST line is spoken by the presenter (speaker "presenter"): it starts at or after 0 s and ends by $presenter s, so it fits inside the presenter's single $presenter-second clip.
- The LAST line is spoken by the presenter too: it starts no earlier than $(Format-ScriptSeconds ([Math]::Max(0.0, $Seconds - $script:ScriptPresenterSeconds))) s and ends by $end s.
- Every line in between is voiceover (speaker "voice"). No other line uses "presenter".
"@
    } else {
        'SPEAKERS: voiceover only. Every line has speaker "voice".'
    }
    @"
TASK: Write the spoken script for a $end-second product video for $name, a US furniture brand. English (US) only.
Product: $ProductName.

SHOTS (the video's timeline; each line of the script should match what is on screen while it is spoken):
$shotLines

BRAND
- Tagline: $($Brand.tagline)
- Voice: $voice.
Facts you may use (the ONLY claims allowed; use one or two that fit, not all):
$facts

$speakers

TIMING
- Times are seconds of the video, from 0 to $end. Lines never overlap and stay inside 0-$end.
- Speaking pace about $wps words per second: a line from start to end holds at most ($wps x its length) words. Leave short pauses; silence over a shot is fine.
- A line may run over more than one shot.

WRITING
- Short, natural sentences, the way a person talks. Warm and plain US English. Vary sentence length.
- Talk about what the viewer sees: the wood, the shape, the details on screen. If a detail is not in the product name, the shots or the facts, do not mention it.
- Do NOT invent claims: no superlatives (best, finest, perfect, ultimate), no "timeless", "exquisite", "elevate", "game changer", no materials, sizes, origins or features not given above.
- No prices, discounts, years, dates or numbers of years of experience. No founding story.
- No emojis, hashtags, exclamation-mark hype, or stage directions in the text.
- Avoid stock phrases like "more than just a table", "where X meets Y", "not only X but also Y".
- Close with one soft, calm line that fits the brand (its tagline or close to it). The end card already shows the website: do not read out a URL or web address.

OUTPUT: JSON only, no other text, in exactly this shape:
{ "lines": [ { "start": 0.3, "end": 2.6, "text": "...", "speaker": "voice" } ] }
"@
}

# The brand's verifiable facts, read from its notes (project.md, written in Vietnamese) and its English introduction.
# A note that is empty or changes wording drops its fact rather than letting an old sentence through.
#   { name, tagline, website, facts[], voice[] }
function Get-GrenheimBrand([string]$Project = $script:ScriptBrandProject) {
    $file = Join-Path $Project 'project.md'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Không tìm thấy hồ sơ thương hiệu: $file. [CAUSE:SCRIPT]" }
    $notes = @{}
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        # "- Key: value"; the first of a key wins (Website is under Nhận diện before any other link).
        if ($line -match '^\s*-\s*([^:]+?)\s*:\s*(.*)$' -and -not $notes.ContainsKey($Matches[1])) { $notes[$Matches[1]] = $Matches[2].Trim() }
    }
    $facts = @()
    if ($notes['Ngành'] -match 'gỗ tự nhiên') { $facts += 'Natural wood furniture for the home' }
    $intro = Join-Path $Project 'sources/brand/02-introduction-en.txt'
    if (Test-Path -LiteralPath $intro -PathType Leaf) {
        # The brand's own English sentence about its makers, as published.
        $sentence = [regex]::Match((Get-Content -LiteralPath $intro -Raw -Encoding UTF8), '[^.\r\n]*skilled craftspeople[^.]*\.')
        if ($sentence.Success) { $facts += $sentence.Value.Trim() }
    }
    if ($notes['Giao hàng'] -match 'miễn phí' -and $notes['Giao hàng'] -match 'Mỹ' -and $notes['Giao hàng'] -match 'Puerto Rico') { $facts += 'Free shipping across the US and Puerto Rico' }
    if ($notes['Bảo hành'] -match '(\d+)\s*năm') { $facts += "$($Matches[1])-year warranty against manufacturing defects" }
    $words = @{ 'ấm áp' = 'warm'; 'tự nhiên' = 'natural'; 'chăm chút' = 'caring, attentive to detail'; 'dễ hiểu' = 'plain and easy to follow' }
    $voice = @(([string]$notes['Giọng viết']) -split ',' | ForEach-Object { $words[$_.Trim()] } | Where-Object { $_ })
    [pscustomobject]@{
        name = [string]$notes['Tên']; tagline = [string]$notes['Tagline EN']; website = [string]$notes['Website']
        facts = @($facts); voice = $voice
    }
}

# Codex's reply as lines. It sometimes wraps the JSON in ```json fences or a sentence; the outermost { } is taken.
function ConvertFrom-ScriptReply([string]$Reply) {
    $text = [string]$Reply -replace '```(?:json)?', ''
    $first = $text.IndexOf('{'); $last = $text.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) { throw 'Codex không trả về JSON lời thoại. [CAUSE:SCRIPT]' }
    try { $parsed = ConvertFrom-Json $text.Substring($first, $last - $first + 1) }
    catch { throw "JSON lời thoại của Codex bị lỗi: $($_.Exception.Message) [CAUSE:SCRIPT]" }
    if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['lines']) { throw 'JSON lời thoại thiếu mục "lines". [CAUSE:SCRIPT]' }
    $raw = @($parsed.lines)  # Windows PowerShell 5.1 hands a JSON array on as one item: unroll it here
    if (-not $raw.Count) { throw 'Codex trả về lời thoại rỗng. [CAUSE:SCRIPT]' }
    $n = 0
    @(foreach ($item in $raw) {
        $n++
        $start = 0.0; $end = 0.0
        if ($null -eq $item -or -not [double]::TryParse([string]$item.start, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$start) -or
            -not [double]::TryParse([string]$item.end, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$end)) {
            throw "Câu $n của lời thoại thiếu thời điểm bắt đầu/kết thúc. [CAUSE:SCRIPT]"
        }
        if ($null -eq $item.PSObject.Properties['text']) { throw "Câu $n của lời thoại thiếu nội dung (text). [CAUSE:SCRIPT]" }
        $speaker = if ($item.speaker) { [string]$item.speaker } else { 'voice' }
        if ($speaker -notin @('voice', 'presenter')) { throw "Câu $n có người nói lạ: $speaker (chỉ voice hoặc presenter). [CAUSE:SCRIPT]" }
        [pscustomobject]@{ start = $start; end = $end; text = ([string]$item.text).Trim(); speaker = $speaker }
    })
}

function Get-ScriptWordCount([string]$Text) { @($Text -split '\s+' | Where-Object { $_ -match '\w' }).Count }

# What is wrong with the lines' timing, in words for the user (and for Codex's second try). Wrap in @(); empty: fine.
# $Mode 'presenter' also checks the presenter lines fit one clip; 'voice' refuses any presenter line.
function Test-ScriptTiming($Lines, [double]$Seconds, [double]$WordsPerSecond = 2.8, [string]$Mode = '') {
    $problems = New-Object System.Collections.Generic.List[string]
    $list = @($Lines)
    $f = { param($v) Format-ScriptSeconds $v }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $line = $list[$i]; $n = $i + 1
        $start = [double]$line.start; $end = [double]$line.end
        $text = [string]$line.text
        if (-not $text.Trim()) { $problems.Add("Câu $n không có chữ.") }
        if ($start -lt 0 -or $end -gt $Seconds + 0.05) { $problems.Add("Câu $n ($(& $f $start)-$(& $f $end) s) nằm ngoài video 0-$(& $f $Seconds) s.") }
        if ($end -le $start) { $problems.Add("Câu $n kết thúc ($(& $f $end) s) không sau lúc bắt đầu ($(& $f $start) s).") }
        elseif ($text.Trim()) {
            $words = Get-ScriptWordCount $text
            $room = [Math]::Max(1, [Math]::Floor(($end - $start) * $WordsPerSecond + 0.5))
            if ($words -gt $room) { $problems.Add("Câu $n có $words từ, quá nhiều cho $(& $f ($end - $start)) s (tối đa khoảng $room từ).") }
        }
        if ($line.speaker -eq 'presenter') {
            if ($Mode -eq 'voice') { $problems.Add("Câu $n do người dẫn nói, nhưng video này chỉ có lời đọc (voice).") }
            elseif ($end - $start -gt $script:ScriptPresenterSeconds + 0.05) { $problems.Add("Câu $n của người dẫn dài $(& $f ($end - $start)) s, quá một clip $($script:ScriptPresenterSeconds) s.") }
        }
    }
    $sorted = @($list | Sort-Object { [double]$_.start })
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if ([double]$sorted[$i].start -lt [double]$sorted[$i - 1].end - 0.01) {
            $problems.Add("Câu `"$($sorted[$i - 1].text)`" ($(& $f $sorted[$i - 1].start)-$(& $f $sorted[$i - 1].end) s) chồng lên câu `"$($sorted[$i].text)`" ($(& $f $sorted[$i].start)-$(& $f $sorted[$i].end) s).")
        }
    }
    if ($Mode -eq 'presenter' -and $list.Count) {
        if ($list[0].speaker -ne 'presenter') { $problems.Add('Câu mở đầu phải do người dẫn nói (presenter).') }
        if ($list[-1].speaker -ne 'presenter') { $problems.Add('Câu kết phải do người dẫn nói (presenter).') }
    }
    $problems.ToArray()  # none: nothing at all, which @() turns into an empty list
}

# One Codex call; when the reply cannot be read or its timing is off, one more with what was wrong. The replies and
# prompts go next to $Output (<Output>.prompt-<k>.txt, <Output>.reply-<k>.txt) so a bad script can be looked into.
function Invoke-ScriptWriter($Shots, $Brand, [string]$ProductName, [double]$Seconds, [string]$Output, [string]$Mode = 'voice') {
    $folder = Split-Path $Output -Parent
    if (-not $folder) { $folder = (Get-Location).Path }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $base = New-ScriptPrompt $Shots $Brand $ProductName $Seconds $Mode
    $prompt = $base; $problems = @()
    for ($try = 1; $try -le 2; $try++) {
        Write-Utf8 "$Output.prompt-$try.txt" $prompt
        $reply = [string](Invoke-HubAI -Kind text -Ai codex -Prompt $prompt -Output "$Output.reply-$try.txt" -Options @{ WorkDir = $folder; TimeoutSec = 600 })
        $lines = $null
        try { $lines = ConvertFrom-ScriptReply $reply; $problems = @(Test-ScriptTiming $lines $Seconds -Mode $Mode) }
        catch { $problems = @($_.Exception.Message -replace '\s*\[CAUSE:\w+\]', '') }
        if (-not $problems.Count) {
            $json = ConvertTo-Json -InputObject ([pscustomobject]@{ mode = $Mode; seconds = $Seconds; lines = @($lines) }) -Depth 4
            Write-Utf8 $Output $json
            return $lines
        }
        # The problems are written for the user in Vietnamese; Codex reads them fine, and the user sees the same list.
        $prompt = $base + "`r`n`r`nYOUR PREVIOUS ANSWER:`r`n$($reply.Trim())`r`n`r`nIT HAD THESE PROBLEMS (in Vietnamese):`r`n" +
            (($problems | ForEach-Object { "- $_" }) -join "`r`n") + "`r`nWrite the whole JSON again with every problem fixed. JSON only."
    }
    throw "Codex viết lời thoại chưa đạt sau 2 lần: $($problems -join ' ') [CAUSE:SCRIPT]"
}
