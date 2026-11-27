# 0032 World-anchored scatter: foliage stays put across streaming

- Status: implemented (bug fix, 2026-11-27)
- Related: ADR 0024 (scatter), ADR 0022 (streaming DC world)

## Symptom

Walking across a chunk boundary rebuilt the whole scatter field and the grass, trees, rocks, snow
and shore props appeared at different points. The user's description: "moving around will respawn
foliage at different points, it should keep static."

## Root cause

Every scatter cell was hashed from the patch-relative coordinate:

```
ix = floor((x - min_x) / step)
```

The patch origin moves by 32 m when the player crosses a chunk boundary, so the same world cell
received a different `ix` and therefore different jitter, tint, yaw and placement. Two secondary
problems made it worse:

- Grass used three bands with different steps (0.22 / 0.45 / 1.0 m). A world point could be in the
  0.45 m band in one patch and the 1.0 m band in the next, so even a corrected hash would have
  produced a different lattice.
- The 70,000-blade cap was applied in iteration order. A shifted patch could reach the cap at a
  different cell, truncating a different part of the field.

A smaller edge effect remains by design: the grass radius is centred on the patch, so cells at the
outer radius can enter or leave as the world streams. The cells that remain inside both patches are
bit-identical.

## Fix

- Every scatter system now iterates **world-space integer cells** and uses the cell index itself
  for `rand01`, not `x - min_x`: grass, trees, rocks, snow and shore.
- Grass is one lattice, `step = 0.25 m`, radius 95 m, with a world-constant 26 % hash thinning.
  Distance only decides whether the cell is inside the radius, never which lattice or hash is used.
- The 70,000 cap and its iteration-order truncation are gone; the measured peak is 71,519 blades.
- Trees/rocks/snow/shore use candidate centres `(cell + 0.5) * step`, so the same world cell has the
  same candidate position in every patch.

## Verification

New test `world-anchored scatter keeps overlapping foliage fixed` builds the patch at `(0,0)` and
`(32,0)`, then compares the exact positions in the region both grass radii cover. It passed with:

- **32,361** overlapping blades exact
- **185** trees exact
- **99** rocks exact
- **130** snow clumps exact
- **320** shore props exact

This is an exact float-position comparison, not a near-position tolerance. `zig build test` is
green (66 tests). Peak scatter rebuild: **8.7 ms**, 71,519 blades, 60 fps at 3840x2103, worst
17.24-17.29 ms. Screenshot: `docs/adr/img/0032-static-scatter.png`.

## Trade-off

The old radial bands concentrated the same 70k blades near the camera. The static lattice spreads
them over the radius, so the meadow is less dense at mid-distance but does not slide under the
player. The radius is still 95 m and the shader still thins beyond 35-85 m; if the near field needs
more blades, raise the lattice acceptance rather than reintroducing a patch-origin-dependent step.

## Files

- `src/world/scatter.zig`
- `docs/adr/img/0032-static-scatter.png`
