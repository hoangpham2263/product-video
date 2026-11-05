# Product Video's run: a short film of the product photo's room, made of short shots.
#   1. Plan (plan.ps1): the shots, each with an angle and a camera move; from the sample video's way of filming when
#      there is one (its cuts, planned angles and measured moves), else data/video.json defaultShots. Angles the user
#      switched off are never used.
#   2. Key frames (generate.ps1, Codex CLI, codexParallel at once): the photo's room seen from each angle the shots use,
#      and with a model photo the model presenting the product. Tried 04/11/2026: Grok's own redrawn angles changed the
#      product's size against the room from one angle to the next; Codex's kept it.
#   3. Clips (generate.ps1, Grok video, 6 s): one per shot, from its angle's frame, the move as words (prompts.ps1).
#   4. One video (edit.ps1): the first Seconds of each clip at its real speed, each going into the next by a transition
#      chosen to fit the two shots (transitions.ps1), then the user's brand intro/outro when there is one (brand.ps1).
# Output: workspace/output/<time>-<product>/: khung-<angle>.png, clip-<i>-grok.mp4, clip-<i>.mp4, video-<product>.mp4
# (video-<product>-canh.mp4 without the brand), logs/ (ke-hoach.json, chuyen-canh.json, prompts). The window follows
# the run through @@EVENT lines (start, frame, clip, final, warning, done, fatal).

