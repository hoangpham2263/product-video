# Install on Windows, run from the Cài button in the Cấu hình window: Node.js, Codex CLI, ChatGPT sign-in and the
# bridge (core/bridge), each only when missing, then the same readiness check as Cấu hình.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Update-SessionPath { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
function Test-Tool([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

Step 'Node.js'
if (-not (Test-Tool node)) {
    if (Test-Tool winget) { winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements; Update-SessionPath }
    if (-not (Test-Tool node)) {
        # No winget: the official LTS installer from nodejs.org (asks for administrator approval).
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $lts = @(Invoke-RestMethod 'https://nodejs.org/dist/index.json' -TimeoutSec 30 | Where-Object { $_.lts })[0].version
            $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
            $msi = Join-Path ([IO.Path]::GetTempPath()) "node-$lts-$arch.msi"
            Write-Host "Đang tải Node.js $lts..."
            Invoke-WebRequest "https://nodejs.org/dist/$lts/node-$lts-$arch.msi" -OutFile $msi -UseBasicParsing
            Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), '/passive') -Verb RunAs -Wait
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
            Update-SessionPath
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
    if (-not (Test-Tool node)) {
        Write-Host 'Chưa cài được Node.js. Kiểm tra mạng rồi bấm Cài lại.' -ForegroundColor Yellow
        Read-Host 'Nhấn Enter để đóng'
        exit 1
    }
}
Write-Host "Node.js $(node --version)"

Step 'Codex'
if (-not (Test-Tool codex)) { npm install -g @openai/codex; Update-SessionPath }
if (-not (Test-Tool codex)) { Write-Host 'Chưa cài được Codex. Bấm Cài lại để thử tiếp.' -ForegroundColor Yellow; Read-Host 'Nhấn Enter để đóng'; exit 1 }
Write-Host (codex --version)

Step 'Đăng nhập ChatGPT'
$status = (& codex login status 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $status -notmatch '(?i)logged in') { codex login } else { Write-Host 'Đã đăng nhập.' }

Step 'Cầu nối trình duyệt'
foreach ($bridge in @(Join-Path $root 'core/bridge')) {
    if (Test-Path -LiteralPath (Join-Path $bridge 'package.json')) { Push-Location $bridge; npm install --silent; Pop-Location; Write-Host "Đã cài: $bridge" }
}

Step 'Kiểm tra'
& (Join-Path $PSScriptRoot 'setup-check.ps1')
