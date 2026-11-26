# 0017 - Physics engines for Zig: what exists, and what to use for water

- Status: proposed (research)
- Date: 2026-11-26
- Decides for: 7.1 (physics and fluid research)
- Depends on: 2.3 (the hand-written box physics), 5.6 (animated water)

## Question

Is there an open-source physics engine in Zig worth integrating - like Bullet - and does
it support fluids well enough to simulate the water?

## What exists (checked 2026-11-26)

| Project | What it is | Stars | Fluids |
|---|---|---|---|
| **zphysics** | Zig build package + bindings over the JoltC C API. Jolt is C++ and shipping in Horizon Forbidden West and Death Stranding 2 | ~89 | **No** |
| **zbullet** | Zig bindings for Bullet 3.25 via `cbullet`, a C API written inside zig-gamedev | ~19 | Not exposed |
| **zjolt** | Vendored Jolt with a plain C ABI, host allocator injection, ABI drift guarded by tests | ~2 | No |
| **zphys** | Pure-Zig 3D physics engine | ~27 | No |
| **zigity-gravity** | Data-oriented physics for Zig 0.16: spheres, AABB, capsules, grid broadphase, zero-copy | - | No |

Two conclusions from that table:

1. **No Zig-native engine supports fluids.** Every one of them is rigid-body only.
2. **Jolt has no fluid simulation and is not getting it soon.** The maintainer, asked
   directly: "Fluids are not currently supported", and on the roadmap "fluid sim is
   pretty low on the list" because doing it at scale needs GPU acceleration, which Jolt
   lacks. Jolt does ship *water buoyancy* calculations, which is force on a body in
   water, not a water surface.

Bullet is the only one with anything fluid-like: an SPH implementation (a Fluids v.2 port,
`btFluidSph`) lives in its extras/a fork, is explicitly experimental, and has no stable
release. Its author's own summary: single-threaded but ~3.5x faster than the original,
rigid-body interaction "more or less final" but "still experimental", and mesh collision
tunnels because the interaction is discrete.

## The mismatch nobody's README mentions

Our water is a **voxel surface**: one flat quad per water block on a 32-block grid, with
displacement and a reflective shader. SPH is a particle method - thousands of particles
per pond to resolve a surface, a smoothing radius, a neighbour grid, and an iso-surface
pass (marching cubes) to turn particles back into something drawable. It would replace a
surface we already render cheaply with a particle system we would then have to rasterise
back into the same shape, at a cost of milliseconds per frame.

For a voxel world the natural fluid models are:

- **Cellular flow** (the Minecraft model): per-block level 0..7, spread to lower
  neighbours each tick, no particle maths. Cheap, blocky by construction, matches the art.
- **Height field / shallow water**: a height per column, solved on the GPU, gives real
  wave propagation (what GPU Gems ch. 1 is doing for the surface) - good for an ocean,
  poor for water flowing around blocks.
- **SPH**: correct for splashes and pouring, but needs particles, neighbour search and a
  surface reconstruction, and looks wrong at 1 m block scale unless the particle count is
  high.

## Recommendation

1. **Do not integrate a physics engine for the water.** Use a voxel flow model (cellular
   levels) for behaviour, and the existing displaced surface for the look. That is a
   task in our own codebase, not a dependency.
2. **If rigid-body physics becomes a requirement** (thrown blocks that stack, vehicles,
   characters), use **zphysics/Jolt** rather than Bullet: Jolt is the better engine today,
   the bindings are maintained inside zig-gamedev, and its determinism and CCD story is
   stronger. Keep the hand-written box simulation for the toy bodies in 2.3 - it is 200
   lines and already works.
3. **Budget for the Zig version wall.** zphysics and zbullet track zig-gamedev's
   supported Zig, which trails this project's 0.17.1. Mach already failed to build on
   0.17.1 (ADR 0007), so treat "does it compile on 0.17.1" as the first gate on any
   dependency, before any feature comparison.

## Open questions worth a spike later

- Does zphysics build against Zig 0.17.1 as-is? (Measure, do not assume - same lesson as
  ADR 0007.)
- What does a cellular flow tick cost on a 452-chunk load set? Only worth it if water
  behaviour (flowing into holes, filling basins) is actually wanted; today water is
  static level-62 sea.
