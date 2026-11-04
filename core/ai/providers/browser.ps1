# The web AIs (Gemini, Google Flow) in the signed-in tabs of the user's own Chrome: core/bridge (local server)
# and core/extension (Product Review). The bridge hands the extension one job at a time, since a page only works while its
# tab is shown, so a call also waits its turn there: up to $script:BridgeQueueSec more than its own time.
$script:BridgeUrl = 'http://127.0.0.1:8775'
$script:BridgeQueueSec = 1800
$script:BridgeHubRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

function Get-ImageBridgeStatus {
    try { return Invoke-RestMethod -Uri "$script:BridgeUrl/status" -TimeoutSec 3 } catch { return $null }
}

# The bridge and the extension, ready: core/bridge/ensure.mjs installs and starts the bridge (again after Cập nhật),
# starts Chrome when the extension is not connected and reloads an extension of another version. -NewSession: a run
# starts here, so the tabs of the Product Review group are closed first (none while another tool's job runs).
function Start-ImageBridge([string]$ProjectRoot, [switch]$NewSession) {
    $ensure = Join-Path $script:BridgeHubRoot 'core/bridge/ensure.mjs'
    $flags = @(if ($NewSession) { '--session' })
    $answer = $null
    try { $answer = (& node $ensure @flags | Select-Object -Last 1) | ConvertFrom-Json } catch {}
    if (-not $answer) { throw '[CAUSE:BRIDGE] Không bật được bridge (core/bridge). Mở Cấu hình xem Node.js đã cài chưa rồi chạy lại.' }
    if (-not $answer.ok) { throw "[CAUSE:BRIDGE] $($answer.error)" }
}

# A bridge that stopped mid-run (the call ends with no answer, then Connection refused) is started again, so the
# next try reaches one.
function Restore-ImageBridge {
    if ($null -ne (Get-ImageBridgeStatus)) { return }
    try { Start-ImageBridge $script:BridgeHubRoot } catch {}
}

# The bridge answers {"error": "..."} with escaped characters; the message itself is what the cause is read from.
function Get-BridgeError($ErrorRecord) {
    $text = if ($ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
    try { $json = $text | ConvertFrom-Json; if ($json.error) { return [string]$json.error } } catch {}
    return $text
}

# $Kind and $Options go to the page as they are (Grok: image or video, and the video's length, resolution, sound).
function Send-BridgeJob([string]$Platform, [string]$Prompt, [string[]]$Images, [string]$Output, [int]$TimeoutSec, [string]$Kind = '', [hashtable]$Options = @{}) {
    $job = @{ platform = $Platform; prompt = $Prompt; images = @($Images | Where-Object { $_ }); output = $Output; timeoutSec = $TimeoutSec }
    if ($Kind) { $job.kind = $Kind; $job.options = $Options }
    $body = $job | ConvertTo-Json -Depth 4
    return Invoke-RestMethod -Uri "$script:BridgeUrl/generate" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec ($TimeoutSec + 120 + $script:BridgeQueueSec)
}

# A text reply from a web AI (Gemini, in a temporary chat that leaves nothing in its history): written to $ResultFile
# and returned. One retry for a busy page; a timeout or a missing sign-in stops there.
function Invoke-BrowserText([string]$Platform, [string]$Prompt, [string[]]$Images, [string]$ResultFile, [int]$TimeoutSec = 300) {
    $name = (Get-HubAIProvider $Platform).Name
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Send-BridgeJob $Platform $Prompt $Images $ResultFile $TimeoutSec | Out-Null
            $text = [IO.File]::ReadAllText($ResultFile, [Text.Encoding]::UTF8).Trim()
            # One finished call, counted in the app's usage line (web AIs report no tokens).
            if ($text) { Write-Host "  [AI-CALL] $Platform"; return $text }
            $detail = "$name trả lời trống."
        } catch { $detail = Get-BridgeError $_; Restore-ImageBridge }
        if ($attempt -eq 2 -or $detail -match 'Hết thời gian|timeout|đăng nhập|Extension|google\.com/sorry') { break }
        Write-Host "  [RETRY] $name; attempt $($attempt + 1)/2..." -ForegroundColor Yellow
    }
    # Google's "unusual traffic" page (google.com/sorry): only the user's own check ends it, so it is not retried.
    $cause = if ($detail -match 'google\.com/sorry') { 'QUOTA' } elseif ($detail -match 'Hết thời gian|timeout') { 'AI_TIMEOUT' } elseif ($detail -match 'đăng nhập|Extension') { 'BRIDGE' } else { 'BUSY' }
    throw "AI failed. ${name}: $detail [CAUSE:$cause]"
}