function Send-Event([hashtable]$Event) { Write-Host ('@@EVENT ' + (ConvertTo-Json -InputObject $Event -Compress -Depth 6)) }
function ConvertTo-Slug([string]$Text) {
    $plain = ($Text.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace 'đ', 'd' -replace 'Đ', 'D'
    $slug = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if ($slug) { $slug } else { 'san-pham' }
}
function Get-ErrorCause([string]$Message) { if ($Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { 'UNKNOWN' } }

# The job the window sends, checked: { product, photo, model?, reference?, music?, length, aspect, resolution, captions? }.
# Length: seconds (one of lengths; 0 is as long as the sample, or defaultLength without one). Aspect: one of aspects
# (defaultAspect, 2:3, when the job has none). Captions: English lines written by Codex and burnt in (default: settings).
function Test-VideoJob($Job) {
    $settings = Get-VideoSettings
    if (-not ([string]$Job.product).Trim()) { throw 'Điền tên sản phẩm.' }
    if (-not $Job.photo -or -not (Test-Path -LiteralPath ([string]$Job.photo) -PathType Leaf)) { throw 'Chưa có ảnh sản phẩm.' }
    if ($Job.model -and -not (Test-Path -LiteralPath ([string]$Job.model) -PathType Leaf)) { throw 'Không thấy ảnh người mẫu.' }
    if ($Job.reference -and -not (Test-Path -LiteralPath ([string]$Job.reference) -PathType Leaf)) { throw 'Không thấy video mẫu.' }
    if ($Job.music -and -not (Test-Path -LiteralPath ([string]$Job.music) -PathType Leaf)) { throw 'Không thấy file nhạc nền.' }
    if (@($settings.resolutions) -notcontains [string]$Job.resolution) { throw "Độ phân giải không hỗ trợ: $($Job.resolution)." }
    $aspect = if ($Job.aspect) { [string]$Job.aspect } else { [string]$settings.defaultAspect }
    if (@($settings.aspects) -notcontains $aspect) { throw "Khổ video không hỗ trợ: $aspect." }
    $length = [int]$Job.length
    if ($length -and @($settings.lengths) -notcontains $length) { throw "Độ dài video $(@($settings.lengths) -join ', ') giây, không phải $length." }
    if (-not $length -and -not $Job.reference) { $length = [int]$settings.defaultLength }
    [pscustomobject]@{
        Product = ([string]$Job.product).Trim(); Photo = [string]$Job.photo; Model = [string]$Job.model; Reference = [string]$Job.reference; Music = [string]$Job.music
        Length = $length; Aspect = $aspect; Resolution = [string]$Job.resolution; Settings = $settings
        Captions = $(if ($null -ne $Job.captions) { [bool]$Job.captions } else { [bool]$settings.captions })
    }
}

# The shots of a job, each with its move in words (MoveEn for Grok, MoveVi for the window), and the video's shape.
# With a sample its moves are measured into $Logs (mau.trf).
function Get-RunPlan($Plan, [string]$Logs) {
    $settings = $Plan.Settings
    if (-not $Plan.Reference) {
        $shots = @(Get-DefaultShots $settings $Plan.Length)
        $aspect = Get-VideoAspect $Plan.Aspect
    } else {
        $info = Get-HubVideoInfo $Plan.Reference
        if ($info.Seconds -lt 1) { throw 'Video mẫu quá ngắn hoặc không đọc được.' }
        $saved = Read-ReferencePlan $Plan.Reference
        $cuts = if ($saved) { $saved.Cuts } else { Get-ReferenceCuts $Plan.Reference ([double]$settings.sceneThreshold) }
        $scenes = @(Get-SampleScenes ([Math]::Min($info.Seconds, [double]$settings.maxSeconds)) $cuts $(if ($saved) { $saved.Angles } else { @() }) $settings)
        $shots = @(Get-SampleShots $scenes $settings $Plan.Length)
        $motion = Save-ReferenceMotion $Plan.Reference $info $Logs
        foreach ($shot in $shots) { $shot | Add-Member -NotePropertyName Move -NotePropertyValue (Get-ReferenceMove $motion $shot.Start $shot.End) }
        $aspect = Get-VideoAspect $Plan.Aspect $info.Width $info.Height
    }
    foreach ($shot in $shots) {
        $text = Get-ShotMoveText $shot.Move $shot.Seconds $settings
        $shot | Add-Member -NotePropertyName MoveEn -NotePropertyValue $text.En
        $shot | Add-Member -NotePropertyName MoveVi -NotePropertyValue $text.Vi
    }
    [pscustomobject]@{ Shots = @($shots); Aspect = $aspect }
}

function Invoke-VideoRun($Job, [string]$OutRoot) {
    $script:Run = @{ Abort = $false }
    try { $plan = Test-VideoJob $Job } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 2 }
    $settings = $plan.Settings
    $slug = ConvertTo-Slug $plan.Product
    $folder = Join-Path $OutRoot ("{0}-{1}" -f [DateTime]::Now.ToString("yyyy-MM-dd_HH'h'mm'm'ss's'"), $slug)
    $logs = Join-Path $folder 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null

    # 1. The plan.
    try { [void](Get-HubFfmpeg); $runPlan = Get-RunPlan $plan $logs }
    catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }
    $shots = $runPlan.Shots; $aspect = $runPlan.Aspect; $total = $shots.Count
    $reshape = Test-PhotoShape $plan.Photo $aspect
    $angleIds = @($shots | ForEach-Object { $_.Angle } | Where-Object { $_ -ne 'as-photo' -or $reshape } | Select-Object -Unique)
    Write-Utf8 (Join-Path $logs 'ke-hoach.json') (ConvertTo-Json -InputObject @{ reference = $plan.Reference; aspect = $aspect; shots = $shots } -Depth 5)

    # 2. Key frames, all from the photo itself, all at once.
    $angles = @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json')).angles)
    $requests = @()
    if ($plan.Model) { $requests += [pscustomobject]@{ Id = 'nguoi-mau'; Label = 'Người mẫu giới thiệu'; Prompt = (New-IntroFramePrompt $plan.Product); Images = @($plan.Photo, $plan.Model); File = (Join-Path $folder 'khung-nguoi-mau.png') } }
    foreach ($id in $angleIds) {
        $angle = $angles | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $requests += [pscustomobject]@{ Id = $id; Label = [string]$angle.label; Prompt = (New-AngleFramePrompt $plan.Product $angle); Images = @($plan.Photo); File = (Join-Path $folder "khung-$id.png") }
    }
    Send-Event @{ kind = 'start'; folder = $folder; frames = $requests.Count; shots = $total; seconds = [Math]::Round(($shots | Measure-Object Seconds -Sum).Sum, 1); aspect = $aspect }
    foreach ($request in $requests) { Write-Utf8 (Join-Path $logs "khung-$($request.Id)-prompt.txt") $request.Prompt }
    $made = if ($requests.Count) { Invoke-CodexFrames $requests $aspect $folder ([int]$settings.codexParallel) } else { @{} }
    $frames = @{}
    for ($k = 0; $k -lt $requests.Count; $k++) {
        $request = $requests[$k]
        $event = @{ kind = 'frame'; index = $k; label = $request.Label; file = ''; ok = $true; message = '' }
        if ($made[$request.Id]) { $event.ok = $false; $event.message = "$($made[$request.Id]) Cảnh này bắt đầu từ ảnh sản phẩm." }
        else { $frames[$request.Id] = $request.File; $event.file = $request.File }
        Send-Event $event
    }

    # Captions: the English lines, written by Codex from the shots and the brand's own facts (script.ps1), before Grok
    # so a bad script is known early. Without them the video is made all the same.
    $lines = @()
    if ($plan.Captions -and -not $script:Run.Abort) {
        Write-Host '  [SCRIPT] English lines' -ForegroundColor Cyan
        try { $lines = @(Invoke-ScriptWriter $shots (Get-BrandFacts) $plan.Product ([double]($shots | Measure-Object Seconds -Sum).Sum) (Join-Path $logs 'kich-ban.json') 'voice') }
        catch { Send-Event @{ kind = 'warning'; message = "Chưa viết được lời cho phụ đề, video không có phụ đề: $($_.Exception.Message -replace '\s*\[CAUSE:\w+\]', '')" } }
    }

    # 3. Clips, one per shot: from its angle's frame (the first one from the model frame), else the photo.
    try { Start-ImageBridge (Get-ToolRoot) -NewSession } catch { Send-Event @{ kind = 'fatal'; message = $_.Exception.Message }; return 1 }
    $clips = @()
    for ($i = 1; $i -le $total -and -not $script:Run.Abort; $i++) {
        $shot = $shots[$i - 1]
        $raw = Join-Path $folder "clip-$i-grok.mp4"
        $person = $i -eq 1 -and $frames['nguoi-mau']
        $start = if ($person) { $frames['nguoi-mau'] } elseif ($frames[$shot.Angle]) { $frames[$shot.Angle] } else { $plan.Photo }
        $label = ($angles | Where-Object { $_.id -eq $shot.Angle } | Select-Object -First 1).label
        $event = @{ kind = 'clip'; index = $i; label = "$label, $(Format-Seconds ([Math]::Round($shot.Seconds, 1)))s, $($shot.MoveVi)"; file = ''; ok = $true; message = '' }
        $prompt = New-ClipPrompt $plan.Product $i $total ([int]$settings.grokSeconds) $shot.MoveEn ([bool]$person)
        Write-Utf8 (Join-Path $logs "clip-$i-prompt.txt") $prompt
        Write-Host "  [CLIP] $i/$total $($shot.Angle) $($shot.MoveVi)" -ForegroundColor Cyan
        try {
            [void](Invoke-GrokClip $prompt $start $raw @{ Seconds = [int]$settings.grokSeconds; Resolution = $plan.Resolution; Audio = $false; Aspect = $aspect; TimeoutSec = 900 })
            $clips += [pscustomobject]@{ Index = $i; Raw = $raw; File = (Join-Path $folder "clip-$i.mp4") }; $event.file = $raw
        } catch { $event.ok = $false; $event.message = $_.Exception.Message }
        Send-Event $event
    }

    # 4. One video: each clip cut to its shot plus the transition into the next, so the video keeps the planned length.
    # A clip that failed takes its cut with it: the next clip comes in by its own shot's transition.
    $ok = $false
    if ($clips.Count) {
        if ($clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = "Chỉ $($clips.Count)/$total cảnh tạo được; video ghép từ các cảnh đó." } }
        $final = Join-Path $folder "video-$slug.mp4"
        $fade = [double]$settings.fadeSeconds
        try {
            for ($k = 0; $k -lt $clips.Count; $k++) {
                Set-HubVideoCut $clips[$k].Raw ($shots[$clips[$k].Index - 1].Seconds + $(if ($k + 1 -lt $clips.Count) { $fade } else { 0 })) $clips[$k].File
            }
            $cuts = Get-ShotTransitions $shots $settings
            $into = @($clips | Select-Object -Skip 1 | ForEach-Object { $cuts[$_.Index - 2] })
            if ($clips.Count -gt 1) {
                $labels = @($clips | ForEach-Object { $shot = $shots[$_.Index - 1]; "$($shot.Angle) shot, camera: $($shot.MoveEn)" })
                try { $into = Select-ShotTransitions $plan.Product @($clips | ForEach-Object { $_.File }) $labels $into $settings $folder $logs }
                catch { Send-Event @{ kind = 'warning'; message = "Chưa chọn được chuyển cảnh theo hình, dùng cách chọn theo máy chạy: $($_.Exception.Message)" } }
            }
            # The shots alone (video-<product>-canh.mp4), then the captions (captions.ps1; the lines are timed on all the
            # shots, so only when every clip was made), then the user's brand intro/outro (brand.ps1) as the final one;
            # the outro comes after the captions, so it carries none. The lines also go out as video-<product>.srt.
            $stage = Join-Path $folder "video-$slug-canh.mp4"
            Join-ShotClips @($clips | ForEach-Object { $_.File }) $fade $stage $into
            if ($lines.Count -and $clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = 'Thiếu cảnh nên lời không còn khớp thời gian: video không có phụ đề.' } }
            elseif ($lines.Count) {
                try {
                    $captioned = Join-Path $folder "video-$slug-phu-de.mp4"
                    Add-VideoCaptions $stage $lines $captioned
                    Write-CaptionSrt $lines (Join-Path $folder "video-$slug.srt")
                    $stage = $captioned
                } catch { Send-Event @{ kind = 'warning'; message = "Chưa đốt được phụ đề, video không có: $($_.Exception.Message)" } }
            }
            $brand = Read-Brand
            if ($brand) {
                try { Add-BrandIntroOutro $stage $final $brand }
                catch { Copy-Item -LiteralPath $stage -Destination $final -Force; Send-Event @{ kind = 'warning'; message = "Chưa thêm được intro/outro, video không có: $($_.Exception.Message)" } }
            } else { Copy-Item -LiteralPath $stage -Destination $final -Force }
            # Music last, under the whole video (outro too): video-<product>.mp4 gets the sound, the silent one is kept
            # as video-<product>-khong-nhac.mp4.
            if ($plan.Music) {
                $silent = Join-Path $folder "video-$slug-khong-nhac.mp4"
                Move-Item -LiteralPath $final -Destination $silent -Force
                try { Add-VideoMusic $silent $plan.Music $final ([double]$settings.musicVolume) ([double]$settings.musicFadeIn) ([double]$settings.musicFadeOut) }
                catch { Copy-Item -LiteralPath $silent -Destination $final -Force; Send-Event @{ kind = 'warning'; message = "Chưa ghép được nhạc nền, video không có nhạc: $($_.Exception.Message)" } }
            }
            $out = Get-HubVideoInfo $final
            Send-Event @{ kind = 'final'; file = $final; seconds = [Math]::Round($out.Seconds, 1); width = $out.Width; height = $out.Height }
            $ok = $true
        } catch { Send-Event @{ kind = 'warning'; message = $_.Exception.Message } }
    }
    $stopped = if ($script:Run.Abort) { 'Dừng vì Grok/bridge cần người dùng xử lý (đăng nhập, hết lượt hoặc extension).' } else { '' }
    Send-Event @{ kind = 'done'; ok = $ok; folder = $folder; clips = $clips.Count; shots = $total; message = $stopped }
    if ($ok) { 0 } else { 1 }
}
