# Prompts of a run (video.ps1): the key frames Codex draws from the product photo, and the clip Grok films from each.

$script:VideoLight = 'Premium photographed realism: clear grain, crisp edges, believable contact shadows; no CGI feel, HDR look, plastic gloss or sharpening halos. One image only: no collage, inset, split screen, text, logo or watermark.'

# The opening frame with a model: the person of image 2 presenting the product in the room of image 1.
function New-IntroFramePrompt([string]$ProductName) {
    @"
TASK: EDIT THE PHOTOGRAPH IN IMAGE 1 into ONE photorealistic brand photograph of the same room, with the person from IMAGE 2 standing beside the product and presenting it. It is the opening frame of a product video.
Target product: $ProductName.

STEP 1 - ROOM (image 1)
Image 1 is the only room: walls, floor, windows, light and every object stay as they are, in the same arrangement. The camera stays where it is in image 1; pull back slightly only if needed so the person and the whole product both fit.

STEP 2 - PRODUCT (image 1)
$(Get-VideoProductRules 1)
Rule 6 does not forbid the one person from image 2 that this task adds; it still applies to everything else.

STEP 3 - PERSON (image 2)
Image 2 controls only the person: the same face, hair, skin tone, body and outfit, recognisably the same person. Nothing else of image 2 (its background, props, flags or text) comes into the result.
Place the person standing on the floor next to the product, at true scale, turned slightly toward the camera with a warm natural smile, one hand gently presenting the product. The person never covers the product or touches it in a way that hides its shape.

STEP 4 - LIGHT AND OUTPUT
Light the person with the room's own light and direction, with matching shadows. $script:VideoLight
"@
}

# A planned shot's opening frame: the room of the product photo seen from another angle (data/angles.json).
# As-photo (the photo itself in the video's frame shape, when the photo has another shape: Grok's video keeps its start
# image's shape, tried 04/11/2026) keeps the camera and extends the room to the new edges.
function New-AngleFramePrompt([string]$ProductName, $Angle) {
    $moved = $Angle.id -ne 'as-photo'
    $task = if ($moved) { 'RE-PHOTOGRAPH the room in IMAGE 1 as ONE new photorealistic photograph taken from a different camera position. Image 1 is the only reference for the room and the product; the new photograph must not repeat its framing.' }
            else { 'EDIT THE PHOTOGRAPH IN IMAGE 1 into ONE clean, sharp, photorealistic photograph of the same scene, from the same camera, in the new frame shape: the whole product stays in view, and the room continues naturally to the new edges.' }
    @"
TASK: $task
Target product: $ProductName. This is the opening frame of one shot of a product film made in this room.

STEP 1 - ROOM
Image 1 is the only room. Its walls, floor, windows, light, plants and every other object stay exactly as they are, in the same arrangement; only the camera moves and the whole view changes perspective together. Do not add, remove, move or restyle anything.

STEP 2 - PRODUCT
$(Get-VideoProductRules 1)
Show the product without any brand name or logo.
SIZE: the product keeps its real size against the room exactly as in image 1. Measure it against the things around it (chairs and their seats, sofa, counters, side tables, lamps, plants, doors, floor tiles or boards, rug) and keep every ratio: its height against a chair seat, sofa or counter and its width against the chairs or sofa stay exactly as in image 1. A closer camera makes it bigger in the frame only through perspective; it never grows, gets taller, thicker or chunkier against the room, and the room's things never shrink around it.

STEP 3 - CAMERA ($($Angle.label_en))
$($Angle.text)
$(if ($moved) { 'Obey this framing exactly; the result must visibly be taken from this new position. A side the photo does not show stays consistent with the visible side.' })

STEP 4 - LIGHT AND OUTPUT
$script:VideoLight No people.
"@
}

