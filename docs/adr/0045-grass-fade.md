# 0045 — Grass fade: a 39 m dead band of paid-for invisible blades

- Status: **fixed** (2026-11-28)
- Task: Vikunja #103, 14.4
- Depends on: ADR 0043 (blades had never been drawn at all)

## The bug, as ground truth rather than impression

Two rules in different files disagreed about where the meadow ends:

- **Stream** (`blade_stream.begin`): keep a cell when its **centre** is within
  `scatter.ACTIVE_RADIUS`.
- **Shader** (`grass_renderer`): `world.y -= max(field - (ACTIVE_RADIUS - FADE), 0) * 0.09`,
  with `field` measured from the field **centre**, not the camera.

With `ACTIVE_RADIUS = 96`, `FADE = 22` and `SINK = 0.09` m/m, a script over the actual geometry
rules (`scratch/ring2.py`) gives:

| Pose | Kept cells | Blades reach | Deepest sink | Buried from |
|---|---|---|---|---|
| spawn (120,120) | 28/64 | 113.2 m | 3.5 m | 78.9 m |
| patch centre (128,128) | 32/64 | 115.1 m | 3.7 m | 78.9 m |
| off-grid (40,200) | 26/64 | 113.2 m | 3.5 m | 78.9 m |

**Every blade was fully underground from 78.9 m, while cells kept carrying geometry out to 113 m.**
A 34-39 m band of instances that were generated, uploaded, vertex-shaded and then discarded. That
band is the "bald ring", and it is also wasted work.

The second half of the bug is the centre test itself: a kept cell reaches up to half a cell diagonal
(22.6 m) past the radius, but a *dropped* cell that overlaps the radius leaves a hole **inside** the
fade. Where the hole lands depends on the grid phase, which is why the ring moved as the player moved.

## The fix

1. **Fade reaches zero at the cell edge.** The sink is now
   `fade_t = clamp((field - (R - FADE)) / FADE, 0, 1); world.y -= fade_t * fade_t * 0.55;` — at most
   0.55 m at the deepest, reaching exactly nothing at `R`, instead of 0.09 m/m running off the end.
2. **Radius reaches the cells it draws.** `ACTIVE_RADIUS 96 -> 84`, `ACTIVE_FADE 22 -> 24` (now a
   shared `scatter.ACTIVE_FADE` constant wired through `dc_main`, not a renderer default that can
   drift).
3. **Keep overlapping cells.** The stream keeps a cell when *any part* of it is inside the radius
   (`reach = R + CELL_M * sqrt(2) / 2`), so there is no hole inside the fade.

## Measurements

| | Before | After |
|---|---|---|
| Blade instances, spawn pose | 2,978,891 | 2,978,891 |
| Live cells | 32 | 32 |
| Worst frame, eye level | 16.98 ms | **16.98 ms** |
| Grass pass | 1.4-2.1 ms | 2.3-2.4 ms |
| Bald band | ~34 m (78.9-113 m) | none visible |
| 60 fps | held | **held (60.3)** |

The cell count is unchanged because 24 kept cells at 84 m plus the overlap band equals the 32
centre-kept cells at 96 m for this grid phase: the same instances, but now the ones that reach
farthest are also the ones the fade finishes on.

## Correction to my first attempt

The first version of this fix used `ACTIVE_RADIUS = 96` **with** the overlap rule, which kept 44 of
64 cells and 4,048,591 blades — worst frame **37.23 ms**. Keeping overlap cells without also
lowering the radius buys coverage by paying for a 36 % larger instance set. Both changes are needed
together.

## Verification

Elevated look-down at spawn: grass forms a continuous meadow past the trees with no readable
boundary and no bare ring (`docs/adr/img/0045-grass-edge.png`). `zig build` and `zig build test`
green; `scatter blades: 401489 overlapping instances exact`.

## Caveat

The fade is a vertex sink, so silhouette edges still reveal the quantised cell boundary at grazing
angles; it reads fine at this radius but a future radius increase will need a real distance
dissolve (alpha cutout with a noise threshold) rather than a sink.

## Files

- `src/gfx/grass_renderer.zig` — quadratic sink to zero, `active_fade` default 24
- `src/world/scatter.zig` — `ACTIVE_RADIUS 84`, new `ACTIVE_FADE 24`
- `src/world/blade_stream.zig` — overlapping-cell gate
- `src/dc_main.zig` — wires `grass.active_fade` from the shared constant
- `scratch/ring2.py` — the geometry-rules check that measured the dead band
