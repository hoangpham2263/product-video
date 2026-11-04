# Settings (Model AI, the Google account) live in workspace/config/<name> of the install. Outside an install (tests
# in a temp folder) a file stays in the workspace it is asked for.
function Get-SharedConfigPath([string]$WorkspaceRoot, [string]$Name) {
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $WorkspaceRoot -Parent) 'core/update.ps1'))) { return (Join-Path $WorkspaceRoot $Name) }
    return (Join-Path $WorkspaceRoot "config/$Name")
}
