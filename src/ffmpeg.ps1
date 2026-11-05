# ffmpeg for Product Video: the one on PATH, else a static build downloaded once into
# workspace/tools/ffmpeg (eugeneware/ffmpeg-static b6.0, one gzip per OS, about 25 MB; GPL build with libx264).
# No ffprobe: what a clip is (size, length) is read from ffmpeg's own banner.
$script:HubFfmpegDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/tools/ffmpeg'
$script:HubFfmpegRelease = 'https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0'

function Get-HubFfmpeg {
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $windows = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $exe = Join-Path $script:HubFfmpegDir $(if ($windows) { 'ffmpeg.exe' } else { 'ffmpeg' })
    if (Test-Path -LiteralPath $exe) { return $exe }
    $asset = if ($windows) { 'ffmpeg-win32-x64.gz' }
             elseif ((uname -m) -match 'arm64') { 'ffmpeg-darwin-arm64.gz' } else { 'ffmpeg-darwin-x64.gz' }
    Write-Host "  [FFMPEG] Downloading $asset (once)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $script:HubFfmpegDir | Out-Null
    $gz = "$exe.gz"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "$script:HubFfmpegRelease/$asset" -OutFile $gz -UseBasicParsing -TimeoutSec 600
        $in = [IO.File]::OpenRead($gz)
        try {
            $unzip = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
            $out = [IO.File]::Create("$exe.part")
            try { $unzip.CopyTo($out) } finally { $out.Dispose(); $unzip.Dispose() }
        } finally { $in.Dispose() }
        Move-Item -LiteralPath "$exe.part" -Destination $exe -Force
        if (-not $windows) { chmod +x $exe }
    } catch {
        Remove-Item -LiteralPath "$exe.part" -Force -ErrorAction SilentlyContinue
        throw "[CAUSE:NETWORK] Không tải được ffmpeg ($asset): $($_.Exception.Message)"
    } finally { Remove-Item -LiteralPath $gz -Force -ErrorAction SilentlyContinue }
    return $exe
}

# ffmpeg with its output kept (it writes everything to stderr). $Folder: where it runs, for a filter that writes a
# file by a relative name (a C: path in a filter option needs escaping).
function Invoke-HubFfmpeg([string[]]$Arguments, [string]$Folder = '') {
    $ffmpeg = Get-HubFfmpeg
    $info = [Diagnostics.ProcessStartInfo]::new($ffmpeg)
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-CliArgument $_ }) -join ' '
    if ($Folder) { $info.WorkingDirectory = $Folder }
    $info.UseShellExecute = $false; $info.RedirectStandardError = $true; $info.RedirectStandardOutput = $true; $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $log = $process.StandardError.ReadToEnd()
    $process.WaitForExit(); [void]$stdout.Result
    [pscustomobject]@{ ExitCode = $process.ExitCode; Log = $log }
}

function Assert-HubFfmpeg($Result, [string]$What) {
    if ($Result.ExitCode -ne 0) {
        $tail = (($Result.Log -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
        throw "ffmpeg không $What. $tail"
    }
}

# Width, height and seconds of a video, from the banner of `ffmpeg -i`.
function Get-HubVideoInfo([string]$Path) {
    $log = (Invoke-HubFfmpeg @('-hide_banner', '-i', $Path)).Log
    $size = [regex]::Match($log, 'Stream #\S+.*?Video:.*?, (\d{2,5})x(\d{2,5})')
    $time = [regex]::Match($log, 'Duration: (\d+):(\d+):(\d+(?:\.\d+)?)')
    if (-not $size.Success) { throw "Không đọc được video: $Path" }
    [pscustomobject]@{
        Width = [int]$size.Groups[1].Value; Height = [int]$size.Groups[2].Value
        Seconds = $(if ($time.Success) { [int]$time.Groups[1].Value * 3600 + [int]$time.Groups[2].Value * 60 + [double]::Parse($time.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0 })
    }
}
