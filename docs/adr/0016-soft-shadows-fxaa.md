# 0016 - PCSS shadows and FXAA

- Status: accepted
- Date: 2026-11-26
- Decides for: 5.1 (softer shadows), 5.2 (antialiasing)
- Depends on: 3.8 (shadow map), 0011 (HDR resolve)

## Shadows: from fixed PCF to percentage-closer soft shadows

The old soft mode was a 5x5 PCF with a 1.4-texel spread. That is a blur of a fixed
width everywhere: a block resting on the ground gets the same penumbra as one
floating four blocks above it, which is the giveaway that a shadow is fake.

PCSS fixes that in two steps: find the average occluder depth in a search disc, then
size the PCF kernel by how far the receiver sits behind it. Contact stays crisp,
height gives width.

| Question | Answer |
|---|---|
| Blocker search | 8 taps of a 16-point Poisson disc, 7 texels |
| Filter | 16 taps of the same disc, radius from the penumbra estimate |
| Radius clamp | 1 to 12 texels |
| Softness | `u_shadow_light_size = 1.2` blocks of penumbra per block of gap |
| A/B | F9: 1 = PCSS, 0 = the old hard 3x3 with a normal offset |

**The textbook penumbra formula does not work with an orthographic light.**
`penumbra = gap * light_size / blocker_distance` assumes a point-ish light at a known
distance; with an ortho light fitted 420 blocks back the denominator is that constant,
so a two-block gap came out as 0.03 blocks - a fifteenth of a texel - and every
shadow stayed exactly as hard as before. Measured: the first PCSS build changed 594
pixels of the frame, which is the noise floor. Using the gap directly
(`penumbra = gap * softness`) keeps the property that matters and changed 22,072
pixels (2.4 %) at a 14 degree sun, all of them on shadow boundaries.

The clamp matters too: at 20 texels the 16 taps are far enough apart to band, which
is why the cap is 12.

## Antialiasing: FXAA in the resolve

| Option | Cost | Why not |
|---|---|---|
| MSAA 4x | a multisample `RGBA16F` target plus a resolve blit, and SSAO would need a resolved depth copy | the best quality for the geometric edges this world is made of, but it is a pipeline change, not a shader |
| SMAA | ~0.1 ms and an area/edge texture pair | better than FXAA, more machinery than "not too heavy" asked for |
| **FXAA** | **0.03 ms**, five extra scene evaluations in the resolve | blurs texture detail slightly, which is the price |
| TAA | needs jitter plus a history buffer and motion vectors | a project of its own |

FXAA runs inside the resolve on the tone-mapped value, converting to sRGB to measure
luma (the thresholds mean nothing in linear light) and back to linear for the write,
so `GL_FRAMEBUFFER_SRGB` keeps working unchanged. F13 toggles it.

## Measured

All at 1280x720, 120.0 fps throughout, worst frame 8.54 ms:

| Pass | Cost |
|---|---|
| sky | 0.38-1.33 ms (clouds depend on how much sky is on screen) |
| shadow map | 0.379 ms |
| SSAO | 0.030 ms |
| resolve with FXAA | 0.050 ms, against 0.022 ms without |

A/B differences on the same pose: PCSS vs hard PCF 22,072 pixels (2.4 %), FXAA on vs
off 77,696 pixels (8.4 %).

Honest limit: the per-fragment cost of 24 shadow taps is not isolated by any GPU
query - the shadow pass is unchanged at 0.379 ms because it only draws depth, and the
extra work lands in the main pass. The evidence that it fits is that the frame stays
at 120.0 fps with the 8.33 ms vsync budget intact; a dedicated timing query around the
chunk pass is the next step if that stops being enough.
