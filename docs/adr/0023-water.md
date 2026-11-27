# 0023 — Water: sea level and a flat surface plane

- Status: accepted (9.1-9.3)
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

## 9.2 Depth, transparency and foam

The flat quad became a **96x96 grid** over the patch (2.67 m spacing, 9,409 vertices, 55,296
indices). Each vertex carries `depth = SEA_LEVEL - heightAt(x,z)`; the grid is rebuilt
synchronously when the patch origin changes and costs **0.7 ms**. No depth texture or FBO is
involved, and the depth test still resolves the sea/land intersection exactly.

- Body colour: shallow `(0.070, 0.220, 0.200)` to deep `(0.008, 0.035, 0.055)` over the first 8 m.
- Alpha: 0.30 at the shoreline to 0.92 in water deeper than 3 m; fresnel adds up to 0.35, so a
  grazing view is nearly opaque.
- Foam: a moving band where depth < 0.6 m, mixed at up to 0.55.
- Drawn after the terrain with `SRC_ALPHA/ONE_MINUS_SRC_ALPHA`, depth test and depth write on.

Measured: 60-62 fps at 3840x2103, worst frame 17-18 ms; the spawn view keeps the terrain at
111,665 verts / 88,389 quads. At (96,34) the lake is 5.93 m deep and shows the full shallow-to-deep
gradient with a foam rim.

## 9.3 Swimming

`DcPlayer` gained a `swimming` state; the height field remains authoritative:

- Enter when the ground is more than **0.6 m** below `SEA_LEVEL` and the feet are at or below the
  surface. Walk into a deep lake and the state flips automatically.
- While swimming: no gravity, 3 m/s (4.2 sprint), Space/Ctrl rise/dive at 1.5 m/s, and with no
  input the body eases back to `SEA_LEVEL - 0.35` (the float line).
- The bed clamps the body at `ground + 0.1`; a shore at or above the sea within step height stands
  the player up and exits the water.
- HUD mode is `SWIM WATER`; `dc_main` logs one line per enter/exit.

Verified by driving it: falling from 60 m at (96,34) logs `swim: enter at (96.0,55.0,34.0)` and
settles at y 54.7; Ctrl dives to 54.2 and buoyancy returns it to 54.6; holding W for 7 s swims
16 m east, logs `swim: exit at (110.6,54.8,34.0)` and the player walks on up to y 56.2. 60 fps,
worst frame 17.0 ms throughout.

## Remaining limits

Depth uses `heightAt` and therefore ignores sphere edits under water; water still ends at the
patch edge; no underwater fog/refraction, reflections, drowning or stamina, and flying ignores the
surface.
