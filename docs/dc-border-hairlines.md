# Chunk-border hairlines in the DC spike: state of the investigation

Everything below is measured, not suspected. Written when the remaining fix was one sampler bug away
and the session ran out of context.

## The symptom

The rendered DC surface shows thin white slivers following chunk boundaries. They are real holes: the
background shows through them (confirmed by clearing to magenta, which terrain shading cannot produce).

## The instrument

`countNearDuplicates()` in `dc_view.zig` spatial-hashes every vertex and counts pairs closer than half
a block but not coincident. That is the defect in one number, and it is what every hypothesis below was
judged by. It prints at startup as

```
duplicates: exact N, near (<0.5 block, >1e-5) M
```

Exact duplicates are harmless (same position, no gap). **Near duplicates are the hairlines.**

## What the number did

| Configuration | near duplicates | notes |
|---|---|---|
| per-chunk y slab (start) | 5,264 | before the peak fix; the defect was already present |
| per-chunk y slab + peak fix | 10,394 | anchoring the slab per chunk made it worse |
| two-cell skirt | 19,805 | nearly double; theory refuted |
| global y slab (kernel fixed) | **272** | mechanism confirmed; but the mesh collapsed to 3,277 quads |

The global slab is the right fix: it drops the defect by ~40x because every chunk then samples the same
y planes, so two neighbours evaluating a shared border cell compute the same vertex.

## Hypotheses tested and refuted (do not re-test these)

- **Pinch / ambiguous cells** (two diagonally opposite corners inside): **0** on the bench terrain.
  Manifold dual contouring would fix nothing here — a large redesign ruled out on evidence.
- **Degenerate quads** (better split still under 1e-5 area): **0**. Smallest triangle area seen: 0.02.
- **Triangulation rule** (fixed diagonal / shorter diagonal / max-min-area): deltas of −15 and −7 px on a
  1.44M-pixel frame. Not the cause.
- **Two-cell skirt**, on the theory that the QEF gradient stencil was clamped in one chunk and central in
  its neighbour: 10,394 → 19,805, i.e. worse.
- **Missing cell vertices** (`skipped_missing_cell`): **0**.
- **Camera outside the world**: a real bug that made the patch edge look like holes (orbit 260 m vs 128 m
  half-extent), fixed by orbiting at 60 m. Worth remembering that two of the "defects" in this
  investigation were the edge of the world seen from outside it.

## Two real bugs found along the way

1. **Peaks cut open** (reported by the user): the field sampled y 40..75 while the terrain peaks near 87.
   Fixed by a taller slab; the make-do per-chunk anchoring cost the duplicate count above.
2. **Segfault** in `extract` after the non-cubic field was added: the loops are x(`cpa`), y(`cpay`),
   z(`cpa`) because `at()` is `i + sx*(j + sy*k)`, and both `cj` and `ck` had been switched to the y
   bound — a ~2x overrun of `cell_vert`. Fixed in `d861ac9`.

## The remaining bug, precisely

With the global slab active (`ny = 71`, y base 20, `side_y = 74`), the kernel produces **272**
near-duplicates (correct) but only **3,277 quads** where 88,722 are expected — most of the surface is
missing. The build tag was verified, so this is a genuine sampler regression, not a stale binary.

The arithmetic checks out on paper, which is why the next step must be a measurement rather than another
patch:

- `side_y = ny_cells + 3 = 74` matches `Field.sideY()` = `ny + 1 + 2*skirt`.
- the value fill `vals[i + side*(j + side_y*k)]` maxes at 90,649 against an allocation of 90,650.
- `Field.at()` uses the same stride, and `corners` has `dj` as the y offset.

**The experiment to run first:** in `meshChunkInto`, print for ONE chunk: min/max field value, min/max
height, and the number of columns whose corners change sign. Two outcomes:

- crossed columns ~1,024 but ~63 vertices in the output → the field is fine and something downstream
  drops cells (check `cpay` in the vertex pass and `own_hi_y` in the quad pass).
- crossed columns themselves tiny → the fill is writing the wrong values (check the `heights` indexing
  and whether any loop bound was left at the old `side`).

## Files

- `src/voxel/dc.zig` — kernel; non-cubic support is in and tested, inactive until a caller sets `ny`.
- `src/tools/dc_view.zig` — reverted to the working per-chunk slab (`eab85c7`) while the sampler bug is
  open. Its `meshChunkInto()` is the function to change.
- ADR 0018/0019/0020 for the decision history.