# The clip of one shot: from its start image, one camera move ($MoveText: plan.ps1 Get-ShotMoveText). The room is the
# image's own.
function New-ClipPrompt([string]$ProductName, [int]$Index, [int]$Total, [int]$Seconds, [string]$MoveText, [bool]$Person) {
    $plan = "Camera: $MoveText, steadily for the whole shot."
    $people = if ($Person) { 'The person in the image presents the product with one slow, graceful gesture, keeping the same face and outfit; no one else appears.' }
              else { 'No hands, arms or people enter the frame; nobody touches, picks up or moves anything.' }
    @"
One continuous $Seconds-second shot (part $Index of $Total of a product film) in the room of the image, one smooth camera move with no cuts, no fades and no zoom jumps.
START: the image, exactly as it is.
$plan
Move on a real camera path (dolly, slider, crane or gimbal) with natural parallax. The room is a fixed physical set: walls, windows, pictures, rug, furniture and props keep their exact shapes, sizes and places, and nothing slides, swaps, appears or disappears; any part of the room the image does not show stays plain and simple, with no new furniture or decor. The product, $ProductName, is a rigid real object: it never moves, bends, morphs or changes shape, color, grain or number of parts, and it stays the subject of the shot.
Photorealistic interior film look, steady exposure. No text, no logos. $people
"@
}

# What each transition looks like, for Codex to choose by (ffmpeg xfade names).
$script:TransitionLooks = [ordered]@{
    fade = 'a plain crossfade'; fadeslow = 'a crossfade that lingers on the first picture, then gives way'; fadefast = 'a quick crossfade'
    fadeblack = 'dips through black'; fadewhite = 'dips through white (a bright flash)'; fadegrays = 'crossfades through grey tones'
    dissolve = 'a grainy pixel dissolve'; distance = 'a soft melt between the pictures'; zoomin = 'zooms into the first picture while the second appears'
    radial = 'a clock-hand sweep'; pixelize = 'pixelates out and in'; circleopen = 'opens as a growing circle'; circleclose = 'closes as a shrinking circle'
    smoothleft = 'the whole frame glides left'; smoothright = 'the whole frame glides right'; smoothup = 'the whole frame glides up'; smoothdown = 'the whole frame glides down'
    slideleft = 'the new picture slides in from the right'; slideright = 'the new picture slides in from the left'; slideup = 'slides in from below'; slidedown = 'slides in from above'
    wipeleft = 'a hard-edged wipe to the left'; wiperight = 'a hard-edged wipe to the right'; wipeup = 'a hard-edged wipe upwards'; wipedown = 'a hard-edged wipe downwards'
    squeezeh = 'squeezes sideways'; squeezev = 'squeezes vertically'; vertopen = 'opens from the vertical middle'; horzopen = 'opens from the horizontal middle'
}

# The cuts of a film, for Codex to choose a transition for each from what the two shots show. Image k is cut k: the last
# frame of the shot before (left) beside the first frame of the shot after (right).
function New-TransitionPrompt([string]$ProductName, $Cuts, [string[]]$Allowed, [double]$Seconds) {
    $list = ($Allowed | ForEach-Object { "- $_$(if ($script:TransitionLooks[$_]) { ": $($script:TransitionLooks[$_])" })" }) -join "`n"
    $lines = ($Cuts | ForEach-Object { "Cut $($_.Index) (image $($_.Index)): from $($_.From) to $($_.To)" }) -join "`n"
    @"
You edit a calm, premium product film of $ProductName (natural wood furniture), made of short shots of one room. Choose the transition for each cut ($(Format-Seconds $Seconds) s long) so that it fits what the two pictures show and how the camera moves, never at random.
Image k shows cut k: the last frame of the shot before on the left, the first frame of the shot after on the right.
$lines

Allowed transitions (use only these names):
$list

How to choose: for every cut, look at both pictures and pick the transition that fits them best (their framing, shapes, lines, light, and the camera move of the shot after). No transition is preferred over another; only the fit counts. The one rule: never two gliding, sliding or wiping cuts in a row.
Answer with JSON only, no other text: [{"cut": 1, "transition": "<name>", "why": "<a few words>"}, ...] with one item per cut.
"@
}
