# Lighting and sky scope contract (phase 3)

Written before the lighting work starts, for the same reason `poc-scope.md` was
written before the game existed: so the phase cannot sprawl. Every phase 3 task
must trace back to a requirement below.

Phase 3 changes how the world *looks*, not what it contains. The PoC contract
(C1-C12) stays in force; this document adds C13-C26 and does not relax anything.

## What exists today, so the contract starts from facts

| Thing | Where | State |
|---|---|---|
| Face shading | `gfx/chunk_renderer.zig`, `faceBrightness()` | Hardcoded table: +y 1.00, +-x 0.80, +-z 0.65, -y 0.50 |
| AO | same shader, `mix(0.45, 1.0, v_ao / 3.0)` | Baked per vertex since 1.12, multiplies the table |
| A/B toggle | `u_shading`, F4 | Switches AO plus face shading on and off |
| Sky | `app.zig`, `glClearColor(0.53, 0.72, 0.92, 1)` | One flat colour, no geometry, no sun |
| Sun | nothing | No direction anywhere in the engine |
| Textures | `gfx/texture.zig`, `gl.TexImage3D(..., gl.RGBA8, ...)` | PNG bytes treated as linear, so the pipeline is neither correct nor intentional |
| Block renderer | `gfx/block_renderer.zig` | Textured, unlit: physics boxes and the brush preview have no shading at all |
| Baseline speed | measured repeatedly | 120.0 fps, 8.33 ms frames, worst 8.43-8.58 ms in short runs; the 1.16 soak saw 27.5-36.3 ms spikes during chunk upload |

## The contract

Numbers are acceptance thresholds, not wishes. A requirement without a way to
prove it does not belong in this table.

| # | Requirement | How it is proven |
|---|---|---|
| C13 | One sun: a single source of truth owns time of day, a unit direction vector, colour and intensity | unit tests on direction length and ramp continuity, plus a HUD readout of time, elevation and azimuth |
| C14 | Directional shading: a face pointing at the sun is measurably brighter than a face pointing away, at every time of day | screenshots from both sides of a hill at three times; the ratio is read from the pixels, not asserted |
| C15 | AO still multiplies in: a concave corner is darker than flat ground under the same sun | A/B screenshot pair on a built corner |
| C16 | F4 keeps working as an A/B: one press switches between the old face table and the new sun-driven model, no restart | two screenshots from one run, before and after the key |
| C17 | The sky is drawn, not cleared: gradient with a horizon, a sun disc at the sun direction, colours that change through the day | screenshots at dawn, noon, dusk and night |
| C18 | Sky and terrain agree: the lit faces point at the sun disc, and there is no seam where terrain meets sky | look at the disc, then at shading; horizon screenshot at render distance |
| C19 | Day cycle: dawn, noon, dusk and night look different, ramps are continuous (no pop at sunrise or sunset), and night is dark but still readable | four screenshots, plus a pan across sunrise with no visible jump |
| C20 | One documented gamma policy, applied everywhere: a mid-grey texel stays mid-grey under neutral light, and a 32-block face shows no banding | gradient screenshot, and the policy recorded in ADR 0008 |
| C21 | Fog uses the sky colour for the view direction, so terrain fades into the sky instead of hitting a wall at the load radius | flight screenshot at radius 6, plus a pixel comparison of fog and sky at the horizon |
| C22 | Physics boxes and the debug renderer are lit by the same model as terrain, so nothing looks pasted on | screenshot with thrown boxes against a lit hillside |
| C23 | Performance: 120 fps at 1280x720 at render distance 6 with sky, sun, fog and lighting on, and no frame over 12 ms in a 60 second flight | HUD frame and worst-frame figures, and a timed flight |
| C24 | Determinism: with a fixed start time (or an explicit override) the sun and sky state is reproducible, so screenshots and tests repeat | a test that sets the time and asserts the same direction twice |
| C25 | Stretch, only if 3.8 lands: terrain shadows move with the sun, no acne at a low sun, toggleable, cost reported | screenshots, a low-sun shot, and a measured frame cost |
| C26 | No regressions: C1-C12 still hold, `zig build test` stays green with the new lighting tests added | the 3.9 checklist repeats the PoC checks it can still run |

## Frame budget

The display is 120 Hz, so a frame is 8.33 ms; the PoC's 60 fps requirement
already implies headroom, and this phase spends it.

| Item | Budget |
|---|---|
| Baseline frame | 8.33 ms, worst 8.6 ms without lighting work |
| Sky pass (3.6) | 1.0 ms or less at 1280x720 |
| Sun and lighting math in the chunk shader (3.5) | 0.3 ms |
| Fog (3.7) | 0.1 ms |
| Shadow map (3.8, stretch only) | 2.0 ms, and off by default if it costs more |
| Worst frame during a 60 s flight at radius 6 | 12 ms |

A feature that blows its budget is disabled by default and reported in its task,
not shipped quietly.

## Out of scope

Permanently, or until a later phase:

- block light, torches, light propagation grids, coloured or point lights
- emissive blocks, bloom, lens flare
- volumetric light, god rays, clouds, weather, precipitation
- HDR framebuffer with an ACES-style tone mapper (a simple curve is allowed for C20)
- real atmospheric scattering models, unless ADR 0009 chooses one and says why
- cascaded shadow maps, contact shadows, SSAO
- MSAA changes, depth of field, motion blur
- shader hot reload

## Traceability

| Task | Requirements |
|---|---|
| 3.1 Sunlight model (ADR 0008) | decides C13-C16, C20 |
| 3.2 Skybox and sun path (ADR 0009) | decides C17-C19, C24 |
| 3.3 Face normals | enables C14 |
| 3.4 Sun model and day cycle | C13, C19, C24 |
| 3.5 Directional lighting | C14, C15, C16, C20, C22 |
| 3.6 Skybox | C17, C18 |
| 3.7 Fog | C21 |
| 3.8 Shadow map (stretch) | C25 |
| 3.9 Milestone run | proves all of them, and C23, C26 |
