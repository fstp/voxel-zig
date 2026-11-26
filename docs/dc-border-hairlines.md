# Chunk-border holes in the DC spike: cause and fix

Status: **resolved 2026-11-27**. The rendered surface has no enclosed background pixels on the
magenta check, and the two chunks that share a border cell now compute it bit-identically.

## The symptom

The DC surface showed thin slivers and scattered specks of background, many of them along lines
that follow chunk boundaries. They were real holes, not shading: with the sky pass skipped and the
framebuffer cleared to magenta, the magenta was visible inside the terrain silhouette - 2,751
pixels in 51 enclosed components on an 8x8-chunk patch at 1920x1080.

## The cause

One vertex per crossed cell means the same world cell is meshed by both chunks whose padded grids
contain it. The two copies must be bit-identical, or the quads on either side of the border connect
to different points and the seam draws a crack.

Every QEF input was already identical - the field is sampled from integer world coordinates and the
sample positions are exact - except one: **`dc.Field.gradient()` falls back to a one-sided
difference at the edge of the padded sample grid**. With a one-cell skirt the cell row at the
border is the last *owned* cell in one chunk (central difference at both corners) and the first
*skirt* cell in the neighbour (one-sided at its outer corner). The two QEFs then disagree, and on
cells where the solve is ill-conditioned the regularised solution lands in different parts of the
clamp box - up to 1.358 blocks apart. 510 of 4,287 shared cells disagreed by more than 1e-3, and
**all 510 sat on a chunk-border column**.

## The instrument that localised it

`diag copies` in `src/tools/dc_view.zig` keys every **referenced** vertex by the cell it belongs to
(`floor(pos)`, valid because the QEF is clamped 2 % inside its cell) and compares copies of the same
cell. It reports a delta histogram and how many disagreeing pairs sit on a border column.

The older `duplicates:` counter could not do this. It counted every pair of vertices closer than
half a block, including skirt vertices that no quad references, so it moved with the amount of
padding rather than with the defect. That is why an earlier session recorded "two-cell skirt made
it worse (10,394 -> 19,805)" and rejected the correct fix; the per-cell metric shows the second
skirt ring only adds unreferenced copies (near-pairs rose 5,269 -> 6,695 while the defect fell to
zero).

## Measured

Same 8x8-chunk patch, 1920x1080, ReleaseFast, magenta background with the sky pass off.

| configuration | cell-copy pairs | exact | >1e-3 | max delta | enclosed magenta px |
|---|---|---|---|---|---|
| one-cell skirt | 4,287 | 3,774 | 510 (all border cells) | 1.358 | 2,751 in 51 components |
| two-cell skirt | 4,287 | 4,287 | **0** | **0** | **0** |

Delta histogram at one-cell skirt: 2 in (1e-3, 1e-2], 63 in (1e-2, 1e-1], 146 in (0.1, 0.5], 299
above 0.5 - the disagreement was not a subpixel rounding issue.

Kernel counters on the same patch were unchanged by the fix and rule out the other candidates:
`skipped_missing_cell` 0, `skipped_bounds` 0, `ambiguous_cells` 0, `degenerate_quads` 0, smallest
triangle area 0.0028. Quad count stayed at 89,004.

## The fix

`meshChunkInto` uses `skirt = 2` and derives `side`, `side_y`, the sample coordinates and
`Field.skirt` from it. The duplicated cell row is then two samples from the padded edge in both
chunks, so both compute central gradients and the copies are bit-identical. The cost is padded
cells, not visible geometry: vertices rise from 100,402 to 112,474 (more skirt vertices are
meshed - they are not drawn), full-patch rebuild 65.9 -> 69.9 ms, and the viewer still runs at
120 fps.

Topology after the fix, welding exact copies by quantised position: 267,607 edges, 1,192 open at the
patch rim (the surface legitimately stops there) and **1** open interior edge (0.0004 %), with 0 NaN
vertices. That single edge is recorded rather than rounded away; it produces no visible pixel.

Regression test: `dc.zig`'s "a curved field reproduces border vertices with a two-cell skirt". The
older overlap test uses a linear plane, where the one-sided and central stencils are numerically
identical, so it passed straight through this bug. The new test uses a sphere field and asserts that
every referenced shared cell agrees to 1e-6; it fails at skirt = 1 (177/178 tests) and passes at
skirt = 2.

## Refuted along the way (do not re-test)

- **Pinch / ambiguous cells** (two diagonally opposite corners inside): **0** on the real fBm
  terrain, counted in `extract`. Manifold DC would fix nothing here.
- **Degenerate quads**: **0**; the best split's smaller triangle never fell below 0.0028.
- **Missing / out-of-bounds cell vertices**: **0**. Not a sampling miss.
- **Triangulation rule**: fixed diagonal, shorter diagonal and max-min-area differ by -15 and -7 px
  of 1.44 M. Not the cause.
- **Camera outside the world**: a real bug that once made the patch edge look like holes; the orbit
  is at 60 m against a 128 m half extent.

## Two real bugs found earlier in this investigation

1. **Peaks cut open** (reported by the user): the field sampled y 40..75 while the terrain peaks near
   87. Fixed by one global y slab tall enough for the peak.
2. **The mesh collapse**: `extract`'s Y loop ran to the X/Z cell count, and with `ny = 71` it covered
   only world y 19..52 - below the terrain - giving 3,277 quads where 88,722 were expected. Fixed in
   `6b3e9c4`. The 272 near-duplicate figure measured on that broken mesh was invalid and is not
   evidence about the seam.

## Files

- `src/voxel/dc.zig` - kernel; `Field.gradient()`'s border fallback is the mechanism, the skirt is
  the caller's contract. Curved-field seam test added.
- `src/tools/dc_view.zig` - `meshChunkInto` owns the `skirt = 2` sampler; `diag copies`, `diag
  closure` and the kernel-counter line are the instruments.
- ADR 0018/0019/0020 for the decision history.
