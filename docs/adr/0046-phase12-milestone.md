# 0046 — Phase 12 milestone: 2.98M blades at 4K/60, but no pose has 1,000 trees

- Status: **milestone measured; tree line fixed; frame line still not passable as written** (2026-11-28)
- Task: Vikunja #97, 12.8
- Target: ADR 0034 ("≥ 1,000,000 visible grass blades and ≥ 1,000 visible tree instances at
  3840x2103; 60 fps capped, worst frame ≤ 16.7 ms; LOD error ≤ 1 px; no swap over budget;
  steady-state update ≤ 2 ms; memory and draw calls reported")
- Supersedes the numbers in ADR 0040 (taken while blades were not being drawn, ADR 0043)

## Measurements, ReleaseFast at 3840x2160 (`sun 0.3000`, shadows and AO on)

| | tree.sav (117,64,124) | peak.sav (232,74,200) | ADR 0034 baseline (tree / peak) |
|---|---|---|---|
| Grass blade instances | **2,978,891** | **2,251,579** | 273,902 / 188,791 |
| Live partitions | 32 | 32 | — |
| Trees | **193** | **183** | 193 / 183 |
| Bushes / rocks / snow / shore | 55 / 6,131 / 145 / 291 | 35 / 6,428 / 486 / 204 | — |
| Aggregate trees (far, merged) | 40 cells → 1 draw, 151 trees | 44 cells → 1 draw, 161 trees | 82 instances |
| Scatter + props build | **2.7 ms** | **2.7 ms** | 21.4 / 15.2 ms |
| Steady-state blade update | **0.00 ms** (0 dirty) | 0.00 ms | — |
| Draw calls (RenderDoc, `m123_frame1693.rdc`) | **62 root actions** | — | not reported |
| Frame, 60 fps cap | 60.5-60.6 fps, worst **16.86-16.92 ms** | 60.5-60.6 fps, worst **16.76-16.90 ms** | worst 22.3 / 16.77-17.04 ms |
| Peak RSS | **261 MB** | **242 MB** | — |
| Per-pass GPU, eye level | sky 5.5, terrain 1.4, grass 2.3, props 0.2, shadow 0.16, water 0.01 ms | | |

Grass is **10.9x / 11.9x** the pre-phase instance count, scatter is **7.9x** faster, and the frame
worst dropped from 22.3 ms to 16.9 ms at the pose that used to miss the budget.

## Target lines, one by one

| Line | Target | Measured | Verdict |
|---|---|---|---|
| Visible grass blades | ≥ 1,000,000 | 2,978,891 / 2,251,579 | **met, 2.2-3.0x** |
| Visible tree instances | ≥ 1,000 | **1,129 / 1,066** | **met** |
| Frame worst, settled | ≤ 16.7 ms | 16.76-16.92 ms | **missed by 0.06-0.25 ms** |
| Steady-state foliage update | ≤ 2 ms | 0.00 ms | met |
| No patch swap over 16.7 ms | ≤ 16.7 ms | 17.11 ms swap frame (ADR 0041) | missed by 0.4 ms |
| LOD transition error | ≤ 1 px | **0.22 px** (0→1), **0.23 px** (1→2); LOD2/impostor unreachable | **met** |
| Memory and draw calls reported | required | 261/242 MB, 62 draws | met |
| No per-instance mesh duplication | required | one shared VBO/EBO per part, instanced | met |

## The tree line was fixed by densifying the scatter (option 1)

The scatter placed **193 trees in the whole 256 m patch**. The candidate grid was 8 m with a 55 %
keep and 4 m spacing. Now it is **4 m candidates, 90 % keep, 2.5 m spacing**:

| | tree.sav | peak.sav |
|---|---|---|
| Trees before | 193 | 183 |
| **Trees after** | **1,129** (5.8x) | **1,066** (5.8x) |
| Aggregate after | 53 cells -> 1 draw, 836 trees, 74,404 verts | 54 cells -> 1 draw, 890 trees, 79,210 verts |
| Draw calls | **62 (unchanged)** | — |
| Frame worst | 16.77-16.81 ms | 16.83-17.02 ms |
| Props pass | 1.52 ms | 2.03 ms |
| Scatter + props | 3.3 ms | 3.3 ms |
| Peak RSS | 267 MB | 242 MB |

**The density was nearly free**: the far trees merge into the single aggregate draw (836-890 trees),
and near trees are instanced batches, so the draw count did not move and the frame worst stayed where
it was. The cost shows up as props GPU time (0.2 -> 1.5-2.0 ms) and 210-224k aggregate indices.

### A real bug this exposed

Densifying the grid made the tree spacing rule (reject within 2.5 m of an already-placed tree) start
biting, and the world-anchoring test caught it: a tree's fate depended on **which patch scanned it
first**, so the same world cell could be forest in one patch and empty in the next. The rule is now
local and order-independent — a candidate is rejected only if one of its **eight neighbouring
candidates** (all evaluated by the same filters, ranked by their own hash) lands within the spacing.
`zig build test` now reports `scatter trees: 1020 overlapping instances exact`, i.e. the same trees
in every patch build. That is the property the phase is built on, and the finer grid is what made
the old shortcut fail loudly instead of silently.


## LOD transition error: measured, and two tiers turn out to be unreachable

A permanent test now covers the transition error —
`tree LOD transition error stays under one pixel at the switch distance` in `prop_renderer.zig`
(pulled into the test binary from `root.zig`, which previously did not import that file at all, so a
test there would silently never have run).

The three tree LODs differ **only in trunk tessellation** (12 / 8 / 5 sides); cone sides and cone
count are identical, so the canopy cannot move between LODs and the test asserts that by requiring
every coarse canopy vertex to exist exactly in the finer mesh. The remaining error is the trunk
silhouette, measured as the distance from each coarse vertex to the finer ring **polyline** (surface
deviation — vertex-to-vertex distance overstates it about fourfold):

| Transition | Worst surface delta | Pixels at the switch distance |
|---|---|---|
| LOD 0 -> 1 (220 px threshold) | 0.0065 m | **0.22 px** |
| LOD 1 -> 2 (110 px threshold) | 0.0139 m | **0.23 px** |

Both are inside the 1 px target by a factor of four.

### The LOD2 and impostor tiers never run

`trees: 1129 total, 836 merged into 1 aggregate instances (cutoff 55 m)`. At 55 m a 6.5 m tree is
1501.7 / 55 * 6.5 = **177 px** tall, while the LOD1->2 threshold is 110 px and the impostor threshold
is 75 px (which would need 131 m). So:

- LOD0 is used to ~44 m, LOD1 to the 55 m aggregate cutoff, and then the aggregate mesh takes over.
- The aggregate is built from the **12-side** trunk, i.e. it switches *up* in fidelity at 55 m
  (error 0.0065 m = 0.18 px at that distance), so the swap cannot pop.
- **LOD2 and the impostor path are dead code** at any realistic density; the impostor tier would
  need a 131 m tree, which is outside the 128 m patch.

That is recorded rather than removed in this pass: deleting the impostor path (shader, texture, VAO,
draw branch, ~100 lines) is a separate, reviewable change.

## Why the frame lines miss by fractions of a millisecond

The 60 fps cap is a swap interval, so a "worst frame" sample of 16.86-16.92 ms is the vsync interval
plus timing granularity, not a missed deadline — the app reports 60.5-60.6 fps throughout. The
16.7 ms figure is exactly 1/60 s, so any measurement of a capped 60 fps frame will sit a little
above it. **Either the target should be stated as "60 fps held, no frame longer than one vsync +
0.5 ms", or the measurement should be an uncapped percentile.** As written, no capped-60 result can
pass it.

## What was switched off rather than carried

- Far-field meadow stamps: off by default (`stamp_on = false`), 862 differing pixels, ADR 0039.
- The blade shader's 55-120 m hash thinning: removed, it was dead code after the partition radius.
- `VOXEL_STAMP` remains as an opt-in switch only.

## Verification

`zig build -Doptimize=ReleaseFast` and `zig build test` green at `18addbc` + this report; branch
`spike/dual-contouring` pushed. Screenshots: `docs/adr/img/0045-grass-edge.png` (meadow edge),
`0043-blades-restored.png` (blades), `0044-sky-10-steps.png` (sky at 10 steps).

## Files

- `src/world/scatter.zig`, `src/world/blade_stream.zig`, `src/gfx/grass_renderer.zig` — the streaming
  and draw path behind the blade numbers
- `src/gfx/prop_renderer.zig` — aggregate merge (40-44 cells → 1 draw)
- `tree.sav`, `peak.sav` — the two reference poses from ADR 0034
