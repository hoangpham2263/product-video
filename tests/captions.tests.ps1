# Checks of src/captions.ps1 (no AI): the .srt file, how captions wrap, and a burn on a tiny generated clip (ffmpeg).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/captions.tests.ps1     (also run by tests/captions.test.mjs)
# Prints one line per check; exits 1 when any fails. Scratch files go to workspace/temp/captions-test (removed after;
# -Keep leaves them, to look at a captioned frame).
param([switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'core/ai/common.ps1')
. (Join-Path $root 'src/ffmpeg.ps1')
. (Join-Path $root 'src/plan.ps1')
. (Join-Path $root 'src/brand.ps1')
. (Join-Path $root 'src/captions.ps1')

$script:Failed = 0
function Assert-That([string]$Name, [scriptblock]$Check) {
    try { $ok = & $Check; $why = '' } catch { $ok = $false; $why = " ($($_.Exception.Message))" }
    if ($ok) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name$why" }
}

$temp = Join-Path $root 'workspace/temp/captions-test'
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    # --- Write-CaptionSrt ---
    $lines = @(
        [pscustomobject]@{ start = 3.5; end = 5.25; text = 'Thứ hai: "giá", 1:1' }
        [pscustomobject]@{ start = 0; end = 1.2; text = 'First' }
        [pscustomobject]@{ start = 2; end = 2.5; text = '   ' }
        [pscustomobject]@{ start = 6; end = 6; text = 'zero length' }
        [pscustomobject]@{ start = 3661.0015; end = 3662; text = 'An hour in' }
    )
    $srt = Join-Path $temp 'a.srt'
    Write-CaptionSrt $lines $srt
    $bytes = [IO.File]::ReadAllBytes($srt)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $expected = "1`r`n00:00:00,000 --> 00:00:01,200`r`nFirst`r`n`r`n2`r`n00:00:03,500 --> 00:00:05,250`r`nThứ hai: `"giá`", 1:1`r`n`r`n3`r`n01:01:01,002 --> 01:01:02,000`r`nAn hour in`r`n"
    Assert-That 'SRT: UTF-8 without BOM' { -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) }
    Assert-That 'SRT: sorted by start, numbered from 1, HH:MM:SS,mmm, empty and zero-length lines skipped' { $text -ceq $expected }
    Assert-That 'Time: rounding and hours' { (Format-SrtTime 0.0004) -eq '00:00:00,000' -and (Format-SrtTime 59.9996) -eq '00:01:00,000' -and (Format-SrtTime 36000) -eq '10:00:00,000' }

    # --- Split-CaptionText ---
    Assert-That 'Wrap: short text is one row' { $r = @(Split-CaptionText 'Bàn gỗ sồi tự nhiên'); $r.Count -eq 1 -and $r[0] -eq 'Bàn gỗ sồi tự nhiên' }
    Assert-That 'Wrap: long text breaks between words, rows of at most 32' {
        $r = @(Split-CaptionText 'A solid oak table that seats six people comfortably')
        $r.Count -eq 2 -and ($r -join ' ') -eq 'A solid oak table that seats six people comfortably' -and -not ($r | Where-Object { $_.Length -gt 32 })
    }
    Assert-That 'Wrap: never more than 2 rows, no word lost, rows about even' {
        $words = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen'
        $r = @(Split-CaptionText $words)
        $r.Count -eq 2 -and ($r -join ' ') -eq $words -and [Math]::Abs($r[0].Length - $r[1].Length) -le 10
    }
    Assert-That 'Wrap: two rows are evened out, no word left alone' {
        $r = @(Split-CaptionText 'Ghế "Grenheim": gỗ sồi, 100% tự nhiên')
        $r.Count -eq 2 -and $r[1] -ne 'nhiên' -and [Math]::Abs($r[0].Length - $r[1].Length) -le 8
    }
    Assert-That 'Wrap: extra spaces dropped, empty text gives no rows' { (@(Split-CaptionText "  a   b `n c ") -join '|') -eq 'a b c' -and @(Split-CaptionText '  ').Count -eq 0 }

    # --- Add-VideoCaptions on a 3 s grey clip ---
    $clip = Join-Path $temp 'grey.mp4'
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-f', 'lavfi', '-i', 'color=c=gray:s=720x1280:d=3:r=30', '-f', 'lavfi', '-i', 'sine=f=440:d=3',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', $clip)) 'tạo được clip thử'
    $out = Join-Path $temp 'captioned.mp4'
    $burn = @(
        [pscustomobject]@{ start = 0.5; end = 1.5; text = 'Ghế "Grenheim": gỗ sồi, 100% tự nhiên' }
        [pscustomobject]@{ start = 1.8; end = 2.6; text = 'A long caption that needs to wrap onto a second row here' }
    )
    Add-VideoCaptions $clip $burn $out
    $before = Get-HubVideoInfo $clip; $after = Get-HubVideoInfo $out
    $log = (Invoke-HubFfmpeg @('-hide_banner', '-i', $out)).Log
    Assert-That 'Burn: output exists, 720x1280' { (Test-Path -LiteralPath $out) -and $after.Width -eq 720 -and $after.Height -eq 1280 }
    Assert-That 'Burn: yuv420p, sound kept' { $log -match 'Video: h264.*yuv420p' -and $log -match 'Audio: aac' }
    Assert-That 'Burn: same length (0.1 s)' { [Math]::Abs($after.Seconds - $before.Seconds) -le 0.1 }
    $frame = { param($at, $name)
        $png = Join-Path $temp $name
        Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-ss', $at, '-i', $out, '-frames:v', '1', $png)) 'lấy được khung'
        (Get-Item -LiteralPath $png).Length }
    $on = & $frame '1.0' 'frame-caption.png'; $off = & $frame '0.2' 'frame-plain.png'; $two = & $frame '2.2' 'frame-two-rows.png'
    # A flat grey frame compresses to almost nothing; text on a box does not.
    Assert-That "Burn: a frame inside a caption differs from one outside ($on vs $off bytes)" { $on -gt $off * 3 -and $two -gt $off * 3 }
    Assert-That 'Burn: nothing below 65% of the height (Reels/TikTok UI)' {
        $crop = Join-Path $temp 'bottom.png'
        Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-ss', '2.2', '-i', $out, '-frames:v', '1', '-vf', 'crop=iw:ih*0.35:0:ih*0.65', $crop)) 'cắt được khung'
        $plain = Join-Path $temp 'bottom-plain.png'
        Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-ss', '0.2', '-i', $out, '-frames:v', '1', '-vf', 'crop=iw:ih*0.35:0:ih*0.65', $plain)) 'cắt được khung'
        [Math]::Abs((Get-Item $crop).Length - (Get-Item $plain).Length) -lt 200
    }
    Assert-That 'Burn: a clip without sound stays without sound; no lines still makes a video' {
        $mute = Join-Path $temp 'mute.mp4'; $mute2 = Join-Path $temp 'mute-out.mp4'
        Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-f', 'lavfi', '-i', 'color=c=gray:s=360x640:d=1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', $mute)) 'tạo được clip thử'
        Add-VideoCaptions $mute @() $mute2
        $l = (Invoke-HubFfmpeg @('-hide_banner', '-i', $mute2)).Log
        $l -match 'Video: h264' -and $l -notmatch 'Audio:'
    }
} catch { $script:Failed++; Write-Host "FAIL (stopped) $($_.Exception.Message)" }
finally { if (-not $Keep) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } }

if ($script:Failed) { Write-Host "$($script:Failed) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
