# Product Video's run: the product photo, filmed the way a sample video (video mẫu) is filmed.
#   1. The sample is read with ffmpeg: its cuts (scene change) split it into shots; a shot longer than Grok can make
#      (15 s) is split into parts that follow each other. Its first and last frames, and every part's, are saved.
#   2. Key frames (Grok image): each saved frame of the sample redrawn with the product in place of the furniture the
#      shot is about (and, with a model photo, the person in it as that model). Same camera, room and light.
#   3. Clips (Grok video): one per part, from its start frame to its end frame, so the camera moves as in the sample.
#      A part that continues a shot starts on the real last frame of the part before it. Each clip is then sped up or
#      slowed down to the part's own length, so the video keeps the sample's pace and cuts.
#   4. One video (src/ffmpeg.ps1): the clips joined.
# Output: workspace/output/<time>-<product>/: mau-<i>.png, khung-<i>.png, clip-<i>.mp4, video-<product>.mp4, logs/.
# The window follows the run through @@EVENT lines (start, frame, clip, final, warning, done, fatal).

function Get-ToolRoot { Split-Path $PSScriptRoot -Parent }
function Read-JsonFile([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Send-Event([hashtable]$Event) { Write-Host ('@@EVENT ' + (ConvertTo-Json -InputObject $Event -Compress -Depth 6)) }
function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function ConvertTo-Slug([string]$Text) {
    $plain = ($Text.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace 'đ', 'd' -replace 'Đ', 'D'
    $slug = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if ($slug) { $slug } else { 'san-pham' }
}
function Get-ErrorCause([string]$Message) { if ($Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { 'UNKNOWN' } }
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
function Format-Seconds([double]$Value) { $Value.ToString('0.###', $script:Invariant) }

function Get-VideoSettings { Read-JsonFile (Join-Path (Get-ToolRoot) 'data/video.json') }

# The job the window sends, checked: { product, photo, model, reference, resolution }.
function Test-VideoJob($Job) {
    $settings = Get-VideoSettings
    if (-not ([string]$Job.product).Trim()) { throw 'Điền tên sản phẩm.' }
    if (-not $Job.photo -or -not (Test-Path -LiteralPath ([string]$Job.photo) -PathType Leaf)) { throw 'Chưa có ảnh sản phẩm.' }
    if ($Job.model -and -not (Test-Path -LiteralPath ([string]$Job.model) -PathType Leaf)) { throw 'Không thấy ảnh người mẫu.' }
    if (-not $Job.reference -or -not (Test-Path -LiteralPath ([string]$Job.reference) -PathType Leaf)) { throw 'Chưa chọn video mẫu.' }
    if (@($settings.resolutions) -notcontains [string]$Job.resolution) { throw "Độ phân giải không hỗ trợ: $($Job.resolution)." }
    [pscustomobject]@{
        Product = ([string]$Job.product).Trim(); Photo = [string]$Job.photo; Model = [string]$Job.model
        Reference = [string]$Job.reference; Resolution = [string]$Job.resolution; Settings = $settings
    }
}

# Grok's frame shape nearest to the sample's.
function Get-VideoAspect([int]$Width, [int]$Height) {
    $ratio = $Width / [double]$Height
    if ($ratio -lt 0.8) { '9:16' } elseif ($ratio -gt 1.25) { '16:9' } else { '1:1' }
}

# Where the sample cuts (seconds), from ffmpeg's scene score.
function Get-ReferenceCuts([string]$Video, [double]$Threshold) {
    $log = (Invoke-HubFfmpeg @('-hide_banner', '-i', $Video, '-an', '-filter:v', "select='gt(scene,$(Format-Seconds $Threshold))',showinfo", '-f', 'null', '-')).Log
    @([regex]::Matches($log, 'pts_time:([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $script:Invariant) })
}

# The parts Grok makes: shots (between cuts; one shorter than minShot joins the shot before), each split into equal
# parts of at most the longest Grok clip. Only the first maxSeconds of the sample are used.
#   { Shot, Start, End, Seconds, GrokSeconds, Continues }
function Get-ReferenceParts([double]$Duration, [double[]]$Cuts, $Settings) {
    $end = [Math]::Min($Duration, [double]$Settings.maxSeconds)
    $bounds = @(0.0)
    foreach ($cut in ($Cuts | Sort-Object)) {
        if ($cut - $bounds[-1] -ge [double]$Settings.minShot -and $end - $cut -ge [double]$Settings.minShot) { $bounds += $cut }
    }
    $bounds += $end
    $lengths = @($Settings.grokSeconds | ForEach-Object { [int]$_ } | Sort-Object)
    $longest = $lengths[-1]
    $parts = @()
    for ($s = 0; $s -lt $bounds.Count - 1; $s++) {
        $length = $bounds[$s + 1] - $bounds[$s]
        $count = [Math]::Ceiling($length / $longest - 0.001)
        for ($p = 0; $p -lt $count; $p++) {
            $seconds = $length / $count
            $grok = $lengths | Where-Object { $_ -ge $seconds - 0.05 } | Select-Object -First 1
            $parts += [pscustomobject]@{
                Shot = $s + 1; Start = $bounds[$s] + $p * $seconds; End = $bounds[$s] + ($p + 1) * $seconds
                Seconds = $seconds; GrokSeconds = $(if ($grok) { $grok } else { $longest }); Continues = $p -gt 0
            }
        }
    }
    if ($parts.Count -gt [int]$Settings.maxParts) { throw "Video mẫu có $($parts.Count) đoạn, tối đa $($Settings.maxParts). Chọn video ngắn hơn hoặc ít cảnh cắt hơn." }
    $parts
}

# One frame of the sample at $At seconds. Near the end the video stream can stop before the container says it does
# (8.54 s of video in an 8.64 s file): then the last frame there is.
function Save-ReferenceFrame([string]$Video, [double]$At, [string]$Png) {
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-ss', (Format-Seconds ([Math]::Max(0, $At))), '-i', $Video, '-frames:v', '1', $Png)) 'lấy được khung của video mẫu'
    if (-not (Test-Path -LiteralPath $Png)) { Save-HubVideoLastFrame $Video $Png }
}

# A clip brought to $Seconds by changing its speed, without sound.
function Set-HubVideoLength([string]$Video, [double]$Seconds, [string]$Output) {
    $info = Get-HubVideoInfo $Video
    $factor = if ($info.Seconds -gt 0) { $Seconds / $info.Seconds } else { 1 }
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-an', '-filter:v', "setpts=$(Format-Seconds $factor)*PTS", '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', $Output)) 'chỉnh được độ dài clip'
}

$script:VideoLight = 'Premium photographed realism: clear grain, crisp edges, believable contact shadows; no CGI feel, HDR look, plastic gloss or sharpening halos. One image only: no collage, inset, split screen, text, logo or watermark.'

# A frame of the sample with the product in it: image 1 the sample's frame, image 2 the product, image 3 the model.
function New-FramePrompt([string]$ProductName, [bool]$Model) {
    $person = if ($Model) { "`nSTEP 3 - PERSON (image 3)`nIf image 1 shows a person, replace them with the person from image 3: the same face, hair, skin tone, body and outfit, in the pose, place and size of the person in image 1. Nothing else of image 3 comes into the result. Rule 6 does not forbid this person; it still applies to everything else. If image 1 shows no person, add none.`n" } else { '' }
    @"
TASK: REDRAW THE FRAME IN IMAGE 1 (a frame of a sample video) as ONE photorealistic photograph with the product from IMAGE 2 in it. Same camera position, height, lens, framing and focus as image 1; the result must line up with image 1.
Target product: $ProductName.

STEP 1 - SHOT (image 1)
Keep image 1's room, walls, floor, windows, light, time of day, colors, props and depth of field exactly as they are. Only the furniture piece the shot is about (the main one, in focus or at the center) is replaced by the product, in the same place and on the same floor line, at the product's true scale. If image 1 shows only a close part of that piece, show the matching part of the product the same way. If the shot is about no furniture at all, place the product where it fits naturally in view, not covering the subject.

STEP 2 - PRODUCT (image 2)
$(Get-VideoProductRules 2)
Show the product without any brand name or logo. Nothing of image 2's background comes into the result.
$person
STEP $(if ($Model) { 4 } else { 3 }) - OUTPUT
Light the product with image 1's light and direction, with matching shadows. $script:VideoLight
"@
}

# Clip of one part: from the start image to the end image, the camera move of the sample.
function New-ClipPrompt([string]$ProductName, [int]$Index, [int]$Total, [int]$Seconds, [bool]$HasEnd, [bool]$Model) {
    $end = if ($HasEnd) { 'END: the last image. Land exactly on it. Move the camera from the start view to the end view the way a real camera would (dolly, slider, crane, gimbal or locked off), easing in and out, with natural parallax; if both images are framed the same, the camera holds almost still with a slow, gentle drift.' }
           else { 'The camera holds the start framing with a slow, gentle push-in.' }
    # Tried 04/11/2026: told only "add no one", Grok still brought in a hand that picked up the cup on the table.
    $still = 'No hands, arms or people enter the frame; nobody touches, picks up or moves anything. Every prop on and around the product stays exactly where it is.'
    $people = if ($Model) { "Only a person already in the first image may move, calmly and naturally, with the same face and outfit throughout. $still" } else { "Only a person already in the first image may move, calmly and naturally. $still" }
    @"
One continuous $Seconds-second shot (part $Index of $Total of a product film), one smooth camera move with no cuts, no fades and no zoom jumps.
START: the first image.
$end
The room is a fixed physical set: walls, windows, pictures, rug, furniture and props keep their exact shapes, sizes and places, and nothing slides, swaps or redraws. The product, $ProductName, is a rigid real object: it never moves, bends, morphs or changes shape, color, grain or number of parts. Nothing appears or disappears.
Photorealistic interior film look, steady exposure. No text, no logos. $people
"@
}

# One Grok call, tried again once when Grok was busy or slow. A sign-in, quota or bridge problem stops the run.
function Invoke-GrokStep([string]$Kind, [string]$Prompt, [string[]]$Images, [string]$Output, [hashtable]$Options = @{}) {
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-HubAI -Kind $Kind -Ai 'grok' -Prompt $Prompt -Images $Images -Output $Output -Options $Options }
        catch {
            $cause = Get-ErrorCause $_.Exception.Message
            if ($cause -in @('QUOTA', 'AUTH', 'BRIDGE')) { $script:Run.Abort = $true }
            if ($attempt -ge 2 -or $cause -notin @('BUSY', 'AI_TIMEOUT', 'NETWORK')) { throw }
            Write-Host "  [RETRY] Grok $Kind, attempt 2/2" -ForegroundColor Yellow
        }
    }
}

function Invoke-VideoRun($Job, [string]$OutRoot) {
    $script:Run = @{ Abort = $false }
    try { $plan = Test-VideoJob $Job } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 2 }
    $slug = ConvertTo-Slug $plan.Product
    $folder = Join-Path $OutRoot ("{0}-{1}" -f [DateTime]::Now.ToString("yyyy-MM-dd_HH'h'mm'm'ss's'"), $slug)
    New-Item -ItemType Directory -Force -Path (Join-Path $folder 'logs') | Out-Null

    # 1. The sample.
    try {
        [void](Get-HubFfmpeg)
        $info = Get-HubVideoInfo $plan.Reference
        if ($info.Seconds -lt 1) { throw 'Video mẫu quá ngắn hoặc không đọc được.' }
        $parts = @(Get-ReferenceParts $info.Seconds (Get-ReferenceCuts $plan.Reference ([double]$plan.Settings.sceneThreshold)) $plan.Settings)
    } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }
    $aspect = Get-VideoAspect $info.Width $info.Height
    $total = $parts.Count
    # Frames to make: the start of every shot, then the end of every part.
    $frameJobs = @()
    for ($i = 1; $i -le $total; $i++) {
        $part = $parts[$i - 1]
        if (-not $part.Continues) { $frameJobs += [pscustomobject]@{ Part = $i; Role = 'start'; At = $part.Start + 0.05; Label = "Cảnh $($part.Shot): đầu" } }
        $frameJobs += [pscustomobject]@{ Part = $i; Role = 'end'; At = $part.End - 0.1; Label = "Đoạn $($i): cuối" }
    }
    Send-Event @{ kind = 'start'; folder = $folder; frames = $frameJobs.Count; parts = $total; shots = $parts[-1].Shot; seconds = [Math]::Round(($parts | Measure-Object Seconds -Sum).Sum, 1); aspect = $aspect }
    Write-Utf8 (Join-Path $folder 'logs/mau.json') (ConvertTo-Json -InputObject @{ reference = $plan.Reference; width = $info.Width; height = $info.Height; seconds = $info.Seconds; aspect = $aspect; parts = $parts } -Depth 4)
    try { Start-ImageBridge (Get-ToolRoot) -NewSession } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }

    # 2. Key frames, each from the sample's frame and the product photo itself, so the product does not drift.
    $starts = @{}; $ends = @{}
    $prompt = New-FramePrompt $plan.Product ([bool]$plan.Model)
    Write-Utf8 (Join-Path $folder 'logs/khung-prompt.txt') $prompt
    for ($f = 0; $f -lt $frameJobs.Count -and -not $script:Run.Abort; $f++) {
        $frame = $frameJobs[$f]
        $sample = Join-Path $folder ("mau-{0}.png" -f $f)
        $file = Join-Path $folder ("khung-{0}.png" -f $f)
        $event = @{ kind = 'frame'; index = $f; label = $frame.Label; file = ''; sample = ''; ok = $true; message = '' }
        Write-Host "  [FRAME] $($f + 1)/$($frameJobs.Count) $($frame.Label)" -ForegroundColor Cyan
        try {
            Save-ReferenceFrame $plan.Reference $frame.At $sample
            $event.sample = $sample
            $images = @($sample, $plan.Photo) + @(if ($plan.Model) { $plan.Model })
            [void](Invoke-GrokStep 'image' $prompt $images $file @{ Aspect = $aspect })
            $event.file = $file
            if ($frame.Role -eq 'start') { $starts[$frame.Part] = $file } else { $ends[$frame.Part] = $file }
        } catch { $event.ok = $false; $event.message = $_.Exception.Message }
        Send-Event $event
    }

    # 3. Clips. $last[i]: the real last frame of clip i, where a part that continues it starts.
    $clips = @(); $last = @{}
    for ($i = 1; $i -le $total -and -not $script:Run.Abort; $i++) {
        $part = $parts[$i - 1]
        $raw = Join-Path $folder ("clip-{0}-grok.mp4" -f $i)
        $file = Join-Path $folder ("clip-{0}.mp4" -f $i)
        $event = @{ kind = 'clip'; index = $i; label = "Cảnh $($part.Shot), $(Format-Seconds ([Math]::Round($part.Seconds, 1)))s"; file = ''; ok = $true; message = '' }
        $start = if ($part.Continues) { if ($last[$i - 1]) { $last[$i - 1] } else { $ends[$i - 1] } } else { $starts[$i] }
        $end = $ends[$i]
        $prompt = New-ClipPrompt $plan.Product $i $total $part.GrokSeconds ([bool]$end) ([bool]$plan.Model)
        Write-Utf8 (Join-Path $folder "logs/clip-$i-prompt.txt") $prompt
        Write-Host "  [CLIP] $i/$total" -ForegroundColor Cyan
        try {
            if (-not $start) { throw 'Thiếu khung đầu của đoạn này.' }
            $images = @($start) + @(if ($end) { $end })
            [void](Invoke-GrokStep 'video' $prompt $images $raw @{ Seconds = $part.GrokSeconds; Resolution = $plan.Resolution; Audio = $false; Aspect = $aspect; TimeoutSec = 900 })
            Set-HubVideoLength $raw $part.Seconds $file
            $clips += $file; $event.file = $file
            $last[$i] = Join-Path $folder ("clip-{0}-cuoi.png" -f $i)
            try { Save-HubVideoLastFrame $raw $last[$i] } catch { $last[$i] = '' }
        } catch { $event.ok = $false; $event.message = $_.Exception.Message }
        Send-Event $event
    }

    # 4. One video.
    $ok = $false
    if ($clips.Count) {
        if ($clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = "Chỉ $($clips.Count)/$total đoạn tạo được; video ghép từ các đoạn đó." } }
        $final = Join-Path $folder "video-$slug.mp4"
        try {
            Join-HubVideoClips $clips $final
            $out = Get-HubVideoInfo $final
            Send-Event @{ kind = 'final'; file = $final; seconds = [Math]::Round($out.Seconds, 1); width = $out.Width; height = $out.Height }
            $ok = $true
        } catch { Send-Event @{ kind = 'warning'; message = $_.Exception.Message } }
    }
    $stopped = if ($script:Run.Abort) { 'Dừng vì Grok/bridge cần người dùng xử lý (đăng nhập, hết lượt hoặc extension).' } else { '' }
    Send-Event @{ kind = 'done'; ok = $ok; folder = $folder; clips = $clips.Count; parts = $total; message = $stopped }
    if ($ok) { 0 } else { 1 }
}
