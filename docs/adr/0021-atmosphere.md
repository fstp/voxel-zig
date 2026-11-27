# 0021 - Atmosphere: what replaces the high cirrus deck

- Status: accepted, implemented 2026-11-27
- Date: 2026-11-27
- Supersedes: the high cirrus deck added in 7.6 (removed here)

## Why this exists

The high deck was removed because it read as parallel stripes, but it was the only thing giving the
sky depth above the cumulus slab. The sky also has no aerial perspective at all: distant terrain is
as saturated as near terrain, and the horizon is a clean gradient rather than an atmospheric band.
The replacement should produce depth from the atmosphere itself, not from a second cloud layer.

Constraints: a stylised palette (ADR 0009), a pinned sun in the spike, 4K at 60 fps, and no extra
render passes unless they earn their cost.

## Survey

| Technique | What it gives | Cost / shape |
|---|---|---|
| Preetham et al. 1999, analytic daylight | cheap closed-form sky colour | no aerial perspective; a fit, not a medium |
| Hosek & Wilkie 2012 | full spectral analytic sky dome | still a sky fit; no scene fog |
| Bruneton & Neyret 2008, precomputed scattering | physically based sky, multiple scattering, aerial perspective | large precomputed LUTs (4D), expensive to build and update |
| Hillaire 2020 (EGSR), "scalable and production ready" | ground-to-space atmosphere from four small LUTs: transmittance, multiple scattering, sky-view, aerial perspective | 3-4 render-to-texture passes, sky-view LUT rebuilt when the sun moves, terrain reads an aerial-perspective volume (32x32x32 in the paper); used in UE/Fortnite |
| Frostbite 2016 (SIGGRAPH course) | scattering LUTs + 32x32x16 aerial-perspective volume + height fog from horizon scattered luminance | same LUT machinery; height fog is an artistic add-on |
| Decima 2017 (SIGGRAPH Advances) | precomputed scattering **combined with an analytic height-fog model** (single scattering, single scale height) | no extra LUTs; the fog is evaluated analytically per pixel; gives artists dense/coloured fog and physical aerial perspective in one model |
| Godot 4 sky shader | procedural sky material, gradient/cloud controls | not a physical medium; useful only as an API reference |

Sources are listed at the bottom. The important distinction: **the physical atmospheres are
LUT-based; the game-practical height fog is analytic**. Hillaire's paper is the state of the art
for a dynamic, ground-to-space atmosphere, but its value is the LUT parameterisation, not a
per-pixel integral — at 4K the sky is rendered into a low-resolution sky-view LUT and upsampled.

## Decision

Take option (a) from the task, extended: keep the existing gradient and sun, and add a
**physically shaped analytic height fog / aerial perspective** to the terrain plus a **horizon haze
band and Mie forward glow** to the sky, in the spirit of Decima's hybrid. No LUTs and no extra
passes.

Why not the Hillaire LUT set now:

- The spike has a pinned sun. A sky-view LUT is rebuilt when the sun moves; a per-frame rebuild for
  a static sun is pure waste.
- The visual target is depth and a horizon band, not a space view or a planet-scale atmosphere.
- The budget is one full-screen sky pass at 4K/60. The terrain fog is ~20 ALU per fragment and the
  sky band a few more; three additional LUT passes are a much larger change with no visible win on
  the target scene.
- The existing palette is art-directed (ADR 0009). A full physical sky would fight it unless it is
  re-tuned, which is a separate art task.

Upgrade path: the atmosphere terms live behind `u_atmosphere` and a small set of uniforms. If the
sun becomes dynamic, or space views / a real aerial-perspective volume are needed, Hillaire's four
LUTs are the documented replacement, and the terrain fog lookup becomes a LUT sample instead of the
analytic integral.

## What is built

- Sky: remove `u_cirrus`/`u_cirrus_shift` and the `cirrus()` function. Add `u_atmosphere`: a
  horizon haze band (exponential in view height) tinted by the horizon colour plus a Mie-like
  forward glow around the sun.
- Terrain: an analytic integral of an exponential height density along the view ray,
  `tau = d0 * exp(-(eye.y - base)/H) * dist * (1 - exp(-dy/H)) / (dy/H)`, blended to a fog colour
  made of the horizon scattering colour plus a sun-forward term. Applied in the same display space
  the spike's terrain shader already outputs, so the established look does not shift.
- `VOXEL_ATMOSPHERE=0` disables both for A/B screenshots.
- `VOXEL_DC_SUN=0.22|0.30|0.38` pins the sun at dawn/noon/dusk for the acceptance shots.
- HUD reports the sky pass's GPU time (`sky.last_ms`), not only frame time.
- Cirrus code and uniforms deleted from `sky_frag.frag`, `sky_renderer.zig` and `dc_view.zig`.

## Verification (measured 2026-11-27)

- 60.0 fps at 3840x2103, frame 16.55 ms, worst 17.16 ms; the sky pass reports 7.74 ms in the HUD.
- Noon A/B with `VOXEL_ATMOSPHERE=0`: mean absolute difference 3.71/255 over the frame and 51 % of
  pixels changed by more than 4 - the haze is present but does not repaint the scene.
- Screenshots at `VOXEL_DC_SUN=0.03` (dawn), `0.30` (noon, sun 62 deg), `0.57` (dusk, sun 9.7 deg)
  with the effect on, plus noon with it off:
  `docs/adr/img/atmosphere-0021-dawn.png`, `-noon.png`, `-dusk.png`, `-noon-off.png`.
- `zig build test`: 178/178; the sky still compiles with `u_atmosphere = 0` for the engine, whose
  accepted look is unchanged.
- Palette stays on ADR 0009's ramp; no bands or stripes at the horizon.
- Fog constants after tuning: density 0.0045 at 30 m, scale height 20 m. A first pass at 0.010 was
  visibly a green wash over the foreground; 0.0045 keeps the near slope clean and lets the far
  ridge pick up the horizon tint.

## Sources

- Hillaire 2020, A Scalable and Production Ready Sky and Atmosphere Rendering Technique:
  https://sebh.github.io/publications/egsr2020.pdf
- Reference implementation: https://github.com/sebh/UnrealEngineSkyAtmosphere
- Bruneton & Neyret, Precomputed Atmospheric Scattering:
  https://inria.hal.science/inria-00288758/document
- Preetham, Shirley & Smits 1999, A Practical Analytic Model for Daylight:
  https://www.cs.utah.edu/~shirley/papers/sunsky/sunsky.pdf
- Hosek & Wilkie 2012, An Analytic Model for Full Spectral Sky-Dome Radiance:
  https://cgg.mff.cuni.cz/projects/SkylightModelling/
- Decima, SIGGRAPH 2017 Advances (analytic height fog + precomputed scattering):
  https://www.realtimerendering.com/advances/s2017/DecimaSiggraph2017.pdf
- Frostbite, Physically Based Sky, Atmosphere and Cloud Rendering (SIGGRAPH 2016 course):
  https://www.slideshare.net/slideshow/physically-based-sky-atmosphere-and-cloud-rendering-in-frostbite/78314147
- Godot 4 sky shaders (API reference only):
  https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/sky_shader.html
- UE5 SkyAtmosphere component (technique context):
  https://dev.epicgames.com/documentation/en-us/unreal-engine/sky-atmosphere-component-in-unreal-engine
