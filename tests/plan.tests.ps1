﻿# Offline checks of src/plan.ps1 (no AI, no ffmpeg): the scenes and shots of a sample, the default shots, the plan
# file and the moves in words.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/plan.tests.ps1     (also run by tests/plan.test.mjs)
# Prints one line per check; exits 1 when any fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/plan.ps1')

$script:Failed = 0
function Assert-That([string]$Name, [scriptblock]$Check) {
    try { $ok = & $Check; $why = '' } catch { $ok = $false; $why = " ($($_.Exception.Message))" }
    if ($ok) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name$why" }
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null; $script:Failed++; Write-Host "FAIL $Name (no error)" }
    catch { if ($_.Exception.Message -match $Pattern) { Write-Host "ok   $Name" } else { $script:Failed++; Write-Host "FAIL $Name ($($_.Exception.Message))" } }
}
function Get-Shape($Items) { (@($Items) | ForEach-Object { '{0}-{1}' -f (Format-Seconds $_.Start), (Format-Seconds $_.End) }) -join ' ' }
function Get-Angles($Items) { (@($Items) | ForEach-Object { $_.Angle }) -join ',' }

$settings = Get-VideoSettings
# The checks below count on these; data/video.json changing them needs the checks looked at again.
Assert-That 'data/video.json: shotSeconds 2.6, minShot 1, maxShots 24, grokSeconds 6, maxZoom 1.25, maxPan 0.12, angles from close-up' {
    $settings.shotSeconds -eq 2.6 -and $settings.minShot -eq 1 -and $settings.maxShots -eq 24 -and $settings.grokSeconds -eq 6 -and
    $settings.maxZoom -eq 1.25 -and $settings.maxPan -eq 0.12 -and (@($settings.angles) -join ',') -eq 'close-up,room-wide,detail,high,profile-left,medium,overhead,hero'
}

# --- Get-VideoAspect ---
Assert-That 'Aspect: auto follows the sample (2:3, 3:2, 1:1), 2:3 without one; a choice wins' {
    (Get-VideoAspect 'auto' 720 1280) -eq '2:3' -and (Get-VideoAspect 'auto' 1920 1080) -eq '3:2' -and (Get-VideoAspect 'auto' 1000 1000) -eq '1:1' -and
    (Get-VideoAspect 'auto') -eq '2:3' -and (Get-VideoAspect '1:1' 720 1280) -eq '1:1'
}

# --- Get-SampleScenes ---
$scenes = Get-SampleScenes 10.04 @(5.25, 3.0) @('as-photo', 'detail', 'three-quarter-left') $settings
Assert-That 'Scenes: the cuts (any order) make the scenes, each with its planned angle' { (Get-Shape $scenes) -eq '0-3 3-5.25 5.25-10.04' -and (Get-Angles $scenes) -eq 'as-photo,detail,three-quarter-left' }
Assert-That 'Scenes: a cut under minShot after the last one, or before the end, is dropped; no plan, no angle' {
    $s = Get-SampleScenes 10 @(0.5, 4, 4.6, 9.5) @() $settings
    (Get-Shape $s) -eq '0-4 4-10' -and (Get-Angles $s) -eq ','
}

# --- Get-SampleShots ---
$shots = Get-SampleShots $scenes $settings
Assert-That 'Shots: each scene cut into equal pieces of at most shotSeconds' { (Get-Shape $shots) -eq '0-1.5 1.5-3 3-5.25 5.25-7.645 7.645-10.04' -and (@($shots | ForEach-Object { $_.Scene }) -join ',') -eq '1,1,2,3,3' }
Assert-That 'Shots: planned angles first; the rest in turn, never twice in a row nor before the planned next one' { (Get-Angles $shots) -eq 'as-photo,close-up,detail,three-quarter-left,room-wide' }
Assert-That 'Shots: a 20 s video of a 10 s sample without a plan: 8 shots of 2.5 s, from as-photo, angles in turn' {
    $s = Get-SampleShots (Get-SampleScenes 10 @() @() $settings) $settings 20
    $s.Count -eq 8 -and [Math]::Abs($s[0].Seconds - 2.5) -lt 1e-9 -and (Get-Angles $s) -eq 'as-photo,close-up,room-wide,detail,high,profile-left,medium,overhead'
}
Assert-Throws 'Shots: more than maxShots is refused' { $few = $settings.PSObject.Copy(); $few.maxShots = 10; Get-SampleShots (Get-SampleScenes 60 @() @() $settings) $few } 'tối đa 10'

# --- Get-DefaultShots ---
$default = Get-DefaultShots $settings 30
Assert-That 'Default: 30 s is 12 shots of 2.5 s, defaultShots in order, opening with a push-in and closing with a pull-back' {
    $default.Count -eq 12 -and [Math]::Abs($default[0].Seconds - 2.5) -lt 1e-9 -and $default[0].Angle -eq 'as-photo' -and $default[0].Move.zoom -eq 1.04 -and
    $default[11].Angle -eq 'as-photo' -and $default[11].Move.zoom -eq 0.96 -and (Get-Angles $default) -eq ((@($settings.defaultShots) | ForEach-Object { $_.angle }) -join ',')
}
Assert-That 'Default: 20 s is 8 shots, 60 s is 24' { (Get-DefaultShots $settings 20).Count -eq 8 -and (Get-DefaultShots $settings 60).Count -eq 24 }

