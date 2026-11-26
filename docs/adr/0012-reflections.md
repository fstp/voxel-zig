# 0012 - Reflections from a sky probe, and why water needed a diffuse scale

- Status: accepted
- Date: 2026-11-26
- Decides for: 4.4 (environment reflections, specular highlights)
- Depends on: 0009 (sky), 0011 (PBR, HDR, tone curve)

## The problem 4.3 measured

Water brightened only 5 percent between a 20 degree view and 2 degrees. Two causes:

1. The environment term was a two-colour hemisphere with no knowledge of the sun, so
   there was nothing to reflect and no highlight to catch.
2. Water's albedo was its full texture colour. A dielectric reflects 4 percent at
   normal incidence, so 96 percent of what you saw was the water's own blue paint -
   the reflection was there and invisible underneath it.

## Decision

| Question | Answer |
|---|---|
| Probe | six 64x64 faces of `RGBA16F`, mipmapped, rendered from a compact sky shader |
| Contents | the sky gradient from `sun.ramp()` plus the sun disc and glow, same constants as the sky pass |
| Sampling | `textureLod(u_env, reflect(-V, N), roughness * 6)` — roughness picks the mip, so a polished face mirrors the gradient and a rough one gets a soft sheen |
| Update | only when the sun moves more than 0.15 degrees in elevation or azimuth; six 64x64 draws, a fraction of a millisecond |
| Materials | a third channel, `diffuse`, 1.0 for solids and 0.12 for water |
| Not included | clouds. They drift every second and the probe does not track them |

`block.layer_materials` is now `{ roughness, metallic, diffuse }` uploaded as
`u_material[8]` of `vec4`, still indexed by the texture-layer byte, so no vertex,
mesher or chunk-format change was needed for reflections either.

## Measured

Same sea view, water pixels only (blue-dominant, open sea columns), by screen band:

| band | mean luminance | median |
|---|---|---|
| near the horizon, about 2 degrees | **40.9** | 40.9 |
| mid, about 10 degrees | **8.9** | 8.2 |

A 4.6x rise where the previous pipeline managed 5 percent. The same frame shows the
sun's own reflection as a bright band near the horizon, which is the specular
highlight the direct GGX lobe alone could not put there: the sun was at 20 degrees
and the view was shallow, so no sun-to-eye mirror direction existed on the water
within the frame except through the probe.

Frame rate unchanged at 120 fps with the cycle running; the probe update is below
the frame-time noise floor.

## Consequences

- Water reads as water: dark where you look down into it, bright where it mirrors
  the sky. Its near-shore colour is now muted by design; `diffuse = 0.12` is the
  knob if shallow water needs more of its own tint back.
- Metals would now reflect the sky properly, but no block is metallic yet - ore
  blocks would be the first, and they need an albedo used as F0 to look right.
- The probe ignores clouds, so a cloud deck does not appear in reflections. Adding
  it means rendering the cloud march into six faces, which is not free and was not
  worth it here.
- A planar reflection for water would be sharper than a 64x64 probe and would show
  the terrain reflected in the sea, at the cost of a second scene pass. That is the
  next step if the sea needs to mirror the shoreline, not just the sky.
