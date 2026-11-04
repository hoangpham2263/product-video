# Product Video's run: one product photo becomes a video of about a minute that moves around the product in one take.
#   1. Key frames (Grok image): frame 0 is the photo rendered clean (or, with a model photo, the model presenting the
#      product in the same room); frame i is the same room seen from scene i's camera angle (data/angles.json),
#      only for the angles Grok's image edit does well (data/video.json keyframeAngles: close crops, high, overhead).
#      Every frame is made from the product photo itself, not from the frame before, so the product does not drift.
#      Orbits, low and wide views have no key frame: Grok's video model makes that camera move on its own.
#   2. Clips (Grok video): clip i goes to frame i (Grok's last frame) and starts on the real last frame of clip i-1
#      (ffmpeg), so each clip starts exactly where the one before ended; clip 1 starts on frame 0.
#   3. One video (src/ffmpeg.ps1): the clips joined, the shared frame shown once.
# Output: workspace/output/<time>-<product>/: khung-<i>-<angle>.png, clip-<i>.mp4, video-<product>.mp4, logs/.
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

function Get-VideoSettings { Read-JsonFile (Join-Path (Get-ToolRoot) 'data/video.json') }
function Get-AngleLibrary { Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json') }

# The job the window sends, checked: { product, photo, model, scenes[], seconds, resolution, audio }. Scenes are angle
# ids in the order the camera visits them; one may come back later in the video.
function Test-VideoJob($Job) {
    $settings = Get-VideoSettings
    if (-not ([string]$Job.product).Trim()) { throw 'Điền tên sản phẩm.' }
    if (-not $Job.photo -or -not (Test-Path -LiteralPath ([string]$Job.photo) -PathType Leaf)) { throw 'Chưa có ảnh sản phẩm.' }
    if ($Job.model -and -not (Test-Path -LiteralPath ([string]$Job.model) -PathType Leaf)) { throw 'Không thấy ảnh người mẫu.' }
    $ids = @($Job.scenes | Where-Object { $_ })
    if (-not $ids.Count) { throw 'Chọn ít nhất một cảnh.' }
    if ($ids.Count -gt [int]$settings.maxScenes) { throw "Tối đa $($settings.maxScenes) cảnh, không phải $($ids.Count)." }
    $library = @((Get-AngleLibrary).angles)
    $scenes = @($ids | ForEach-Object {
        $id = [string]$_
        $angle = $library | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $angle -or $id -eq 'as-photo') { throw "Cảnh không có trong thư viện góc: $id." }
        if (@($settings.hiddenAngles) -contains $id) { throw "Góc $($angle.label) phải quay ra sau hoặc sang hông, tool không dùng." }
        $angle
    })
    # Seconds of each scene: one length for all (6, 10, 15), or "auto", the length data/video.json suggests for each
    # angle's kind of camera move.
    $sceneSeconds = if ([string]$Job.seconds -eq 'auto') {
        @($scenes | ForEach-Object {
            $byAngle = $settings.secondsByAngle.PSObject.Properties[[string]$_.id]
            if ($byAngle) { [int]$byAngle.Value } else { [int]$settings.secondsByGroup.([string]$_.group) }
        })
    } else {
        if (@($settings.seconds) -notcontains [int]$Job.seconds) { throw "Mỗi cảnh dài $(@($settings.seconds) -join ', ') giây, không phải $($Job.seconds)." }
        @($scenes | ForEach-Object { [int]$Job.seconds })
    }
    if (@($sceneSeconds | Where-Object { @($settings.seconds) -notcontains $_ }).Count) { throw "data/video.json đề xuất độ dài Grok không làm được: $($sceneSeconds -join ', ')." }
    if (@($settings.resolutions) -notcontains [string]$Job.resolution) { throw "Độ phân giải không hỗ trợ: $($Job.resolution)." }
    $aspect = if ($Job.aspect) { [string]$Job.aspect } else { [string]$settings.defaultAspect }
    if (@($settings.aspects) -notcontains $aspect) { throw "Tỷ lệ khung không hỗ trợ: $aspect." }
    [pscustomobject]@{
        Product = ([string]$Job.product).Trim(); Photo = [string]$Job.photo; Model = [string]$Job.model
        Scenes = $scenes; SceneSeconds = $sceneSeconds; Resolution = [string]$Job.resolution; Audio = [bool]$Job.audio; Aspect = $aspect
        # Scenes whose end is a key frame made by Grok image; the others end where the video's own camera move takes it.
        Keyframes = @($settings.keyframeAngles)
        # Close crops: the scene after one, with no key frame of its own, pulls back to frame 0 (see data/video.json).
        Close = @($settings.closeAngles)
        # Wide views with no key frame end on frame 0 too: left alone, Grok draws a room of its own.
        Wide = @($settings.wideAngles)
        AsPhoto = $library | Where-Object { $_.id -eq 'as-photo' } | Select-Object -First 1
    }
}

