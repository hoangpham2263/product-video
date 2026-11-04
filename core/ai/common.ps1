# Helpers every AI provider and tool shares: the tools run on Windows PowerShell 5.1 and on PowerShell 7 (Windows/macOS).
$script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

# Stop a process and every child it started.
function Stop-ProcessTree([Diagnostics.Process]$Process) {
    if ($script:OnWindows) {
        & taskkill.exe /PID $Process.Id /T /F *> $null
        return $LASTEXITCODE -eq 0
    }
    try { $Process.Kill($true); return $true } catch { return $false }
}

# Width/height from the file header (PNG, JPEG, WebP), without an imaging library.
function Get-ImageSize([byte[]]$Bytes) {
    $be16 = { param($i) ([int]$Bytes[$i] -shl 8) -bor [int]$Bytes[$i + 1] }
    $be32 = { param($i) ([long]$Bytes[$i] -shl 24) -bor ([long]$Bytes[$i + 1] -shl 16) -bor ([long]$Bytes[$i + 2] -shl 8) -bor [long]$Bytes[$i + 3] }
    if ($Bytes.Length -ge 24 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) {
        return [pscustomobject]@{ Format = 'png'; Width = (& $be32 16); Height = (& $be32 20) }
    }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8) {
        $i = 2
        while ($i + 9 -lt $Bytes.Length) {
            if ($Bytes[$i] -ne 0xFF) { $i++; continue }
            $marker = $Bytes[$i + 1]
            if ($marker -in 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF) {
                return [pscustomobject]@{ Format = 'jpeg'; Width = (& $be16 ($i + 7)); Height = (& $be16 ($i + 5)) }
            }
            $i += 2 + (& $be16 ($i + 2))
        }
    }
    if ($Bytes.Length -ge 30 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -eq 'WEBP') {
        $kind = [Text.Encoding]::ASCII.GetString($Bytes, 12, 4)
        if ($kind -eq 'VP8X') { return [pscustomobject]@{ Format = 'webp'; Width = 1 + ([int]$Bytes[24] -bor ([int]$Bytes[25] -shl 8) -bor ([int]$Bytes[26] -shl 16)); Height = 1 + ([int]$Bytes[27] -bor ([int]$Bytes[28] -shl 8) -bor ([int]$Bytes[29] -shl 16)) } }
        if ($kind -eq 'VP8 ') { return [pscustomobject]@{ Format = 'webp'; Width = ([int]$Bytes[26] -bor ([int]$Bytes[27] -shl 8)) -band 0x3FFF; Height = ([int]$Bytes[28] -bor ([int]$Bytes[29] -shl 8)) -band 0x3FFF } }
        if ($kind -eq 'VP8L') { $b = $Bytes; return [pscustomobject]@{ Format = 'webp'; Width = 1 + (([int]$b[21] -bor ([int]$b[22] -shl 8)) -band 0x3FFF); Height = 1 + ((([int]$b[22] -shr 6) -bor ([int]$b[23] -shl 2) -bor ([int]$b[24] -shl 10)) -band 0x3FFF) } }
    }
    return $null
}

# Re-encode JPEG/WebP as PNG in place: GDI+ on Windows, sips on macOS.
function ConvertTo-PngFile([string]$Path) {
    $info = Get-ImageSize ([IO.File]::ReadAllBytes($Path))
    if ($info -and $info.Format -eq 'png') { return }
    if ($script:OnWindows) {
        Add-Type -AssemblyName System.Drawing
        $bytes = [IO.File]::ReadAllBytes($Path)
        $stream = New-Object IO.MemoryStream(, $bytes)
        $image = [Drawing.Image]::FromStream($stream)
        try { $image.Save($Path, [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose(); $stream.Dispose() }
        return
    }
    $temp = "$Path.convert.png"
    & sips -s format png $Path --out $temp *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp)) { throw "Không đổi được ảnh sang PNG: $Path" }
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

# Open a folder or file with the system viewer.
function Open-SystemPath([string]$Path) {
    if ($script:OnWindows) { Start-Process explorer.exe -ArgumentList ('"' + $Path + '"') } else { & open $Path }
}

# One argument of a command line, quoted the way Windows' CommandLineToArgvW reads it back.
function ConvertTo-CliArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
