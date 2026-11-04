# Captions (subtitles) on a finished video: an .srt file to upload next to it, and the same lines burnt into the
# picture with ffmpeg drawtext (ffmpeg.ps1), for platforms that ignore subtitle files.
# A line is { start, end, text } in seconds. Burnt captions sit centred, in white on the brand green (#103e2e) at 75%,
# the bottom of the block around 62% of the height: the bottom 35% of a 9:16 frame is under Reels/TikTok's buttons.
# Sizes are measured on a 720x1280 frame and scaled with the video's height, as in brand.ps1.
# Fonts and texts are copied into a work folder and ffmpeg runs there (as brand.ps1 does), so the filter never holds
# a C: path, and a caption's quotes, colons or commas never need escaping (textfile=, expansion=none).

# The app loads this after brand.ps1 (and so after ffmpeg.ps1 and plan.ps1); a test loading it alone gets them here.
if (-not (Get-Command ConvertTo-CliArgument -ErrorAction SilentlyContinue)) { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'core/ai/common.ps1') }
if (-not (Get-Command Invoke-HubFfmpeg -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ffmpeg.ps1') }
if (-not (Get-Command Format-Seconds -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'plan.ps1') }
if (-not $script:BrandFonts) { . (Join-Path $PSScriptRoot 'brand.ps1') }

$script:CaptionStyle = @{
    Font      = 'light'   # a $script:BrandFonts kind (brand.ps1): the same face as the outro's lines
    FontSize  = 34        # on a 1280-high frame
    Color     = 'white'
    Box       = '0x103e2e@0.75'
    BoxBorder = 14        # padding around each row, on a 1280-high frame
    Bottom    = 0.62      # bottom of the caption block, share of the height (UI covers below 0.65)
    Width     = 32        # characters per row before wrapping
    MaxRows   = 2
    Fade      = 0.15      # seconds of fade in and out
}

# The lines worth showing: text kept (trimmed), end after start, in order of start.
function Get-CaptionLines($Lines) {
    @(@($Lines) | Where-Object { $_ -and ([string]$_.text).Trim() -and [double]$_.end -gt [double]$_.start } |
        ForEach-Object { [pscustomobject]@{ start = [Math]::Max(0.0, [double]$_.start); end = [double]$_.end; text = ([string]$_.text).Trim() } } |
        Sort-Object start)
}

# HH:MM:SS,mmm, as SRT wants it.
function Format-SrtTime([double]$Seconds) {
    $ms = [long][Math]::Round([Math]::Max(0.0, $Seconds) * 1000)
    '{0:00}:{1:00}:{2:00},{3:000}' -f [Math]::Floor($ms / 3600000), [Math]::Floor(($ms % 3600000) / 60000), [Math]::Floor(($ms % 60000) / 1000), ($ms % 1000)
}

# A caption as at most $MaxRows rows of about $Width characters, broken between words, the rows of even length (a
# greedy wrap leaves one word alone on the last row). When the words need more rows, the text is still split into
# $MaxRows even rows (longer than $Width, never cut short): a caption that loses words says something else.
function Split-CaptionText([string]$Text, [int]$Width = 32, [int]$MaxRows = 2) {
    $words = @(([string]$Text).Trim() -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { return @() }
    $rows = [Collections.Generic.List[string]]::new(); $row = ''
    foreach ($word in $words) {
        if (-not $row) { $row = $word }
        elseif (($row.Length + 1 + $word.Length) -le $Width) { $row += " $word" }
        else { $rows.Add($row); $row = $word }
    }
    $rows.Add($row)
    if ($rows.Count -le 1) { return @($rows) }
    # Cut at word gaps, each row taking its even share of the characters.
    $count = [Math]::Min($rows.Count, $MaxRows)
    $total = ($words -join ' ').Length; $result = @(); $row = ''; $left = $count
    for ($i = 0; $i -lt $words.Count; $i++) {
        $target = ($total - (($result | ForEach-Object { $_.Length + 1 }) | Measure-Object -Sum).Sum) / $left
        $next = if ($row) { "$row $($words[$i])" } else { $words[$i] }
        if ($row -and $left -gt 1 -and [Math]::Abs($next.Length - $target) -gt [Math]::Abs($row.Length - $target)) {
            $result += $row; $left--; $row = $words[$i]
        } else { $row = $next }
    }
    $even = @($result + $row)
    # Evening out may push a row past $Width when the words only just fit; the greedy rows are right then.
    if ($rows.Count -le $MaxRows -and ($even | Where-Object { $_.Length -gt $Width -and $_.Contains(' ') })) { return @($rows) }
    $even
}

# An .srt file of the lines (UTF-8 without BOM, which every player and upload form reads).
function Write-CaptionSrt($Lines, [string]$Path) {
    $blocks = @(); $n = 0
    foreach ($line in (Get-CaptionLines $Lines)) {
        $n++
        $blocks += "$n`r`n$(Format-SrtTime $line.start) --> $(Format-SrtTime $line.end)`r`n$($line.text -replace '\r?\n', "`r`n")`r`n"
    }
    $folder = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    if ($folder) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ($blocks -join "`r`n"), [Text.UTF8Encoding]::new($false))
}

# The lines burnt into the video. $Style: a hashtable overriding any of $script:CaptionStyle's keys.
# Sound is copied as it is when there is some; the picture is H.264 yuv420p, ready to post.
function Add-VideoCaptions([string]$Video, $Lines, [string]$Output, $Style = $null) {
    $look = $script:CaptionStyle.Clone()
    if ($Style) { foreach ($key in @($Style.Keys)) { $look[$key] = $Style[$key] } }
    $info = Get-HubVideoInfo $Video
    $h = $info.Height
    $y = { param($v) [int][Math]::Round([double]$v * $h / 1280) }
    $size = & $y $look.FontSize; $border = [Math]::Max(2, (& $y $look.BoxBorder))
    # Rows sit one under the other with their boxes just touching (two see-through boxes overlapping show a darker band).
    $pitch = [int][Math]::Round($size * 1.25) + 2 * $border
    $bottom = [int][Math]::Round([double]$look.Bottom * $h)
    $fade = [double]$look.Fade
    $work = Join-Path ([IO.Path]::GetTempPath()) "captions-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $utf8 = [Text.UTF8Encoding]::new($false)
        $font = $script:BrandFonts[$look.Font] | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $font) { throw 'Không tìm thấy font cho phụ đề.' }
        Copy-Item -LiteralPath $font -Destination (Join-Path $work 'caption.ttf')
        $filters = @()
        $k = 0
        foreach ($line in (Get-CaptionLines $Lines)) {
            $rows = @(Split-CaptionText $line.text $look.Width $look.MaxRows)
            $s = Format-Seconds $line.start; $e = Format-Seconds $line.end
            # Fade no longer than a third of a short caption, so it still shows fully for a moment.
            $f = Format-Seconds ([Math]::Min($fade, ($line.end - $line.start) / 3))
            $alpha = "if(lt(t,$s+$f),(t-$s)/$f,if(gt(t,$e-$f),($e-t)/$f,1))"
            for ($r = 0; $r -lt $rows.Count; $r++) {
                $file = "c$k-$r.txt"
                [IO.File]::WriteAllText((Join-Path $work $file), $rows[$r], $utf8)
                # Each row centred on its own (this ffmpeg has no text_align); top of its text, inside its box.
                $top = $bottom - ($rows.Count - $r) * $pitch + $border
                $filters += "drawtext=fontfile=caption.ttf:textfile=$file`:expansion=none:fontsize=$size`:fontcolor=$($look.Color)" +
                    ":box=1:boxcolor=$($look.Box):boxborderw=$border`:x=(w-text_w)/2:y=$top" +
                    ":enable='between(t,$s,$e)':alpha='$alpha'"
            }
            $k++
        }
        if (-not $filters.Count) { $filters += 'null' }
        $filters += 'format=yuv420p'
        # The graph goes in a file: many captions make it longer than a command line may be.
        [IO.File]::WriteAllText((Join-Path $work 'filter.txt'), ($filters -join ",`n"), $utf8)
        $hasAudio = (Invoke-HubFfmpeg @('-hide_banner', '-i', $Video)).Log -match 'Stream #\S+.*?Audio:'
        $sound = if ($hasAudio) { @('-map', '0:a:0', '-c:a', 'copy') } else { @('-an') }
        $arguments = @('-y', '-hide_banner', '-i', [IO.Path]::GetFullPath($Video), '-filter_script:v', 'filter.txt', '-map', '0:v:0') + $sound +
            @('-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', [IO.Path]::GetFullPath($Output))
        Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments $work) 'thêm được phụ đề'
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
