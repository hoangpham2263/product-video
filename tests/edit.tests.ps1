# Checks of src/edit.ps1 with ffmpeg on tiny generated clips (no AI): the music laid under a video.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/edit.tests.ps1     (also run by tests/edit.test.mjs)
# Prints one line per check; exits 1 when any fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'core/ai/common.ps1')
. (Join-Path $root 'src/ffmpeg.ps1')
. (Join-Path $root 'src/plan.ps1')
. (Join-Path $root 'src/edit.ps1')

$script:Failed = 0
function Assert-That([string]$Name, [scriptblock]$Check) {
    try { $ok = & $Check; $why = '' } catch { $ok = $false; $why = " ($($_.Exception.Message))" }
    if ($ok) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name$why" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("pv-edit-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $video = Join-Path $temp 'video.mp4'; $short = Join-Path $temp 'short.m4a'; $long = Join-Path $temp 'long.m4a'
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-f', 'lavfi', '-i', 'color=c=gray:s=160x240:r=30:d=4', '-pix_fmt', 'yuv420p', '-c:v', 'libx264', $video)) 'tạo được video thử'
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1.5', '-c:a', 'aac', $short)) 'tạo được nhạc thử'
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=9', '-c:a', 'aac', $long)) 'tạo được nhạc thử'
    $sound = { param($file) [regex]::IsMatch((Invoke-HubFfmpeg @('-hide_banner', '-i', $file)).Log, 'Stream #\S+.*Audio:') }
    foreach ($case in @(@('longer music is cut to the video', $long), @('shorter music is looped to the video', $short))) {
        $out = Join-Path $temp "out-$([guid]::NewGuid().ToString('N')).mp4"
        Add-VideoMusic $video $case[1] $out 0.8 0.5 1
        Assert-That "Music: $($case[0]), the picture kept, sound added" { [Math]::Abs((Get-HubVideoInfo $out).Seconds - 4) -lt 0.1 -and (& $sound $out) -and (Get-HubVideoInfo $out).Width -eq 160 }
    }
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:Failed) { Write-Host "$script:Failed check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
