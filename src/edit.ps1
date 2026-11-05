# Editing a run's clips with ffmpeg (ffmpeg.ps1): each Grok clip cut to its shot, then all joined by their transitions;
# last, the music under the whole video.

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

# The music track under the whole video: from its start, cut to the video's length (looped when shorter), fading in over
# $FadeIn and out over the last $FadeOut seconds, at $Volume. The picture is copied as it is; sound AAC, ready to post.
function Add-VideoMusic([string]$Video, [string]$Music, [string]$Output, [double]$Volume = 0.8, [double]$FadeIn = 1, [double]$FadeOut = 2) {
    $seconds = (Get-HubVideoInfo $Video).Seconds
    if ($seconds -le 0) { throw "Không đọc được độ dài video: $Video" }
    $out = [Math]::Max(0.0, $seconds - $FadeOut)
    $audio = "[1:a]atrim=0:$(Format-Seconds $seconds),asetpts=PTS-STARTPTS,afade=t=in:d=$(Format-Seconds $FadeIn),afade=t=out:st=$(Format-Seconds $out):d=$(Format-Seconds $FadeOut),volume=$(Format-Seconds $Volume)[a]"
    $arguments = @('-y', '-hide_banner', '-i', $Video, '-stream_loop', '-1', '-i', $Music, '-filter_complex', $audio, '-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-t', (Format-Seconds $seconds), '-movflags', '+faststart', $Output)
    Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments) 'ghép được nhạc'
}
