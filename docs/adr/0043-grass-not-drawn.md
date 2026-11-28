# 0043 — The meadow was not being drawn: two silent bugs and what the GPU timers exposed

- Status: **fixed** (2026-11-28)
- Found while instrumenting the frame for 14.3 (steady-frame cost)
- Supersedes the visual claims in ADR 0038/0039/0040 about grass rendering

## What happened

The per-pass `GL_TIME_ELAPSED` instrumentation added for 14.3 reported **`grass 0.00 ms` at every
pose**, including one where the meadow fills the screen. 2.98 M blade instances cannot be free, so
that zero was treated as a bug signal rather than a result. Two independent bugs were behind it.

### 1. The draw ran with no VAO bound (since 12.6)

`GrassRenderer.bindRange` ended with `gl.BindVertexArray(0)` and `drawRange` issued
`gl.DrawArraysInstanced` immediately **after** it. Drawing with VAO 0 in a core-profile context is
`GL_INVALID_OPERATION`, so the call was a no-op with no error surfaced: no blades, no cost, nothing
in the log. The unbind is now after the draw (`ADR 0043`), and the comment says why.

### 2. The fade uniforms were never uploaded (introduced with the 12.7 fade)

The vertex shader lowers blades with

```glsl
world.y -= max(field - (u_active_radius - u_active_fade), 0.0) * 0.09;
```

`GrassRenderer` had `active_radius`, `active_fade` and `field_centre` fields, and `dc_main` dutifully
set them on startup and on every patch swap — **but no code path ever called `setFloat`/`setFloat2`
for them**. All three read 0, so the expression degenerated to `world.y -= field * 0.09` measured
from the *world origin*: at x = z = 120 m the whole meadow was lowered **15 m** below the terrain.
The blades were submitted, vertex-shaded and paid for, then drawn underground.

## How it looked from the outside

The screenshots taken for 12.5/12.6/12.7 "showing the meadow" were showing the **terrain's ground
texture**. That is why the grass edge always looked perfectly continuous, why removing the far-field
hash thinning changed nothing visible, and why the 12.7 stamp A/B came out at 862 differing pixels:
there were no blades in the frame to differ.

**Lesson: a screenshot proves something renders, not that the thing under test renders.** Any claim
of the form "blades/trees/water look right" needs a check that can fail — here, the per-pass GPU
time (a pass that costs 0.00 ms while covering the screen is broken), or a probe that reads back
geometry, not a pixel count.

## State after the fix

| Measurement | Before | After |
|---|---|---|
| Grass GPU time, eye level | 0.00 ms | 1.4-2.1 ms |
| Blades visible at ground level | none (texture only) | yes — tufts, flowers, ferns |
| Frame, eye level | 16.8-16.9 ms | **16.9-16.9 ms**, 60 fps held |
| Frame, looking down | 16.8 ms | 16.8 ms |

The restored meadow costs 1.4-2.1 ms and 60 fps still holds, which also means the streaming work of
12.6/12.7 is sound — it just was not visible before.

## Still wrong, visible in the same frame

The fade maths survives the fix and is too aggressive: with `active_radius = 80`, `active_fade = 22`
and a scale of 0.09 m per metre, blades sink up to ~2 m between 58 m and 80 m from the field centre,
which shows as a **bald ring inside the field** and a hard partition edge. The stream already drops
whole cells at the radius, so the vertex fade should be either much shorter (the last few metres,
by ~0.25 m) or removed. Tracked as 14.4.

## Files

- `src/gfx/grass_renderer.zig` — VAO bind order in `drawRange`, fade uniform uploads
- `src/dc_main.zig` — per-pass `GpuQuery` instrumentation, `VOXEL_GPU_SYNC`
