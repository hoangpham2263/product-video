# Product Video's run: the product photo, filmed in the style of a sample video (video mẫu): its cuts, the length of
# each shot and how the camera moves in it. The room is the product photo's own; nothing of the sample's room is used.
#   1. The sample is read with ffmpeg: its cuts (scene change) split it into shots; a shot longer than Grok can make
#      (15 s) is split into parts that follow each other. vidstabdetect measures the camera's move, in phases of a few
#      seconds (src/motion.mjs): sideways, up or down, in or out.
#      A sample in the library may carry a plan (<video>.json beside it: its shots and each shot's angle, from
#      data/angles.json); then the shots are the plan's.
#   2. Key frames (Grok image): with a model photo, the model presenting the product in the photo's room; for a planned
#      shot of another angle (a close-up, a three-quarter view), the photo's room seen from that angle.
#   3. Clips (Grok video): one per part, from the product photo (or the model frame) and the measured move as words; a
#      part that continues a shot starts on the real last frame of the part before it. Each clip is then sped up or
#      slowed down to its part's length, so the video keeps the sample's pace and cuts.
#   4. One video: parts of one shot fade into each other (fadeSeconds), and a new shot dissolves in (shotFadeSeconds):
#      the user found a straight cut to another angle too sudden (04/11/2026).
# Tried 04/11/2026: redrawing the sample's own frames with the product (to copy it exactly) made the room's things slide
# and change between frames, and the user wants the style, not the sample's room.
# Output: workspace/output/<time>-<product>/: clip-<i>-grok.mp4, clip-<i>.mp4, video-<product>.mp4, logs/.
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

# The job the window sends, checked: { product, photo, model, reference, length, resolution }. Length: seconds of the
# video (one of data/video.json lengths), 0 for as long as the sample.
function Test-VideoJob($Job) {
    $settings = Get-VideoSettings
    if (-not ([string]$Job.product).Trim()) { throw 'Điền tên sản phẩm.' }
    if (-not $Job.photo -or -not (Test-Path -LiteralPath ([string]$Job.photo) -PathType Leaf)) { throw 'Chưa có ảnh sản phẩm.' }
    if ($Job.model -and -not (Test-Path -LiteralPath ([string]$Job.model) -PathType Leaf)) { throw 'Không thấy ảnh người mẫu.' }
    if (-not $Job.reference -or -not (Test-Path -LiteralPath ([string]$Job.reference) -PathType Leaf)) { throw 'Chưa chọn video mẫu.' }
    if (@($settings.resolutions) -notcontains [string]$Job.resolution) { throw "Độ phân giải không hỗ trợ: $($Job.resolution)." }
    $length = [int]$Job.length
    if ($length -and @($settings.lengths) -notcontains $length) { throw "Độ dài video $(@($settings.lengths) -join ', ') giây, không phải $length." }
    [pscustomobject]@{
        Product = ([string]$Job.product).Trim(); Photo = [string]$Job.photo; Model = [string]$Job.model
        Reference = [string]$Job.reference; Length = $length; Resolution = [string]$Job.resolution; Settings = $settings
    }
}

# Grok's frame shape nearest to the sample's.
function Get-VideoAspect([int]$Width, [int]$Height) {
    $ratio = $Width / [double]$Height
    if ($ratio -lt 0.8) { '9:16' } elseif ($ratio -gt 1.25) { '16:9' } else { '1:1' }
}

