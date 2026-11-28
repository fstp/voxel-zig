# 0041 — Patch-swap budget: threading, off-frame work, and the draw calls RenderDoc found

- Status: measured; **partially met, left open** (2026-11-28)
- Task: Vikunja #100, "14.1 Patch-swap budget: partition build off-frame and the swap frame under 16.7 ms"
- Follows: ADR 0040 (phase-12 milestone, line 6 open), ADR 0038 (partitioned blade streaming)
- Tool evidence: RenderDoc capture `~/captures/swap_frame2291.rdc` on burken

## What was open

ADR 0040 left line 6 ("no single patch-swap frame over 16.7 ms") open with three named costs:
the largest blade partition built inline (10.02 ms), the prop rebuild (6.1 ms) and the AO bake
(2.5 ms), plus the terrain mesh upload. The flat-pose swap frame measured 30-42 ms.

## What was built

1. **Blade partitions on an Io worker.** `blade_stream.Job` + `startJob`/`takeJob`: the cell is
   generated into a buffer the job owns, drained on the main thread, then copied into its slot.
   Dispatch costs ~1.0 us (`io.async`), the job lands one to two frames later, and the main thread
   never blocks. Measured: `started->landed 13-16 ms` on the worker, main-thread cost ~0.
2. **Props off the swap frame.** `scatter.buildProps` now runs alongside the mesh slices
   (2.7-6.5 ms, no longer inside the swap).
3. **AO bake off the swap frame** (2.5 ms -> 0), and **water grid split** into
   `buildPatch` (0.55 ms, off-frame) + `uploadPatch` (swap frame).
4. **Terrain mesh double buffering.** `DcRenderer` keeps two (VAO, VBO, EBO) sides; the pending
   patch is uploaded in ~12k-vertex slices across the suspension frames, and the swap only flips.
   Measured: remainder upload 42-60 us, flip 0 us.
5. **Fifty draw calls removed, found with RenderDoc, not by reading code.** The capture showed the
   per-tree aggregates as one draw per 32 m cell: 45 draws with `num_instances = 1` in the main
   pass *and* 45 more in each shadow cascade, all with index counts of 252-3024. They are now
   concatenated into **one mesh, one instance buffer, one draw** (`45 cells merged into 1 draw,
   177 trees, 15753 verts, 44704 indices`), which removes 45 draws from the main pass and 45 from
   each of the two shadow maps.

## Result

| Quantity | Before | After |
|---|---|---|
| Blade build on the swap frame | 10.02 ms inline | ~0 (worker, dispatched 1 us) |
| Prop rebuild on the swap frame | 6.1 ms | 0 (off-frame) |
| AO bake on the swap frame | 2.5 ms | 0 (off-frame) |
| Water grid on the swap frame | 3.5-15 ms | 0.55 ms off-frame + upload |
| Terrain upload on the swap frame | 8-9 ms `BufferData` | 0.04-0.06 ms sliced remainder |
| Aggregate draw calls (main pass) | 45 | **1** |
| Aggregate draw calls (each shadow cascade) | 45 | **1** |
| Steady-state blade update | 0.00 ms | 0.00 ms |
| Steady frame | 16.9 ms | 16.8-16.9 ms on the flat walk; 23.4 ms while climbing away from a swap |

**Every component the task named is now off the swap frame**, and the frame that used to cost
30-42 ms is down to the mesh flip plus the AO/water uploads — but the frame is not under 16.7 ms yet, so this
task's acceptance line is **not met**, and the shrink from 30-42 ms to 23-30 ms is the honest
result.

## The stall was a full GPU queue, proved by the sync A/B (14.2)

`VOXEL_GPU_SYNC=1` drains the queue with `glFinish` at frame end, and the picture changes completely:

| Measurement | Unsynced | `VOXEL_GPU_SYNC=1` |
|---|---|---|
| GPU time per swap section (`GL_TIME_ELAPSED`) | 0.000-0.009 ms | 0.000-0.009 ms |
| CPU time in the swap sections | 10-11 ms in whichever section came first | **0.04-0.08 ms** |
| Queue drained at frame end | not measured | **16.0-16.2 ms every frame** |
| Worst frame on a swap (after startup) | 23-30 ms | **17.11 ms** |
| Steady frame, same pose | 16.8-16.9 ms | 17.0-17.1 ms |

The per-section GPU queries report essentially nothing, so the 10 ms was never work in those
sections. It was the CPU blocking inside whichever GL call first made the driver wait for a queue
that was ~16 ms deep — which is why the label moved between `remainder`, `flip` and `water` from
one swap to the next. **With the queue kept short, the swap costs 0.04-0.08 ms and the frame sits
0.1 ms above the steady frame.**

So the renderer is GPU-bound at ~16 ms in this pose, and the patch swap was a victim of that, not a
cause. The remaining 0.4 ms above 16.7 is the steady frame, and RenderDoc's overdraw pass names
where it goes: **29x estimated average overdraw in the shadow cascades** (44 draws into a
3840x2127 target).

## Left open: the *steady* frame, not the swap

Measured worst frames on a 12 s walk at 60 fps: **23.4-30.4 ms**, with the first second after start
at 42 ms. The
remaining spikes are the frame the pending patch *completes* on: it flips the mesh, uploads the AO
map and the water grid, and runs `props.uploadTrees` (which now builds and uploads the merged
aggregate mesh). They are GPU-side uploads with no `glFinish` after them, so the CPU stamp shows
them cheap while the frame still spends the time somewhere the instrumentation cannot yet see.

Before touching that, one instrumentation fact must be stated: a wall-clock stamp around a block
that issues only GL calls reported 10-11 ms for a `glBindVertexArray` (flip 0 us inside the same
block). The stamps were inconsistent until the app's clock was replaced with
`std.Io.Timestamp.now`. **Do not trust sub-block timings around GL calls without checking that the
clock is monotonic under RenderDoc's injection** — an injected library changes where a libc
`clock_gettime` resolves from, and the resulting "stall" was measurement, not work.

## RenderDoc notes for the next session

- Trigger: `renderdoccmd capture -d . -c ~/captures/swap ./zig-out/bin/voxel-zig`, then
  `xdotool windowactivate` **before** `xdotool key --clearmodifiers F12`. An F12 sent to an
  unfocused window produces no capture and no error.
- The capture at 4K is 177 MB, and `list_actions` is the fastest way to see a draw-call regression:
  the aggregate issue was invisible in the code and obvious in the action list (45 identical
  `glDrawElementsInstanced` with `num_instances = 1`).
- `get_pipeline_state` on this build returns warnings for every state group
  (`'PipeState' object has no attribute 'GetViewports'`); the action list alone is reliable.

## Files

- `src/world/blade_stream.zig` (Job, startJob/takeJob)
- `src/gfx/dc_renderer.zig` (two mesh sides, sliced upload, flip)
- `src/gfx/water_renderer.zig` (buildPatch/uploadPatch)
- `src/gfx/prop_renderer.zig` (merged aggregate mesh)
- `src/dc_main.zig` (off-frame props/AO/water, switch to `std.Io.Timestamp`)
