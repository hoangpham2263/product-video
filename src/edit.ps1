# Editing a run's clips with ffmpeg (ffmpeg.ps1): each Grok clip cut to its shot, then all joined by their transitions.

# The first $Seconds of a clip at its real speed, without sound, at $Fps.
function Set-HubVideoCut([string]$Video, [double]$Seconds, [string]$Output, [int]$Fps = 30) {
    Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-i', $Video, '-an', '-t', (Format-Seconds $Seconds), '-filter:v', "fps=$Fps", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', $Output)) 'cắt được clip'
}

# The clips as one video, each going into the next over $Fade seconds by its transition ($Transitions[k - 1] into
# clip k, ffmpeg xfade names; fade when none); a clip of another shape fills the first one's frame (cropped). All at
# $Fps (Set-HubVideoCut).
function Join-ShotClips([string[]]$Files, [double]$Fade, [string]$Output, [string[]]$Transitions = @(), [int]$Fps = 30) {
    $first = Get-HubVideoInfo $Files[0]
    $w = $first.Width - ($first.Width % 2); $h = $first.Height - ($first.Height % 2)
    $inputs = @(); $chains = @()
    for ($k = 0; $k -lt $Files.Count; $k++) {
        $inputs += @('-i', $Files[$k])
        $chains += "[${k}:v]fps=$Fps,scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h},setsar=1,format=yuv420p,settb=AVTB[v$k]"
    }
    $label = 'v0'; $length = $first.Seconds
    for ($k = 1; $k -lt $Files.Count; $k++) {
        $transition = if ($k - 1 -lt $Transitions.Count -and $Transitions[$k - 1]) { $Transitions[$k - 1] } else { 'fade' }
        $chains += "[$label][v$k]xfade=transition=${transition}:duration=$(Format-Seconds $Fade):offset=$(Format-Seconds ($length - $Fade))[j$k]"
        $length += (Get-HubVideoInfo $Files[$k]).Seconds - $Fade
        $label = "j$k"
    }
    # xfade hands out 4:4:4, which phones do not play: back to 4:2:0.
    $chains[-1] = $chains[-1] -replace '\[(\w+)\]$', ',format=yuv420p[$1]'
    $arguments = @('-y', '-hide_banner') + $inputs + @('-filter_complex', ($chains -join ';'), '-map', "[$label]", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', '-an', $Output)
    Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments) 'ghép được video'
}
