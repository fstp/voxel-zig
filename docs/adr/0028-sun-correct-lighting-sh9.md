# 0028 Sun-correct lighting and SH9 sky ambient

- Status: implemented (11.2, 2026-11-27)
- Task: Vikunja #163 (#85)
- Research: ADR 0027

## Context

ADR 0027 found that the DC terrain shader had a hardcoded direct direction and a constant hemisphere
ambient; only the sun direction reached grass and props, and the terrain used it only for fog. At
sun time 0.10 and 0.30 the same four terrain pixels were bit-identical. This ADR makes the sun the
only source of direct light and replaces the constant ambient with SH9 sky irradiance.

## Implementation

- `src/world/sun.zig` adds `Sh9`: 128 Fibonacci-sphere samples of the same gradient/haze the sky
  pass draws (without the sun disc or clouds), projected into nine real-SH coefficients with the
  cosine convolution folded in. `Sun.skySh()` is evaluated once per frame on the CPU.
- `src/gfx/dc_renderer.zig` evaluates `u_sh[9]` for the perturbed normal, uses
  `u_sun_colour * max(N.L, 0)` for the direct term, and applies a small downward ground-bounce
  term. The hardcoded `l = normalize(vec3(0.45, 0.75, 0.40))` is gone.
- `src/gfx/grass_renderer.zig`, `prop_renderer.zig` and `water_renderer.zig` receive
  `u_sun_colour`, `u_ambient_sky` and `u_ambient_ground` from the same `Sun.lighting()` values, so
  time of day cannot disagree between terrain, grass, trees, rocks and water.
- `VOXEL_SHADOWS=0 VOXEL_AO=0` isolate the lighting change.

## Evidence (peak pose, HUD off, ReleaseFast)

Same four terrain pixels at sun 0.10 vs 0.30:

| Pixel | 0.10 | 0.30 |
|---|---|---|
| (960, 700) | 110, 136, 155 | 130, 152, 162 |
| (1200, 760) | 84, 106, 95 | 104, 122, 101 |
| (600, 820) | 93, 114, 102 | 114, 130, 109 |
| (1500, 900) | 110, 132, 123 | 139, 153, 132 |

Terrain-region mean luma difference **17.62**, **96.83 %** of pixels above 8 levels, **6.35 %**
above 24. Mean luma 114.1 at 0.10 and 131.7 at 0.30. The old build changed 0 of those pixels.
Screenshots: `docs/adr/img/0028-sun-010.png`, `0028-sun-030.png`.

Frame time: 60 fps holds, worst 17.09-17.33 ms; uncapped 120 Hz worst 8.43-8.49 ms with shadows and
AO off (the SH projection is not measurable at vsync). `zig build test` green.

## Limitations

- Impostor trees are still baked against a fixed sun in the atlas; their far-field shading does not
  rotate with time of day yet. The LOD0-2 trees, grass, rocks and water do.
- SH9 models the sky gradient, not the sun disc or clouds; the sun remains a separate directional
  light by design.
- Grass/props use a hemisphere evaluation of the same ambient values rather than the nine
  coefficients; terrain uses the full SH evaluation.

## Files

- `src/world/sun.zig`
- `src/gfx/dc_renderer.zig`
- `src/gfx/grass_renderer.zig`
- `src/gfx/prop_renderer.zig`
- `src/gfx/water_renderer.zig`
- `src/dc_main.zig`
