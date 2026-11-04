# The AIs every tool can use, behind one call: Invoke-HubAI -Kind text|image|video -Ai <id> -Prompt ... -Output <file>.
# The app dot-sources this file (from src: ../core/ai/ai.ps1) and keeps only its own prompts and
# choices. A new AI is one entry in $script:HubAIProviders plus its provider file in providers/:
#   cli      a command on this machine (codex, agy)
#   browser  a site in the user's own Chrome, through core/bridge and the Product Review extension (core/extension/sites/)
# Errors end in [CAUSE:<kind>] (AUTH, QUOTA, BUSY, NETWORK, AI_TIMEOUT, BRIDGE, ...), which tools show and retry by.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'providers/codex.ps1')
. (Join-Path $PSScriptRoot 'providers/antigravity.ps1')
. (Join-Path $PSScriptRoot 'providers/browser.ps1')

# Every call, one JSON line in workspace/logs/ai-usage.jsonl (Cấu hình → Lượt dùng AI): the CLIs here, the web
# AIs in core/bridge/server.mjs (which knows the Google account a job ran with). Tests point HUB_AI_USAGE_FILE elsewhere.
$script:HubAIUsageFile = if ($env:HUB_AI_USAGE_FILE) { $env:HUB_AI_USAGE_FILE } else { Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'workspace/logs/ai-usage.jsonl' }
function Add-HubAIUsage([string]$Ai, [string]$Kind, [string]$Account, [bool]$Ok, [string]$Cause = '', [int]$Ms = 0, $Tokens = $null) {
    $entry = [ordered]@{ t = [DateTime]::UtcNow.ToString('o'); ai = $Ai; kind = $Kind; account = $Account; ok = $Ok; ms = $Ms }
    if ($Cause) { $entry.cause = $Cause }
    if ($Tokens) { $entry.in = [long]$Tokens.Input; $entry.cached = [long]$Tokens.Cached; $entry.out = [long]$Tokens.Output }
    $line = (ConvertTo-Json -InputObject $entry -Compress) + "`n"
    # Parallel workers append to the same file: one at a time, and never fail a call over it.
    for ($i = 0; $i -lt 20; $i++) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $script:HubAIUsageFile -Parent) | Out-Null
            [IO.File]::AppendAllText($script:HubAIUsageFile, $line, [Text.UTF8Encoding]::new($false)); return
        } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } catch { return }
    }
}

$script:HubAIProviders = [ordered]@{
    codex = [pscustomobject]@{ Name = 'Codex CLI'; Via = 'cli'; Kinds = @('text', 'image') }
    gemini = [pscustomobject]@{ Name = 'Gemini web'; Via = 'browser'; Kinds = @('text') }
    flow = [pscustomobject]@{ Name = 'Google Flow'; Via = 'browser'; Kinds = @('image') }
    grok = [pscustomobject]@{ Name = 'Grok web'; Via = 'browser'; Kinds = @('image', 'video') }
    antigravity = [pscustomobject]@{ Name = 'Antigravity CLI'; Via = 'cli'; Kinds = @('text') }
}

function Get-HubAIProvider([string]$Id) {
    $provider = $script:HubAIProviders[$Id]
    if (-not $provider) { throw "AI không hỗ trợ: $Id. [CAUSE:UNSUPPORTED]" }
    return $provider
}

# The AIs that can do one kind of work, for a tool's choices: @{ id; name }.
function Get-HubAIChoices([ValidateSet('text', 'image', 'video')][string]$Kind) {
    foreach ($id in $script:HubAIProviders.Keys) {
        $provider = $script:HubAIProviders[$id]
        if ($provider.Kinds -contains $Kind) { [pscustomobject]@{ id = $id; name = $provider.Name } }
    }
}

