# 0027 Lighting improvements: direct light, occlusion, sky, and when GI is worth it

- Status: research complete (2026-11-27)
- Task: Vikunja #162 (#84), "11.1 Lighting research: GI or a staged direct/occlusion/sky stack"
- Depends on: ADR 0008/0011/0015/0016 (the block renderer's lighting stack, deleted with the
  block engine by ADR 0022), ADR 0021 (atmosphere), ADR 0025/0026 (DC surface)

## Context

The DC app did not inherit the block renderer's lighting stack. The current terrain shader has:

- a **hardcoded** direct-light direction `l = normalize(vec3(0.45, 0.75, 0.40))`;
- a constant hemisphere ambient `mix(vec3(0.16,0.18,0.14), vec3(0.36,0.48,0.62), n.y)`;
- **no shadow map and no ambient occlusion**;
- `Sun.lighting()` (direction, sun colour, ambient sky/ground) exists, but only its direction is
  passed to grass, trees, rocks and water; the terrain shader uses that direction only for fog.

Measured on burken at the snow ridge pose (232, 74, 200), surfaces on, HUD off, ReleaseFast:
the same terrain pixels are **bit-identical** at `VOXEL_DC_SUN=0.10` and `0.30`:

| Pixel | sun 0.10 | sun 0.30 |
|---|---|---|
| (960, 700) | 127, 140, 134 | 127, 140, 134 |
| (1200, 760) | 95, 108, 81 | 95, 108, 81 |
| (600, 820) | 105, 115, 87 | 105, 115, 87 |
| (1500, 900) | 124, 131, 102 | 124, 131, 102 |

The lower-region mean luma difference is 2.24, but it is entirely the fog/sky tint changing; the
terrain's direct term does not move. That is a correctness bug before it is a quality issue: the
time of day changes the sky but not the ground.

Frame budget: 3840x2103, ReleaseFast, current build holds **60.0 fps, worst 16.85-17.18 ms**;
uncapped at 120 Hz the far pose is **10.3 ms worst**, so a 60 fps frame has roughly **6.4 ms** of
headroom. A 2048 shadow map plus a 4 m AO texture should fit in that headroom; a full GI system
starts at the size of the whole budget.

## Research scope

Primary sources reviewed: cascaded/parallel-split shadow maps,[1] GTAO/HBAO,[2][3] SH9
irradiance,[4] DDGI,[5] voxel cone tracing,[6] the EA/SIGGRAPH GI survey,[7] radiance cascades,[8]
and practical SSGI notes.[9] A 2026 comparison of GI architectures recommends SSGI for
resource-constrained/small projects, voxel GI for linear medium-sized experiences, and DDGI/GIBS
for AAA open worlds;[10] that ranking is useful context, not a substitute for our constraints.

Our constraints differ from a typical AAA target in four ways:

- **OpenGL 4.6**, so no DXR/Vulkan ray-tracing acceleration structure. DDGI and path-traced GI
  would need a CPU/heightfield ray marcher or a rasterized probe pipeline.
- **4K at 60 fps**, with about 6.4 ms of headroom, not a 1080p console frame.
- **No TAA and no MSAA.** Temporal denoisers and jittered SSGI accumulation are not available;
  screen-space noise has to be removed spatially.
- **Procedural, streaming terrain.** Lightmaps, precomputed radiance transfer and static probe
  bakes do not fit the world.

## Options and measured/reported cost

