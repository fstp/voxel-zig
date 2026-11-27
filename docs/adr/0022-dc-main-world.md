# 0022 - The DC world becomes the engine

- Status: implemented (8.2 port, 8.4 module split)
- Date: 2026-11-27
- Supersedes: the block world (phases 1-4) as the playable world; ADR 0018's DC extraction becomes
  the only world path.

## Inventory (block-only, delete after the DC build is green)

| Area | Files |
|---|---|
| app | `app.zig` (block App, save, brush, bodies, net, water, shadow/SSAO/post wiring) |
| voxel | `voxel/block.zig`, `voxel/mesher.zig`, `voxel/raycast.zig`, `voxel/coords.zig` |
| world | `world/world.zig`, `chunk.zig`, `chunk_slab.zig`, `chunk_mesher.zig`, `terrain.zig`, `save.zig`, `brush.zig`, `undo.zig` |
| render | `gfx/block_renderer.zig`, `chunk_renderer.zig`, `shadow_renderer.zig`, `ssao.zig`, `post.zig`, `texture.zig`, `debug_draw.zig` |
| other | `player/player.zig`, `physics/bodies.zig`, `net/udp.zig` |
| assets | `assets/blocks/*` (256 px texture arrays, ~2.1 MB) |

**Keep**: `math/*`, `camera.zig`, `input.zig`, `voxel/dc.zig`, `world/noise.zig`, `world/sun.zig`,
`gfx/window.zig`, `gl.zig`, `shader.zig`, `sky_renderer.zig`, `hud.zig`, `hud_font.zig`, `stb.zig`,
`font8x6.zig`, `assets/font/hud.png`.

**Port from the spike** (`tools/dc_view.zig`): the field sampler and meshing/streaming into
`src/world/dc_world.zig`; the program/VAO/upload/draw into `src/gfx/dc_renderer.zig`; the player
motion into `src/player/dc_player.zig`; the app loop into `src/dc_main.zig`, which becomes the
`voxel-zig` executable root. `main.zig` and `app.zig` stop being built.

## Design

- **World**: the analytic height field `y - heightAt(x, z)` plus an ordered list of sphere edits.
  An added sphere unions with the field (`min(f, |p-c|-r)`), a carved one subtracts
  (`max(f, -(|p-c|-r))`). Every sample evaluates the edit list; it is short and the mesher already
  evaluates the field once per column.
- **Streaming**: keep the spike's 8x8-chunk patch, one global y slab (20..92), two-cell skirt and
  four chunks per frame. A patch rebuild is requested when the player crosses a chunk border or
  after an edit; the old mesh stays on screen until the new one is complete.
- **Collision**: the spike's height-field player (gravity, jump, walk/fly, step height) with
  `groundAt` extended by the added spheres' top surface, so placed geometry is walkable.
- **Editing**: sphere trace the field from the eye (12 m); primary click carves a radius-3 sphere
  at the hit, secondary click adds one at the hit point. The edit is appended to the list and a
  patch rebuild is requested. Undo is out of scope for this step.
- **Save**: a line-based text file, `dc_world.sav` (or `VOXEL_DC_SAVE`), holding the format version,
  seed, sun time, player state and the edit list. F5 saves; the file is loaded at startup when it
  exists. Text rather than JSON because it is inspectable and has no schema churn.
- **Not carried over in this step**: block water, the RLE save, brush shapes/undo, physics bodies,
  multiplayer, LOD. Water is recorded as the next world feature (sea level in the field); LOD stays
  deferred per ADR 0018.
- **Build**: the installed binary is `voxel-zig` (DC app). `dc-view`/`dc-bench` tool steps leave the
  install; the test step includes only the modules the DC path uses.

## Measured (2026-11-27)

- `voxel-zig` is now built from `src/dc_main.zig`; the installed binary is the only executable
  (`dc-view` and `dc-bench` are gone from the build and `zig-out/bin`).
- Starts in the DC world at 3840x2103, 60 fps, 111,665 verts / 88,389 quads over the 8x8 patch.
- Dig (left click): sphere-traced hit at (47.0, 56.0, 47.0), carve edit appended, patch rebuilt to
  111,706 verts. Place (right click): second edit appended, 111,702 verts. HUD shows `EDITS 2`.
- F5 writes `dc_world.sav` (header, sun, player, two edit lines); relaunching reads it back
  ("world: 1 edits" for the one-edit save) and reproduces the edited mesh vertex-for-vertex.
- `zig build -Doptimize=ReleaseFast` and `zig build test` green after deleting every block module
  and `assets/blocks` (2.1 MB). The test tree now exercises math, camera, dc, noise and sun only.

## Module layout (8.4)

The app was split with no behaviour change:

- `src/dc_main.zig` (493 lines, down from 1,265): window and loop, input, HUD, sky, streaming,
  sun and the save triggers.
- `src/world/dc_world.zig` (575): `CHUNK`/`SEED`/`PATCH`/`CELL`, `heightAt`, `Vertex` and the
  material palette, `Edit`/`editField`/`fieldAt`/`raycastField`, `PlayerSave` and the save/load
  format, chunk/patch stats, `meshChunkInto`/`meshPatch`, and the streaming diagnostics.
- `src/gfx/dc_renderer.zig` (207): the terrain shaders, the `Shader`, VAO/VBO/EBO ownership, upload
  and the draw with depth/blend/cull state plus the fog/atmosphere uniforms.
- `src/player/dc_player.zig` (106): the height-field motion model.
- `root.zig` exports `world.dc_world`, `gfx.DcRenderer` and `player.DcPlayer`; the test tree
  imports the new modules.

Verified identical after the split: fresh world 111,665 verts / 88,389 quads; one carve gives
111,706 / 88,431 and a relaunch reloads it vertex-for-vertex; `zig build` and `zig build test`
green.

## Acceptance (met)

`voxel-zig` starts in the DC world at 60 fps/4K; the block modules no longer compile into anything;
`zig build test` green; dig/place, save and reload verified; docs updated; the app is split into
world, renderer and player modules.
