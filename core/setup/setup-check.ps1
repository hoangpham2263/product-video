# Cấu hình, shared by every tool: read-only readiness, sign-in and live quota checks; no AI turns are created.
param([switch]$AsJson)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$checks = New-Object Collections.Generic.List[object]
$checks.Add([pscustomobject]@{
    Ok = $PSVersionTable.PSVersion.Major -ge 5
    Message = $(if ($PSVersionTable.PSVersion.Major -ge 5) { 'Hệ thống: sẵn sàng.' } else { 'Hệ thống chưa được hỗ trợ.' })
    Action = 'Sử dụng Windows 10/11 và cài đặt theo setup.txt.'
})
$engine = Get-Command codex -ErrorAction SilentlyContinue
$checks.Add([pscustomobject]@{
    Ok = [bool]$engine
    Message = $(if ($engine) { 'Công cụ xử lý: đã cài đặt.' } else { 'Chưa cài công cụ xử lý.' })
    Action = 'Bấm Cấu hình rồi bấm Cài.'
})
$loggedIn = $false
$apiKey = $false
if ($engine) {
    try {
        $auth = & {
            # The CLI writes successful status to stderr on Windows PowerShell 5.1.
            $ErrorActionPreference = 'Continue'
            $text = & codex login status 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.Trim() }
        }
        $status = $auth.Text
        $loggedIn = $auth.ExitCode -eq 0 -and $status -match '(?i)logged in'
        $apiKey = $loggedIn -and $status -match '(?i)api key'
    } catch { $loggedIn = $false }
}
# The ChatGPT account Codex signed in with: the email in its sign-in token (auth.json), never the token itself.
# Read even when the sign-in has run out, so the page can say whose session expired.
$codexAccount = ''
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$codexAuthFile = Test-Path -LiteralPath (Join-Path $codexHome 'auth.json')
if ($codexAuthFile -and -not $apiKey) {
    try {
        $part = ((Get-Content -LiteralPath (Join-Path $codexHome 'auth.json') -Raw | ConvertFrom-Json).tokens.id_token -split '\.')[1].Replace('-', '+').Replace('_', '/')
        $part += '=' * ((4 - $part.Length % 4) % 4)
        $codexAccount = [string]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json).email
    } catch { $codexAccount = '' }
}
$checks.Add([pscustomobject]@{
    Ok = $loggedIn
    Message = $(if ($apiKey) { 'Tài khoản: đã cấu hình API, tính phí riêng.' } elseif ($loggedIn) { 'ChatGPT: đã đăng nhập.' } else { 'ChatGPT: chưa đăng nhập hoặc phiên đăng nhập đã hết hạn.' })
    Action = 'Bấm Đăng nhập rồi nhập mã hiện ra ở trang đăng nhập ChatGPT trong Chrome.'
})
. (Join-Path $PSScriptRoot 'quota.ps1')
$quotaAvailable = $false
$codexExpired = $false
$quotaMessages = @()
if ($loggedIn) {
    if ($apiKey) {
        $quotaMessages = @('Hạn mức: tài khoản API tính phí riêng; app chưa hiển thị số dư API.')
    } else {
        $quota = Get-ChatGptQuota $engine.Source
        $quotaAvailable = $quota.Available
        $quotaMessages = @($quota.Messages)
    }
    # Signed in on paper but the server refuses the sign-in: it has expired, and the tools cannot use Codex.
    $codexExpired = [bool]$quota.Expired
    foreach ($message in $quotaMessages) {
        $checks.Add([pscustomobject]@{ Ok = -not $codexExpired; Message = $message; Action = $(if ($codexExpired) { 'Bấm Cấu hình rồi Đăng nhập lại.' } else { '' }) })
    }
}
$ready = @($checks | Where-Object { -not $_.Ok }).Count -eq 0
# The Cấu hình window shows these in order (Node.js first); each step only matters once the one before it is done.
# State: ok, fail, warn (works but unconfirmed) or wait (blocked by an earlier step). Action names the fix button.
$node = Get-Command node -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'config.ps1')
# The main window shows what is left; here only when it resets, to keep the step short.
$quotaText = if ($quotaAvailable -and $quota.Resets) { "Đặt lại: $($quota.Resets)" } else { (@($quotaMessages) -join ' ').Trim() }
# The Product Review extension (core/extension) in the user's own Chrome, for runs on Google Flow, Gemini or ChatGPT in the
# browser, and who is signed in there (core/bridge/ensure.mjs --logins, read by the extension). Only checks: Chrome is
# not started for it. Google covers Flow and Gemini web.
$extensionDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'extension'
$web = $null; $extensionState = 'warn'
if ($node) {
    try {
        $answer = (& node (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge/ensure.mjs') --logins --no-open | Select-Object -Last 1) | ConvertFrom-Json
        if ($answer.ok) { $extensionState = 'ok'; $web = $answer.logins } elseif ($answer.extension -eq $false) { $extensionState = 'fail' }
    } catch {}
}
$browserReady = $extensionState -eq 'ok'
# The Google account Flow and Gemini run with, chosen on Cấu hình (workspace/config/google-account.json { email });
# none chosen is Google's default, the first one signed in. A choice no longer signed in there is dropped.
$googleChoiceFile = Get-SharedConfigPath (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'workspace') 'google-account.json'
$googleChoice = ''
try { $googleChoice = [string](Get-Content -LiteralPath $googleChoiceFile -Raw -Encoding UTF8 | ConvertFrom-Json).email } catch {}
function Get-WebStep([string]$Id, [string]$Title, [string]$Site, [string]$Uses) {
    $state = if (-not $browserReady) { 'wait' } elseif (-not $web) { 'warn' } elseif ($web.$Site) { 'ok' } else { 'fail' }
    $accounts = @(if ($web -and $web.accounts) { $web.accounts })
    if ($googleChoice -and $accounts.Count -and $accounts -notcontains $googleChoice) {
        Remove-Item -LiteralPath $googleChoiceFile -Force -ErrorAction SilentlyContinue
        $script:googleChoice = ''
    }
    $account = if ($state -ne 'ok' -or -not $accounts.Count) { '' } elseif ($script:googleChoice) { $script:googleChoice } else { [string]$accounts[0] }
    $detail = switch ($state) {
        'wait' { 'Mở Chrome có extension Product Review trước.' }
        'warn' { 'Chưa kiểm tra được. Bấm Đăng nhập để xem trong Chrome.' }
        'ok' { if ($accounts.Count -gt 1) { "Flow và Gemini chạy bằng tài khoản đang chọn ($($accounts.Count) tài khoản đã đăng nhập)." } else { 'Đã đăng nhập trong Chrome.' } }
        default { 'Chưa đăng nhập. Bấm Đăng nhập rồi đăng nhập Google trong Chrome.' }
    }
    # Google's account chooser in Chrome: sign in, add or switch the account. Accounts: every one signed in
    # there, for the page to choose from.
    [pscustomobject]@{ Id = $Id; Title = $Title; State = $state; Detail = $detail; Account = $account; Accounts = $(if ($state -eq 'ok') { @($accounts) } else { @() }); Uses = $Uses; Action = $(if ($browserReady) { 'google' } else { '' }) }
}
# Antigravity CLI (agy, Google sign-in): Viết review: Antigravity CLI. agy models answers only when signed in.
$agy = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $agy) { $agy = @((Join-Path $HOME '.local/bin/agy'), (Join-Path $HOME '.local/bin/agy.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
$agyState = 'warn'; $agyDetail = 'Chưa cài (không bắt buộc). Cài Antigravity để chọn Viết review: Antigravity CLI.'; $agyAccount = ''
if ($agy) {
    $agyOk = $false
    # Its own sign-in, apart from Chrome's: its log names the account ("authenticated successfully as …").
    $agyLog = [IO.Path]::GetTempFileName()
    try {
        # -WindowStyle exists only on Windows.
        $hidden = @{}; if ($env:OS -eq 'Windows_NT') { $hidden.WindowStyle = 'Hidden' }
        $p = Start-Process -FilePath $agy -ArgumentList @('--log-file', "`"$agyLog`"", 'models') -PassThru @hidden -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
        if ($p.WaitForExit(20000)) { $agyOk = $p.ExitCode -eq 0 } else { $p.Kill() }
        if ((Get-Content -LiteralPath $agyLog -Raw -ErrorAction SilentlyContinue) -match 'authenticated successfully as (\S+@\S+)') { $agyAccount = $Matches[1] }
    } catch { $agyOk = $false }
    Remove-Item -LiteralPath $agyLog -Force -ErrorAction SilentlyContinue
    if ($agyOk) { $agyState = 'ok'; $agyDetail = 'Đã đăng nhập (tài khoản riêng của Antigravity, không theo Chrome).' }
    else { $agyState = 'fail'; $agyDetail = 'Chưa đăng nhập. Mở Antigravity (hoặc chạy agy trong Terminal) rồi đăng nhập Google.' }
}
$steps = @(
    [pscustomobject]@{ Id = 'node'; Title = 'Node.js'; State = $(if ($node) { 'ok' } else { 'fail' }); Detail = $(if ($node) { 'Đã cài.' } else { 'Chưa cài. Cần để cài Codex.' }); Action = $(if ($node) { '' } else { 'install' }) }
    [pscustomobject]@{ Id = 'codex'; Title = 'Codex'; State = $(if ($engine) { 'ok' } else { 'fail' }); Detail = $(if ($engine) { 'Đã cài.' } else { 'Chưa cài công cụ tạo ảnh.' }); Action = $(if ($engine) { '' } else { 'install' }) }
    [pscustomobject]@{ Id = 'login'; Title = 'Codex (ChatGPT)'; State = $(if (-not $engine) { 'wait' } elseif ($loggedIn) { 'ok' } else { 'fail' }); Account = $codexAccount; Uses = 'Viết review: Codex · Tạo ảnh: Codex' 
        Detail = $(if (-not $engine) { 'Cài Codex trước.' } elseif ($apiKey) { 'Đã cấu hình API, tính phí riêng.' } elseif ($loggedIn) { 'Đã đăng nhập.' } else { 'Chưa đăng nhập hoặc phiên đã hết hạn.' })
        # Signed in already: the same button signs in again with another account.
        Action = $(if ($engine) { 'login' } else { '' }) }
    [pscustomobject]@{ Id = 'quota'; Title = 'Hạn mức sử dụng'; State = $(if (-not $loggedIn) { 'wait' } elseif ($apiKey -or $quotaAvailable) { 'ok' } else { 'warn' })
        Detail = $(if (-not $loggedIn) { 'Đăng nhập trước.' } else { $quotaText }); Action = '' }
    [pscustomobject]@{ Id = 'browser'; Title = 'Extension Product Review'; State = $extensionState
        Detail = $(switch ($extensionState) { 'ok' { 'Đã kết nối trong Chrome. Các tool mở tab riêng trong nhóm Product Review.' } 'fail' { "Chưa cài trong Chrome. Bấm Mở: chrome://extensions, bật Chế độ nhà phát triển, Tải tiện ích đã giải nén, chọn thư mục $extensionDir." } default { 'Chrome chưa mở (hoặc chưa cài Node.js). Bấm Mở để mở Chrome.' } })
        Action = 'browser' }
    Get-WebStep 'google' 'Google (Flow, Gemini web)' 'google' 'Tạo ảnh: Google Flow · Viết review: Gemini web'
    [pscustomobject]@{ Id = 'antigravity'; Title = 'Antigravity CLI'; State = $agyState; Detail = $agyDetail; Account = $agyAccount; Uses = 'Viết review: Antigravity CLI'; Action = $(if ($agy) { 'antigravity' } else { '' }) }
)
# Each AI's sign-in: signed in, expired (its sign-in is still on this computer but no longer accepted), signed out
# (it was signed in here before) or never. The last account seen is kept (workspace/config/ai-accounts.json), so an
# expired or signed-out AI still says whose it was, instead of looking as if it had never been set up.
$accountsFile = Get-SharedConfigPath (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'workspace') 'ai-accounts.json'
$known = @{}
try { (Get-Content -LiteralPath $accountsFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $known[$_.Name] = [string]$_.Value } } catch {}
$stored = $false
foreach ($step in $steps | Where-Object { $_.Id -in @('login', 'google', 'antigravity') }) {
    $was = $known[$step.Id]
    $signIn = if ($step.Id -eq 'login' -and $codexExpired) { 'expired' } elseif ($step.State -eq 'ok') { 'ok' } elseif ($step.State -eq 'wait') { 'wait' }
        elseif ($step.Id -eq 'login' -and $codexAuthFile) { 'expired' }
        elseif ($step.Id -eq 'antigravity' -and $agy -and (Test-Path -LiteralPath (Join-Path $HOME '.gemini/oauth_creds.json'))) { 'expired' }
        elseif ($was) { 'signedout' } else { 'none' }
    if ($signIn -eq 'ok' -and $step.Account -and $step.Account -ne $was) { $known[$step.Id] = $step.Account; $stored = $true }
    if ($signIn -ne 'ok' -and -not $step.Account) { $step.Account = $was }
    $step | Add-Member -NotePropertyName SignIn -NotePropertyValue $signIn -Force
    $whose = if ($step.Account) { " ($($step.Account))" } else { '' }
    switch ($signIn) {
        'expired' { $step.State = 'fail'; $step.Detail = "Phiên đăng nhập đã hết hạn$whose. Bấm Đăng nhập lại." }
        'none' { if ($step.Id -eq 'login') { $step.Detail = 'Chưa đăng nhập. Bấm Đăng nhập.' } }
        'signedout' { $step.Detail = "Đã đăng xuất hoặc hết phiên$whose. Bấm Đăng nhập lại." }
    }
}
if ($stored) {
    New-Item -ItemType Directory -Force -Path (Split-Path $accountsFile -Parent) | Out-Null
    [IO.File]::WriteAllText($accountsFile, ([pscustomobject]$known | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
$report = [pscustomobject]@{
    Ready = $ready
    QuotaAvailable = $quotaAvailable
    # The app turns its check button into this step: install, login or nothing left.
    NextAction = $(if (-not $engine) { 'install' } elseif (-not $loggedIn -or $codexExpired) { 'login' } else { '' })
    Checks = $checks.ToArray()
    Steps = $steps
    Summary = $(if (-not $ready) { 'Vui lòng xử lý các mục trên trước khi bắt đầu.' } elseif ($apiKey) { 'Đã kiểm tra cài đặt và tài khoản API.' } elseif ($quotaAvailable) { 'Đã kiểm tra đăng nhập và hạn mức Codex. Hạn mức tạo ảnh không được thống kê riêng.' } else { 'Đã kiểm tra cài đặt và đăng nhập. Chưa xác định được hạn mức còn lại.' })
}
if ($AsJson) { $report | ConvertTo-Json -Depth 5 }
else {
    Write-Output 'KIỂM TRA CHATGPT'
    foreach ($check in $report.Checks) {
        Write-Output $check.Message
        if (-not $check.Ok) { Write-Output $check.Action }
    }
    Write-Output $report.Summary
}
if (-not $ready) { exit 1 }