| Technique | Evidence | Fit here | Verdict |
|---|---|---|---|
| Correct sun + SH9 sky ambient | 9 SH coefficients approximate diffuse irradiance to ~1 % average error[4] | Negligible; fixes a real bug | **Do first** |
| Cascaded/parallel-split shadow maps + PCF/PCSS | GPU Gems 3 split scheme;[1] the same engine's block renderer measured a 2048 map at **0.33-0.38 ms** and PCSS improved 2.4 % of pixels at a 14° sun | Terrain, trees and rocks cast; grass optional | **Do first** |
| HBAO/GTAO | HBAO horizon integration;[3] GTAO reports **0.5 ms on a PS4 at 1080p** with spatio-temporal filtering[2] | Needs a depth/normal prepass; no TAA means spatial-only blur; good contact detail | **Do after shadows** |
| Heightfield horizon AO | Our probe: 4 m grid, 16 directions, 32 m radius = **2.12 ms**; 8 directions = **1.05 ms**; 2 m = 7.26 ms; 1 m = 53.97 ms | Terrain-only, camera-independent, no screen-space noise; ignores trees/props | **Do first for terrain; 4 m grid** |
| GGX/PBR specular | Block renderer ADR 0011; resolve 0.012-0.014 ms; no textures needed | Wet mud, snow, water read better; mostly a shader change | Second stage |
| SSGI | A screen-space pass, so cost scales with pixels, but it needs temporal or spatial denoise and misses off-screen geometry;[7][9] | No TAA; low-frequency colour bleed only | **Spike later, not first** |
| DDGI | **6 ms/frame at 1920x1080 on an RTX 2080 Ti** in the paper's scene;[5] requires ray tracing or a custom probe renderer | Needs a probe grid and ray hits; 4K multiplies final shading | Not first |
| Voxel cone tracing | **25-70 FPS on a GTX 480** at 2011 resolutions; **1024x768 11.4 FPS** with 3 diffuse + 1 specular cone; ~1 GB[6] | Voxelization/octree + memory; modern GPU helps, but 4K/60 and streaming make it a project | Not first |
| Radiance cascades | Path of Exile 2 uses screenspace RC at **~3 ms on a GTX 1050**; a 3D world-space SDF demo is **30-50 ms on an RTX 3060**[8] | Noiseless, but the practical version is screenspace/flatland; 3D is still expensive | Research later |
| Hardware path tracing / RT GI | Requires Vulkan/DXR, not OpenGL 4.6 | Would replace the renderer backend | Out of scope |
| Baked GI / lightmaps / PRT | Static geometry and UVs; procedural streaming world has neither | No | No |

