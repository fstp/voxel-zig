# 0034 Massive foliage: what to borrow from the HPG 2026 path-tracing paper

- Status: research complete (2026-11-27)
- Task: Vikunja #90, "12.1 Research: map the massive dynamic foliage paper onto this renderer"
- Related: ADR 0024 (foliage), ADR 0029 (shadows), ADR 0032 (world-anchored scatter), ADR 0037 (dense clumps)
- Paper: Dirk Gerrit van Antwerpen, Pascal Gautron, Edd Biddulph, Christoph Kubisch, Jan Schmid, Martin Stich,
  "Real-time Path Tracing of Massive Dynamic Foliage", PACMCGIT 9(4), HPG 2026.
  <https://dl.acm.org/doi/10.1145/3820021>

## Context

The paper is an end-to-end **hardware path tracer** for 60 million plants instanced from 230 models,
with 1,000+ bone plant skeletons, at 60 fps and 1440p upscaled to 2160p on an RTX 4090. It combines:

- per-plant wind simulated on skeletons (Section 4);
- instance merging along the skeleton with an animation-error bound (Section 5);
- reusable geometry clusters (CLAS) and opacity micromaps (OMM) for fine twigs and leaves (Section 6);
- memory-driven LOD selection (Section 7);
- far-field stamps into terrain and aggregate tree geometry (Section 8);
- a partitioned TLAS (PTLAS) that only rebuilds changed partitions (Section 9).

This engine is an **OpenGL 4.6 rasterizer** with a 256 m streaming patch, deterministic scatter, two
2048 shadow cascades, 4K/60 target, and no DXR/Vulkan ray tracing, no hardware OMM, no CLAS and no
PTLAS. It also has no TAA and no MSAA, so alpha-to-coverage and sorted blending are not available for
foliage cards. Pretending those APIs exist would produce a plan that cannot be implemented.

## Measured baseline

ReleaseFast, 3840x2103, shadows and AO on, `VOXEL_DC_SUN=0.30`:

| Pose | Blades | Trees | Rocks | Snow | Shore | Scatter rebuild | Frame |
|---|---:|---:|---:|---:|---:|---:|---|
| `tree.sav` (117, 64, 124) | **273,902** | 193 | 122 | 145 | 291 | **21.4 ms** | 60 fps capped, worst 22.3 ms |
| `peak.sav` (232, 74, 200) | **188,791** | 183 | 110 | 486 | 204 | **15.2 ms** | 60 fps capped, worst 16.77-17.04 ms |

The tree pose is already over one 16.67 ms frame in the worst-case measurement, so the phase has to
reduce per-frame work as well as add density; it cannot just scale the current scatter counts.

## Mapping

| Paper technique | This engine's equivalent | Decision |
|---|---|---|
| Per-plant skeleton wind (4) | Rigid part hierarchy on a tree/clump, per-instance phase derived from world position; no bone skinning | **Adapt** (12.3) |
| Instance merging + animation error (5) | Merge rigid parts into coarse LOD meshes; compute geometric + animation error and a cutoff screen size | **Adapt** (12.4) |
| CLAS geometry reuse across LODs (6) | One shared VBO/EBO per foliage part, merged LOD index lists, one instanced draw per asset/LOD | **Adapt** (12.2/12.4) |
| Opacity micromaps (6.2) | Baked R8 opacity masks on proxy cards; hard alpha test or Perlin dissolve because there is no MSAA/TAA; shared masks across LODs | **Adapt, decision gate** (12.5) |
| Memory-driven LOD selection (7) | Offline/startup LOD set with triangle/mask/instance memory and screen-space error; no per-LOD CLAS reuse | **Adapt** (12.4) |
| Far stamps + aggregate trees (8) | Stamp low vegetation into the terrain material mask; aggregate far trees into merged cells/billboards; animation cutoff | **Adapt** (12.7) |
| Partitioned TLAS (9) | CPU spatial partitions, persistent instance slots, dirty-partition updates and draw batching | **Adapt** (12.6) |
| Hardware path tracing, OMM traversal, CLAS, PTLAS, DLSS/denoiser | Requires DXR/Vulkan RT and new acceleration-structure APIs | **Reject for the GL renderer**; scope separately in 12.9 |
| 230 production models, 60 M plants, 5x5 km biotope | Our procedural stylised trees/grass and 256 m patch | **Out of scope** for this phase |

The important mapping is conceptual, not API-level: keep geometry shared, keep instances few,
make fine detail a mask, update only what changed, and stop animating what is too small to see.

## Target

Phase 12 must prove a **rasterized** version of the system, not a path tracer:

- **>= 1,000,000 visible grass blades** and **>= 1,000 visible tree instances** at 3840x2103.
- 60 fps capped, worst frame **<= 16.7 ms** after the first settled second at the tree and peak poses.
- Foliage LOD transition error **<= 1 px** at 4K; no visible popping in a camera move.
- Scatter/instance update work spread so no single patch swap causes a frame over the 16.7 ms budget;
  steady-state foliage update <= 2 ms on the test pose.
- Memory and draw-call counts reported before/after; no per-instance mesh duplication.

These are deliberately below the paper's 60 M plants and 3 M instances, which target an RTX 4090
path tracer at a different resolution and feature set. The comparison is the mechanism, not the
number.

## Consequences

- **No full path tracer in this phase.** The GL renderer cannot expose OMM/CLAS/PTLAS, and a
  software ray tracer would not reach the target. If the actual paper pipeline is wanted, it is a
  separate Vulkan/DXR backend (12.9), with its own denoiser and acceleration-structure streaming.
- **Alpha masks are cutout masks, not blended cards.** No TAA/MSAA means a hard cutoff or the
  existing stochastic dissolve; a soft alpha card will shimmer.
- **The current 21 ms scatter rebuild is a known cost.** 12.6 must make patch/instance updates
  incremental; otherwise the target is unattainable even if the GPU can draw the instances.
- **Stylised assets limit the result.** The paper's LOD/memory trade-offs assume dense production
  meshes; our low-poly trees and 7-vertex blades need different thresholds. Measure on our assets.
- **12.2-12.8 remain blocked until this ADR is accepted.** 12.9 is a gated stretch, not part of the
  milestone.

## References

- Paper: <https://dl.acm.org/doi/10.1145/3820021> (DOI 10.1145/3820021), HPG 2026 slides:
  <https://highperformancegraphics.org/2026/_assets/slides/Dietger_slides.pdf>
- OMM and DXR/PTLAS API background: Microsoft DirectX Raytracing functional spec and the
  CLAS/PTLAS preview notes; these are referenced only to justify the rejection in the GL path.
- Baseline logs: `tree.sav` and `peak.sav` runs recorded in the task comment; scatter counts from
  the app's own startup and streaming log.

## Files

- `docs/adr/0034-massive-foliage-adaptation.md`
- Vikunja tasks 12.1-12.9 (#90-#98)