# Where the sample changes shot (seconds), from ffmpeg's scene score between frames half a second apart: a dissolve
# changes little from one frame to the next and reads as no cut (tried 04/11/2026: 0.03 at most, frame by frame).
function Get-ReferenceCuts([string]$Video, [double]$Threshold) {
    $log = (Invoke-HubFfmpeg @('-hide_banner', '-i', $Video, '-map', '0:v:0', '-an', '-filter:v', "fps=2,select='gt(scene,$(Format-Seconds $Threshold))',showinfo", '-f', 'null', '-')).Log
    @([regex]::Matches($log, 'pts_time:([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $script:Invariant) })
}

# The parts Grok makes: shots (between cuts; one shorter than minShot joins the shot before), each split into equal
# parts of at most the longest Grok clip. Only the first maxSeconds of the sample are used. $Length (seconds, 0: as
# the sample) stretches every shot alike: the same moves and cuts, the camera slower.
#   { Shot, Start, End (in the sample), Seconds (in the video), GrokSeconds, Continues }
# $Angles: the angle of each shot, from a plan (as-photo when there is none).
function Get-ReferenceParts([double]$Duration, [double[]]$Cuts, $Settings, [double]$Length = 0, [string[]]$Angles = @()) {
    $end = [Math]::Min($Duration, [double]$Settings.maxSeconds)
    $stretch = if ($Length -gt 0) { $Length / $end } else { 1 }
    $bounds = @(0.0)
    foreach ($cut in ($Cuts | Sort-Object)) {
        if ($cut - $bounds[-1] -ge [double]$Settings.minShot -and $end - $cut -ge [double]$Settings.minShot) { $bounds += $cut }
    }
    $bounds += $end
    $lengths = @($Settings.grokSeconds | ForEach-Object { [int]$_ } | Sort-Object)
    $longest = $lengths[-1]
    $parts = @()
    for ($s = 0; $s -lt $bounds.Count - 1; $s++) {
        $source = $bounds[$s + 1] - $bounds[$s]
        $length = $source * $stretch
        $count = [Math]::Ceiling($length / $longest - 0.001)
        for ($p = 0; $p -lt $count; $p++) {
            $seconds = $length / $count
            $grok = $lengths | Where-Object { $_ -ge $seconds - 0.05 } | Select-Object -First 1
            $parts += [pscustomobject]@{
                Shot = $s + 1; Start = $bounds[$s] + $p * $source / $count; End = $bounds[$s] + ($p + 1) * $source / $count
                Seconds = $seconds; GrokSeconds = $(if ($grok) { $grok } else { $longest }); Continues = $p -gt 0
                Angle = $(if ($s -lt $Angles.Count -and $Angles[$s]) { $Angles[$s] } else { 'as-photo' })
            }
        }
    }
    if ($parts.Count -gt [int]$Settings.maxParts) { throw "Video mẫu có $($parts.Count) đoạn, tối đa $($Settings.maxParts). Chọn video ngắn hơn hoặc ít cảnh cắt hơn." }
    $parts
}

# The plan of a library sample (<video>.json): { shots: [{ start, angle }] }, start in seconds, angle an id of
# data/angles.json. None: $null.
function Read-ReferencePlan([string]$Video) {
    $file = "$Video.json"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $plan = Read-JsonFile $file
    $ids = @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json')).angles | ForEach-Object { $_.id })
    $shots = @($plan.shots | Sort-Object { [double]$_.start })
    foreach ($shot in $shots) { if ($ids -notcontains [string]$shot.angle) { throw "Kế hoạch của video mẫu có góc lạ: $($shot.angle)." } }
    [pscustomobject]@{ Cuts = @($shots | Select-Object -Skip 1 | ForEach-Object { [double]$_.start }); Angles = @($shots | ForEach-Object { [string]$_.angle }) }
}

# The camera's move over the whole sample, measured once: vidstabdetect at 5 frames a second (a slow move shifts less
# than a pixel from one frame to the next and would read as still), 720 wide. Writes logs/mau.trf.
function Save-ReferenceMotion([string]$Video, $Info, [string]$Logs) {
    $height = [Math]::Round(720 * $Info.Height / $Info.Width / 2) * 2
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-map', '0:v:0', '-an', '-filter:v', 'fps=5,scale=720:-2,vidstabdetect=shakiness=8:accuracy=15:stepsize=4:result=mau.trf', '-f', 'null', '-') $Logs) 'đo được chuyển động của video mẫu'
    [pscustomobject]@{ File = Join-Path $Logs 'mau.trf'; Width = 720; Height = $height; Fps = 5 }
}

# The move from $Start to $End seconds (src/motion.mjs): { panX, panY, zoom, seconds }.
function Get-ReferenceMove($Motion, [double]$Start, [double]$End) {
    $out = & node (Join-Path $PSScriptRoot 'motion.mjs') $Motion.File $Motion.Width $Motion.Height $Motion.Fps (Format-Seconds $Start) (Format-Seconds $End) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return [pscustomobject]@{ panX = 0; panY = 0; zoom = 1; seconds = $End - $Start } }
    $out | ConvertFrom-Json
}

# A measured move in words, with how far it goes: English for Grok, Vietnamese for the window. The picture sliding one
# way means the camera went the other; growing means it pushed in. Each phase is capped (maxZoom, maxPan): tried
# 04/11/2026, a sample walking into the next room (push-in x3) told only as "clearly pushes in" sent Grok around the
# table, into a room of its own, and the table changed shape.
function ConvertTo-MoveText($Move, $Settings) {
    $en = @(); $vi = @()
    $cap = { param($v, $most) [Math]::Max(-$most, [Math]::Min($most, $v)) }
    $x = & $cap ([double]$Move.panX) ([double]$Settings.maxPan); $y = & $cap ([double]$Move.panY) ([double]$Settings.maxPan)
    $z = [double]$Move.zoom
    $z = [Math]::Max(1 / [double]$Settings.maxZoom, [Math]::Min([double]$Settings.maxZoom, $z))
    $percent = { param($v) [int][Math]::Round(100 * $v) }
    if ($z -ge 1.04) { $en += "the camera slowly pushes in (dolly forward) so the product looks about $(& $percent ($z - 1))% larger by the end of this phase"; $vi += 'đẩy vào' }
    elseif ($z -le 0.96) { $en += "the camera slowly pulls back (dolly out) so the product looks about $(& $percent (1 - $z))% smaller by the end of this phase"; $vi += 'kéo ra' }
    if ([Math]::Abs($x) -ge 0.03) { $side = if ($x -lt 0) { 'right' } else { 'left' }; $en += "the camera slowly slides to the $side (truck), about $(& $percent ([Math]::Abs($x)))% of the frame width"; $vi += "trượt $(if ($x -lt 0) { 'phải' } else { 'trái' })" }
    if ([Math]::Abs($y) -ge 0.03) { $up = $y -gt 0; $en += "the camera slowly $(if ($up) { 'rises' } else { 'lowers' }) (pedestal), about $(& $percent ([Math]::Abs($y)))% of the frame height"; $vi += $(if ($up) { 'nâng lên' } else { 'hạ xuống' }) }
    if (-not $en.Count) { $en += 'the camera holds almost still, a locked-off shot with only a faint drift'; $vi += 'đứng yên' }
    [pscustomobject]@{ En = ($en -join ' while '); Vi = ($vi -join ', ') }
}

# The moves of one part, in phases of about phaseSeconds of the sample (a stretched video measures the same stretch of
# the sample, so a slower video does not read as still): "0-5 s: ..., 5-10 s: ...".
function Get-PartMoves($Motion, $Part, $Settings) {
    $source = $Part.End - $Part.Start
    $count = [Math]::Max(1, [Math]::Round($source / [double]$Settings.phaseSeconds))
    $step = $source / $count
    $grokStep = $Part.GrokSeconds / $count
    @(for ($k = 0; $k -lt $count; $k++) {
        $text = ConvertTo-MoveText (Get-ReferenceMove $Motion ($Part.Start + $k * $step) ($Part.Start + ($k + 1) * $step)) $Settings
        [pscustomobject]@{ From = [Math]::Round($k * $grokStep); To = [Math]::Round(($k + 1) * $grokStep); En = $text.En; Vi = $text.Vi }
    })
}

# A clip brought to $Seconds by changing its speed, without sound, at $Fps. The new frames are blended from their
# neighbours: tried 04/11/2026, Grok's 24 fps sped up to ~28 and then made 30 by repeating frames stuttered every half
# second; motion interpolation (minterpolate) was smooth too but took minutes per clip.
function Set-HubVideoLength([string]$Video, [double]$Seconds, [string]$Output, [int]$Fps = 30) {
    $info = Get-HubVideoInfo $Video
    $factor = if ($info.Seconds -gt 0) { $Seconds / $info.Seconds } else { 1 }
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-an', '-filter:v', "setpts=$(Format-Seconds $factor)*PTS,framerate=fps=$Fps", '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', $Output)) 'chỉnh được độ dài clip'
}

# The parts as one video, each fading into the one before over its Fade seconds (0: a straight cut). Tried 04/11/2026:
# Grok redraws its start image slightly on the clip's second frame, so even a part that continues a shot jumps when
# joined straight.
#   $Items: { File, Fade }, all at $Fps (Set-HubVideoLength).
function Join-PartClips($Items, [string]$Output, [int]$Fps = 30) {
    $first = Get-HubVideoInfo $Items[0].File
    $w = $first.Width - ($first.Width % 2); $h = $first.Height - ($first.Height % 2)
    $inputs = @(); $chains = @()
    for ($k = 0; $k -lt $Items.Count; $k++) {
        $inputs += @('-i', $Items[$k].File)
        $chains += "[${k}:v]fps=$Fps,scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p,settb=AVTB[v$k]"
    }
    $label = 'v0'; $length = $first.Seconds
    for ($k = 1; $k -lt $Items.Count; $k++) {
        $seconds = (Get-HubVideoInfo $Items[$k].File).Seconds
        $fade = [double]$Items[$k].Fade
        if ($fade -gt 0) {
            $chains += "[$label][v$k]xfade=transition=fade:duration=$(Format-Seconds $fade):offset=$(Format-Seconds ($length - $fade))[j$k]"
            $length += $seconds - $fade
        } else {
            $chains += "[$label][v$k]concat=n=2:v=1:a=0[j$k]"
            $length += $seconds
        }
        $label = "j$k"
    }
    $arguments = @('-y', '-hide_banner') + $inputs + @('-filter_complex', ($chains -join ';'), '-map', "[$label]", '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', '-an', $Output)
    Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments) 'ghép được video'
}

