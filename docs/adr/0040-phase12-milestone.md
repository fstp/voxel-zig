# 0040 — Phase 12 milestone: what holds at 4K, and what does not

- Status: milestone **not met**, measured (2026-11-28)
- Task: Vikunja #97, "12.8 Milestone: 1M visible foliage instances at 4K/60"
- Baseline: ADR 0034 (273,902 blades / 193 trees at `tree.sav`, scatter 20.5 ms, 60 fps capped)

## Acceptance lines from ADR 0034

| # | Line | Result |
|---|---|---|
| 1 | >= 1,000,000 visible grass blades at 3840x2103 | **met, 11x margin** |
| 2 | >= 1,000 visible tree instances | **not met — 193 trees exist, 42 aggregate instances** |
| 3 | 60 fps capped | **met** |
| 4 | worst frame <= 16.7 ms after settling | **met on the flat-motion pose, missed on swaps and on the climb** |
| 5 | foliage LOD error <= 1 px | met at the measured thresholds (ADR 0034) |
| 6 | no single swap frame over budget; steady-state update <= 2 ms | **steady state met (0.00 ms), swap frame not met** |
| 7 | memory and draw calls reported | met below |

## Numbers

ReleaseFast, RX 9070 XT, window 3840x2103, `VOXEL_DC_SUN=0.30`, sun paused at noon.

**Steady state** (walking on flat ground, 60 fps cap):

| Quantity | Value |
|---|---|
| Blades | **2,978,891** (11x the 1 M target) |
| Blade partitions / live slots | 32 / 2,978,891 of 4,000,000 |
| Blade instance memory | 2,978,891 x 36 B = **107.2 MB** (+ 36.8 MB reserve) |
| Dirty partitions / blade update | **0 / 0.00 ms** |
| Terrain | 111,024 verts, 87,829 quads |
| Props | 6,131 rocks, 145 snow, 291 shore, 193 trees -> 0 impostors at this pose (LOD counts in the tree-draw line) |
| Frame / worst | **16.94 ms / 17.26 ms**, FPS 60.0 |
| Sky pass | 8.52 ms |

**Climbing a slope** (same pose walked uphill): worst frame **21.1-22.2 ms**. The eye-level
downhill pose hides fill cost; a slope with the canopy and meadow filling the frame does not.

**Patch swap** (26.7 m sideways on flat ground, 32 m patch step): 9 blade partitions built and
uploaded, per-partition **up to 10.02 ms**, swap frame **33.20 ms**. Unchanged by this phase: the
swap frame also carries the prop rebuild (6.1 ms), the AO bake (2.5 ms), the water grid, the
scatter tile rebuild and the terrain mesh upload.

**Uncapped** (`VOXEL_DC_FPS=120`), ground pose: 120.0 fps, worst frame **8.44-8.48 ms**.

## What the phase actually delivered

- **Blades: 273,902 -> 2,978,891** (10.9x) at the same 60 fps, through the dense clump lattice
  (ADR 0037), the world-anchored scatter fix (ADR 0032) and partitioned streaming (ADR 0038).
- **Blade update on a patch move: full rebuild (218 ms class) -> one strip of cells, 0.00 ms
  steady state.**
- **Trees:** bounded-error LODs (ADR 0034), rigid-part wind (12.3), aggregation beyond 55 m.
- **Software masks (12.5):** accepted for grass clumps at mid distance (167x fewer triangles),
  rejected for the conifer canopy; not wired into the app, so `docs/adr/0035` stands as a decision
  without a shipped path.
- **Far-field stamp (12.7):** built, measured invisible (0.010 % of pixels, a colour match with the
  existing ground photo), left off by default. `docs/adr/0039`.

## Why lines 2 and 6 failed

- **1,000 tree instances (line 2) is a density decision, not a code limit.** The scatter places one
  tree per 8 m candidate cell inside forest-density noise above 0.02, at most 55 % acceptance, and
  a 4 m clearance check: 193 trees at the test pose. Reaching 1,000 means multiplying the forest
  density, which changes the world's look and is not a streaming or LOD problem. The renderer can
  draw it: at 4,000 aggregate instances the tree pass costs 0.03 ms class (ADR 0034 measurement).
- **The swap frame (line 6) is the one cell build plus everything else on that frame.** The blade
  part is 10.02 ms for the largest entering cell; the prop rebuild, AO bake and mesh upload add the
  rest. Two fixes remain open: build cells on a worker thread (the mesher already runs a second
  build off-thread), and move the AO bake and prop rebuild off the swap frame. Neither is in phase
  12; both are listed for the next phase.

## Decision

**The milestone stays open.** Lines 1, 3, 4 (flat), 5 and the steady-state half of 6 are met and
measured; line 2 is a world-design choice that was not part of any phase-12 task, and the swap
frame is a known open item (3 x 16.7 ms is still under a 50 ms hitch, but it is not "no frame over
budget"). Phase 12's own mechanism work (12.1-12.7) is complete; the milestone is not, and this ADR
records exactly which lines are open rather than redefining them.

Next-phase candidates, in cost order:

1. Partition build on a worker thread (removes the 10 ms cell from the frame).
2. AO bake + prop rebuild off the swap frame (removes ~9 ms).
3. Forest density pass to reach 1,000 trees, if the world should look like that.

## References

- Screenshot with the HUD at this pose: `docs/adr/img/0038-blades-ground.png` (from 12.6; the same
  pose family and sun).
- ADR 0034 target table, ADR 0035 masks, ADR 0037 dense clumps, ADR 0038 streaming, ADR 0039 stamp.

## Files

- `docs/adr/0040-phase12-milestone.md`
- Vikunja 12.8 (#97), left open
