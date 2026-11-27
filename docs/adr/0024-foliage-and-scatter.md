# 0024 — Foliage and terrain detail: survey and plan

- Status: proposed (research for 10.1/10.2; no implementation yet)
- Date: 2026-11-27

## Context

The DC world is bare geometry with procedural materials: grass-free hills, no trees, no rocks or
flowers. The mesh is a 64-chunk, 256 m patch (1 m height field, edit spheres) drawn in one pass at
3840x2103, capped at 60 fps (worst frame ~17 ms, sky ~7 ms). Rendering is OpenGL 4.6 core with no
mesh shaders and no TAA or MSAA; the terrain shader already carries analytic noise detail (ADR
0019). The save format stores player, sun and edit spheres, so foliage must be a pure function of
the world and must disappear where a sphere edit removes the surface.

This ADR surveys how modern games and engines render foliage, decides what this engine should do,
and splits the implementation.

## What modern engines do

### Ground cover (grass, ferns, flowers)

**Ghost of Tsushima (Sucker Punch, GDC 2021)** is the reference implementation. The world is cut
into tiles carrying height, material, grass-type and grass-height textures; a compute shader runs
one lane per candidate blade, jitters the position, distance/frustum/occlusion-culls, samples type
and height, and appends survivors to an instance buffer; a second one-thread dispatch writes the
indirect draw arguments. A scene considers **>1 M candidate blades, draws ~83,000, and costs
~2.5 ms end to end**. Blades are Bezier curves generated entirely in the vertex shader from
`gl_VertexID`/`gl_InstanceID` (15 verts high LOD, 7 low); there are no vertex streams. Clumps come
from a procedural Voronoi (nearest of nine jittered points) and drive height, facing and pull
toward the clump centre, because uniform randomness looked like a golf course. Grass casts shadows
through a terrain impostor (raise the terrain to grass height, dither the depth) rather than
running the blade pipeline per light. Far grass is replaced by an artist-authored terrain texture
instead of blades.
Sources: <https://gerigory.github.io/GDC2021-Procedural-Grass-in-Ghost-of-Tsushima/>,
<https://www.youtube.com/watch?v=Ibe1JBF5i5Y>

**Jahrmann & Wimmer, "Responsive Real-Time Grass Rendering" (I3D 2017)** draws every blade as a
tessellated object and culls per blade on orientation (edge-on blades project to sub-pixel slivers
and alias), frustum, distance (a hash keeps a stable subset as distance grows) and occlusion
against a depth buffer, then draws through an indirect call. It is implemented in **OpenGL 4.5**,
which matters here: the same API family we use.
Source: <https://www.cg.tuwien.ac.at/research/publications/2017/JAHRMANN-2017-RRTG/JAHRMANN-2017-RRTG-draft.pdf>

**Helio (2026)** is the modern GPU-driven version: 8 m tiles in a camera ring, placement as a pure
function of `(tile, lane, generation, seed)` enforced bit-identical in CI, Hi-Z cluster culling,
four LODs (11-vert blade, 7-vert blade, card, clump card) and past 120 m a **terrain material
perturbation with no geometry**. Budget at 1080p: 1 M blades under 3 ms total (placement 0.20,
cull 0.15, raster 2.1). It also documents the anti-pop stack: feathered distance cull, stochastic
cross-fade keyed on a stable seed, wind evaluated at `t` and `t-dt` for motion vectors.
Source: <https://pulsarnative.com/blog/2026-08-02-helio-foliage-system>

**A WebGPU port of the GoT pipeline** considers 8.8 M candidates on a 2976² grid, culls to one
indirect draw, and feathers every distance cutoff (±14 % band by blade hash) so the field thins
into stragglers instead of ending at a ring. Past ~200 m it shades the terrain with a "far grass
carpet". Its lesson list is blunt: do per-blade work once in compute, the vertex shader should be
a dumb reader; feather every cull; share noise fields between systems.
Source: <https://threenames.dev/posts/grasslands>

**Outerra's OpenGL draw-call benchmark** answers the low-level question we actually face: for
procedural blades built from `gl_VertexID`, **indexed triangle lists beat triangle strips and
geometry shaders**, and small meshes in many instanced draws lose throughput. Group instances so
the effective mesh per draw is roughly **1k-20k triangles** (5k is a safe cross-vendor target);
geometry-shader expansion is consistently below instanced vertex-shader rendering.
Source: <https://outerra.blogspot.com/2016/01/procedural-rendering-performance-test-1.html>

