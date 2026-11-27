# 0026 QEF regularisation bias: remove the 1 m terrain terraces

- Status: implemented (2026-11-27)
- Depends on: ADR 0018/0020 (dual contouring), ADR 0022 (DC world), ADR 0025 (surface rules)
- Task: Vikunja #161 (#83), "10.8b QEF cell-centre bias: remove the 1 m terrain terraces"

## Context

The 10.8 snow pass made the terrain look like a staircase. That was not a snow problem: the same
rectangular steps were there with `VOXEL_SURFACES=0`, and a mesh probe showed why.

Meshing one chunk (7,6) and comparing every vertex to `heightAt(x,z)`:

| | before | after |
|---|---|---|
| mean `abs(vertex.y - heightAt)` | **0.4300 m** | **0.0297 m** |
| max residual | **1.2608 m** | **0.3314 m** |
| vertex example | `(222.02, 60.02, 200.02)`, height 61.00, residual -0.980 | `(222.30, 60.98, 199.71)`, height 61.09, residual -0.111 |
| next vertex | `(223.02, 61.02, ...)`, residual -0.232 | `(222.71, 61.16, ...)`, residual -0.004 |

The vertices were snapping to cell tops and bottoms (`60.02`, `61.02`, `61.98` with a 1 m cell)
instead of following the continuous height field. That is the signature of a QEF solve that is
being clamped to its cell rather than finding the surface.

## Root cause

`Qef.solve` solved the regularised normal equations

```
A = sum(n n^T) + eps * I
b = sum(n * (n . p))
x = A^-1 b
```

For a heightfield, a typical cell is crossed by a single nearly horizontal tangent plane. That
system is rank-deficient in the two tangent directions. With the raw `b`, the solution is the point
on that plane **closest to the world origin**, not a point in the cell. The solve then clamps
`x` into `[lo+inset, hi-inset]`, so an underdetermined cell lands on a cell boundary - alternately
the top and the bottom of neighbouring cells - and the mesh is a 1 m staircase. The `mass` fallback
was never reached because `eps` makes the determinant nonzero, so the comment "regularisation pulls
the solution toward the mass point" described something the code did not do.

## Decision

Add the missing Tikhonov bias to `b`:

```
centre = 0.5 * (lo + hi)
b'     = b + eps * centre
x      = (A + eps*I)^-1 b'
```

For an underdetermined cell this returns the projection of the **cell centre** onto the plane:
a vertex in the middle of the cell, at the surface height. For a well-conditioned cell the bias is
small and the normal QEF feature solution dominates. The clamp stays as the final safety net.

The change is four lines in `src/voxel/dc.zig` plus the comment; no vertex format, index buffer,
draw call or shader changed.

## Tests

The two seam tests had to be made representative of production:

- `dual contouring: an overlapping chunk reproduces the border vertices exactly` now gives both
  chunks the two-cell skirt the mesher actually uses. With no skirt, the shared border cell on one
  side used a one-sided gradient and the other a central one; the old clamping hid those low-bit
  differences, and the bias exposed them. With skirt 2 the copies are bit-identical:
  **144 considered / 144 matched**.
- `dual contouring: two skirted chunks tile without a crack` now uses skirt 2 instead of 1 and the
  seam window check is `checked > 10` (it finds **16** edges, all shared exactly, `bad = 0`). The
  threshold changed only because biased vertices no longer sit on the old boundary positions, so
  fewer edges fall inside the fixed 4 m window; 16 is still a real border sample.

`zig build test`: **65/65 pass, TEST_EXIT=0**. `zig build -Doptimize=ReleaseFast`: **BUILD_EXIT=0**.

## Measured after the fix

| Quantity | Value |
|---|---|
| far pose geometry | 111,762 verts / 88,272 quads |
| close peak geometry | 111,418 verts / 88,067 quads |
| shore geometry | 111,874 verts / 88,470 quads |
| frame rate | 60.0 fps, worst 16.85-17.09 ms |
| chunk (7,6) counts | 1,856 verts / 1,472 quads (unchanged) |
| mesh residual, mean / max | **0.0297 m / 0.3314 m** (was 0.4300 / 1.2608) |

The geometry counts are unchanged because the same cells are crossed; only the vertex positions
move. That is the expected result for a placement fix, and is the opposite of the earlier
"identical metrics means the field change did nothing" trap: here the positions and the residual
moved, the counts did not.

## Consequences

- The terrain now follows `heightAt` to within 3 cm mean, so scatter, grass, trees and the water
  depth grid agree with the visible surface much more closely (they already sampled `heightAt`).
- The snow cap in ADR 0025 no longer reads as rectangular terraces; the 10.8 screenshots were
  retaken after this fix.
- Sharp brush edits are slightly rounded by the centre bias, which is acceptable for a terrain
  sandbox; if a feature needs a harder edge, lower the cell size or add a feature-aware QEF rather
  than removing the bias.
- This fixes **placement**, not resolution: 1 m cells still limit how much detail the terrain can
  carry. The 10.9 scatter detail and the 10.10 card LOD are the next visual steps.

## Evidence

`docs/adr/img/0026-qef-before.png` and `0026-qef-after.png` are the same far pose
(200, 100, 150, yaw 2.472, pitch -0.327), surfaces on, HUD off. Before: white terraces and a
blocky ridge. After: a continuous snow field and a smooth shoreline.

## Files

- `src/voxel/dc.zig` - `Qef.solve` bias and comment; seam tests use the production two-cell skirt.
- `src/world/dc_world.zig` - unchanged; this ADR confirms its height sampling was already correct.

## References

- T. Ju, F. Losasso, S. Schaefer, J. Warren, "Dual Contouring of Hermite Data", SIGGRAPH 2002.
- A. Nealen, T. Igarashi, O. Sorkine, M. Alexa, "Laplacian Surface Editing" - the regularised
  least-squares form used here.
- `references/isosurface-extraction.md` - the existing DC kernel notes and seam-test rules.
