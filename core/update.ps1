# Run from Cập nhật: bring Product Video up to the latest GitHub Release (vX.Y.Z) of hoangpham2263/product-video.
# Git checkouts use git pull; ZIP installs download the newest release ZIP. User data is never touched.
# -Check prints the newer version ('' when current); -Apply installs it (the app reopens itself afterwards).
param([string]$Root = (Split-Path $PSScriptRoot -Parent), [switch]$NoRun, [switch]$Check, [switch]$Apply)
$ErrorActionPreference = 'Stop'
$script:Repo = 'hoangpham2263/product-video'
$script:Asset = 'product-video.zip'
# Local data the app writes; an update keeps it as it is (AGENTS.md is merged, see Merge-AgentInstructions).
$script:KeepPaths = '^(workspace|\.git|core/bridge/node_modules|AGENTS\.md)(/|$)'

function Copy-AppUpdate([string]$Source, [string]$Target) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\', '/').Length + 1) -replace '\\', '/'
        if ($relative -match $script:KeepPaths) { continue }
        $destination = Join-Path $Target $relative
        # A file the running app holds open (its window icon, say) cannot be replaced; unchanged ones are left alone.
        $current = Get-Item -LiteralPath $destination -ErrorAction SilentlyContinue
        if ($current -and $current.Length -eq $file.Length -and (Get-FileHash -LiteralPath $current.FullName).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}

# AGENTS.md: the guide (everything outside the lessons block) follows the release, and the lessons block keeps this
# machine's lessons, adding the release's lessons it has not had yet (by id). workspace/agent-lessons-seen.txt keeps
# each release lesson's id and text hash: a lesson removed here stays removed, and one still exactly as last shipped
# takes the release's newer wording, while one edited here is kept. The previous file is backed up first. A file that
# cannot be read this way is left untouched.
$script:LessonBlock = '(?ms)^<!-- app-lessons:start -->\r?\n(?<body>.*?)^<!-- app-lessons:end -->'
function Get-AgentLessonItems([string]$Body) {
    if ($Body -match '(?m)^```json') { return $null }
    $items = [regex]::Matches($Body, '(?ms)^### [^\r\n]+\r?\n<!-- app-lesson: (?<meta>[^\r\n]+) -->\r?\n.*?(?=^### |\z)')
    if ($items.Count -ne [regex]::Matches($Body, '<!-- app-lesson:').Count) { return $null }
    return , @(foreach ($item in $items) { [pscustomobject]@{ Id = [string](ConvertFrom-Json -InputObject $item.Groups['meta'].Value).id; Text = $item.Value } })
}

