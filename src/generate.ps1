# The AI steps of a run (video.ps1): key frames drawn by Codex CLI from the product photo, clips filmed by Grok web from
# each frame. Prompts are prompts.ps1's.

# Width / height of the photo against the video's shape: true when they differ enough to need an as-photo frame of
# the video's shape (Grok's video keeps its start image's shape, tried 04/11/2026).
function Test-PhotoShape([string]$Photo, [string]$Aspect) {
    $info = Get-HubVideoInfo $Photo
    $want = switch ($Aspect) { '2:3' { 2 / 3 } '3:2' { 3 / 2 } default { 1 } }
    [Math]::Abs([Math]::Log(($info.Width / [double]$info.Height) / $want)) -gt 0.15
}

# The size Codex is asked for.
function Get-CodexShape([string]$Aspect) {
    switch ($Aspect) { '2:3' { 'portrait 2:3 (1024x1536)' } '3:2' { 'landscape 3:2 (1536x1024)' } default { 'square 1:1 (1024x1024)' } }
}

# Key frames by Codex CLI, $Parallel at once: each is its own codex process saving a PNG in $Folder.
#   $Frames: { Id, Prompt, Images, File }. Returns @{ Id = error message, '' when made }.
function Invoke-CodexFrames($Frames, [string]$Aspect, [string]$Folder, [int]$Parallel) {
    $shape = "`nOUTPUT SHAPE: $(Get-CodexShape $Aspect)."
    $ai = Join-Path (Get-ToolRoot) 'core/ai/ai.ps1'
    $jobs = @(); $result = @{}
    foreach ($frame in $Frames) {
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $Parallel) { Start-Sleep -Seconds 3 }
        Write-Host "  [FRAME] $($frame.Id)" -ForegroundColor Cyan
        $jobs += Start-Job -Name $frame.Id -ArgumentList $ai, ($frame.Prompt + $shape), $frame.Images, $frame.File, $Folder -ScriptBlock {
            param($ai, $prompt, $images, $file, $folder)
            . $ai
            try { [void](Invoke-HubAI -Kind image -Ai codex -Prompt $prompt -Images $images -Output $file -Options @{ WorkDir = $folder; TimeoutSec = 900 }); '' }
            catch { $_.Exception.Message }
        }
    }
    $jobs | Wait-Job | Out-Null
    foreach ($job in $jobs) {
        $message = [string](Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1)
        $file = ($Frames | Where-Object { $_.Id -eq $job.Name } | Select-Object -First 1).File
        $result[$job.Name] = if (Test-Path -LiteralPath $file) { '' } elseif ($message) { $message } else { 'Codex không trả về ảnh.' }
    }
    $jobs | Remove-Job -Force
    $result
}

# One Grok video, tried again once when Grok was busy or slow. A sign-in, quota or bridge problem stops the run.
function Invoke-GrokClip([string]$Prompt, [string]$Image, [string]$Output, [hashtable]$Options) {
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-HubAI -Kind video -Ai 'grok' -Prompt $Prompt -Images @($Image) -Output $Output -Options $Options }
        catch {
            $cause = Get-ErrorCause $_.Exception.Message
            if ($cause -in @('QUOTA', 'AUTH', 'BRIDGE')) { $script:Run.Abort = $true }
            if ($attempt -ge 2 -or $cause -notin @('BUSY', 'AI_TIMEOUT', 'NETWORK')) { throw }
            Write-Host '  [RETRY] Grok video, attempt 2/2' -ForegroundColor Yellow
        }
    }
}