# --- Read-ReferencePlan ---
$temp = Join-Path ([IO.Path]::GetTempPath()) ("pv-plan-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $video = Join-Path $temp 'mẫu.mp4'
    Assert-That 'Plan: none beside the video gives $null' { $null -eq (Read-ReferencePlan $video) }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/plan.mp4.json') -Destination "$video.json"
    $plan = Read-ReferencePlan $video
    Assert-That 'Plan: the library plan gives cuts after the first shot, an angle per shot and its note' { (@($plan.Cuts) -join ',') -eq '3,5.25' -and (@($plan.Angles) -join ',') -eq 'as-photo,detail,three-quarter-left' -and $plan.Note }
    Assert-That 'Plan: feeds Get-SampleScenes as the run does' { (Get-Shape (Get-SampleScenes 10.04 $plan.Cuts $plan.Angles $settings)) -eq '0-3 3-5.25 5.25-10.04' }
    [IO.File]::WriteAllText("$video.json", '{ "shots": [ { "start": 4, "angle": "close-up" }, { "start": 0, "angle": "front" }, { "start": 1.5, "angle": "detail" } ] }', [Text.UTF8Encoding]::new($false))
    $plan = Read-ReferencePlan $video
    Assert-That 'Plan: shots are sorted by start' { (@($plan.Cuts) -join ',') -eq '1.5,4' -and (@($plan.Angles) -join ',') -eq 'front,detail,close-up' }
    [IO.File]::WriteAllText("$video.json", '{ "shots": [ { "start": 0, "angle": "as-photo" }, { "start": 2, "angle": "spin" } ] }', [Text.UTF8Encoding]::new($false))
    Assert-Throws 'Plan: an angle not in data/angles.json is refused' { Read-ReferencePlan $video } 'góc lạ: spin'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }

# --- ConvertTo-MoveText --- (panX/panY: the picture's shift, + right/down; zoom: end size / start size)
function Get-Move([double]$PanX, [double]$PanY, [double]$Zoom) { ConvertTo-MoveText ([pscustomobject]@{ panX = $PanX; panY = $PanY; zoom = $Zoom }) $settings }
$m = Get-Move 0.02 -0.02 1.03
Assert-That 'Move: under 3% slide and 4% zoom is still' { $m.Vi -eq 'đứng yên' -and $m.En -match 'holds almost still' }
$m = Get-Move -0.05 0 1.1
Assert-That 'Move: picture growing and sliding left = push in, camera slides right' { $m.Vi -eq 'đẩy vào, trượt phải' -and $m.En -match 'pushes in .* about 10% larger' -and $m.En -match ' while the camera slowly slides to the right \(truck\), about 5% of the frame width' }
$m = Get-Move 0.08 0 0.9
Assert-That 'Move: picture shrinking and sliding right = pull back, camera slides left' { $m.Vi -eq 'kéo ra, trượt trái' -and $m.En -match 'pulls back .* about 10% smaller' -and $m.En -match 'slides to the left' }
$m = Get-Move 0 0.05 1
Assert-That 'Move: picture sliding down = camera rises; up = lowers' { $m.Vi -eq 'nâng lên' -and $m.En -match 'rises \(pedestal\), about 5% of the frame height' -and (Get-Move 0 -0.04 1).Vi -eq 'hạ xuống' }
$m = Get-Move -0.5 0.3 3
Assert-That 'Move: capped at maxZoom (25%) and maxPan (12%); a pull-back at 1/maxZoom (20%)' { $m.En -match '25% larger' -and $m.En -match '12% of the frame width' -and $m.En -match '12% of the frame height' -and (Get-Move 0 0 0.3).En -match '20% smaller' }

# --- Get-ShotMoveText --- (the shot's move spread over the 6 s Grok clip, of which only the shot's seconds are kept)
$m = Get-ShotMoveText ([pscustomobject]@{ panX = 0; panY = 0; zoom = 1.04 }) 2.5 $settings
Assert-That 'Shot move: 4% larger over 2.5 s asks Grok for about 10% over 6 s' { $m.Vi -eq 'đẩy vào' -and $m.En -match 'about 10% larger' }
$m = Get-ShotMoveText ([pscustomobject]@{ panX = -0.04; panY = 0; zoom = 1 }) 2.5 $settings
Assert-That 'Shot move: a 4% slide right over 2.5 s asks for about 10%' { $m.Vi -eq 'trượt phải' -and $m.En -match 'about 10% of the frame width' }

if ($script:Failed) { Write-Host "$script:Failed check(s) failed"; exit 1 }
Write-Host 'all checks passed'
exit 0
