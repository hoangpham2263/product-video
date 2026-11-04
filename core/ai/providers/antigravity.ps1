# Antigravity CLI (agy), signed in with Google: text only, no API key.
# agy takes its prompt only as an argument, so the prompt and its images go into a folder of their own and agy is
# told to read them there (also clear of Windows' command-line length limit).

function Get-AntigravityCommand {
    $command = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($path in @((Join-Path $HOME '.local/bin/agy'), (Join-Path $HOME '.local/bin/agy.exe'))) { if (Test-Path -LiteralPath $path) { return $path } }
    throw 'AI failed. Chưa có Antigravity CLI (agy). Cài Antigravity rồi đăng nhập Google, hoặc chọn AI khác. [CAUSE:AUTH]'
}

function Invoke-AntigravityText([string]$Prompt, [string[]]$Images, [string]$ResultFile, [int]$TimeoutSec = 300) {
    $agy = Get-AntigravityCommand
    # A folder of its own in the system temp, outside the repo: agy would otherwise read the AGENTS.md files above
    # the run's logs. It holds only this prompt and its images.
    $work = Join-Path ([IO.Path]::GetTempPath()) "hub-agy-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    [IO.File]::WriteAllText((Join-Path $work 'prompt.md'), $Prompt, [Text.UTF8Encoding]::new($false))
    $names = @()
    $i = 0
    foreach ($image in @($Images | Where-Object { $_ })) {
        $i++
        $name = "image-$i$([IO.Path]::GetExtension($image).ToLowerInvariant())"
        Copy-Item -LiteralPath $image -Destination (Join-Path $work $name) -Force
        $names += $name
    }
    $images = if ($names.Count) { "The images it refers to, in order, are $($names -join ', ') in the same folder." } else { 'It has no images.' }
    $task = "Your task is in prompt.md in the current folder. $images Do exactly what prompt.md asks and reply with only the answer it asks for, nothing else. Do not create or change any file."
    $detail = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $info = [Diagnostics.ProcessStartInfo]::new($agy, "--print-timeout $($TimeoutSec)s -p=`"$task`"")
        $info.WorkingDirectory = $work
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $info.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($info)
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(($TimeoutSec + 30) * 1000)) {
            try { $process.Kill() } catch {}
            $detail = "hết $TimeoutSec giây"
            continue
        }
        $text = $out.Result.Trim()
        if ($process.ExitCode -eq 0 -and $text) {
            [IO.File]::WriteAllText($ResultFile, $text, [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            # One finished call, counted in the app's usage line (they report no tokens).
            Write-Host '  [AI-CALL] antigravity'
            return $text
        }
        $detail = (@($err.Result, $text) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
        if ($detail -match '(?i)sign in|login|unauthor') { break }
        if ($attempt -lt 2) { Write-Host "  [RETRY] Antigravity; attempt 2/2..." -ForegroundColor Yellow }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $cause = if ($detail -match '(?i)sign in|login|unauthor') { 'AUTH' } elseif ($detail -match 'giây|timeout') { 'AI_TIMEOUT' } elseif ($detail -match '(?i)quota|limit|429') { 'QUOTA' } else { 'BUSY' }
    throw "AI failed. Antigravity CLI: $(if ($detail.Length -gt 300) { $detail.Substring(0, 300) } else { $detail }) [CAUSE:$cause]"
}
