# 0020 - DC against the blocky path: what is measured, what is not

- Status: measurement complete, integration not started
- Date: 2026-11-26
- Depends on: 0018 (dual contouring), 0019 (procedural materials)

## Why this exists

The spike has to earn the right to replace the block renderer. That means numbers on the same
scene, not impressions. This records what the spike actually measured, and is equally explicit
about what it did not.

## Measured

Same terrain generator, same 32-cell chunks, 1 m cells, ReleaseFast on burken.

| | blocky path | dual contouring |
|---|---|---|
| quads per 32^3 chunk | ~8,570 (943k in view across ~110 drawn chunks) | 1,369 (136,920 across 100 chunks) |
| mesh time per chunk | not measured | 0.37 ms mean, 0.44 ms worst |
| verts per chunk | not measured | 1,552 |
| cracks at chunk borders | none (face-culled, shares faces exactly) | none, with a one-cell skirt and a half-open ownership cube |
| remaining visible defects | none known on this axis | 185 enclosed-background pixels of pinch artefacts |
| materials | 256^2 texture array, indexed by block face id | per-vertex id + world-space procedural noise |

The quad ratio is the headline: **1,369 vs 8,570 per chunk, 6.3x fewer**. That is expected - the
blocky mesher emits a quad per visible face while DC emits one per crossed cell edge - and it is
the reason the path is worth continuing.

## Not measured, and required before integration

1. **Blocky mesh time per chunk** by the same harness. Without it the quad ratio says nothing about
   CPU cost per chunk, only about geometry submitted.
2. **Frame time at 1080p with the DC path inside the engine**, against the recorded 120 fps /
   8.5 ms worst frame of the blocky path. The spike viewer is 1600x900 with a trivial shader, so
   its frame rate is not comparable.
3. **Water.** The sea is block-shaped today; a DC world has no block water. Not designed yet.
4. **Save format.** RLE blocks become a field or generator parameters plus edits. Not designed.
5. **Collision and raycasting.** The player AABB and block raycast do not apply to a DC surface.

## Integration plan, in the order that keeps the old path usable

1. `Config.dc_world` behind `VOXEL_WORLD=dc`, defaulting to blocks. Nothing is removed until the
   new path wins on the same scene.
2. Generate chunk fields from the existing noise, mesh with `dc.extract` on the worker pool, upload
   through a new `ChunkRendererDC` that takes pos/normal/material - it cannot reuse the block
   renderer, which is built around a texture array and per-layer material uniforms.
3. Bring the spike's fragment shader across (value-noise derivatives, material-driven bump) and
   wire it to the real exposure/HDR/MSAA/post chain rather than a bare clear-and-draw.
4. Compare at 1080p on a fixed camera: quads drawn, mesh ms per chunk, frame time, and the
   enclosed-background defect count with `VOXEL_DC_BG=magenta`.
5. Only then flip the default, and only if it wins on frame time and looks better.

## What the spike proved, and what it did not

Proved: the extraction is correct (closed interior, seam-exact tiling under a skirt), it is cheap
(0.37 ms per chunk), it needs 6.3x less geometry, and materials work without textures. The defect
metric is now trustworthy because the background is a colour the render cannot produce.

Did not prove: that it renders faster in the real engine, that water or collision can be carried
over, or that the pinch artefacts are acceptable at scale. Those are the integration's job.
