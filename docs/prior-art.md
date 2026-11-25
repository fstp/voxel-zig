# Prior art notes

Short, opinionated notes on what exists and what we take from it. Read before
designing a subsystem; update when something new is worth knowing.

## Sources

| Source | What it actually is | Status |
|---|---|---|
| [OpenStaticFish/ZigCraft](https://github.com/OpenStaticFish/ZigCraft) | A real Minecraft-like engine in Zig: ~100k LOC across `world-core`, `world-meshing`, `world-runtime`, `worldgen-overworld`, `engine-graphics` (Vulkan), `engine-core` (job system). Targets Zig **0.16.0**. | read, valuable |
| [Selveris/voxel-engine](https://github.com/Selveris/voxel-engine) | **Not a voxel engine.** 48-line SDL2 window + clear demo from a Vulkan tutorial, plus an OBJ/MTL loader. Zig 0.13. | discarded |
| [vengi Meshing](https://vengi-voxel.github.io/vengi/Meshing/) | C++ voxel tooling; documents its mesher modes: cubic (default, blocky), marching cubes (organic), binary greedy, greedy + texture atlas (export only). | read, confirms cubic |
| [0fps: meshing](https://0fps.net/2012/06/30/meshing-in-a-minecraft-game/), [0fps: AO](https://0fps.net/2013/07/03/ambient-occlusion-for-minecraft-like-worlds/) | The canonical naive-vs-greedy and per-vertex AO write-ups. | already used in ADR 0004 |

ZigCraft is the only one worth reading in depth. Concrete numbers from it, for
calibration against our own (ADR 0004: 1,414 quads / 170 KB per surface chunk,
18.8 us to mesh):

## ZigCraft, condensed

- **Chunk**: 16 x 256 x 16 column, `blocks` + per-voxel `PackedLight` + `biomes` +
  `heightmap` arrays inline, a 10-state enum (`missing` .. `renderable`), `job_token`,
  atomic `content_revision` / `light_revision`, `pin_count`, `dirty`, `modified`.
- **Meshing**: greedy, with *tolerance* merging - a quad merges while light differs by
  at most 1 level and biome tint by at most 0.02. AO, light and colour come from
  separate sampler modules. Output splits into solid / cutout / fluid vertex sets.
- **GPU memory**: one "megabuffer" (large VBO) with sub-allocations per chunk mesh,
  instead of a VBO per chunk.
- **Streaming**: worker budget split gen vs mesh (roughly 2/3 - 1/3 of `cpu_count - 1`),
  startup radius ramps 3 -> 5 -> 7, unload buffer beyond the render distance,
  `max_uploads_per_frame` cap.
- **Jobs**: hand-rolled priority min-heap keyed by squared distance to the player, lazy
  reprioritisation when the player moves, worker pool on `Mutex`/`Condition`, cleanup
  callbacks for dropped jobs.

## What we copy

1. **A chunk state machine.** Our `Chunk` gets an explicit state enum (`empty`,
   `queued_generate`, `generating`, `ready`, `queued_mesh`, `meshing`, `mesh_ready`,
   `uploading`, `renderable`, `unloading`) instead of ad-hoc booleans (1.5, 1.11).
2. **Monotonic revision stamps**, ZigCraft's `content_revision` is the same idea as our
   generation stamp (ADR 0006); they store it as `std.atomic.Value(u64)` inside the
   chunk, which is where ours belongs too.
3. **Distance-squared priority.** Their queue ordering confirms ours: sort the ring by
   squared distance, nearest first.
4. **Split mesh outputs by material class** (solid / cutout / fluid). Matches ADR 0002's
   pass plan; leaves go in cutout, water in fluid, everything else solid.
5. **Budget split between generation and meshing.** They run more generators than
   meshers; our measured ratio is 86 us vs 19 us per chunk (4.5:1), so a 3:1 or 4:1
   worker split is justified when we go multi-worker per stage.
6. **Tolerance-based greedy merging** (light +-1, colour +-0.02) for 2.1: exact-match
   merging collapses because AO/light differ at every corner, tolerance merging does not.
7. **Startup radius ramp** (3 -> 5 -> 7) so the first seconds do not try to load the
   whole ring at once (1.11).
8. **A megabuffer for chunk vertices** as the later draw-call reduction step: one big
   VBO + sub-allocations beats 676 individual VBOs (1.16 at the earliest).

## What we avoid

9. **Per-voxel light arrays in the chunk from day one.** Their chunk carries a
   `PackedLight` per voxel plus biome and height arrays inline: 32 KB of blocks becomes
   a ~100 KB struct. We add lighting in 1.12 as a bolt-on, not as the base layout.
10. **Their job system.** A priority heap + `std.Thread.Mutex`/`Condition` worker pool is
    ~800 LOC and, in 0.17, `Mutex`/`Condition` moved into `std.Io` anyway. Our probe
    (ADR 0006) gets the same 676-chunk set done in 8 ms with `io.async` and a bounded
    submit loop.
11. **16 x 256 x 16 columns.** Measured in ADR 0003: a block edit in a column layout
    remeshes the whole 256-high column; our 32^3 cubes remesh 1/8th of that volume.
12. **GPU meshing and a Vulkan RHI.** ZigCraft ships a compute-shader mesher and a
    27k-LOC graphics module. For a PoC, CPU meshing at 18.8 us/chunk against an 8.9x
    throughput headroom is not a bottleneck.
13. **Their scope.** 8 modules, ECS, atmosphere, UI framework, persistence, tests
    everywhere. Our PoC budget is ~3k lines; anything that does not serve the 0.9
    contract stays in phase 2.

## Ports of call if we get stuck

- Greedy with AO: 0fps AO post + ZigCraft's `ao_calculator.zig`.
- Chunk streaming edge cases (unload while a job is in flight): ZigCraft's
  `chunk_queue_coordinator.zig` and `pin_count` model; our answer is single-ownership +
  generation stamps (ADR 0006), so compare before adopting pin counts.
- Mesh buffer management: `world-meshing/src/chunk_allocator.zig`.
