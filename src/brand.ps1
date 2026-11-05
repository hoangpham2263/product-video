# The brand's intro and outro on every finished video (ffmpeg only), from data/brand/ (brand.json and its logos): part
# of the app, so every install has them (the user, 04/11/2026: not kept in workspace/). Chosen with the user for GRENHEIM:
#   Intro: no clip of its own; the logo over the first seconds, the picture kept sharp (the user turned down a blurred
#   opening). The white logo with a soft dark shadow hugging its strokes, like a text-shadow, centred at 2/5 of the
#   height: a faint logo, a round glow behind it and a frosted disc were all turned down (it was lost on wood and lamps,
#   or the disc hid the room). Outro: a card of seconds on the brand colour (logo, then the lines one by one, held to the end),
#   dissolving in from the last shot over fade seconds.
# brand.json measures are on a 720x1280 frame: across scales with the video's width, down and font sizes with its
# height, so a 2:3 video keeps the layout (and the text above 65% of the height, Reels/TikTok's safe area).
# Fonts: light (Segoe UI Light) and serif (Georgia), else what the Mac has. Logos, fonts and texts are copied next to
# each other in a work folder, so the filter never holds a C: path or a character that needs escaping.

$script:BrandFonts = @{
    light = @('C:\Windows\Fonts\segoeuil.ttf', '/System/Library/Fonts/Supplemental/Arial.ttf', '/Library/Fonts/Arial.ttf')
    serif = @('C:\Windows\Fonts\georgia.ttf', '/System/Library/Fonts/Supplemental/Georgia.ttf', '/Library/Fonts/Georgia.ttf')
}

# A font of $script:BrandFonts (light, serif) copied into $Folder as $Name, for drawtext to find by a plain name.
function Copy-BrandFont([string]$Kind, [string]$Folder, [string]$Name) {
    $font = $script:BrandFonts[$Kind] | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $font) { throw "Không tìm thấy font ($Kind)." }
    Copy-Item -LiteralPath $font -Destination (Join-Path $Folder $Name)
}

function Get-BrandFolder { Join-Path (Get-ToolRoot) 'data/brand' }

# The brand, or $null when the app ships none.
function Read-Brand {
    $file = Join-Path (Get-BrandFolder) 'brand.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) { Read-JsonFile $file } else { $null }
}

function Add-BrandIntroOutro([string]$Video, [string]$Output, $Brand, [int]$Fps = 30) {
    $info = Get-HubVideoInfo $Video
    $w = $info.Width - ($info.Width % 2); $h = $info.Height - ($info.Height % 2)
    $x = { param($v) [int][Math]::Round([double]$v * $w / 720) }
    $y = { param($v) [int][Math]::Round([double]$v * $h / 1280) }
    $s = { param($v) Format-Seconds ([double]$v) }
    $work = Join-Path ([IO.Path]::GetTempPath()) "brand-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($kind in $script:BrandFonts.Keys) { Copy-BrandFont $kind $work "$kind.ttf" }
        $intro = $Brand.intro; $outro = $Brand.outro
        Copy-Item -LiteralPath (Join-Path (Get-BrandFolder) $intro.logo) -Destination (Join-Path $work 'intro.png')
        Copy-Item -LiteralPath (Join-Path (Get-BrandFolder) $outro.logo.file) -Destination (Join-Path $work 'outro.png')
        $introEnd = [double]$intro.fadeOut[0] + [double]$intro.fadeOut[1] + 0.1
        $card = [double]$outro.seconds
        $fades = ",fade=t=in:st=$(& $s $intro.fadeIn[0]):d=$(& $s $intro.fadeIn[1]):alpha=1,fade=t=out:st=$(& $s $intro.fadeOut[0]):d=$(& $s $intro.fadeOut[1]):alpha=1"
        # Shadow: the logo's own shape in black (opacity), blurred (blur, in 720-wide units) on a margin around it, under
        # the logo, so it reads on wood, stone and light walls alike.
        $pad = & $x (3 * [double]$intro.shadow.blur + 4)
        $inputs = @('-i', $Video, '-loop', '1', '-t', (& $s $introEnd), '-i', 'intro.png', '-loop', '1', '-t', (& $s $card), '-i', 'outro.png')
        $chains = @(
            "[0:v]fps=$Fps,scale=${w}:${h},setsar=1,format=yuv420p[main]"
            "[1:v]scale=$(& $x $intro.width):-1,format=rgba,colorchannelmixer=aa=$(& $s $intro.opacity),pad=iw+2*${pad}:ih+2*${pad}:${pad}:${pad}:color=black@0,split[logo][cast]"
            "[cast]colorchannelmixer=rr=0:gg=0:bb=0:aa=$(& $s $intro.shadow.opacity),gblur=sigma=$(& $s ((& $x $intro.shadow.blur)))[shade]"
            "[shade][logo]overlay=0:0$fades[il]"
            "[main][il]overlay=(W-w)/2:$(& $y $intro.y)-${pad}:eof_action=pass,format=yuv420p,settb=AVTB[body]"
            "color=c=0x$($outro.background):s=${w}x${h}:r=${Fps}:d=$(& $s $card)[bg]"
            "[2:v]scale=$(& $x $outro.logo.width):-1,format=rgba,fade=t=in:st=$(& $s $outro.logo.start):d=0.5:alpha=1[ol]"
        )
        $text = "[bg][ol]overlay=(W-w)/2:$(& $y $outro.logo.y):eof_action=pass"
        $lines = @($outro.lines)
        for ($k = 0; $k -lt $lines.Count; $k++) {
            $line = $lines[$k]
            [IO.File]::WriteAllText((Join-Path $work "line-$k.txt"), [string]$line.text, $utf8)
            $text += ",drawtext=fontfile=$($line.font).ttf:textfile=line-$k.txt:expansion=none:fontsize=$(& $y $line.size):fontcolor=$($line.color)" +
                ":x=(w-text_w)/2:y=$(& $y $line.y):alpha='clip((t-$(& $s $line.start))/0.5,0,1)'"
        }
        $chains += "$text,format=yuv420p,setsar=1,settb=AVTB[card]"
        $chains += "[body][card]xfade=transition=fade:duration=$(& $s $outro.fade):offset=$(& $s ($info.Seconds - [double]$outro.fade)),format=yuv420p[out]"
        $arguments = @('-y', '-hide_banner') + $inputs + @('-filter_complex', ($chains -join ';'), '-map', '[out]', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '18', '-movflags', '+faststart', '-an', [IO.Path]::GetFullPath($Output))
        Assert-HubFfmpeg (Invoke-HubFfmpeg $arguments $work) 'thêm được intro/outro'
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
