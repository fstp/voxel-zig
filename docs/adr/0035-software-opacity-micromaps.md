# 0035 — Software opacity micromaps: measured decision

- Status: research complete (2026-11-28)
- Date: 2026-11-28
- Task: Vikunja #94, "12.5 Software opacity micromaps for fine foliage detail"
- Related: ADR 0034 (massive foliage adaptation), ADR 0024 (foliage and scatter), ADR 0032
  (world-anchored scatter), ADR 0037 (dense clumped grass)
- Paper: van Antwerpen et al., "Real-time Path Tracing of Massive Dynamic Foliage", PACMCGIT 9(4),
  HPG 2026, section 6.2 (opacity micromaps) — <https://dl.acm.org/doi/10.1145/3820021>

## Context

The paper's opaque-micromap (OMM) path removes fine twig, needle and leaf geometry from ray
traversal and replaces it with a compact opacity mask that the hardware accelerator tests. This
renderer is an OpenGL 4.6 rasterizer: no OMM traversal, no CLAS, no PTAS, **no MSAA and no TAA**.
A mask here can only be a baked texture on a proxy card, tested with a hard alpha cutoff or the
existing Perlin dissolve; sorted blending and alpha-to-coverage are not available (ADR 0034).

12.5 is a decision gate: do masks on cards beat the geometry on *this* scene, and where? It is
not a commitment to ship. ADR 0034 also warned that our assets are stylised — a 5-cone conifer is
84 triangles and a grass blade is a 7-vertex strip — so the paper's trade-offs do not transfer
unmeasured.

## Method

Probe: `~/voxel-spikes/software-omm` (throwaway, outside the repo), ReleaseFast, RX 9070 XT,
1280x720, vsync off. It:

- builds two source assets procedurally: a **grass clump of 200 seven-vertex blades (1,000 tris,
  1,400 verts, 0.84 x 0.56 m)** and the engine's **conifer LOD0 (84 tris, 89 verts, 3.90 x
  6.57 m)**;
