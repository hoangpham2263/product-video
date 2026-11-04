# The cut into each shot (ffmpeg xfade names), chosen to fit the two shots: by Codex from the pictures, with the
# camera moves as the fallback. The user's own banned list (workspace/lua-chon.json, the window's Hiệu ứng page) is
# never used.

# What a move mostly is: push, pull, right, left, rise, lower (the camera's way) or still.
function Get-MoveKind($Move) {
    $z = [Math]::Log([Math]::Max(0.01, [double]$Move.zoom)); $x = [double]$Move.panX; $y = [double]$Move.panY
    $big = [Math]::Max([Math]::Abs($z), [Math]::Max([Math]::Abs($x), [Math]::Abs($y)))
    if ($big -lt 0.02) { 'still' }
    elseif ($big -eq [Math]::Abs($z)) { if ($z -gt 0) { 'push' } else { 'pull' } }
    elseif ($big -eq [Math]::Abs($x)) { if ($x -lt 0) { 'right' } else { 'left' } }
    elseif ($y -gt 0) { 'rise' } else { 'lower' }
}

# The cut into each shot after the first (ffmpeg xfade names), by the shot's own move: a camera sliding right comes in
# sliding (the picture moves left), a rise comes in from above. Settings transitions: move kind -> names, taken in turn
# so one kind does not repeat the same cut. Never one of bannedTransitions (the user's own list; the first allowed of
# fade, fadeslow instead). Never two moving cuts (slide, smooth, wipe, cover, reveal) in a row: the user found the frame
# sweeping one way, then back the other way at the next cut, too jerky (04/11/2026); after one, the next is a fade.
function Get-ShotTransitions($Shots, $Settings) {
    $Shots = @($Shots)
    $banned = @($Settings.bannedTransitions)
    $spare = @('fade', 'fadeslow') | Where-Object { $banned -notcontains $_ } | Select-Object -First 1
    if (-not $spare) { $spare = 'fade' }
    $moving = { param($name) $name -match '^(smooth|slide|wipe|cover|reveal)' }
    $used = @{}; $last = ''
    @(for ($i = 1; $i -lt $Shots.Count; $i++) {
        $kind = Get-MoveKind $Shots[$i].Move
        $list = @($Settings.transitions.$kind | Where-Object { $_ -and $banned -notcontains $_ })
        $pick = $spare
        if ($list.Count) {
            $n = [int]$used[$kind]; $used[$kind] = $n + 1
            $pick = $list[$n % $list.Count]
            if ((& $moving $pick) -and (& $moving $last)) {
                $calm = @($list | Where-Object { -not (& $moving $_) })
                $pick = if ($calm.Count) { $calm[0] } else { $spare }
            }
        }
        $last = $pick
        $pick
    })
}

# The cuts chosen to fit the pictures (the user, 04/11/2026: a transition must suit the two shots and their setting, not
# be picked at random): Codex sees, for each cut, the last frame before beside the first frame after, and picks from the
# allowed transitions. The rules hold after it: never a banned one, never two moving cuts in a row. $Rule: the
# move-based picks (plan.ps1 Get-ShotTransitions), for any cut Codex leaves out or names wrong. $Labels: each clip's
# "angle, move". Writes logs/noi-<k>.jpg and logs/chuyen-canh.json (the picks and why).
function Select-ShotTransitions([string]$ProductName, [string[]]$Files, [string[]]$Labels, [string[]]$Rule, $Settings, [string]$Folder, [string]$Logs) {
    $allowed = @($Settings.transitionNames | Where-Object { @($Settings.bannedTransitions) -notcontains $_ })
    $images = @(); $cuts = @()
    for ($k = 1; $k -lt $Files.Count; $k++) {
        $image = Join-Path $Logs "noi-$k.jpg"
        Assert-HubFfmpeg (Invoke-HubFfmpeg @('-y', '-hide_banner', '-sseof', '-0.1', '-i', $Files[$k - 1], '-i', $Files[$k], '-filter_complex', '[0:v]scale=384:-2,setsar=1[a];[1:v]scale=384:-2,setsar=1[b];[a][b]hstack', '-frames:v', '1', '-update', '1', $image)) 'lấy được khung chỗ nối'
        $images += $image
        $cuts += [pscustomobject]@{ Index = $k; From = $Labels[$k - 1]; To = $Labels[$k] }
    }
    $prompt = New-TransitionPrompt $ProductName $cuts $allowed ([double]$Settings.fadeSeconds)
    Write-Utf8 (Join-Path $Logs 'chuyen-canh-prompt.txt') $prompt
    $reply = [string](Invoke-HubAI -Kind text -Ai codex -Prompt $prompt -Images $images -Output (Join-Path $Logs 'chuyen-canh-tra-loi.txt') -Options @{ WorkDir = $Folder; TimeoutSec = 600 })
    $json = [regex]::Match($reply, '\[[\s\S]*\]')
    if (-not $json.Success) { throw 'Codex không trả về danh sách chuyển cảnh.' }
    $parsed = ConvertFrom-Json $json.Value  # Windows PowerShell 5.1 hands a JSON array on as one item: unroll it here
    $picks = @($parsed)
    $moving = { param($name) $name -match '^(smooth|slide|wipe|cover|reveal)' }
    $chosen = @(); $log = @(); $last = ''
    for ($k = 1; $k -lt $Files.Count; $k++) {
        $pick = $picks | Where-Object { [int]$_.cut -eq $k } | Select-Object -First 1
        $name = if ($pick -and $allowed -contains [string]$pick.transition) { [string]$pick.transition } else { $Rule[$k - 1] }
        if ((& $moving $name) -and (& $moving $last)) { $name = if (-not (& $moving $Rule[$k - 1])) { $Rule[$k - 1] } else { 'fade' } }
        $chosen += $name; $last = $name
        $log += [pscustomobject]@{ cut = $k; from = $Labels[$k - 1]; to = $Labels[$k]; transition = $name; codex = [string]$pick.transition; why = [string]$pick.why }
    }
    Write-Utf8 (Join-Path $Logs 'chuyen-canh.json') (ConvertTo-Json -InputObject $log -Depth 3)
    $chosen
}
