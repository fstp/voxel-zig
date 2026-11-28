# 0038 — Partitioned blade streaming: persistent slots per 32 m cell

- Status: implemented (2026-11-28)
- Task: Vikunja #95, "12.6 Partitioned foliage instance streaming (PTLAS analogue)"
- Related: ADR 0034 (massive foliage adaptation), ADR 0032 (world-anchored scatter), ADR 0037
  (dense clumped grass)
- Files: `src/world/blade_stream.zig`, `src/world/scatter.zig`, `src/gfx/grass_renderer.zig`

## Context

Every 32 m patch move rebuilt the whole blade field and re-uploaded the whole instance buffer.
Measured on this machine at the spawn pose, the blade build alone is **218.4 ms for 2,503,346
instances**, and it ran inside the frame that swapped the patch, so that frame was ~200 ms plus
everything else. The paper's PTAS idea — partition the active set, keep slots persistent, touch
only what changed — applies directly to the CPU/GL side of this renderer.

The world was already a good fit: ADR 0032 made every instance a pure function of its world cell,
so a cell that stays put produces bit-identical instances whenever it is rebuilt.

## Design

- **Partition = one 32 m DC chunk.** `scatter.buildBladesCell(edits, cx, cz, out)` builds the four
  blade layers for one cell. It uses the same 0.25 m / 1.3 m / 7 m / 4.5 m world lattices, the same
  Wyhash salts and the same absolute 2 m height lattice as the whole-patch build (each cell builds a
  25x25 local grid anchored on the global 2 m grid, with an 8 m halo for the normal sampling and the
  blades a tuft spills outside), so the composed patch and the streamed patch are the same set.
- **Active set is cell-quantised.** A cell carries blades when its centre is within
  `ACTIVE_RADIUS = 96 m` of the patch centre. The old build clipped candidates at 95 m from the
  centre; quantising to cells means a cell's contents no longer depend on the patch, which is what
  makes retention valid. The quantised edge lands inside the grass shader's own 55-120 m hash
  thinning, and the ground-level check shows no cut-off line.
- **Registry (`blade_stream.zig`).** A fixed-capacity instance buffer, a first-fit slot allocator
  with coalescing, one persistent range per cell, and a `built` flag so an empty cell counts as
  finished. `begin()` marks the target patch's cells, `step(alloc, edits, budget, uploads)` builds
  at most `budget` missing cells (one per frame), `commit()` frees the cells the new patch does not
  want and makes the rest live. A cell keeps its range across frames; nothing moves unless the
  allocator is out of holes, in which case `compact()` re-packs once.
- **Renderer.** `GrassRenderer.ensureCapacity/uploadRange/drawRange`: one instanced draw per live
  partition and `glBufferSubData` for the entering cells only. `upload()` remains for one-shot use.

## Numbers (ReleaseFast, 3840x2103, `VOXEL_DC_SUN=0.30`)

| Quantity | Before | After |
|---|---|---|
| Full blade build at startup | 218.4 ms (and again on every patch swap) | 218.4 ms once, at startup |
| Patch-swap blade rebuild | whole patch | one strip: **8 cells, 385,064 instances, 1.0-11.7 ms per cell** |
| Patch-swap frame | ~200 ms + frame work | **27.48 ms worst** |
| Steady-state blade update | full buffer re-upload | **0.00 ms, 0 dirty partitions** |
| Frame at 2.50M blades, ground pose | 16.94-17.06 ms | 16.94-17.15 ms, 60 fps |

Verification:

- **Placement parity.** `VOXEL_BLADE_CHECK=1` builds the whole patch a second time at startup and
  compares the multiset of instances: `stream 2503346 blades sum 938f0ba4ff618151, full build
  2503346 blades sum 938f0ba4ff618151, equal true`. The streamed set is bit-identical to the
  composed patch build.
- **World anchoring** (`scatter` test): patches at (0,0) and (32,0) share 401,489 blades exactly in
  the region both active-cell sets cover.
- **Slot reuse and coalescing** (`blade_stream` test): a freed middle range is re-used exactly, a
  split leaves the right remainder, and adjacent frees coalesce into one 300-instance hole.
- **Only entering cells rebuild** (`blade_stream` test): two patches moving one cell east give
  `6 builds total, 2 dropped, 4 live` — the two kept cells are not rebuilt.

## Consequences

- The remaining swap spike is **one dense cell of synchronous build (up to 11.7 ms)**. It is the
  next thing to fix: build partitions on a worker thread, or drop to 16 m cells (4x cheaper per
  cell, 4x more cells). Neither is in 12.6.
- Props (trees, rocks, snow, shore) are still a whole-patch build (`scatter.buildProps`, 6.1 ms)
  plus the AO bake (2.5 ms) and the mesh upload inside the swap frame. Those, not the blades, are
  now the largest whole-patch costs on a swap.
- **Blade placement at the rim changed by construction.** The old build clipped candidates at 95 m
  from the patch centre; the new one builds whole cells whose centre is within 96 m, so the rim
  ring differs from the pre-refactor build (2,503,346 instances at the spawn pose vs 2,182,160
  before). The composing build and the stream agree exactly; the change is the quantisation, and it
  is what makes a retained cell valid.
- Buffer high-water mark is 2.89M instances after one diagonal move (fragmentation); capacity is
  4M and `compact()` exists for the case where no hole fits. Do not lower the capacity without
  re-measuring the high-water mark.
- `PARTS n  DIRTY m  BLADE UPD x.xx ms` is on the HUD and the once-per-second log line carries the
  same values, so a swap can be audited from text without screenshots.