- bakes each into an RGBA8 atlas through an orthographic FBO pass, **one view, shared by every
  instance and every plane** (the task's "share the mask across instances and LODs");
- draws a 5x5 grid of instances three ways — full geometry, and cards in three proxy forms: a
  single world-anchored plane (2 tris), a camera-facing billboard (2 tris) and a 3-plane cross at
  60 degrees (6 tris), all with a hard alpha test at 0.5 and LINEAR filtering;
- writes frames for a pixel diff (`PIL`, per-pixel absolute difference: mean and percent of
  pixels differing by more than 8 levels), times the draw with `GL_TIME_ELAPSED` plus a
  `glFinish`/readback drain over 30 frames of 5,041 instances, and records a 24-frame pan
  (0.25 deg/frame at 15 m) for temporal stability.

The geometry path and the bake share one fragment shader, so a baked texel is byte-identical to
the geometry render where the mask is solid; cards then draw unlit, exactly like the engine's
fixed-sun impostor atlas. Differences in the diff are therefore silhouette, parallax and cutoff,
not shading.

## Numbers

### Geometry replaced, and mask memory

| Asset | Source | 3-plane card | Reduction | Atlas | R8 mask | RGBA8 albedo+mask |
|---|---|---:|---:|---|---:|---:|
| Grass clump | 1,000 tris | 6 tris | **167x** | 256x256 | 65,536 B | 262,144 B |
| Conifer LOD0 | 84 tris | 6 tris | **14x** | 512x512 | 262,144 B | 1,048,576 B |

Both clear the acceptance line of 3x. Mask memory is **per asset, not per instance**: the same
texture serves all 5,041 instances and all three planes.

### Does a card hold the silhouette?

Coverage = non-background pixels as a fraction of the geometry render's, yaw 0:

| Distance | Grass cross | Grass plane | Grass billboard | Tree cross | Tree plane | Tree billboard |
|---|---:|---:|---:|---:|---:|---:|
| 2 m | 0.79 | 0.26 | 0.24 | 0.71 | 0.23 | 0.28 |
| 4 m | 0.85 | 0.39 | 0.43 | 0.94 | 0.28 | 0.26 |
| 8 m | 0.87 | 0.49 | 0.67 | 0.83 | 0.39 | 0.23 |
| 15 m | 0.90 | 0.55 | 0.68 | 0.88 | 0.38 | 0.30 |
| 30 m | 0.90 | 0.56 | 0.57 | 0.98 | 0.39 | 0.52 |
| 60 m | 0.95 | 0.65 | 0.59 | 1.04 | 0.45 | 0.56 |

Over eight yaws at 15 m (min / mean): grass plane 0.46 / 0.55, cross 0.90 / 0.93, billboard
0.19 / 0.45; tree plane 0.14 / 0.34, cross 0.65 / 0.85, billboard 0.15 / 0.30.

**The 3-plane cross is the only proxy that keeps coverage at every angle.** A single world plane
collapses edge-on (loses 45-86 % of the footprint), and a billboard loses the ground contact and
the parallax that makes a clump read as volume.

### How much does the frame change?

Full-frame difference against the geometry render (mean levels / percent of pixels over 8):

| Distance | Grass plane | Grass cross | Grass billboard | Tree plane | Tree cross | Tree billboard |
|---|---|---|---|---|---|---|
| 2 m | 24.0 / 43.4 % | **21.0 / 42.9 %** | 24.5 / 43.7 % | 32.0 / 53.1 % | **23.9 / 47.2 %** | 31.5 / 53.0 % |
| 4 m | 9.9 / 18.3 % | **8.2 / 17.4 %** | 9.8 / 18.4 % | 42.2 / 70.4 % | **10.2 / 33.1 %** | 43.1 / 71.8 % |
| 15 m | 0.27 / 0.52 % | **0.23 / 0.49 %** | 0.26 / 0.49 % | 20.6 / 32.5 % | **8.3 / 20.0 %** | 22.4 / 33.3 % |
| 60 m | 0.011 / 0.02 % | **0.009 / 0.02 %** | 0.012 / 0.02 % | 0.51 / 0.80 % | **0.21 / 0.52 %** | 0.40 / 0.60 % |

At 15 m the **grass** card changes **0.49 %** of the frame by more than 8 levels — below the noise
of a moving scene (the 20.1 rasterizer A/B and the 4.66 snow A/B in ADR 0025 both changed more).
At 4 m it changes 17 % and the clump visibly flattens into three fan-shaped sheets; at 2 m nearly
every pixel differs.

The **tree** card never reaches that point: 20 % of the frame at 15 m, 33 % at 4 m, with triple
trunks (the baked mask carries bark, so each of the three planes draws its own trunk) and flat
shards where the planes intersect. It is recognisably a conifer and recognisably the wrong one.

### Draw cost (5,041 instances)

| Asset | Geometry | 3-plane cross | Speed-up |
|---|---|---|---|
| Grass | 0.397 ms (5,041,000 tris) | **0.037 ms (30,246 tris)** | **10.7x** |
| Conifer | 0.119 ms (423,444 tris) | 0.099 ms (30,246 tris) | 1.2x |

The grass number passes the plausibility check (12.7 Gtri/s on a 9070 XT); the card is fill-bound,
not vertex-bound, so its advantage grows with blade density and shrinks with overdraw.

### Temporal stability without TAA

Per-pixel standard deviation across the 24-frame pan, over pixels lit in at least half the frames:

| Asset | Geometry | 3-plane cross |
|---|---|---|
| Grass | 5,626 px, mean std 27.69, p95 40.47 | 5,085 px, mean std **26.36**, p95 37.87 |
| Conifer | 416,139 px, mean std 5.35, p95 33.15 | 368,837 px, mean std **7.53**, p95 34.66 |

Cutout grass cards are **not worse** than the blade geometry (±5 %), because the blades are
already 1 px slivers with no MSAA. Tree cards are **41 % worse** in the mean, another symptom of
the single-view mask sliding over a round canopy.

## Decision

**Accept the mask as a mid-distance LOD for grass clumps; reject it for the conifer canopy.**

- **Grass clumps, 8 m and beyond:** a baked R8 mask on a 3-plane cross. 167x fewer triangles,
  10.7x cheaper draw, 65 KB of mask per clump asset, frame difference under 0.5 % of pixels by
  15 m, and no extra temporal instability. Inside ~8 m the clump stays per-blade geometry: at 4 m
  the card is visibly a stack of flat fans, and the engine's near grass is already cheap.
- **Conifers:** keep the 84-triangle mesh and the existing octahedral impostor atlas. The
  single-view 3-plane cross loses 12-35 % of the silhouette, triples the trunk and changes 20 % of
  the frame at 15 m. A per-view mask atlas with the trunk excluded is the only version worth
  testing, and that is the impostor mechanism the engine already ships.
- **Single plane and billboard are rejected** as the base proxy: coverage collapses at grazing
  angles and on the ground contact respectively. The cross earns its extra 4 triangles.
- **No hardware-OMM claims.** This is a texture mask tested with `discard`; nothing here is DXR
  traversal, CLAS reuse or an OMM accelerator.

## Consequences for the rest of phase 12

- **12.6 (partitioned instance streaming):** carry one mask texture per asset, not per instance;
  the partition holds instance records only. The near band (< 8 m) still needs the blade stream,
  so the product is a two-band system, not one card field.
- **12.7 (far-field stamps):** at 60 m a clump covers 251 px in this test and both paths are
  indistinguishable; the stamp can be the same mask, drawn as a single quad, since the cross
  matters only while the clump still has visible height.
- **Scene-scale estimate:** at `tree.sav` the app reports 2,599,194 blades. A 1.3 m clump lattice
  over the 256 m patch with the ADR 0037 acceptance range is roughly 29,000 clumps; at 6 tris per
  carded clump the whole far band is ~174,000 triangles against ~13,000,000 blade triangles
  today, and the 0.037 ms per 5,041 cards scales to ~0.21 ms for 29,000. This is an extrapolation
  from the measured per-card cost, not a scene measurement.
- **Do not spend the mask budget on trees.** At 84 triangles the canopy has no sub-triangle
  detail to encode; the mask can only reproduce a silhouette the mesh already draws.

## What would change the answer

- A per-view mask atlas (4-8 views, barycentric blend) with the trunk excluded, for trees.
- MSAA or TAA plus alpha-to-coverage, which would remove the 1-bit cutoff and allow soft cards.
- A mip-aware mask (coverage-preserving blends) if cards ever have to survive minification below
  one texel per blade, where a hard cutoff either disappears or pops.
- Real production geometry (the paper's use case): with 3,000-triangle twig clusters the mask wins
  by two orders of magnitude, not 14x.

## References

- Paper: <https://dl.acm.org/doi/10.1145/3820021> — section 6.2 for the OMM concept as adapted here.
- Probe source and frames: `~/voxel-spikes/software-omm` on burken (throwaway; not in the repo).
- Evidence: `docs/adr/img/0035-grass-4m.png` (geometry above, 3-plane card below, 4 m),
  `docs/adr/img/0035-tree-15m.png` (geometry above, card below, 15 m).

## Files

- `docs/adr/0035-software-opacity-micromaps.md`
- `docs/adr/img/0035-grass-4m.png`, `docs/adr/img/0035-tree-15m.png`
- Vikunja task 12.5 (#94)