### Placement

**Horizon Zero Dawn (Guerrilla, GDC 2017)** converts world maps into per-type density maps through
a rule graph, then a **fixed dithering pattern** turns density into exact points. The stated goals
are the ones we need: data-driven, **deterministic** (same data, same forest) and **locally
stable** (an edit changes only its neighbourhood). Trees have a footprint, and layers that share a
footprint use the same pattern so they cannot intersect. The whole chain runs on the GPU around
the player.
Sources: <https://academy.lerpworks.com/en/learn/horizon-placement/>,
<https://gdcvault.com/play/1024700/GPU-Based-Run-Time-Procedural>

Modern engines expose the same idea as masks: slope, altitude, curvature, flow and occlusion are
multiplied into a density, with smooth remaps so biomes fade instead of cutting. Houdini/UE PCG
workflows use jittered grid or Poisson-disk points, relax iterations against clumping, and give
each species its own scatter and spacing.
Sources: <https://www.bsm3d.com/articles/houdini-heightfield-terrains.html>,
<https://dev.epicgames.com/documentation/en-us/unreal-engine/foliage-mode-in-unreal-engine?application_version=5.8>

### Trees and large vegetation

- **LOD chain first:** full mesh with leaf cards up close, reduced trunk and composite cards in the
  midground, and an **impostor** far away. Every step roughly halves cost and must cross-fade
  without popping. <https://www.numivo.org/blog/dense-forest-lods-impostors>
- **Octahedral impostors** bake the tree from a hemisphere grid into one atlas (8/16/32 cells per
  side, 4096 px), then draw a camera-facing quad and blend the three nearest atlas cells. Measured
  demo: **10,957 trees = 22,692 triangles and 3 draw calls**, versus 8.5 M triangles as meshes.
  This is now the standard far LOD; Microsoft Flight Simulator's forests are essentially this.
  Sources: <https://andersonmancini.dev/blog/octahedral-impostors>,
  <https://app.cinevva.com/blog/2026-05-11-foliage-overdraw>
- **Nanite Foliage (UE 5.7+, experimental)** removes authored LODs via Nanite Voxels/Assemblies/
  Skinning. It is engine-specific virtual geometry; there is no OpenGL 4.6 equivalent, and even in
  UE the older guidance is that Nanite is a poor fit for dense masked foliage because overdraw
  dominates. <https://www.unrealengine.com/en-US/news/unreal-engine-5-7-is-now-available>,
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/working-with-naniteenabled-content>
- **Shading and motion:** two-sided foliage with a translucency/back-scatter term, vertex wind with
  three levels (whole-asset bend, branch sway, leaf flutter) driven by vertex colours that encode
  rigidity and branch distance; Horizon stores these in the mesh and animates in the shader.
  Source: <https://www.youtube.com/watch?v=wavnKZNSYqU>

### Alpha, overdraw and fading

Foliage overdraw is the dominant cost: masked quads defeat early-Z because the shader must run
before `discard`, so a pixel can shade 10-15 leaf layers. The modern stack is: a **depth prepass**
for masked geometry, front-to-back instance sorting, LODs/impostors, cluster culling, and keeping
everything in the **masked** path rather than blended. Reported result: effective overdraw from
8-15x down to 1-2x. Dithered LOD fades and alpha-to-coverage are the usual transition tools, but
**both need a temporal or multisample resolve** (TAA or MSAA). Hashed alpha needs TAA; alpha to
coverage needs MSAA.
Sources: <https://app.cinevva.com/blog/2026-05-11-foliage-overdraw>,
<https://dev.epicgames.com/community/learning/tutorials/oLqa/unreal-engine-smooth-apparition-of-instances-with-dithering>,
<https://craftpbr.com/guides/dithered-transparency>

## Constraints this engine imposes

