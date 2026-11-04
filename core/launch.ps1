# Opens Product Review. macOS and Windows show the same web page from the same Node server (src/mac/server.mjs):
# start-app.command gets the entry to start printed (-Mac); on Windows this script starts it and shows it in one app
# window (WinForms with WebView2, core/webview2): no browser or address bar.
param([switch]$Mac)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$entry = [IO.Path]::GetFullPath((Join-Path $root 'src/mac/server.mjs'))
if ($Mac) { return $entry }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$logs = Join-Path $root 'workspace/logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
function Write-HubError([string]$Text) {
    try { Add-Content -LiteralPath (Join-Path $logs 'app-errors.log') -Encoding UTF8 -Value ("[{0:o}] Product Review`r`n  {1}`r`n" -f (Get-Date), $Text) } catch { }
}
function Show-HubMessage([string]$Text) { [void][Windows.Forms.MessageBox]::Show($Text, 'Product Review', 'OK', 'Warning') }

# Node runs the pages' servers; without it, the installer from Cấu hình (Node.js, Codex, sign-in) runs first.
function Find-Node {
    @((Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source), (Join-Path $env:ProgramFiles 'nodejs\node.exe')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
$node = Find-Node
if (-not $node) {
    if ([Windows.Forms.MessageBox]::Show("Product Review cần Node.js. Cài ngay?`r`n`r`nCửa sổ cài đặt sẽ mở; cài xong Product Review tự mở.", 'Product Review', 'OKCancel', 'Information') -ne 'OK') { return }
    Start-Process powershell.exe -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'setup/setup-install.ps1') + '"'))
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $node = Find-Node
    if (-not $node) { Show-HubMessage 'Chưa cài được Node.js. Mở Product Review lại để thử lần nữa.'; return }
}

