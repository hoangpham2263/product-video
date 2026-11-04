# Entry of a run. The job is the JSON the window sends (server.mjs writes it to workspace/temp); the work is
# Invoke-VideoRun (video.ps1).
param(
    [Parameter(Mandatory)][string]$JobFile,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $OutputEncoding
[Console]::OutputEncoding = $OutputEncoding

foreach ($module in @('../core/ai/ai.ps1', 'product-rules.ps1', 'ffmpeg.ps1', 'video.ps1')) {
    . (Join-Path $PSScriptRoot $module)
}
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/output' }
exit (Invoke-VideoRun (Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json) $OutDir)
