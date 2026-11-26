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
| cracks at chunk borders | none (face-culled, shares faces exactly) | none after the two-cell-skirt fix (2026-11-27); a one-cell skirt left 510 border cells disagreeing by up to 1.358 blocks |
| remaining visible defects | none known on this axis | 0 enclosed-background pixels after the two-cell-skirt fix; 2,751 in 51 components before it |
| materials | 256^2 texture array, indexed by block face id | per-vertex id + world-space procedural noise |

The quad ratio is the headline: **1,369 vs 8,570 per chunk, 6.3x fewer**. That is expected - the
blocky mesher emits a quad per visible face while DC emits one per crossed cell edge - and it is
the reason the path is worth continuing.

## The border-hole defect: cause and closure (2026-11-27)

The DC column above used to carry 185 enclosed-background pixels labelled "pinch artefacts". On the
current 8x8 patch the honest magenta check measured 2,751 such pixels in 51 components, and they
were not pinches: `ambiguous_cells` and `degenerate_quads` were both 0, and no quad was skipped for
a missing cell. The defect was that two chunks sharing a border cell computed its QEF from
different gradient stencils - `Field.gradient()` falls back to a one-sided difference at the edge
of the padded sample grid, so the owner used a central difference and the skirting neighbour a
one-sided one. 510 of 4,287 referenced cell copies disagreed by more than 1e-3 (299 by more than
half a block, worst 1.358).

A two-cell skirt puts the shared cells two samples from the padded edge, so both sides use central
differences: cell-copy deltas went 510 -> 0, and enclosed magenta pixels 2,751 -> 0 (two captures at
different orbit phases). Quad count unchanged at 89,004; vertices 100,402 -> 112,474 because more
skirt cells are meshed and not drawn. A curved-field regression test was added; the older
plane-field overlap test cannot see this, because one-sided and central differences agree exactly
on a linear field.

Measurements, the misleading near-duplicate counter and the refuted hypotheses:
`docs/dc-border-hairlines.md`.

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

Proved: the extraction is correct (closed interior, seam-exact tiling under a two-cell skirt), it is
cheap (0.37 ms per chunk), it needs 6.3x less geometry, and materials work without textures. The
defect metric is trustworthy only when the background is a colour the render cannot produce AND the
sky pass is skipped in that mode; the magenta clear alone is overdrawn by the sky.

Did not prove: that it renders faster in the real engine, that water or collision can be carried
over, or that the defect count stays at zero across every camera angle and LOD - two orbit phases
were checked, not a sweep. Those are the integration's job.
