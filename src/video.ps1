# Product Video's run: a short film of the product photo's room, made of short shots.
#   1. Plan (plan.ps1): the shots, each with an angle and a camera move; from the sample video's way of filming when
#      there is one (its cuts, planned angles and measured moves), else data/video.json defaultShots.
#   2. Key frames (Codex CLI, codexParallel at once): the photo's room seen from each angle the shots use, and with a
#      model photo the model presenting the product. Tried 04/11/2026: Grok's own redrawn angles changed the product's
#      size against the room from one angle to the next (a coffee table grew taller than the sofa seat); Codex's kept it.
#   3. Clips (Grok video, 6 s): one per shot, from its angle's frame, the move as words.
#   4. One video: the first Seconds of each clip at its real speed, dissolving into the next over fadeSeconds (the user
#      found a straight cut to another angle too sudden, 04/11/2026).
# Output: workspace/output/<time>-<product>/: khung-<angle>.png, clip-<i>-grok.mp4, clip-<i>.mp4, video-<product>.mp4,
# logs/ (ke-hoach.json, prompts). The window follows the run through @@EVENT lines (start, frame, clip, final, warning,
# done, fatal).

function Send-Event([hashtable]$Event) { Write-Host ('@@EVENT ' + (ConvertTo-Json -InputObject $Event -Compress -Depth 6)) }
function ConvertTo-Slug([string]$Text) {
    $plain = ($Text.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace 'đ', 'd' -replace 'Đ', 'D'
    $slug = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if ($slug) { $slug } else { 'san-pham' }
}
function Get-ErrorCause([string]$Message) { if ($Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { 'UNKNOWN' } }

# The job the window sends, checked: { product, photo, model?, reference?, length, aspect, resolution }. Length: seconds
# (one of lengths; 0 is as long as the sample, or defaultLength without one). Aspect: one of aspects (auto: the
# sample's shape, else 2:3).
function Test-VideoJob($Job) {
    $settings = Get-VideoSettings
    if (-not ([string]$Job.product).Trim()) { throw 'Điền tên sản phẩm.' }
    if (-not $Job.photo -or -not (Test-Path -LiteralPath ([string]$Job.photo) -PathType Leaf)) { throw 'Chưa có ảnh sản phẩm.' }
    if ($Job.model -and -not (Test-Path -LiteralPath ([string]$Job.model) -PathType Leaf)) { throw 'Không thấy ảnh người mẫu.' }
    if ($Job.reference -and -not (Test-Path -LiteralPath ([string]$Job.reference) -PathType Leaf)) { throw 'Không thấy video mẫu.' }
    if (@($settings.resolutions) -notcontains [string]$Job.resolution) { throw "Độ phân giải không hỗ trợ: $($Job.resolution)." }
    $aspect = if ($Job.aspect) { [string]$Job.aspect } else { 'auto' }
    if (@($settings.aspects) -notcontains $aspect) { throw "Khổ video không hỗ trợ: $aspect." }
    $length = [int]$Job.length
    if ($length -and @($settings.lengths) -notcontains $length) { throw "Độ dài video $(@($settings.lengths) -join ', ') giây, không phải $length." }
    if (-not $length -and -not $Job.reference) { $length = [int]$settings.defaultLength }
    [pscustomobject]@{
        Product = ([string]$Job.product).Trim(); Photo = [string]$Job.photo; Model = [string]$Job.model; Reference = [string]$Job.reference
        Length = $length; Aspect = $aspect; Resolution = [string]$Job.resolution; Settings = $settings
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

# Width / height of the photo against the video's shape: true when they differ enough to need an as-photo frame of
# the video's shape (Grok's video keeps its start image's shape, tried 04/11/2026).
function Test-PhotoShape([string]$Photo, [string]$Aspect) {
    $info = Get-HubVideoInfo $Photo
    $want = switch ($Aspect) { '2:3' { 2 / 3 } '3:2' { 3 / 2 } default { 1 } }
    [Math]::Abs([Math]::Log(($info.Width / [double]$info.Height) / $want)) -gt 0.15
}

# The size Codex is asked for.
function Get-CodexShape([string]$Aspect) {
    switch ($Aspect) { '2:3' { 'portrait 2:3 (1024x1536)' } '3:2' { 'landscape 3:2 (1536x1024)' } default { 'square 1:1 (1024x1024)' } }
}

# Key frames by Codex CLI, $Parallel at once: each is its own codex process saving a PNG in $Folder.
#   $Frames: { Id, Prompt, Images, File }. Returns @{ Id = error message, '' when made }.
function Invoke-CodexFrames($Frames, [string]$Aspect, [string]$Folder, [int]$Parallel) {
    $shape = "`nOUTPUT SHAPE: $(Get-CodexShape $Aspect)."
    $ai = Join-Path (Get-ToolRoot) 'core/ai/ai.ps1'
    $jobs = @(); $result = @{}
    foreach ($frame in $Frames) {
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $Parallel) { Start-Sleep -Seconds 3 }
        Write-Host "  [FRAME] $($frame.Id)" -ForegroundColor Cyan
        $jobs += Start-Job -Name $frame.Id -ArgumentList $ai, ($frame.Prompt + $shape), $frame.Images, $frame.File, $Folder -ScriptBlock {
            param($ai, $prompt, $images, $file, $folder)
            . $ai
            try { [void](Invoke-HubAI -Kind image -Ai codex -Prompt $prompt -Images $images -Output $file -Options @{ WorkDir = $folder; TimeoutSec = 900 }); '' }
            catch { $_.Exception.Message }
        }
    }
    $jobs | Wait-Job | Out-Null
    foreach ($job in $jobs) {
        $message = [string](Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1)
        $file = ($Frames | Where-Object { $_.Id -eq $job.Name } | Select-Object -First 1).File
        $result[$job.Name] = if (Test-Path -LiteralPath $file) { '' } elseif ($message) { $message } else { 'Codex không trả về ảnh.' }
    }
    $jobs | Remove-Job -Force
    $result
}

# One Grok video, tried again once when Grok was busy or slow. A sign-in, quota or bridge problem stops the run.
function Invoke-GrokClip([string]$Prompt, [string]$Image, [string]$Output, [hashtable]$Options) {
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-HubAI -Kind video -Ai 'grok' -Prompt $Prompt -Images @($Image) -Output $Output -Options $Options }
        catch {
            $cause = Get-ErrorCause $_.Exception.Message
            if ($cause -in @('QUOTA', 'AUTH', 'BRIDGE')) { $script:Run.Abort = $true }
            if ($attempt -ge 2 -or $cause -notin @('BUSY', 'AI_TIMEOUT', 'NETWORK')) { throw }
            Write-Host '  [RETRY] Grok video, attempt 2/2' -ForegroundColor Yellow
        }
    }
}

# The first $Seconds of a clip at its real speed, without sound, at $Fps.
function Set-HubVideoCut([string]$Video, [double]$Seconds, [string]$Output, [int]$Fps = 30) {
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-an', '-t', (Format-Seconds $Seconds), '-filter:v', "fps=$Fps", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', $Output)) 'cắt được clip'
}

