# 0037 Dense clumped grass

- Status: implemented (2026-11-27)
- Related: ADR 0024 (foliage), ADR 0032 (world-anchored scatter)

## Problem

The 0.25 m grass lattice with constant 26 % thinning gave 71,519 blades at the peak pose and
98,261 at the tree pose. It read as individual blades with large bare areas, not as grass. The
request was much denser coverage with random clumps rather than a uniform carpet.

## Change

- Keep a sparse world-anchored base lattice (0.25 m, 6 % acceptance).
- Add a second world-anchored **clump layer** on 2.6 m cells. Each selected cell gets a jittered
  tuft centre, a radius of 1.0-2.1 m and 100-260 blades distributed in a disk. Selection
  probability is 22-56 %, driven by the broad density field plus a finer noise term, so clumps
  form regions of different density rather than a regular pattern.
- Gate terrain height/slope/density once per tuft, then sample the exact `heightAt` per blade.
  The tuft centre and all blade offsets are hashed from world cell indices, so the field stays
  static across a 32 m streaming-patch move (ADR 0032).
- No cap and no patch-relative salt.

## Measured result

At `tree.sav` (117, 64, 124, sun 0.30, 4K window):

- **273,902 blades**, 193 trees, 122 rocks, 145 snow, 291 shore
- scatter rebuild **21.4 ms**
- 60 fps capped, worst frame **22.3 ms** over the first seconds

At `peak.sav` with the previous 273k settings: **188,791 blades** and 15.2 ms scatter. The
world-anchored overlap test still passes with **88,735** blades exact in the central overlap
region, plus 185 trees / 99 rocks / 130 snow / 320 shore.

Screenshots: `docs/adr/img/0037-dense-grass.png` (clumped meadow) and
`0037-dense-grass-tree.png` (tree pose).

## Trade-off

The clump layer is denser and visibly nonuniform, but costs **~21 ms** on a patch rebuild versus
~9 ms for the old uniform lattice. It is a one-off streaming hitch, not a per-frame cost. If the
hitch matters, the next step is to build the clump lists incrementally per chunk instead of
rebuilding the whole patch at once. The base lattice is deliberately sparse; lowering it further
would make the gaps too large for the current clump coverage.

## Files

- `src/world/scatter.zig`
- `src/gfx/grass_renderer.zig` (unchanged; it still draws one 7-vertex blade per instance)
- `docs/adr/img/0037-dense-grass.png`