$script:VideoLight = 'Keep the time of day and the light direction of image 1, shaped like professional interior photography: soft diffused key light, open shadows, faithful wood color, no color cast. Premium photographed realism: clear grain, crisp edges, believable contact shadows; no CGI feel, HDR look, plastic gloss or sharpening halos. One image only: no collage, inset, split screen, text, logo or watermark.'

# Frame i: the room of the product photo seen from one camera angle, the product unchanged (the core rules,
# profile content). The as-photo angle is frame 0 without a model: the photo itself, rendered clean and sharp.
function New-FramePrompt([string]$ProductName, $Angle, [int]$Index, [int]$Total) {
    $moved = $Angle.id -ne 'as-photo'
    $task = if ($moved) { 'RE-PHOTOGRAPH the room in IMAGE 1 as ONE new photorealistic photograph taken from a different camera position. Image 1 is the only reference for the room and the product; the new photograph must not repeat its framing.' }
            else { 'EDIT THE PHOTOGRAPH IN IMAGE 1 into ONE clean, sharp, photorealistic photograph of the same scene, from the same camera.' }
    @"
TASK: $task
Target product: $ProductName. This is key frame $Index of $Total of one continuous video shot in this room.

STEP 1 - ROOM
Image 1 is the only room. Its walls, floor, windows, light, plants and every other object stay exactly as they are, in the same arrangement; only the camera moves and the whole view changes perspective together. Do not add, remove, move or restyle anything.

STEP 2 - PRODUCT
$(Get-VideoProductRules 1)
Show the product without any brand name or logo.

STEP 3 - CAMERA ($($Angle.label_en))
$($Angle.text)
$(if ($moved) { 'Obey this framing exactly; the result must visibly be taken from this new position. A side the photo does not show stays consistent with the visible side.' })

STEP 4 - LIGHT AND OUTPUT
$script:VideoLight No people.
"@
}

# Frame 0 with a model: the person of image 2 presenting the product in the room of image 1, from the photo's camera.
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