The heightfield AO probe was a throwaway `probe_ao.zig` in the repo root, not committed: it samples
`heightAt` on a grid, casts 8/16 horizon rays per cell over 32/64 m, and integrates
`AO = 1 - average(sin(horizon))`. Interior statistics at 4 m/16/32: mean **0.884**, min **0.671**,
9.2 % of cells below 0.8, 0 % below 0.5. At 4 m/8/32: mean **0.884**, min **0.671**, 9.6 % below
0.8, **1.05 ms**. At 2 m/8/32: mean 0.872, **7.26 ms**; 1 m/8/32: mean 0.866, **53.97 ms**.
The 4 m grid is 64x64 for the 256 m patch and is low-frequency by design; it is cheap enough to
bake on patch rebuild. A line-sweep implementation (Barrett's horizon sweep) should be faster than
this per-cell ray marcher, but the 4 m result already fits.

## Decision

**Do not add global illumination first.** The current frame is missing direct-sun correctness,
shadows and ambient occlusion. Those are the cues a viewer reads as "lit"; GI adds low-frequency
colour bleed on top. Adding GI now would spend the budget on the least visible term while the sun
still does not move the ground.

The accepted first stage is:

1. **11.2 Sun-correct lighting + SH9 sky ambient.** Replace the hardcoded `l` with
   `u_sun_dir`, multiply by `u_sun_colour`, and replace the constant hemisphere with nine sky
   coefficients evaluated per fragment (or per vertex). Apply the same `Sun.lighting()` values to
   terrain, grass, trees and rocks so the time of day cannot disagree between them.
2. **11.3 Cascaded sun shadows.** Two or three 2048 cascades fitted to the camera frustum, texel
   snapping, PCF/PCSS, terrain + trees + rocks as casters. Target under 1.5 ms; A/B at a low sun
   and at noon.
3. **11.4 Heightfield horizon AO.** Bake a 4 m/16-direction AO texture (2.12 ms per patch) and
   sample it in the terrain shader; multiply ambient fully and direct light partly. Target under
   2.5 ms added to the patch rebuild; no TAA needed.
4. **Second stage:** GGX specular for wet mud, snow and water; optional cloud shadows.
5. **Later GI spike:** a half-resolution SSGI pass with a spatial denoise, only after the first
   stage. If it flickers without TAA or fails to beat the AO/shadow stack, drop it. DDGI, VCT and
   radiance cascades are not justified before that experiment; the 4K/60 budget and OpenGL 4.6
   make them multi-week features with a high risk of not shipping.

This ordering also gives a clean A/B narrative: each step is a separate uniform/feature with a
measurable screenshot and a frame-time line, and the expensive GI option is compared against a
world that already has correct sun, shadows and AO.

## Limitations and risks

- A shadow map fitted to the DC patch must handle the 256 m world and the far view; 2-3 cascades
  are likely, and grass as a caster may not be worth the vertex cost. Terrain/trees/rocks first.
- The 4 m AO texture cannot resolve a tree root or a 1 m rock; those need the shadow map or a
  later contact-AO pass. It is a terrain-scale term, not a replacement for SSAO.
- The AO bake adds 2.12 ms to the existing 7-10 ms scatter rebuild on a patch swap. If the hitch
  is visible, compute it in slices or on a worker; do not hide it in the frame average.
- SH9 is an approximation of the sky, not a replacement for the sun; the sun stays a directional
  light. The ambient must be projected from the same procedural sky the sky pass draws, or the
  horizon and the lit faces will disagree.
- No TAA/MSAA remains a hard constraint: PCSS/PCF is fine, SSGI is not automatically fine.

## Follow-up tasks

- **11.2** Sun-correct lighting and SH9 sky ambient (#85)
- **11.3** Cascaded sun shadows (#86)
- **11.4** Heightfield horizon AO (#87)
- **11.5** SSGI half-resolution spike, decision gate (#88)

## Sources

1. F. Zhang, H. Sun, O. Nyman, "Parallel-Split Shadow Maps on Programmable GPUs", GPU Gems 3,
   chapter 10. https://developer.nvidia.com/gpugems/gpugems3/part-ii-light-and-shadows/chapter-10-parallel-split-shadow-maps-programmable-gpus
2. J. Jimenez, X.-C. Wu, A. Pesce, A. Jarabo, "Practical Realtime Strategies for Accurate Indirect
   Occlusion", Activision technical memo ATVI-TR-16-01, 2016.
   https://www.activision.com/cdn/research/PracticalRealtimeStrategiesTRfinal.pdf
3. L. Bavoil, M. Sainz, R. Dimitrov, "Image-Space Horizon-Based Ambient Occlusion", SIGGRAPH 2008.
   https://developer.download.nvidia.com/SDK/10.5/direct3d/Source/ScreenSpaceAO/doc/ScreenSpaceAO.pdf
4. R. Ramamoorthi, P. Hanrahan, "An Efficient Representation for Irradiance Environment Maps",
   SIGGRAPH 2001. https://graphics.stanford.edu/papers/envmap
5. Z. Majercik, J.-P. Guertin, D. Nowrouzezahrai, M. McGuire, "Dynamic Diffuse Global Illumination
   with Ray-Traced Irradiance Fields", JCGT 8(2), 2019. https://jcgt.org/published/0008/02/01/
6. C. Crassin, F. Neyret, M. Sainz, S. Green, E. Eisemann, "Interactive Indirect Illumination Using
   Voxel Cone Tracing", Pacific Graphics 2011.
   https://gigavoxels.inria.fr/Publications/2011/CNSGE11b/GIVoxels-pg2011-authors.pdf
7. C. Barré-Brisebois, "A Certain Slant of Light: Past, Present and Future Challenges of Global
   Illumination in Games", SIGGRAPH 2017.
   https://colinbarrebrisebois.com/wp-content/uploads/2022/06/siggraph2017-acertainslantoflight.pdf
8. A. Sannikov, "Radiance Cascades: A Novel Approach to Calculating Global Illumination" (WIP).
   https://github.com/Raikiri/RadianceCascadesPaper
9. Three.js, "SSGINode" documentation (temporal filtering requires TAA; without it a manual
   denoise is required). https://threejs.org/docs/pages/SSGINode.html
10. H. Planell Moreno, "Architectural trade-offs in real-time global illumination: a guide for
    independent and AA 3D game engines", UPC, 2026.
    https://upcommons.upc.edu/entities/publication/cda6cba5-61ed-416e-99fa-21b2624be14a/full