# Text: the reply, also written to $Output. Image: the image saved at $Output (PNG); Codex saves it where the prompt
# says and returns its reply, a web AI returns the bridge's answer (source, bytes). Video: an MP4 at $Output, from a web
# AI (Grok): image 1 is the first frame, image 2 (optional) the last.
# Options, all optional: TimeoutSec; Grok: Aspect (9:16, 16:9, 1:1), video also Seconds (6, 10, 15), Resolution
# (480p, 720p, 1080p), Audio; Codex: WorkDir (required), Model, Effort, ReconnectSec, Attempts, RetryDelaySec,
# ReplyFile (an image's reply).
function Invoke-HubAI {
    param(
        [Parameter(Mandatory)][ValidateSet('text', 'image', 'video')][string]$Kind,
        [Parameter(Mandatory)][string]$Ai,
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$Images = @(),
        [Parameter(Mandatory)][string]$Output,
        [hashtable]$Options = @{}
    )
    $provider = Get-HubAIProvider $Ai
    if ($provider.Kinds -notcontains $Kind) { throw "AI failed. $($provider.Name) không làm được việc này ($Kind). [CAUSE:UNSUPPORTED]" }
    $timeout = if ($Options.ContainsKey('TimeoutSec')) { [Math]::Max(1, [int]$Options.TimeoutSec) } else { 0 }
    if ($provider.Via -eq 'cli') {
        # The bridge counts the web AIs; the CLIs are counted here, failures too, with what stopped them.
        $watch = [Diagnostics.Stopwatch]::StartNew(); $script:CodexCallTokens = $null
        $account = if ($Ai -eq 'codex') { Get-CodexAccount } else { '' }
        try { $result = Invoke-HubAIProvider $Kind $Ai $Prompt $Images $Output $Options $timeout }
        catch {
            $cause = if ($_.Exception.Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { 'UNKNOWN' }
            Add-HubAIUsage $Ai $Kind $account $false $cause ([int]$watch.ElapsedMilliseconds) $script:CodexCallTokens
            throw
        }
        Add-HubAIUsage $Ai $Kind $account $true '' ([int]$watch.ElapsedMilliseconds) $script:CodexCallTokens
        return $result
    }
    return Invoke-HubAIProvider $Kind $Ai $Prompt $Images $Output $Options $timeout
}

# What Codex alone needs to deliver an image: one pass with its image tool, saved as a PNG at $Output.
function Get-CodexImageDelivery([string]$Output) {
    @"
SINGLE-PASS DELIVERY: create ONE image with your image tool from the attached images, then save the complete image it returns, unprocessed. The user reviews it: do not run visual QA, compare or score variants, or regenerate to satisfy your own critique.
Save a new PNG at this exact path: $Output
Do not modify any input file. Reply briefly in English.
"@
}

# The CLIs are agents that can open files. Every input is in the prompt and its images, so they are told to stay in them.
function Get-CliInputBoundary {
    'CLOSED INPUT: this prompt and the attached images are everything you need. Do not open, list or search any other file or folder, do not read project notes or instructions, and do not run commands to look around.'
}

function Invoke-HubAIProvider([string]$Kind, [string]$Ai, [string]$Prompt, [string[]]$Images, [string]$Output, [hashtable]$Options, [int]$timeout) {
    if ($Ai -in @('codex', 'antigravity')) { $Prompt += "`n" + (Get-CliInputBoundary) }
    switch ($Ai) {
        'codex' {
            $codex = @{
                Sandbox = $(if ($Kind -eq 'image') { 'workspace-write' } else { 'read-only' })
                WorkDir = $Options.WorkDir; Model = [string]$Options.Model; Effort = [string]$Options.Effort; TimeoutSec = $timeout
            }
            foreach ($key in @('ReconnectSec', 'Attempts', 'RetryDelaySec')) { if ($Options.ContainsKey($key)) { $codex[$key] = [int]$Options[$key] } }
            if (-not $codex.WorkDir) { throw 'Invoke-HubAI codex: Options.WorkDir is required.' }
            # Every image AI gets the same request; Codex, an agent that saves files, is also told where and how. Its
            # reply then goes to Options.ReplyFile (beside the image when not given).
            $reply = $Output
            if ($Kind -eq 'image') {
                $Prompt += "`n" + (Get-CodexImageDelivery $Output)
                $reply = if ($Options.ReplyFile) { [string]$Options.ReplyFile } else { "$Output.reply.txt" }
            }
            return Invoke-CodexExec -PromptText $Prompt -Images $Images -ResultFile $reply @codex
        }
        'antigravity' { return Invoke-AntigravityText $Prompt $Images $Output $(if ($timeout) { $timeout } else { 300 }) }
        default {
            if ($Kind -eq 'text') { return Invoke-BrowserText $Ai $Prompt $Images $Output $(if ($timeout) { $timeout } else { 300 }) }
            if ($Kind -eq 'video') { return Invoke-BrowserVideo $Ai $Prompt $Images $Output $Options $(if ($timeout) { $timeout } else { 900 }) }
            return Invoke-BrowserImage $Ai $Prompt $Images $Output $(if ($timeout) { $timeout } else { 600 }) $Options
        }
    }
}
