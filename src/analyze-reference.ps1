# Phân tích video mẫu, for the window's analysis page (server.mjs, POST /api/analyze): how the sample is made, read the
# way the run reads it (plan.ps1): its scenes (its plan <video>.json if there is one, else ffmpeg's cuts), the angle and
# number of shots each scene becomes, the camera's move in it (vidstabdetect, src/motion.mjs) and one frame from the
# middle of it (a dissolve blurs its ends). No AI. Prints one line:
#   @@RESULT { ok, video, width, height, seconds, aspect, planned, note, shots: [{ index, start, seconds, angle, clips,
#   move: { panX, panY, zoom, vi }, thumb }], clips, maxShots, warnings }
param(
    [Parameter(Mandatory)][string]$Video,
    [Parameter(Mandatory)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding

foreach ($module in @('../core/ai/common.ps1', 'ffmpeg.ps1', 'plan.ps1')) {
    . (Join-Path $PSScriptRoot $module)
}

function Send-Result($Result) { Write-Output ('@@RESULT ' + (ConvertTo-Json -InputObject $Result -Compress -Depth 8)) }

try {
    if (-not (Test-Path -LiteralPath $Video -PathType Leaf)) { throw 'Không thấy video mẫu.' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    [void](Get-HubFfmpeg)
    $settings = Get-VideoSettings
    $info = Get-HubVideoInfo $Video
    if ($info.Seconds -lt 1) { throw 'Video mẫu quá ngắn hoặc không đọc được.' }

    $warnings = @()
    $saved = Read-ReferencePlan $Video
    $cuts = if ($saved) { $saved.Cuts } else { Get-ReferenceCuts $Video ([double]$settings.sceneThreshold) }
    $scenes = @(Get-SampleScenes ([Math]::Min($info.Seconds, [double]$settings.maxSeconds)) $cuts $(if ($saved) { $saved.Angles } else { @() }) $settings)
    if ($info.Seconds -gt [double]$settings.maxSeconds) { $warnings += "Chỉ lấy $($settings.maxSeconds) giây đầu." }
    # The shots as the run makes them at the sample's length; too many is a warning here, not a stop.
    $loose = $settings.PSObject.Copy(); $loose.maxShots = 100000
    $shots = @(Get-SampleShots $scenes $loose)
    if ($shots.Count -gt [int]$settings.maxShots) { $warnings += "Như mẫu thì ra $($shots.Count) cảnh, tối đa $($settings.maxShots): chọn độ dài ngắn hơn khi tạo video." }

    $motion = Save-ReferenceMotion $Video $info $OutDir
    $rows = foreach ($scene in $scenes) {
        $own = @($shots | Where-Object { $_.Scene -eq $scene.Index })
        $move = Get-ReferenceMove $motion $scene.Start $scene.End
        $thumb = Join-Path $OutDir ("canh-{0:00}.jpg" -f $scene.Index)
        $at = Format-Seconds ($scene.Start + ($scene.End - $scene.Start) / 2)
        $shot = Invoke-HubFfmpeg @('-y', '-hide_banner', '-ss', $at, '-i', $Video, '-map', '0:v:0', '-frames:v', '1', '-vf', 'scale=480:-2', '-q:v', '3', $thumb)
        if ($shot.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $thumb)) { $thumb = ''; $warnings += "Chưa lấy được hình cảnh $($scene.Index)." }
        [pscustomobject]@{
            index = $scene.Index; start = [Math]::Round($scene.Start, 2); seconds = [Math]::Round($scene.End - $scene.Start, 2)
            angle = [string]$own[0].Angle; clips = $own.Count
            move = [pscustomobject]@{ panX = $move.panX; panY = $move.panY; zoom = $move.zoom; vi = (ConvertTo-MoveText $move $settings).Vi }; thumb = $thumb
        }
    }
    Send-Result ([pscustomobject]@{
        ok = $true; video = $Video; width = $info.Width; height = $info.Height; seconds = [Math]::Round($info.Seconds, 2)
        aspect = (Get-VideoAspect 'auto' $info.Width $info.Height); planned = [bool]$saved; note = $(if ($saved) { $saved.Note } else { '' })
        shots = @($rows); clips = $shots.Count; maxShots = [int]$settings.maxShots; warnings = $warnings
    })
    exit 0
} catch {
    Send-Result ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
    exit 1
}