function Merge-AgentInstructions([string]$Source, [string]$Target) {
    $from = Join-Path $Source 'AGENTS.md'; $to = Join-Path $Target 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $from)) { return }
    if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $from -Destination $to; return }
    try {
        $upstream = [IO.File]::ReadAllText($from); $local = [IO.File]::ReadAllText($to)
        $up = [regex]::Matches($upstream, $script:LessonBlock); $mine = [regex]::Matches($local, $script:LessonBlock)
        if ($up.Count -ne 1 -or $mine.Count -ne 1) { return }
        $upItems = Get-AgentLessonItems $up[0].Groups['body'].Value; $myItems = Get-AgentLessonItems $mine[0].Groups['body'].Value
        if ($null -eq $upItems -or $null -eq $myItems) { return }
        $seenFile = Join-Path $Target 'workspace/agent-lessons-seen.txt'
        $hash = { param($Text) [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($Text -replace '\r', '').Trim()))) -replace '-' }
        $seen = @{}
        if (Test-Path -LiteralPath $seenFile) { foreach ($line in Get-Content -LiteralPath $seenFile) { $id, $sum = $line -split '\s+', 2; if ($id) { $seen[$id] = [string]$sum } } }
        $have = @($myItems | ForEach-Object Id)
        $added = @($upItems | Where-Object { $_.Id -notin $have -and -not $seen.ContainsKey($_.Id) })
        $body = $mine[0].Groups['body'].Value
        foreach ($item in $myItems) {
            $next = @($upItems | Where-Object Id -eq $item.Id)
            if ($next.Count -and $seen[$item.Id] -and $seen[$item.Id] -eq (& $hash $item.Text)) { $body = $body.Replace($item.Text.TrimEnd(), $next[0].Text.TrimEnd()) }
        }
        if ($added.Count) { $body = $body.TrimEnd() + "`n`n" + (($added | ForEach-Object { $_.Text.TrimEnd() }) -join "`n`n") + "`n`n" }
        $merged = $upstream.Substring(0, $up[0].Index) + "<!-- app-lessons:start -->`n" + $body + '<!-- app-lessons:end -->' + $upstream.Substring($up[0].Index + $up[0].Length)
        New-Item -ItemType Directory -Force -Path (Join-Path $Target 'workspace/backups') | Out-Null
        if ($merged -ne $local) {
            Copy-Item -LiteralPath $to -Destination (Join-Path $Target 'workspace/backups/AGENTS-before-update.md') -Force
            [IO.File]::WriteAllText($to, $merged, [Text.UTF8Encoding]::new($true))
        }
        foreach ($item in $upItems) { $seen[$item.Id] = & $hash $item.Text }
        Set-Content -LiteralPath $seenFile -Value @($seen.Keys | Sort-Object | ForEach-Object { "$_ $($seen[$_])" }) -Encoding UTF8
    } catch { Write-Verbose $_ }
}

function Get-LatestRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$script:Repo/releases/latest" -Headers @{ 'User-Agent' = 'product-video' } -TimeoutSec 10
}

# The version in use: the release a ZIP install came from, or the newest tag of a git checkout (as Get-AppVersion).
function Get-InstalledVersion([string]$Root) {
    $versionFile = Join-Path $Root 'workspace/version.txt'
    if (Test-Path -LiteralPath $versionFile) { return (Get-Content -LiteralPath $versionFile -Raw).Trim() }
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) { return [string](git -C $Root describe --tags --abbrev=0 2>$null) }
    return ''
}

# Git checkouts and ZIP installs alike: a newer GitHub Release is the update, named by its version.
function Get-AppUpdate([string]$Root) {
    $latest = (Get-LatestRelease).tag_name
    return $(if ($latest -match '^v\d+(\.\d+)*$' -and $latest -ne (Get-InstalledVersion $Root)) { $latest } else { '' })
}

function Update-App([string]$Root) {
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        if (Get-Command git -ErrorAction SilentlyContinue) { git -C $Root pull --ff-only --quiet 2>$null | Out-Null }
        return
    }
    $headers = @{ 'User-Agent' = 'product-video' }
    $release = Get-LatestRelease
    $latest = $release.tag_name
    $asset = @($release.assets | Where-Object name -eq $script:Asset)
    if ($latest -notmatch '^v\d+(\.\d+)*$' -or -not $asset.Count) { return }
    $versionFile = Join-Path $Root 'workspace/version.txt'
    if ((Test-Path -LiteralPath $versionFile) -and (Get-Content -LiteralPath $versionFile -Raw).Trim() -eq $latest) { return }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('product-video-update-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
        $zip = Join-Path $temp 'app.zip'
        Invoke-WebRequest -Uri $asset[0].browser_download_url -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 120
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $temp 'x') -Force
        $source = @(Get-ChildItem -LiteralPath (Join-Path $temp 'x') -Directory)[0].FullName
        if (-not (Test-Path -LiteralPath (Join-Path $source 'core/update.ps1'))) { throw 'ZIP không đúng cấu trúc Product Video.' }
        Copy-AppUpdate $source $Root
        Merge-AgentInstructions $source $Root
        New-Item -ItemType Directory -Force -Path (Split-Path $versionFile -Parent) | Out-Null
        Set-Content -LiteralPath $versionFile -Value $latest -Encoding ASCII
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Check) { return (Get-AppUpdate $Root) }
if ($Apply) { Update-App $Root }
