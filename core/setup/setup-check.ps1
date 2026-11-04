# Cấu hình: read-only readiness checks. Product Video needs Node.js (its server and the bridge), the Product Video
# extension in the user's own Chrome (core/extension, through core/bridge) and grok.com signed in there; Grok's sign-in
# cannot be read from outside the page, so that step only opens grok.com.
param([switch]$AsJson)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$node = Get-Command node -ErrorAction SilentlyContinue
$extensionDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'extension'
$extensionState = 'warn'
if ($node) {
    try {
        $answer = (& node (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge/ensure.mjs') --no-open | Select-Object -Last 1) | ConvertFrom-Json
        if ($answer.ok) { $extensionState = 'ok' } elseif ($answer.extension -eq $false) { $extensionState = 'fail' }
    } catch {}
}
$steps = @(
    [pscustomobject]@{ Id = 'grok'; Title = 'Grok (grok.com)'; State = $(if ($extensionState -eq 'ok') { 'warn' } else { 'wait' }); Account = ''; Uses = 'Tạo khung hình và video'
        Detail = $(if ($extensionState -eq 'ok') { 'Grok chạy bằng tài khoản đang đăng nhập grok.com trong Chrome. Bấm Mở Grok để xem hoặc đăng nhập.' } else { 'Cài extension Product Video trước.' })
        Action = $(if ($extensionState -eq 'ok') { 'site' } else { '' }) }
    [pscustomobject]@{ Id = 'node'; Title = 'Node.js'; State = $(if ($node) { 'ok' } else { 'fail' }); Detail = $(if ($node) { 'Đã cài.' } else { 'Chưa cài.' }); Action = $(if ($node) { '' } else { 'install' }) }
    [pscustomobject]@{ Id = 'browser'; Title = 'Extension Product Video'; State = $extensionState
        Detail = $(switch ($extensionState) { 'ok' { 'Đã kết nối trong Chrome. Mỗi việc mở tab riêng trong nhóm Product Video.' } 'fail' { "Chưa cài trong Chrome. Bấm Mở: chrome://extensions, bật Chế độ nhà phát triển, Tải tiện ích đã giải nén, chọn thư mục $extensionDir." } default { 'Chrome chưa mở (hoặc chưa cài Node.js). Bấm Mở để mở Chrome.' } })
        Action = 'browser' }
)
$ready = [bool]$node -and $extensionState -eq 'ok'
$report = [pscustomobject]@{ Ready = $ready; Steps = $steps; Summary = $(if ($ready) { 'Sẵn sàng.' } else { 'Vui lòng xử lý các mục trên trước khi bắt đầu.' }) }
if ($AsJson) { $report | ConvertTo-Json -Depth 5 }
else { foreach ($step in $steps) { Write-Output "$($step.Title): $($step.Detail)" } }
if (-not $ready) { exit 1 }
