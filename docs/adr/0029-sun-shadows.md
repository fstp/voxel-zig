# 0029 Cascaded sun shadows with PCSS, and all-object casters

- Status: implemented (11.3 and 11.3b, 2026-11-27)
- Tasks: Vikunja #164 (#86) and #167 (#89)
- Research: ADR 0027

## Context

The DC app had no shadow path. The block renderer's 2048^2 sun map was deleted with the block
engine (ADR 0022). ADR 0027 ranked a camera-fitted sun shadow map above any GI work because the
scene had no direct-shadow cue at all.

## Implementation

- `src/gfx/shadow_renderer.zig`: two 2048x2048 depth-only cascades. The near cascade is centred
  30 m ahead of the camera with a 58 m half-extent; the far cascade is 95 m ahead with a 125 m
  half-extent. The light matrices are fitted to a ground-height centre, snapped to whole shadow
  texels in light space, and rebuilt every frame.
- Casters: terrain (`DcRenderer.drawDepth`), every tree through the LOD1 proxy (so far impostor
  trees cast too), rocks, snow clumps, shore reeds/driftwood and the full grass blade pass. No
  visible object class is skipped.
- Receivers: terrain, grass, trees, rocks, snow/shore props and water. Each shader chooses the
  near/far cascade by view distance and blends between 55 and 75 m.
- PCSS: an eight-tap blocker search at four texels, then a 5x5 filter whose radius grows with the
  receiver-to-blocker gap (`0.75..6` texels). Normal offset 0.10 m and depth bias 0.0015. Ambient
  is also partly shadowed (`mix(0.58,1,shadow)`), otherwise a low sun's direct term is too small
  to read.
- `VOXEL_SHADOWS=0` turns the pass and the lookup off for A/B.

## Evidence

Low sun (0.57), peak pose, shadows off -> on: mean luma difference **1.86**, **7.18 %** of pixels
above 8 levels, **0.52 %** above 24. Screenshots:
`docs/adr/img/0029-shadows-off.png` and `0029-shadows-on.png`. The far pose
(`0029-shadows-far.png`) shows long tree/terrain shadows with no visible cascade seam or
rectangular edge. Water receives the same lookup; tree/rock shadows on the lake are subtle because
the water body is already a low-contrast surface.

Performance at 4K, ReleaseFast:

| Run | Worst frame |
|---|---|
| shadows + AO on, uncapped 120 Hz | **8.42-8.52 ms** |
| shadows + AO off, uncapped 120 Hz | 8.43-8.83 ms |
| shadows + AO on, capped 60 fps | 60 fps, worst 17.08-17.40 ms |

The shadow cost is inside the uncapped frame-time noise on this GPU. AO adds 1.78-2.10 ms only on
the patch rebuild, not per frame. `zig build test` green.

## Limitations

- The cascades are camera-centred boxes, not exact frustum splits; a very wide FOV or a camera
  looking sharply sideways can leave near-field casters outside the near map. The far map still
  covers the middle distance.
- Grass is drawn in full for both cascades; a distance-limited caster would be the next
  optimisation if the shadow pass grows.
- Softness is screen-space PCSS, not a physically exact area-light sample; the penumbra radius is
  clamped to 6 texels to keep the 5x5 filter bounded.
- Water shadowing darkens the body by 28 % and the specular lobe, but does not add refraction or
  caustics.

## Files

- `src/gfx/shadow_renderer.zig`
- `src/gfx/dc_renderer.zig`
- `src/gfx/grass_renderer.zig`
- `src/gfx/prop_renderer.zig`
- `src/gfx/water_renderer.zig`
- `src/dc_main.zig`

## Addendum: tree shadow caster LOD (2026-11-27)

The first implementation cast **every** tree through the mid LOD (`tree_meshes[1]`, 40 triangles),
while the camera drew the nearest trees with LOD0 (84 triangles). A near tree therefore tested its
own LOD0 canopy against a different LOD1 silhouette, and the lower cones picked up hard dark wedges
that were neither a correct self-shadow nor a ground shadow.

RenderDoc capture `tree_frame1187.rdc` made the mismatch explicit:

- near shadow cascade, tree depth draw: **120 indices, 193 instances** (LOD1)
- main pass, near tree draw: **252 indices, 33 instances** (LOD0)

The fix makes the shadow pass use `tree_meshes[0]` and the LOD0 instance buffer for all trees. The
extra triangles are negligible (193 x 84), and a near tree now shadows itself against the geometry
the camera actually sees. Screenshot pair: `docs/adr/img/0029-tree-shadow-fix.png` (same pose, before
left, after right). `zig build test` green; 60 fps maintained. Far impostor trees still use the mesh
proxy for their ground shadow because the impostor card has no depth geometry.