# One image from a web AI (Google Flow), saved as PNG at $Output. Not retried here: the workflow first looks
# for an image that arrived anyway.
# Options: Aspect (Grok: 9:16, 16:9, 1:1; left as the page has it when not given).
function Invoke-BrowserImage([string]$Platform, [string]$Prompt, [string[]]$Images, [string]$Output, [int]$TimeoutSec = 600, [hashtable]$Options = @{}) {
    $page = @{}
    if ($Options.Aspect) { $page.aspect = [string]$Options.Aspect }
    try {
        $result = Send-BridgeJob $Platform $Prompt $Images $Output $TimeoutSec 'image' $page
    } catch {
        $detail = Get-BridgeError $_
        Restore-ImageBridge
        # A sign-in or a Flow account not set up for images (its first-visit screen, Tác nhân on) needs the user, so it is
        # not retried (BRIDGE).
        # A refusal (Flow: may violate its policies) comes back the same for the same images and prompt: not retried.
        $cause = if ($detail -match 'chính sách|polic(y|ies)|từ chối tạo|kiểm duyệt|moderat') { 'POLICY' } elseif ($detail -match 'Hết thời gian|timeout') { 'AI_TIMEOUT' } elseif ($detail -match 'đăng nhập|Extension|Google Flow của tài khoản đang chọn') { 'BRIDGE' } else { 'BUSY' }
        throw "[CAUSE:$cause] $Platform không tạo được ảnh. $detail"
    }
    ConvertTo-PngFile $Output
    Write-Host "  [AI-CALL] $Platform"
    return $result
}

# One video from a web AI (Grok), saved as MP4 at $Output: image 1 is its first frame, image 2 (optional) its last.
# Options: Seconds, Resolution, Audio, Aspect. Not retried here, as an image: the workflow decides.
function Invoke-BrowserVideo([string]$Platform, [string]$Prompt, [string[]]$Images, [string]$Output, [hashtable]$Options = @{}, [int]$TimeoutSec = 900) {
    $page = @{}
    if ($Options.ContainsKey('Seconds')) { $page.seconds = [int]$Options.Seconds }
    if ($Options.ContainsKey('Resolution')) { $page.resolution = [string]$Options.Resolution }
    if ($Options.ContainsKey('Audio')) { $page.audio = [bool]$Options.Audio }
    if ($Options.Aspect) { $page.aspect = [string]$Options.Aspect }
    try {
        $result = Send-BridgeJob $Platform $Prompt $Images $Output $TimeoutSec 'video' $page
    } catch {
        $detail = Get-BridgeError $_
        Restore-ImageBridge
        $cause = if ($detail -match 'chính sách|polic(y|ies)|từ chối tạo|kiểm duyệt|moderat') { 'POLICY' } elseif ($detail -match 'hết lượt|giới hạn|limit') { 'QUOTA' } elseif ($detail -match 'Hết thời gian|timeout') { 'AI_TIMEOUT' } elseif ($detail -match 'đăng nhập|Extension') { 'BRIDGE' } else { 'BUSY' }
        throw "[CAUSE:$cause] $Platform không tạo được video. $detail"
    }
    if (-not (Test-Path -LiteralPath $Output) -or (Get-Item -LiteralPath $Output).Length -lt 10000) { throw "[CAUSE:BUSY] $Platform trả về video rỗng." }
    Write-Host "  [AI-CALL] $Platform video"
    return $result
}
