# 0044 — The sky pass: 22 cloud march steps cost 8.1 ms, 10 cost 5.8 ms and look the same

- Status: **fixed** (2026-11-28)
- Task: Vikunja #102, 14.3 (rescoped from "shadow overdraw" after measurement)
- Follows: ADR 0043 (the grass that was not being drawn)

## The measurement that rescoped the task

14.3 was filed from RenderDoc's overdraw pass, which reported 29x average overdraw in the shadow
cascades. Per-pass `GL_TIME_ELAPSED` says otherwise:

| Pass | GPU time, eye level (4K) |
|---|---|
| **sky** | **5.9-11.1 ms** |
| terrain | 0.7-1.6 ms |
| grass | 1.4-2.1 ms (once actually drawn, ADR 0043) |
| props | 0.13-0.23 ms |
| shadow cascades | 0.09 + 0.08 ms |
| water / hud | 0.01 / 0.00 ms |

The overdraw figure counted 44 depth-only draw calls, not their cost; two 2048 depth passes are
0.17 ms together. **The raymarched sky is the frame's dominant cost**, and its own early-out
(`dir.y < 0.02`) is why looking down measures 0.09 ms.

## What was changed

The cloud march in `sky_frag.frag` was a hard-coded 22 steps with three-octave noise per step and,
inside cloud, two extra density taps for the light term. The step budget is now a uniform
(`u_cloud_steps`), default 10, overridable with `VOXEL_CLOUD_STEPS` for A/Bs.

## Measurements (median of 8 one-second samples, same pose, same sun)

| Steps | Sky pass, median | min-max |
|---|---|---|
| 22 (old default) | 8.12 ms | 5.91-11.11 |
| 14 | 6.97 ms | 5.69-7.73 |
| **10 (new default)** | **5.77 ms** | 5.64-5.85 |
| 6 | 3.65 ms | 3.58-3.67 |

The 22-step setting is also the noisiest (5.9-11.1 across eight samples), which by itself is an
argument for a cheaper march: the pass occasionally overshoots by 3 ms.

## Quality

Frame-to-frame diff between the 22-step and 10-step renders, sky region only (3840x900):
**mean |delta| 1.91, p99 = 11, max 152, 4.45 % of sky pixels differ by more than 8.** The max
lands on cloud edges. Side by side the deck, its structure and the horizon haze read the same; the
10-step version is marginally softer at the edges.

## Result

Sky **8.12 -> 5.77 ms** median with no visible change. Frame stays at the vsync cap (16.86-16.89 ms,
60 fps), so the gain is headroom rather than a higher number: the app now has ~2.3 ms of slack it did
not have before, and the pass no longer spikes to 11 ms.

## Left open

- The frame is still at the cap (16.9 ms vs 16.7), so nothing here is *proven* to buy frames yet.
  The next real test is a heavier scene (far-field density up) to see whether the saved 2.3 ms is
  what keeps 60 fps.
- `cloudDensity` is called three times per in-cloud step (one density, two light taps) with three
  octaves each. A cheaper light tap (two octaves, or a single tap at 70 m instead of 45 + 110) is
  still on the table if the sky needs to get cheaper again.

## Files

- `src/shaders/sky_frag.frag` — `u_cloud_steps`
- `src/gfx/sky_renderer.zig` — `cloud_steps` default 10, uniform upload
- `src/dc_main.zig` — `VOXEL_CLOUD_STEPS` override