$script:VideoLight = 'Premium photographed realism: clear grain, crisp edges, believable contact shadows; no CGI feel, HDR look, plastic gloss or sharpening halos. One image only: no collage, inset, split screen, text, logo or watermark.'

# The opening frame with a model: the person of image 2 presenting the product in the room of image 1.
function New-IntroFramePrompt([string]$ProductName) {
    @"
TASK: EDIT THE PHOTOGRAPH IN IMAGE 1 into ONE photorealistic brand photograph of the same room, with the person from IMAGE 2 standing beside the product and presenting it. It is the opening frame of a product video.
Target product: $ProductName.

STEP 1 - ROOM (image 1)
Image 1 is the only room: walls, floor, windows, light and every object stay as they are, in the same arrangement. The camera stays where it is in image 1; pull back slightly only if needed so the person and the whole product both fit.

STEP 2 - PRODUCT (image 1)
$(Get-VideoProductRules 1)
Rule 6 does not forbid the one person from image 2 that this task adds; it still applies to everything else.

STEP 3 - PERSON (image 2)
Image 2 controls only the person: the same face, hair, skin tone, body and outfit, recognisably the same person. Nothing else of image 2 (its background, props, flags or text) comes into the result.
Place the person standing on the floor next to the product, at true scale, turned slightly toward the camera with a warm natural smile, one hand gently presenting the product. The person never covers the product or touches it in a way that hides its shape.

STEP 4 - LIGHT AND OUTPUT
Light the person with the room's own light and direction, with matching shadows. $script:VideoLight
"@
}

