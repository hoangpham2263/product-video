# The plan of a video: its shots, each a short piece (at most shotSeconds) with an angle of data/angles.json and a
# camera move. Grok keeps a product true for its first 2-3 seconds and then drifts (tried 04/11/2026: 15 s clips bent
# the product; pieces of 2.5 s from 6 s clips looked right), so every shot is the start of its own Grok clip.
#   With a sample video (video mẫu), only how it is made is learnt, never its look: where it cuts (its plan
#   <video>.json when there is one, else ffmpeg's scene cuts), each scene's angle (from the plan) and how the camera
#   moves (vidstabdetect, src/motion.mjs). Each scene is cut into pieces; a piece without a planned angle takes the next
#   one of data/video.json angles.
#   Without one: data/video.json defaultShots in turn, as many as the length needs.
# Used by the run (video.ps1) and the analysis page (analyze-reference.ps1). No AI here.

function Get-ToolRoot { Split-Path $PSScriptRoot -Parent }
function Read-JsonFile([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
function Format-Seconds([double]$Value) { $Value.ToString('0.###', $script:Invariant) }
# data/video.json, with the user's own choices when they saved some: the transitions and angles not to use
# (workspace/lua-chon.json { bannedTransitions, bannedAngles }, from the window's Hiệu ứng and Góc máy pages; an update
# keeps workspace/).
# -Defaults: data/video.json alone (the tests, which must not depend on this machine's choices).
function Get-VideoSettings([switch]$Defaults) {
    $settings = Read-JsonFile (Join-Path (Get-ToolRoot) 'data/video.json')
    $own = Join-Path (Get-ToolRoot) 'workspace/lua-chon.json'
    if (-not $Defaults -and (Test-Path -LiteralPath $own -PathType Leaf)) {
        $choices = Read-JsonFile $own
        foreach ($key in 'bannedTransitions', 'bannedAngles') { if ($null -ne $choices.$key) { $settings.$key = @($choices.$key) } }
    }
    $settings
}
function Get-AngleIds { @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/angles.json')).angles | ForEach-Object { $_.id }) }

# The angles shots may take turns through: the settings' angles the user has not switched off (all others of
# data/angles.json when every one of those is off).
function Get-TurnAngles($Settings) {
    $off = @($Settings.bannedAngles)
    $turns = @($Settings.angles | Where-Object { $off -notcontains $_ })
    if (-not $turns.Count) { $turns = @(Get-AngleIds | Where-Object { $off -notcontains $_ -and $_ -ne 'as-photo' }) }
    if (-not $turns.Count) { throw 'Mọi góc máy đều đang tắt: bật lại ít nhất một góc ở trang Góc máy.' }
    $turns
}

# The video's shape. Codex draws only 2:3, 3:2 and 1:1 and Grok's video keeps its start image's shape, so these are the
# only three. auto: the sample's (nearest), else 2:3.
function Get-VideoAspect([string]$Choice, [int]$Width = 0, [int]$Height = 0) {
    if ($Choice -and $Choice -ne 'auto') { return $Choice }
    if (-not $Width -or -not $Height) { return '2:3' }
    $ratio = $Width / [double]$Height
    if ($ratio -lt 0.8) { '2:3' } elseif ($ratio -gt 1.25) { '3:2' } else { '1:1' }
}

# ----- The sample -----

# Where the sample changes scene (seconds), from ffmpeg's scene score between frames half a second apart: a dissolve
# changes little from one frame to the next and reads as no cut (tried 04/11/2026: 0.03 at most, frame by frame).
function Get-ReferenceCuts([string]$Video, [double]$Threshold) {
    $log = (Invoke-HubFfmpeg @('-hide_banner', '-i', $Video, '-map', '0:v:0', '-an', '-filter:v', "fps=2,select='gt(scene,$(Format-Seconds $Threshold))',showinfo", '-f', 'null', '-')).Log
    @([regex]::Matches($log, 'pts_time:([\d.]+)') | ForEach-Object { [double]::Parse($_.Groups[1].Value, $script:Invariant) })
}

# The plan of a sample (<video>.json, written by the analysis page or kept in the library): { note?, shots: [{ start,
# angle }] }, start in seconds, angle an id of data/angles.json. None: $null.
function Read-ReferencePlan([string]$Video) {
    $file = "$Video.json"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $plan = Read-JsonFile $file
    $ids = Get-AngleIds
    $shots = @($plan.shots | Sort-Object { [double]$_.start })
    foreach ($shot in $shots) { if ($ids -notcontains [string]$shot.angle) { throw "Kế hoạch của video mẫu có góc lạ: $($shot.angle)." } }
    [pscustomobject]@{ Note = [string]$plan.note; Cuts = @($shots | Select-Object -Skip 1 | ForEach-Object { [double]$_.start }); Angles = @($shots | ForEach-Object { [string]$_.angle }) }
}

# The sample's scenes up to $End: between the cuts kept (a scene shorter than minShot joins the one before).
#   { Index, Start, End, Angle } (Angle: the plan's, '' when none)
function Get-SampleScenes([double]$End, [double[]]$Cuts, [string[]]$Angles, $Settings) {
    $bounds = @(0.0)
    foreach ($cut in ($Cuts | Sort-Object)) {
        if ($cut - $bounds[-1] -ge [double]$Settings.minShot -and $End - $cut -ge [double]$Settings.minShot) { $bounds += $cut }
    }
    $bounds += $End
    @(for ($s = 0; $s -lt $bounds.Count - 1; $s++) {
        [pscustomobject]@{ Index = $s + 1; Start = $bounds[$s]; End = $bounds[$s + 1]; Angle = $(if ($s -lt $Angles.Count) { [string]$Angles[$s] } else { '' }) }
    })
}

# The shots of a sample: each scene cut into equal pieces of at most shotSeconds of the video. $Length (seconds, 0: as
# the sample) stretches every scene alike. Angle: the plan's for a scene's first piece; the others take turns through
# the settings' angles, never the one just before nor (last piece of a scene) the one planned next; the video opens
# as-photo. An angle the user switched off (bannedAngles) is never used, planned or not: the next one in turn instead.
#   { Index, Scene, Start, End (in the sample), Seconds (in the video), Angle }
function Get-SampleShots($Scenes, $Settings, [double]$Length = 0) {
    $Scenes = @($Scenes)  # one scene comes as one object, which has no Count in Windows PowerShell 5.1
    $end = $Scenes[-1].End
    $stretch = if ($Length -gt 0) { $Length / $end } else { 1 }
    $off = @($Settings.bannedAngles)
    $turns = Get-TurnAngles $Settings; $turn = 0
    $opening = if ($off -notcontains 'as-photo') { 'as-photo' } else { $turns[$turn++] }
    $shots = @(); $previous = ''
    for ($s = 0; $s -lt $Scenes.Count; $s++) {
        $scene = $Scenes[$s]
        $planned = if ($scene.Angle -and $off -notcontains $scene.Angle) { $scene.Angle } else { '' }
        $source = $scene.End - $scene.Start
        $count = [Math]::Ceiling($source * $stretch / [double]$Settings.shotSeconds - 0.001)
        $after = if ($s + 1 -lt $Scenes.Count) { $Scenes[$s + 1].Angle } else { '' }
        for ($p = 0; $p -lt $count; $p++) {
            $avoid = if ($p -eq $count - 1) { $after } else { '' }
            $angle = if ($p -eq 0 -and $planned) { $planned }
                     elseif ($shots.Count -eq 0) { $opening }
                     else { do { $next = $turns[$turn++ % $turns.Count] } while (($next -eq $previous -or $next -eq $avoid) -and $turns.Count -gt 2); $next }
            $shots += [pscustomobject]@{
                Index = $shots.Count + 1; Scene = $scene.Index; Start = $scene.Start + $p * $source / $count; End = $scene.Start + ($p + 1) * $source / $count
                Seconds = $source * $stretch / $count; Angle = $angle
            }
            $previous = $angle
        }
    }
    Assert-ShotCount $shots.Count $Settings
    $shots
}

# Without a sample: defaultShots in turn, each with its own move, $Length seconds in all. A shot whose angle the user
# switched off keeps its move and takes the next angle in turn (never the one just before).
#   { Index, Seconds, Angle, Move: { panX, panY, zoom } }
function Get-DefaultShots($Settings, [double]$Length) {
    $count = [Math]::Ceiling($Length / [double]$Settings.shotSeconds - 0.001)
    Assert-ShotCount $count $Settings
    $list = @($Settings.defaultShots)
    $off = @($Settings.bannedAngles)
    $turns = Get-TurnAngles $Settings; $turn = 0; $previous = ''
    @(for ($i = 0; $i -lt $count; $i++) {
        $d = $list[$i % $list.Count]
        $angle = [string]$d.angle
        if ($off -contains $angle) { do { $angle = $turns[$turn++ % $turns.Count] } while ($angle -eq $previous -and $turns.Count -gt 1) }
        $previous = $angle
        [pscustomobject]@{ Index = $i + 1; Seconds = $Length / $count; Angle = $angle; Move = [pscustomobject]@{ panX = [double]$d.panX; panY = [double]$d.panY; zoom = [double]$d.zoom } }
    })
}

function Assert-ShotCount([int]$Count, $Settings) {
    if ($Count -gt [int]$Settings.maxShots) { throw "Video cần $Count cảnh, tối đa $($Settings.maxShots). Chọn độ dài ngắn hơn hoặc video mẫu ngắn hơn." }
}

# ----- Camera moves -----

# The camera's move over the whole sample, measured once: vidstabdetect at 5 frames a second (a slow move shifts less
# than a pixel from one frame to the next and would read as still), 720 wide. Writes mau.trf into $Folder.
function Save-ReferenceMotion([string]$Video, $Info, [string]$Folder) {
    $height = [Math]::Round(720 * $Info.Height / $Info.Width / 2) * 2
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-map', '0:v:0', '-an', '-filter:v', 'fps=5,scale=720:-2,vidstabdetect=shakiness=8:accuracy=15:stepsize=4:result=mau.trf', '-f', 'null', '-') $Folder) 'đo được chuyển động của video mẫu'
    [pscustomobject]@{ File = Join-Path $Folder 'mau.trf'; Width = 720; Height = $height; Fps = 5 }
}

# The move from $Start to $End seconds of the sample (src/motion.mjs): { panX, panY, zoom }.
function Get-ReferenceMove($Motion, [double]$Start, [double]$End) {
    $out = & node (Join-Path $PSScriptRoot 'motion.mjs') $Motion.File $Motion.Width $Motion.Height $Motion.Fps (Format-Seconds $Start) (Format-Seconds $End) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return [pscustomobject]@{ panX = 0; panY = 0; zoom = 1 } }
    $out | ConvertFrom-Json
}

# A move in words, with how far it goes: English for Grok, Vietnamese for the window. The picture sliding one way means
# the camera went the other; growing means it pushed in. Capped (maxZoom, maxPan): tried 04/11/2026, a sample walking
# into the next room told only as "clearly pushes in" sent Grok around the table, into a room of its own.
function ConvertTo-MoveText($Move, $Settings) {
    $en = @(); $vi = @()
    $cap = { param($v, $most) [Math]::Max(-$most, [Math]::Min($most, $v)) }
    $x = & $cap ([double]$Move.panX) ([double]$Settings.maxPan); $y = & $cap ([double]$Move.panY) ([double]$Settings.maxPan)
    $z = [double]$Move.zoom
    $z = [Math]::Max(1 / [double]$Settings.maxZoom, [Math]::Min([double]$Settings.maxZoom, $z))
    $percent = { param($v) [int][Math]::Round(100 * $v) }
    if ($z -ge 1.04) { $en += "the camera slowly pushes in (dolly forward) so the product looks about $(& $percent ($z - 1))% larger by the end"; $vi += 'đẩy vào' }
    elseif ($z -le 0.96) { $en += "the camera slowly pulls back (dolly out) so the product looks about $(& $percent (1 - $z))% smaller by the end"; $vi += 'kéo ra' }
    if ([Math]::Abs($x) -ge 0.03) { $side = if ($x -lt 0) { 'right' } else { 'left' }; $en += "the camera slowly slides to the $side (truck), about $(& $percent ([Math]::Abs($x)))% of the frame width"; $vi += "trượt $(if ($x -lt 0) { 'phải' } else { 'trái' })" }
    if ([Math]::Abs($y) -ge 0.03) { $up = $y -gt 0; $en += "the camera slowly $(if ($up) { 'rises' } else { 'lowers' }) (pedestal), about $(& $percent ([Math]::Abs($y)))% of the frame height"; $vi += $(if ($up) { 'nâng lên' } else { 'hạ xuống' }) }
    if (-not $en.Count) { $en += 'the camera holds almost still, a locked-off shot with only a faint drift'; $vi += 'đứng yên' }
    [pscustomobject]@{ En = ($en -join ' while '); Vi = ($vi -join ', ') }
}

# A shot's move for Grok: the move over the shot, spread over the whole Grok clip, so that its first Seconds (the part
# kept, at real speed) travel what the shot should. Capped like any move.
function Get-ShotMoveText($Move, [double]$Seconds, $Settings) {
    $scale = [double]$Settings.grokSeconds / [Math]::Max(0.5, $Seconds)
    $spread = [pscustomobject]@{ panX = [double]$Move.panX * $scale; panY = [double]$Move.panY * $scale; zoom = [Math]::Pow([Math]::Max(0.01, [double]$Move.zoom), $scale) }
    ConvertTo-MoveText $spread $Settings
}
