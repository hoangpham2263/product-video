# Core rules for how the product must look in an edited photo (Grok Video frames). Rule 5 (FIT) says how the photo itself is rendered; what the
# product looks like (rules 1-4, 6, 7) must not change. The frames are rendered clean and sharp.
function Get-VideoProductRules([int]$ProductIndex) {
    $fit = "5. FIT: place it at true scale with the light direction, contact shadows and occlusion of the photo, seen from the camera angle the task asks for. Feet touch the floor (sinking slightly into a rug). Render the whole photo clean and sharp with natural fine detail, free of halos, harsh sharpening, HDR and plastic gloss."
    @"
CORE PRODUCT RULES (image $ProductIndex is the product photo; these apply to every product):
1. SOURCE: image $ProductIndex is the only source for how the product looks. The text note only names things; where it differs from image $ProductIndex, follow image $ProductIndex.
2. COLOR: reproduce the color you see on the product in image $ProductIndex, part by part: hue, depth (light or dark) and saturation. Judge it on evenly lit areas, not on glare, deep shadow or a color cast of image $ProductIndex's own room. Do not brighten, warm up, restain or improve it. Image 1's room must not tint it: cool grey floors, marble, white walls and dim or warm light must not make it paler, yellower, redder, greyer or glossier. Only a soft local shadow and highlight may change it.
3. SHAPE: same silhouette, proportions, thickness and number of parts. For every leg, support, arm, root, strap or trim keep where it forks or joins, how many there are, how thick, and which way each goes. Never simplify a forked, curved or organic part into a plain column, pillar or stump; each part is one continuous piece, not a detached blob.
4. SURFACE: same material, grain or pattern and finish sheen. Parts made of the same material share one color: do not lighten, darken or add shine to one of them, and add no scratches, stains or wear.
$fit
6. LIMITS: add or remove no part, prop, person, text or logo. A part hidden in image $ProductIndex stays plausible and consistent with its visible side; do not invent extra parts.
7. CHECK before finishing: compare the result with image $ProductIndex on shape, number of parts, color and sheen, and correct any difference.
"@
}