# A planned shot's opening frame: the room of the product photo seen from another angle (data/angles.json).
function New-AngleFramePrompt([string]$ProductName, $Angle) {
    @"
TASK: RE-PHOTOGRAPH the room in IMAGE 1 as ONE new photorealistic photograph taken from a different camera position. Image 1 is the only reference for the room and the product; the new photograph must not repeat its framing.
Target product: $ProductName. This is the opening frame of one shot of a product film made in this room.

STEP 1 - ROOM
Image 1 is the only room. Its walls, floor, windows, light, plants and every other object stay exactly as they are, in the same arrangement; only the camera moves and the whole view changes perspective together. Do not add, remove, move or restyle anything.

STEP 2 - PRODUCT
$(Get-VideoProductRules 1)
Show the product without any brand name or logo.

STEP 3 - CAMERA ($($Angle.label_en))
$($Angle.text)
Obey this framing exactly; the result must visibly be taken from this new position. A side the photo does not show stays consistent with the visible side.

STEP 4 - LIGHT AND OUTPUT
$script:VideoLight No people.
"@
}

# Clip of one part: from the start image, the sample's camera moves phase by phase. The room is the image's own.
function New-ClipPrompt([string]$ProductName, [int]$Index, [int]$Total, [int]$Seconds, $Moves, [bool]$Person) {
    $plan = if ($Moves.Count -eq 1) { "Camera: $($Moves[0].En), steadily for the whole shot." }
            else { "Camera, phase by phase, flowing into each other without stops:`n" + (($Moves | ForEach-Object { "- $($_.From)-$($_.To) s: $($_.En)." }) -join "`n") }
    $people = if ($Person) { 'The person in the image presents the product with one slow, graceful gesture, keeping the same face and outfit; no one else appears.' }
              else { 'No hands, arms or people enter the frame; nobody touches, picks up or moves anything.' }
    @"
One continuous $Seconds-second shot (part $Index of $Total of a product film) in the room of the image, one smooth camera move with no cuts, no fades and no zoom jumps.
START: the image, exactly as it is.
$plan
Move on a real camera path (dolly, slider, crane or gimbal) with natural parallax. The room is a fixed physical set: walls, windows, pictures, rug, furniture and props keep their exact shapes, sizes and places, and nothing slides, swaps, appears or disappears; any part of the room the image does not show stays plain and simple, with no new furniture or decor. The product, $ProductName, is a rigid real object: it never moves, bends, morphs or changes shape, color, grain or number of parts, and it stays the subject of the shot.
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
    $logs = Join-Path $folder 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null

    # 1. The sample: shots, parts and the camera's moves.
    try {
        [void](Get-HubFfmpeg)
        $info = Get-HubVideoInfo $plan.Reference
        if ($info.Seconds -lt 1) { throw 'Video mẫu quá ngắn hoặc không đọc được.' }
        $shotPlan = Read-ReferencePlan $plan.Reference
        $cuts = if ($shotPlan) { $shotPlan.Cuts } else { Get-ReferenceCuts $plan.Reference ([double]$plan.Settings.sceneThreshold) }
        $parts = @(Get-ReferenceParts $info.Seconds $cuts $plan.Settings $plan.Length $(if ($shotPlan) { $shotPlan.Angles } else { @() }))
        $motion = Save-ReferenceMotion $plan.Reference $info $logs
        foreach ($part in $parts) { $part | Add-Member -NotePropertyName Moves -NotePropertyValue @(Get-PartMoves $motion $part $plan.Settings) }
    } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }
    $aspect = Get-VideoAspect $info.Width $info.Height
    $total = $parts.Count
    $angles = @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json')).angles)
    $framed = @($parts | Where-Object { -not $_.Continues -and $_.Angle -ne 'as-photo' } | ForEach-Object { $_.Angle } | Select-Object -Unique)
    Send-Event @{ kind = 'start'; folder = $folder; frames = $(if ($plan.Model) { 1 } else { 0 }) + $framed.Count; parts = $total; shots = $parts[-1].Shot; seconds = [Math]::Round(($parts | Measure-Object Seconds -Sum).Sum, 1); aspect = $aspect }
    Write-Utf8 (Join-Path $logs 'mau.json') (ConvertTo-Json -InputObject @{ reference = $plan.Reference; width = $info.Width; height = $info.Height; seconds = $info.Seconds; aspect = $aspect; parts = $parts } -Depth 5)
    try { Start-ImageBridge (Get-ToolRoot) -NewSession } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }

    # 2. With a model: the opening frame. Without it (or when it fails) the video starts from the photo itself.
    $opening = $plan.Photo
    if ($plan.Model -and -not $script:Run.Abort) {
        $file = Join-Path $folder 'khung-nguoi-mau.png'
        $prompt = New-IntroFramePrompt $plan.Product
        Write-Utf8 (Join-Path $logs 'khung-nguoi-mau-prompt.txt') $prompt
        $event = @{ kind = 'frame'; index = 0; label = 'Người mẫu giới thiệu'; file = ''; ok = $true; message = '' }
        try { [void](Invoke-GrokStep 'image' $prompt @($plan.Photo, $plan.Model) $file @{ Aspect = $aspect }); $opening = $file; $event.file = $file }
        catch { $event.ok = $false; $event.message = $_.Exception.Message; Send-Event @{ kind = 'warning'; message = "Khung người mẫu chưa tạo được, video bắt đầu từ ảnh sản phẩm. $($event.message)" } }
        Send-Event $event
    }

    # Opening frames of the planned angles, one per angle, all made from the photo itself.
    $angleFrames = @{}
    $index = if ($plan.Model) { 1 } else { 0 }
    foreach ($id in $framed) {
        if ($script:Run.Abort) { break }
        $angle = $angles | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $file = Join-Path $folder "khung-$id.png"
        $prompt = New-AngleFramePrompt $plan.Product $angle
        Write-Utf8 (Join-Path $logs "khung-$id-prompt.txt") $prompt
        $event = @{ kind = 'frame'; index = $index; label = [string]$angle.label; file = ''; ok = $true; message = '' }
        Write-Host "  [FRAME] $id" -ForegroundColor Cyan
        try { [void](Invoke-GrokStep 'image' $prompt @($plan.Photo) $file @{ Aspect = $aspect }); $angleFrames[$id] = $file; $event.file = $file }
        catch { $event.ok = $false; $event.message = "$($_.Exception.Message) Cảnh này bắt đầu từ ảnh sản phẩm." }
        Send-Event $event
        $index++
    }

    # 3. Clips. A new shot starts from its angle's frame, else the photo (the first one from the model frame); a part
    # that continues one starts on the real last frame of the part before.
    $clips = @(); $last = @{}
    for ($i = 1; $i -le $total -and -not $script:Run.Abort; $i++) {
        $part = $parts[$i - 1]
        $raw = Join-Path $folder ("clip-{0}-grok.mp4" -f $i)
        $moveVi = ($part.Moves | ForEach-Object { $_.Vi }) -join ' → '
        $event = @{ kind = 'clip'; index = $i; label = "Cảnh $($part.Shot), $(Format-Seconds ([Math]::Round($part.Seconds, 1)))s, $moveVi"; file = ''; ok = $true; message = '' }
        $start = if ($part.Continues) { $last[$i - 1] } elseif ($angleFrames[$part.Angle]) { $angleFrames[$part.Angle] } elseif ($i -eq 1) { $opening } else { $plan.Photo }
        $person = $i -eq 1 -and $opening -ne $plan.Photo
        $prompt = New-ClipPrompt $plan.Product $i $total $part.GrokSeconds $part.Moves $person
        Write-Utf8 (Join-Path $logs "clip-$i-prompt.txt") $prompt
        Write-Host "  [CLIP] $i/$total $moveVi" -ForegroundColor Cyan
        try {
            if (-not $start) { throw 'Đoạn trước chưa tạo được, không có khung để nối tiếp.' }
            [void](Invoke-GrokStep 'video' $prompt @($start) $raw @{ Seconds = $part.GrokSeconds; Resolution = $plan.Resolution; Audio = $false; Aspect = $aspect; TimeoutSec = 900 })
            $clips += [pscustomobject]@{ Index = $i; Raw = $raw; File = (Join-Path $folder ("clip-{0}.mp4" -f $i)) }; $event.file = $raw
            $last[$i] = Join-Path $folder ("clip-{0}-cuoi.png" -f $i)
            try { Save-HubVideoLastFrame $raw $last[$i] } catch { $last[$i] = '' }
        } catch { $event.ok = $false; $event.message = $_.Exception.Message }
        Send-Event $event
    }

    # 4. One video. Each clip is brought to its part's length plus the fade into the clip after it, so the video keeps
    # the sample's length.
    $ok = $false
    if ($clips.Count) {
        if ($clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = "Chỉ $($clips.Count)/$total đoạn tạo được; video ghép từ các đoạn đó." } }
        $final = Join-Path $folder "video-$slug.mp4"
        $fadeIn = { param($k) if ($k -eq 0) { 0 } elseif ($clips[$k - 1].Index -eq $clips[$k].Index - 1 -and $parts[$clips[$k].Index - 1].Continues) { [double]$plan.Settings.fadeSeconds } else { [double]$plan.Settings.shotFadeSeconds } }
        try {
            $items = @()
            for ($k = 0; $k -lt $clips.Count; $k++) {
                $clip = $clips[$k]
                $fadeOut = if ($k + 1 -lt $clips.Count) { & $fadeIn ($k + 1) } else { 0 }
                Set-HubVideoLength $clip.Raw ($parts[$clip.Index - 1].Seconds + $fadeOut) $clip.File
                $items += [pscustomobject]@{ File = $clip.File; Fade = (& $fadeIn $k) }
            }
            Join-PartClips $items $final
            $out = Get-HubVideoInfo $final
            Send-Event @{ kind = 'final'; file = $final; seconds = [Math]::Round($out.Seconds, 1); width = $out.Width; height = $out.Height }
            $ok = $true
        } catch { Send-Event @{ kind = 'warning'; message = $_.Exception.Message } }
    }
    $stopped = if ($script:Run.Abort) { 'Dừng vì Grok/bridge cần người dùng xử lý (đăng nhập, hết lượt hoặc extension).' } else { '' }
    Send-Event @{ kind = 'done'; ok = $ok; folder = $folder; clips = $clips.Count; parts = $total; message = $stopped }
    if ($ok) { 0 } else { 1 }
}