# The clips as one video, each dissolving into the one before over $Fade seconds; a clip of another shape fills the
# first one's frame (cropped). All at $Fps (Set-HubVideoCut).
function Join-ShotClips([string[]]$Files, [double]$Fade, [string]$Output, [int]$Fps = 30) {
    $first = Get-HubVideoInfo $Files[0]
    $w = $first.Width - ($first.Width % 2); $h = $first.Height - ($first.Height % 2)
    $inputs = @(); $chains = @()
    for ($k = 0; $k -lt $Files.Count; $k++) {
        $inputs += @('-i', $Files[$k])
        $chains += "[${k}:v]fps=$Fps,scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h},setsar=1,format=yuv420p,settb=AVTB[v$k]"
    }
    $label = 'v0'; $length = $first.Seconds
    for ($k = 1; $k -lt $Files.Count; $k++) {
        $chains += "[$label][v$k]xfade=transition=fade:duration=$(Format-Seconds $Fade):offset=$(Format-Seconds ($length - $Fade))[j$k]"
        $length += (Get-HubVideoInfo $Files[$k]).Seconds - $Fade
        $label = "j$k"
    }
    # xfade hands out 4:4:4, which phones do not play: back to 4:2:0.
    $chains[-1] = $chains[-1] -replace '\[(\w+)\]$', ',format=yuv420p[$1]'
    $arguments = @('-y', '-hide_banner') + $inputs + @('-filter_complex', ($chains -join ';'), '-map', "[$label]", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', '-an', $Output)
    Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments) 'ghép được video'
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

    # 4. One video: each clip cut to its shot plus the dissolve into the next, so the video keeps the planned length.
    $ok = $false
    if ($clips.Count) {
        if ($clips.Count -lt $total) { Send-Event @{ kind = 'warning'; message = "Chỉ $($clips.Count)/$total cảnh tạo được; video ghép từ các cảnh đó." } }
        $final = Join-Path $folder "video-$slug.mp4"
        $fade = [double]$settings.fadeSeconds
        try {
            for ($k = 0; $k -lt $clips.Count; $k++) {
                Set-HubVideoCut $clips[$k].Raw ($shots[$clips[$k].Index - 1].Seconds + $(if ($k + 1 -lt $clips.Count) { $fade } else { 0 })) $clips[$k].File
            }
            Join-ShotClips @($clips | ForEach-Object { $_.File }) $fade $final
            $out = Get-HubVideoInfo $final
            Send-Event @{ kind = 'final'; file = $final; seconds = [Math]::Round($out.Seconds, 1); width = $out.Width; height = $out.Height }
            $ok = $true
        } catch { Send-Event @{ kind = 'warning'; message = $_.Exception.Message } }
    }
    $stopped = if ($script:Run.Abort) { 'Dừng vì Grok/bridge cần người dùng xử lý (đăng nhập, hết lượt hoặc extension).' } else { '' }
    Send-Event @{ kind = 'done'; ok = $ok; folder = $folder; clips = $clips.Count; shots = $total; message = $stopped }
    if ($ok) { 0 } else { 1 }
}
