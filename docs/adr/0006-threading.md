# 0006 - Threading: chunk jobs on std.Io, no locks in the streaming path

- Status: accepted
- Date: 2026-11-25
- Decides for: 1.11 (streaming), 1.13 (worker threads), 1.16 (frame budget)

## Decision

| Question | Answer |
|---|---|
| Concurrency API | **`std.Io.Threaded` + `io.async` + `Future.await`** (Zig 0.17 removed `std.Thread.Pool`) |
| Pool size | default `async_limit` = cpu_count - 1 (31 on burken's 32 threads) |
| Jobs | `generateChunk(chunk, seed)` then `meshChunk(chunk)`, one chunk per job |
| In-flight cap | **8** jobs; per frame submit up to **4** nearest, await up to **4** oldest |
| Locks | **none** in the streaming path - ownership moves with the future |
| Cancellation | never cancel a running job (86 us); drop its result if the chunk's **generation stamp** changed |
| Stats | `std.atomic.Value(u64)` counters, read by the HUD |
| Memory | chunk buffers from the slab (ADR 0003); mesh buffers from `std.heap.smp_allocator`, freed by the main thread after the GL upload |

## The trap in the 0.17 Io model

Per `std.Io.Threaded` docs: until `async_limit` is reached, `Io.async` when all threads
are busy **spawns a new thread**; past the limit, it **runs the task immediately on the
calling thread**. Submitting a whole 676-chunk ring in one loop therefore executes part
of the generation on the main thread, inside the frame. That is why the design keeps an
in-flight counter and submits at most 4 jobs per frame instead of pushing the queue.

## Diagram

```
main thread (owns GL, world map)              std.Io.Threaded pool (31 workers)
--------------------------------              ---------------------------------
frame N:
  desired = ring(player, radius 6)            [ ] idle workers
  submit up to 4 nearest   ---------------->  generateChunk(chunk, seed)   ~86 us
  await up to 4 oldest     <---------------  Future(void) completes
  upload finished meshes to GL
  mesh pass for ready chunks ------------>    meshChunk(chunk)              ~19 us
  read stats (atomics)
```

The await is only requested for jobs whose result the frame actually needs to upload;
the rest keep running while the frame continues.

## Shared state

Everything else is single-owner, which is what keeps this lock-free:

| Data | Written by | Read by | Guard |
|---|---|---|---|
| chunk voxel buffer | one worker (its job) | main, after the future completes | none - single owner, handed over by the future |
| chunk generation stamp | main (load/unload) | worker/main at result time | `std.atomic.Value(u32)`, compare before upload |
| world chunk map | main only | main only | none |
| job ring / submit cursor | main only | main only | none |
| in-flight future array | main only | main only | none |
| GL objects + upload | main only | main only | none |
| counters (submitted/done/dropped) | workers + main | HUD | `std.atomic.Value(u64)` |

No `std.Io.Mutex` anywhere in the hot path. If a mutex shows up in this table later, the
ownership model has broken down and the design should be reconsidered rather than
guarded.

## Measured

Probe at `~/voxel-spikes/threadprobe` (ReleaseFast, 676 chunks = 13x13x4, real noise
generation at 86 us/chunk and real naive meshing, checksum 199,717 quads identical in
every run):

| configuration | wall time for the whole load set |
|---|---|
| sequential on the main thread | **71 ms** |
| async, limit 1 | 47 ms |
| async, limit 2 | 32 ms |
| async, limit 4 | 20 ms |
| async, limit 8 | 14 ms |
| async, limit 16 | 10 ms |
| async, default (31) | **8 ms** (8.9x) |

Frame-paced submission, main-thread cost per frame:

| jobs per frame | frames to finish | avg per frame | worst frame |
|---|---|---|---|
| 2 | 676 | 0.08 ms | 0.29 ms |
| 4 | 338 | 0.08 ms | 0.53 ms |
| 8 | 170 | 0.09 ms | 0.70 ms |

At 4 per frame the main thread spends under 0.1 ms per frame on scheduling and 0.53 ms
in the worst case, against a 16.6 ms budget. Generation dominates (86 us vs 19 us), so
the ring fills at the rate the pool can generate, which is the correct bottleneck.

Scaling flattens after 8 workers because the workload is small (71 ms of work, thread
spawn cost included); a 13x13x4 ring is not a reason to use 31 threads, it is a reason
to use 8 and keep the machine responsive.

## Dependencies of this model

- Generation must stay pure (ADR 0005) or results depend on thread order.
- Chunk buffers must come from a slab (ADR 0003); per-job `alloc` would put the chunk
  allocator in the hot path.
- The 8-job in-flight cap is what prevents inline execution on the main thread; it is a
  constant to tune, not a magic number.

## Consequences

- 1.13 implements `src/world/scheduler.zig`: ring enumeration by distance, the submit and
  await budgets, generation stamps, and the counters.
- 1.11 reuses the same ring for load/unload and calls the scheduler; unload must bump the
  generation stamp before freeing so a late result is dropped, not written into freed
  memory.
- 1.15's HUD reads the atomic counters directly.
- 1.16 measures worst frame time with the budget constants at their measured values.
