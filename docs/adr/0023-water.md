# 0023 — Water: sea level and a flat surface plane

- Status: accepted (9.1)
- Date: 2026-11-27

## Context

The block world had water; the DC world has none. Before shading, reflection or swimming can be
designed, the world needs a sea level and a surface that sits in the terrain's valleys.

The field on the current patch ranges **49.07 m to 73.07 m**. Below 52 m is 2.1 % of sampled
positions, below 54 m 6.0 %. A sea at 55 m therefore produces a handful of valley lakes instead of drowning
the world.

## Decision

- `dc_world.SEA_LEVEL = 55.0`.
- The sea is **one two-triangle quad** over the current patch, expanded in the vertex shader from
  the live patch origin and `PATCH * CHUNK` (256 m), drawn after the terrain with depth test and
  depth write on.
- Waves are a **fragment normal** built from three directional sine waves (0.45, 1.05, 2.70
  rad/m). Keeping displacement out of the geometry means the shoreline is exactly the terrain/sea
  intersection and there is no water-side-face class of bug (the block world's 6.3 seam problems).
- Shading: dark teal body, fresnel sky tint, a softened sun lobe (`pow(..., 90) * 0.35`) and the
  terrain's height fog.
- **Fog must be mixed after the gamma encode**, in display space, exactly as the terrain shader
  does (ADR 0021). Mixing before the encode made the fog colour be encoded twice and turned the
  first sea into a pale sheet.

## Bug found on the first render

`Hud.end()` leaves depth writes off. The old block draw happened to re-enable only `DEPTH_TEST`, so
after the first HUD frame nothing wrote depth. The sea then drew over the terrain as a flat white
sheet. `DcRenderer.draw` and `WaterRenderer.draw` now both call `gl.DepthMask(TRUE)`; the terrain
occludes the sea again.

## Verified

- 60 fps at 3840x2103, worst frame 16.9 ms, terrain unchanged at 111,665 verts / 88,389 quads.
- Lakes appear in the valleys from above and from the ground; the shoreline follows the field's
  contour without z-fighting.
- Water colour at the surface is ~RGB (123,159,166) at the current sun/time — a medium teal-grey
  consistent with a flat, unlit-depth sea.

## Limits (deliberately out of 9.1)

No depth-based transparency or absorption, no shoreline foam, no reflections, no swimming or
buoyancy, and the plane ends at the patch edge (a hard straight cut when the camera looks outward
from the edge).