| Constraint | Consequence |
|---|---|
| OpenGL 4.6 core, no mesh shaders | Instancing and compute+indirect are available; Nanite/meshlet pipelines are not |
| No TAA and no MSAA in `voxel-zig` | Dithered/stochastic fades would be visible noise; alpha-to-coverage is a no-op. Use hard alpha test with coverage mips, or opaque geometry |
| 3840x2103 at 60 fps, worst ~17 ms | Foliage budget is small (target <=1.5 ms added). Fill/overdraw, not vertex count, is the risk |
| One 256 m patch streamed in 64 chunks | Scatter must be chunk-local and rebuild with the patch; no world-wide instance buffer |
| Save format stores sphere edits | Foliage must vanish where an edit removes the surface. A per-chunk generation counter is the invalidation key |
| No texture arrays after ADR 0022 | Tree leaf cards need a small 2D atlas (or procedural cards); grass should not use textures at all |
| Existing analytic material shader | Far ground cover can be a terrain shading term, matching Helio/GoT's far impostor |

## Decision

Build **one generic scatter system** first, then two consumers (ground cover and trees), rather
than a bespoke grass renderer.

### 1. Scatter (10.3)

- Chunk-local (32 m) instance lists built on the CPU when a patch chunk is meshed. Each candidate
  is a pure function of `(world x, world z, type, seed, generation)`: jittered stratified grid,
  hash-based rejection, density from slope/height/noise and distance to water, plus a footprint
  radius for spacing between trees. Rebuilding a chunk must reproduce byte-identical instances.
- `generation` is bumped by sphere edits that touch the chunk; that chunk's instances are rebuilt,
  so a dug hole removes its grass.
- One `glDrawElementsInstanced` per type, with the shared geometry in a VBO/EBO and per-instance
  data in a second VBO (position, facing, scale, type/seed). No per-instance draw calls.
- Start CPU-side. Compute placement + `glDrawElementsIndirect` is the proven next step if instance
  counts make the CPU build or draw submission the bottleneck; GL 4.6 supports it, but at 64
  chunks and tens of thousands of instances the complexity is not yet justified.

### 2. Ground cover (10.4)

- **Procedural blades, not cards.** One blade = 7 vertices / 5 triangles (a two-segment strip),
  positions generated in the vertex shader from `gl_VertexID` and the instance data, following
  GoT/Jahrmann. No alpha, no sorting, no overdraw beyond real geometry.
- Clumps via a Voronoi hash at ~2-4 m scale: shared facing, height multiplier and centre pull.
  This is what keeps the field from looking like a lawn.
- Wind in the vertex shader: a 2D scrolling Perlin/noise sample at the blade base, a sine sway
  whose phase includes a per-blade hash and the distance along the blade. Wind is evaluated in
  world space so neighbouring blades agree.
- Distance: full density to ~25 m, hash-thinned to zero by ~70 m (no TAA, so no stochastic
  cross-fade); past that the terrain shader's noise/colour carries the field. Target 20,000-40,000
  blades in the patch initially, measured against the 1.5 ms budget.