# Clip i: one camera move from frame i-1 (first frame) to frame i (last frame, when there is one). The intro clip lets
# the model present the product and leave the frame, since the next frame has no one in it.
# With no last image the camera only leans toward the angle (a small arc, a push, a slide) and stays on the side of the
# room the photo shows: whatever it turns to that the photo does not show, Grok invents (data/video.json motionNote).
function New-ClipPrompt([string]$ProductName, $Angle, [int]$Index, [int]$Total, [int]$Seconds, [bool]$Intro, [bool]$HasEnd, [bool]$Reveal = $false) {
    $end = if ($Reveal) { "END: the last image, the real room with the whole product. The camera pulls back, travelling through a $($Angle.label_en) view, and lands exactly on it; every wall, window, picture and piece of furniture is the one in the last image." }
           elseif ($HasEnd) { "END: the last image, a $($Angle.label_en) view. Land exactly on it." }
           else { "END: the camera moves only a little toward a $($Angle.label_en) view: a small arc of at most 15 to 20 degrees, or a slow push-in, pull-back, rise or slide. It stays on the side of the room the first image shows and never turns to a side, corner or wall the first image does not show. The product stays exactly as in the first image." }
    $people = if ($Intro) { 'The person in the first image smiles, looks at the product and presents it with one slow, graceful hand gesture, then calmly walks out of frame to the side; by the end there is no one in the frame. Their face and outfit stay the same throughout.' }
              else { 'No people.' }
    @"
One continuous $Seconds-second shot (part $Index of $Total of a product film), one smooth camera move with no cuts, no fades and no zoom jumps.
START: the first image.
$end
Move the camera steadily from the start view to the end view on a real camera path (dolly, slider, crane or gimbal), easing in and out, with natural parallax.
The room is a fixed physical set and only the camera moves through it: walls, windows, pictures, rug, furniture and props keep their exact shapes, sizes and places relative to each other, with true parallax, and nothing slides, swaps or redraws. Any part of the room the first image does not show stays plain and simple: no new furniture, windows, pictures or decor. The product, $ProductName, is a rigid real object: it never moves, bends, morphs or changes shape, color, wood grain or number of parts. Nothing appears or disappears.
Photorealistic interior film look, steady exposure, soft natural daylight. No text, no logos. $people
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
    $total = $plan.Scenes.Count
    Send-Event @{ kind = 'start'; folder = $folder; scenes = $total; seconds = ($plan.SceneSeconds | Measure-Object -Sum).Sum; intro = [bool]$plan.Model }
    try { [void](Get-HubFfmpeg) } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }
    $bridged = $false
    try { Start-ImageBridge (Get-ToolRoot) -NewSession; $bridged = $true } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }

    # 1. Key frames.
    $frames = @('') * ($total + 1)
    for ($i = 0; $i -le $total -and -not $script:Run.Abort; $i++) {
        $intro = $i -eq 0 -and $plan.Model
        $angle = if ($i -eq 0) { $plan.AsPhoto } else { $plan.Scenes[$i - 1] }
        $label = if ($intro) { 'Người mẫu giới thiệu' } elseif ($i -eq 0) { 'Ảnh gốc' } else { [string]$angle.label }
        if ($i -gt 0 -and $plan.Keyframes -notcontains $angle.id) {
            Send-Event @{ kind = 'frame'; index = $i; label = $label; file = ''; ok = $true; message = 'Không cần khung ảnh: video tự đi máy tới góc này.' }
            continue
        }
        $file = Join-Path $folder ("khung-{0}-{1}.png" -f $i, $(if ($intro) { 'nguoi-mau' } else { $angle.id }))
        $prompt = if ($intro) { New-IntroFramePrompt $plan.Product } else { New-FramePrompt $plan.Product $angle ($i + 1) ($total + 1) }
        $images = if ($intro) { @($plan.Photo, $plan.Model) } else { @($plan.Photo) }
        Write-Utf8 (Join-Path $folder "logs/khung-$i-prompt.txt") $prompt
        Write-Host "  [FRAME] $i/$total $label" -ForegroundColor Cyan
        $event = @{ kind = 'frame'; index = $i; label = $label; file = ''; ok = $true; message = '' }
        try { [void](Invoke-GrokStep 'image' $prompt $images $file @{ Aspect = $plan.Aspect }); $frames[$i] = $file; $event.file = $file }
        catch {
            $event.ok = $false; $event.message = $_.Exception.Message
            # Without frame 0 the video still starts: from the photo itself (and without the model).
            if ($i -eq 0 -and -not $script:Run.Abort) {
                $frames[0] = $plan.Photo
                Send-Event @{ kind = 'warning'; message = "Khung mở đầu chưa tạo được, video bắt đầu từ ảnh gốc$(if ($plan.Model) { ', không có người mẫu' }). $($event.message)" }
            }
        }
        Send-Event $event
    }

    # 2. Clips, each from the frame before to its own. $ends[i]: the real last frame of clip i (ffmpeg).
    $clips = @()
    $ends = @('') * ($total + 1)
    for ($i = 1; $i -le $total -and -not $script:Run.Abort; $i++) {
        $angle = $plan.Scenes[$i - 1]
        $file = Join-Path $folder ("clip-{0}.mp4" -f $i)
        $event = @{ kind = 'clip'; index = $i; label = [string]$angle.label; file = ''; ok = $true; message = '' }
        # The clip before ended near frame i-1, not exactly on it: starting from its real last frame makes the cut seamless.
        # When the clip before failed, the latest frame there is (an end or a key frame) is the start.
        $start = ''
        for ($k = $i - 1; $k -ge 0 -and -not $start; $k--) { $start = if ($ends[$k]) { $ends[$k] } else { $frames[$k] } }
        $intro = $i -eq 1 -and $plan.Model -and $frames[0] -ne $plan.Photo
        # After a close crop the start shows only part of the product: with nothing to aim at, Grok invents the rest.
        # Frame 0 (the whole product) is the end then, unless it has the model in it.
        $afterClose = $i -gt 1 -and $plan.Close -contains $plan.Scenes[$i - 2].id
        $reveal = -not $frames[$i] -and ($afterClose -or $plan.Wide -contains $angle.id) -and $frames[0] -and -not ($plan.Model -and $frames[0] -ne $plan.Photo)
        $endFrame = if ($frames[$i]) { $frames[$i] } elseif ($reveal) { $frames[0] } else { '' }
        $hasEnd = [bool]$endFrame
        $prompt = New-ClipPrompt $plan.Product $angle $i $total $plan.SceneSeconds[$i - 1] $intro $hasEnd $reveal
        Write-Utf8 (Join-Path $folder "logs/clip-$i-prompt.txt") $prompt
        Write-Host "  [CLIP] $i/$total $($angle.id)" -ForegroundColor Cyan
        try {
            if (-not $start) { throw 'Cảnh trước không có khung cuối để bắt đầu.' }
            $images = @($start) + @(if ($hasEnd) { $endFrame })
            [void](Invoke-GrokStep 'video' $prompt $images $file @{ Seconds = $plan.SceneSeconds[$i - 1]; Resolution = $plan.Resolution; Audio = $plan.Audio; Aspect = $plan.Aspect; TimeoutSec = 900 })
            $clips += $file; $event.file = $file
            $ends[$i] = Join-Path $folder ("khung-{0}-cuoi-clip.png" -f $i)
            try { Save-HubVideoLastFrame $file $ends[$i] } catch { $ends[$i] = '' }
        } catch { $event.ok = $false; $event.message = $_.Exception.Message }
        Send-Event $event
    }

    # 3. One video.
    $ok = $false
    if ($clips.Count) {
        if ($clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = "Chỉ $($clips.Count)/$total cảnh tạo được; video ghép từ các cảnh đó nên có chỗ nhảy cảnh." } }
        $final = Join-Path $folder "video-$slug.mp4"
        try {
            Join-HubVideoClips $clips $final
            $info = Get-HubVideoInfo $final
            Send-Event @{ kind = 'final'; file = $final; seconds = [Math]::Round($info.Seconds, 1); width = $info.Width; height = $info.Height }
            $ok = $true
        } catch { Send-Event @{ kind = 'warning'; message = $_.Exception.Message } }
    }
    $stopped = if ($script:Run.Abort) { 'Dừng vì Grok/bridge cần người dùng xử lý (đăng nhập, hết lượt hoặc extension).' } else { '' }
    Send-Event @{ kind = 'done'; ok = $ok; folder = $folder; clips = $clips.Count; scenes = $total; message = $stopped }
    if ($ok) { 0 } else { 1 }
}