# The server's port, the one Node would pick for this folder (BASE_PORT in src/mac/server.mjs), handed to it so the
# two never disagree.
function Get-HubPort([string]$Dir, [int]$Base) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    return $Base + ([Convert]::ToInt32($hex.Substring(0, 6), 16) % 1000)
}
$serverService = 'product-review'
$serverRoot = $root; $port = Get-HubPort $root 47000
$serverLogs = $logs; $arguments = @(('"' + $entry + '"'), '--no-open')
. (Join-Path $PSScriptRoot 'server-health.ps1')
$basePort = $port
$addressFile = Join-Path $logs '../server-address.json'
$serverReady = $false
for ($attempt = 0; $attempt -lt 3 -and -not $serverReady; $attempt++) {
    $port = Select-HubServerPort $basePort $addressFile
    $env:PR_PORT = [string]$port
    if (Test-HubServer) { $serverReady = $true; break }
    New-Item -ItemType Directory -Force -Path $serverLogs | Out-Null
    $out = Join-Path $serverLogs "server-$port.log"; $err = Join-Path $serverLogs "server-$port.err.log"
    foreach ($file in @($out, $err)) { if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 1MB) { Move-Item -LiteralPath $file -Destination ($file -replace '\.log$', '.old.log') -Force } }
    $serverProcess = Start-Process $node -ArgumentList $arguments -WorkingDirectory $serverRoot -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    [void]$serverProcess.Handle
    try {
        $deadline = (Get-Date).AddSeconds(20)
        do {
            $serverReady = Test-HubServer
            if ($serverReady -or $serverProcess.HasExited) { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
    } finally {
        # Only this launcher's own child; do not leave a failed startup running in the background.
        if (-not $serverReady -and -not $serverProcess.HasExited) { $serverProcess.Kill(); $serverProcess.WaitForExit() }
        $serverProcess.Dispose()
    }
    if (-not $serverReady) { Write-HubError "Server did not start: $entry (port $port); log: $err"; $basePort = $port + 1 }
}
if (-not $serverReady) { Show-HubMessage 'Không mở được Product Review. Xem workspace/logs/app-errors.log để biết tiến trình/cổng lỗi.'; return }
$addressTemp = "$addressFile.$PID.tmp"
@{root=$serverRoot;service=$serverService;port=$port} | ConvertTo-Json -Compress | Set-Content -LiteralPath $addressTemp -Encoding UTF8
Move-Item -LiteralPath $addressTemp -Destination $addressFile -Force
$startUrl = "http://127.0.0.1:$port/"

# The WebView2 SDK is loaded from a copy in workspace/, so an update can replace core/webview2 while the window is open.
# Without the WebView2 Runtime (older Windows 10), the pages open in the default browser instead.
$sdkSource = Join-Path $PSScriptRoot 'webview2'
$sdk = Join-Path $root 'workspace/webview2/sdk'
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $sdkSource -Recurse -File -Filter *.dll)) {
        $to = Join-Path $sdk $file.FullName.Substring($sdkSource.Length + 1)
        $copy = Get-Item -LiteralPath $to -ErrorAction SilentlyContinue
        if (-not $copy -or $copy.Length -ne $file.Length -or $copy.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) {
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            try { Copy-Item -LiteralPath $file.FullName -Destination $to -Force } catch { }
        }
    }
    # A ZIP saved by a browser marks its files as downloaded from the internet, and .NET will not load a marked DLL
    # (0x80131515), so the window would fall back to the browser.
    Get-ChildItem -LiteralPath $sdkSource, $sdk -Recurse -File -Filter *.dll | Unblock-File -ErrorAction SilentlyContinue
    Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll'), (Join-Path $sdk 'Microsoft.Web.WebView2.WinForms.dll')
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'x64' } default { 'x86' } }
    [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath((Join-Path $sdk $arch))
    [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString([NullString]::Value)
    $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2 -Property @{ Dock = 'Fill' }
    $webView.CreationProperties = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties -Property @{ UserDataFolder = (Join-Path $root 'workspace/webview2/data') }
} catch {
    Write-HubError "WebView2: $($_.Exception.Message)"
    Start-Process $startUrl
    return
}

$form = New-Object Windows.Forms.Form -Property @{ Text = 'Product Review'; Size = '1120,840'; MinimumSize = '640,480'; StartPosition = 'CenterScreen'; BackColor = [Drawing.Color]::FromArgb(240, 240, 240) }
$hubIcon = Join-Path $root 'icon.png'
# Read into memory, so the file stays free for Cập nhật to replace while the window is open.
if (Test-Path -LiteralPath $hubIcon) { $form.Icon = [Drawing.Icon]::FromHandle((New-Object Drawing.Bitmap((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($hubIcon))))).GetHicon()) }
$form.Controls.Add($webView)
# The page's title is the window's. The app's own pages stay in the window; other links (a new window too) open in
# the default browser.
$isLocal = { param([string]$Uri) $Uri -match '^(http://127\.0\.0\.1:\d+/|about:|data:)' }
$webView.add_CoreWebView2InitializationCompleted({
        param($source, $ready)
        if (-not $ready.IsSuccess) { Write-HubError "WebView2: $($ready.InitializationException.Message)"; Start-Process $startUrl; $form.Close(); return }
        $core = $webView.CoreWebView2
        $core.Settings.IsStatusBarEnabled = $false
        $core.add_DocumentTitleChanged({ $form.Text = $webView.CoreWebView2.DocumentTitle })
        $core.add_NewWindowRequested({
                param($source, $request)
                $request.Handled = $true
                if (& $isLocal $request.Uri) { $webView.CoreWebView2.Navigate($request.Uri) } else { Start-Process $request.Uri }
            })
        $core.add_NavigationStarting({
                param($source, $navigation)
                if (-not (& $isLocal $navigation.Uri)) { $navigation.Cancel = $true; Start-Process $navigation.Uri }
            })
    })
# Closing the window stops the server, after asking while a run is still going.
$form.Add_FormClosing({
        param($source, $closing)
        try {
            $run = (New-Object Net.WebClient).DownloadString("http://127.0.0.1:$(([Uri]$webView.Source).Port)/api/run") | ConvertFrom-Json
            if ($run.running -and [Windows.Forms.MessageBox]::Show($form, 'Đang chạy. Đóng cửa sổ sẽ dừng lượt chạy này. Vẫn đóng?', 'Product Review', 'YesNo', 'Warning') -ne 'Yes') { $closing.Cancel = $true }
        } catch { }
    })
$form.Add_FormClosed({ try { [void](New-Object Net.WebClient).UploadString("http://127.0.0.1:$port/api/quit", '') } catch { } })
$webView.Source = [Uri]$startUrl
try { [Windows.Forms.Application]::Run($form) } finally { $webView.Dispose(); $form.Dispose() }