- Shading: two-sided, wrap diffuse plus a small back-scatter term, distance-faded specular and
  normals tilted outward (GoT's tricks), then the existing fog. No shadow pass in the first cut.

### 3. Trees and large vegetation (10.5-10.6)

- Low-poly authored/procedural trees (500-2,000 triangles) with 3 mesh LODs, instanced per type.
- Placement on gentle slopes below the treeline with a footprint radius (Poisson-like rejection
  from the same scatter), clustered by a low-frequency noise mask.
- Beyond ~120-150 m switch to an **octahedral impostor** baked at startup from the LOD0 mesh into a
  small atlas (8x8 cells, 1024-2048 px). A quad per tree, view-direction octahedral lookup with
  three-cell barycentric blending. If the bake is too much for 10.5, ship mesh LODs first and add
  impostors in 10.6.
- Leaf cards use hard alpha test (cutoff 0.5) with **alpha-coverage mips** so distant crowns do
  not dissolve; no blended foliage. A depth prepass is only worth it if measurement shows the
  overdraw; with a few hundred trees at 4K it may not be.
- Wind: per-vertex rigidity in the vertex colour (base 0, branch 0.5, leaf 1) driving a bend that
  grows with height, plus a small leaf flutter. Trunk stays rigid.

### 4. Terrain detail props (10.7)

Rocks, scree and flowers use the same scatter with a footprint and no LOD chain beyond a low-poly
mesh; flowers can reuse the grass blade shader with a different instance type. This is where the
"terrain more interesting" goal is cheapest per triangle: a few hundred rocks and flower clusters
change the silhouette more than doubling grass density.

## Rejected options

- **UE5 Nanite / Nanite Foliage**: engine-specific virtual geometry; no GL 4.6 path.
- **Mesh shaders / meshlets**: not available in OpenGL 4.6.
- **Per-blade CPU simulation**: GoT and Jahrmann run placement/culling on the GPU for a reason;
  our counts are low enough that CPU scatter is fine, but per-blade CPU physics every frame is not.
- **Alpha-blended grass/trees**: sorting and overdraw, and the app has no TAA to hide dithering.
- **Dithered LOD cross-fade**: needs TAA; without it the checkerboard is visible.
- **Geometry-shader blade expansion**: measured slower than instanced vertex-shader rendering.
- **Grass cards**: GoT rejected them for wind flexibility and overdraw; same constraints here.

## Follow-up tasks

- **10.3 Scatter foundation** — deterministic chunk-local instances, one instanced draw, counts in
  the HUD, rebuild on patch swap and edit; measure instance build time.
- **10.4 Ground cover** — procedural 7-vertex blades, Voronoi clumps, wind, distance thinning, far
  terrain shading; measure added frame cost at 4K.
- **10.5 Trees** — low-poly mesh + 3 LODs, placement masks/footprint, instanced draws, wind and
  masked leaf cards with coverage mips.
- **10.6 Tree impostors** — offline/startup octahedral bake, atlas sampling, LOD switch and fade.
- **10.7 Detail props** — rocks/scree/flowers through the same scatter.

## Risks

- **Fill rate at 4K.** Grass overdraw can eat the frame even with few triangles. Keep blades
  opaque and thin, cap density by distance, and measure with a GPU timer before raising counts.
- **No TAA/MSAA.** Any transparency trick that relies on dithering will look like noise. Stay on
  hard alpha test and geometry.
- **Determinism.** Float hash and instance order must be stable; a seed that changes per frame
  turns thinning into shimmer. Use integer inputs and a fixed iteration order.
- **Edits.** Forgetting the generation bump leaves grass floating over a dug hole; the chunk
  rebuild must be part of the edit path, not an afterthought.
- **Streaming.** Building all instances on the frame that swaps the patch would hitch; spread the
  build over the same 16-frame swap as the mesh, or budget it.

## Sources

- GDC 2021, *Procedural Grass in Ghost of Tsushima* (Eric Wohllaib) — talk transcript/summary:
  <https://gerigory.github.io/GDC2021-Procedural-Grass-in-Ghost-of-Tsushima/>; video:
  <https://www.youtube.com/watch?v=Ibe1JBF5i5Y>
- Jahrmann & Wimmer, *Responsive Real-Time Grass Rendering for General 3D Scenes*, I3D 2017:
  <https://www.cg.tuwien.ac.at/research/publications/2017/JAHRMANN-2017-RRTG/JAHRMANN-2017-RRTG-draft.pdf>
- Helio GPU-driven foliage (2026): <https://pulsarnative.com/blog/2026-08-02-helio-foliage-system>
- *Grasslands* WebGPU port (2026): <https://threenames.dev/posts/grasslands>
- Outerra, *Procedural grass* OpenGL draw-call benchmark:
  <https://outerra.blogspot.com/2016/01/procedural-rendering-performance-test-1.html>
- Horizon Zero Dawn placement (GDC 2017):
  <https://academy.lerpworks.com/en/learn/horizon-placement/>,
  <https://gdcvault.com/play/1024700/GPU-Based-Run-Time-Procedural>
- Horizon Zero Dawn vegetation talk (GDC 2018): <https://www.youtube.com/watch?v=wavnKZNSYqU>
- Octahedral impostors: <https://andersonmancini.dev/blog/octahedral-impostors>,
  <https://app.cinevva.com/blog/2026-05-11-foliage-overdraw>
- Unreal Engine Foliage Mode (instancing, cull distance, PerInstanceFade):
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/foliage-mode-in-unreal-engine?application_version=5.8>
- UE dithering/fade tutorial:
  <https://dev.epicgames.com/community/learning/tutorials/oLqa/unreal-engine-smooth-apparition-of-instances-with-dithering>
- UE5.7 Nanite Foliage: <https://www.unrealengine.com/en-US/news/unreal-engine-5-7-is-now-available>
- Foliage overdraw survey: <https://app.cinevva.com/blog/2026-05-11-foliage-overdraw>
- Houdini heightfield biomes/masks:
  <https://www.bsm3d.com/articles/houdini-heightfield-terrains.html>
