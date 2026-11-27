# 0030 Heightfield horizon AO for the DC terrain

- Status: implemented (11.4, 2026-11-27)
- Task: Vikunja #165 (#87)
- Research: ADR 0027

## Context

The DC terrain had no ambient occlusion. A screen-space pass would need a depth/normal prepass and
a temporal or spatial denoiser, and the engine deliberately has no TAA. The terrain is a
heightfield, so its large-scale occlusion can be computed directly from `heightAt` and stored as a
low-frequency texture, independent of the camera.

## Implementation

- `src/world/heightfield_ao.zig`: 64x64 samples over the 256 m patch (4 m texels), 12 azimuths,
  32 m horizon radius. `AO = 1 - average(sin(horizon))`; the height grid is bilinearly sampled.
- `DcRenderer` owns a 64x64 R8 texture, uploaded with `uploadAo`; the terrain shader samples it
  with the patch origin/size uniforms and multiplies ambient fully and direct sun by
  `mix(0.72,1,ao)`.
- The bake runs on the initial patch and on each streaming patch swap. `VOXEL_AO=0` is the A/B.
- No screen-space noise, no TAA dependency and no camera dependence.

## Evidence

ReleaseFast bake: **2.10 ms** initial peak patch, **1.78 ms** on a streamed patch (12 directions;
the 16-direction probe in ADR 0027 was 2.12 ms, 8 directions 1.05 ms). The 64x64 texture is
bilinear on the GPU. The peak screenshot with AO on:
`docs/adr/img/0030-ao-on.png`.

The effect is intentionally low-frequency: the terrain in the test world is smooth, so the
AO difference is concentrated in the valleys and the shaded side of ridges. A 4 m texel cannot
resolve a tree root or a 1 m rock; the sun shadow map and contact-scale detail remain separate.

Frame time: 60 fps holds, worst 17.08-17.40 ms; uncapped 120 Hz worst 8.42-8.52 ms with shadows
and AO. The AO bake is a patch-rebuild cost, not a per-frame cost. `zig build test` green.

## Limitations

- The grid is fixed to the 256 m patch and 4 m spacing; a larger streaming radius or a finer AO
  would need a tiled/multi-resolution version.
- AO is terrain-only. Props, grass and trees do not contribute to the terrain's sky occlusion;
  their contact shadows come from the sun map, not this texture.
- Patch edges clamp the height samples; no seam has been observed, but a true border-aware bake
  would sample the neighbouring patch if the world grows beyond one patch.

## Files

- `src/world/heightfield_ao.zig`
- `src/gfx/dc_renderer.zig`
- `src/dc_main.zig`
