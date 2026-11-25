# PoC scope contract

Written before any game code exists, so that the project cannot sprawl. Every
implementation task must trace back to a requirement below; anything that does not
belongs to phase 2.

## The inspiration, and what is actually fun about it

BFS (stream #2, "How to create a volcano") is a **multiplayer voxel sandbox**:
a world generator with biomes (forest, desert, ashlands), hand-sculpted terrain,
characters you drop in, and "toys" - objects that carry **stickers** (behaviours):
a *live* sticker makes lava hurt anything that has one, a *fluid* sticker turns a toy
into water or lava, so a pile of buses becomes a lava source. You author a scenario,
press play, and mess around in it with friends.

That is the long-term target, and none of it except the world is in the PoC. What makes
it fun is *authoring and playing in a shared world*; what makes that possible is a
voxel world that streams, renders and edits fast enough to feel solid. The PoC is that
foundation.

## What the PoC is not

Out of scope, permanently or until after the milestone:

- multiplayer, networking, server authority
- physics props, stickers/behaviours, characters other than the player
- fluid simulation (water and lava are decoration at most)
- terrain sculpting brushes, undo
- biomes beyond one, caves, trees, structures
- LOD, greedy meshing, GPU meshing
- audio, menu UI, controller support
- Windows and macOS support (Linux/X11 is the only target)
- any modding or scripting layer

Those live in phase 2 of the Vikunja plan, except where the table at the end maps them.

## The contract

Numbers come from the measured ADRs; they are acceptance thresholds, not wishes.

| # | Requirement | Verifiable test |
|---|---|---|
| C1 | A seeded world of 32^3 chunks, heightmap terrain, 8..120 height, sea level 62 | same seed regenerates an identical chunk (hash of 1,000 voxels) |
| C2 | Chunk streaming at radius 6 (13x13x4 = 676 chunks) with load/unload | fly 30 m/s for 2 min, no frame over 25 ms, no hole under the player |
| C3 | 60 fps average at 1280x720 with vsync, frustum culling on | HUD average over 60 s while flying |
| C4 | Player: AABB 0.6 x 1.8, gravity, jump 1.25 blocks, walk 4.3 m/s, sprint 5.6 | walk a hill, jump a 1-block step, cannot clip a corner at sprint |
| C5 | DDA raycast up to 6 blocks, break and place any block, remesh on edit | dig a tunnel across a chunk boundary and rebuild it, no holes |
| C6 | At least 8 block types with distinct textures, correct faces | visual check: grass block reads as grass from every angle |
| C7 | World persists: seed, player position, modified chunks | dig a hole, quit, restart, hole is there |
| C8 | Debug HUD: fps, chunks loaded, queue depth, memory, triangles | toggles with F1, under 0.5 ms cost |
| C9 | Determinism: generation is a pure function of (seed, chunk) | unit test hashing voxels twice from the same inputs |
| C10 | Generation and meshing off the main thread, bounded in-flight (8) | HUD shows worker jobs; main-thread scheduling under 0.5 ms/frame |
| C11 | Memory under 300 MB RSS at radius 6 with typical terrain | measured with `/usr/bin/time -v` at the milestone |
| C12 | Stability | 10 min of flying and editing, no crash, RSS within 10 % of start |

Frame budget: 16.6 ms, of which meshing is 19 us and a chunk generation is 86 us
(ADR 0004, 0005), so neither is allowed to be the reason a frame drops.

## Definition of done

The milestone task (1.16) is done when every row above has a tick or a written
deferral, a 2-minute recording exists, and the repo is tagged `poc-v0.1`. A requirement
that fails is either fixed or moved to phase 2 with its reason recorded in the task -
silently dropping one is the failure mode this document exists to prevent.

## Traceability

| Task | Serves |
|---|---|
| 1.1 repo, window, main loop | C3 |
| 1.2 math module | C3, C4, C5 (foundation) |
| 1.3 camera, fly controls, frustum | C2, C3 |
| 1.4 block registry, textures, GL | C6 |
| 1.5 chunk and world model | C1, C12 |
| 1.6 naive mesher | C3, C6 |
| 1.7 render a chunk grid | C3, C6 |
| 1.8 terrain generation v1 | C1, C9 |
| 1.9 player controller and collision | C4 |
| 1.10 raycast, break and place | C5 |
| 1.11 chunk streaming, frustum culling | C2 |
| 1.12 ambient occlusion, face shading | C3 (visual quality) |
| 1.13 worker-thread generation and meshing | C10 |
| 1.14 save and load | C7 |
| 1.15 debug HUD and timers | C8 |
| 1.16 milestone run | C1-C12 |

Phase 2 items map back to BFS: 2.2 biomes/caves/water, 2.3 physics toys, 2.4
multiplayer, 2.5 sculpting brushes. Stickers and characters are not yet planned as
tasks; they belong after 2.3 exists, when there is something to attach behaviours to.

## How this document changes

Adding a requirement is allowed if it is measured, but it must displace something or be
explicitly budgeted (CPU, memory, or time). Adding a *feature* means editing the phase 2
list, not this one. If a requirement turns out to be unachievable, say so in the task,
record the number that failed, and move it - do not redefine success quietly.
