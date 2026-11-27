# 0022 - The DC world becomes the engine

- Status: implemented (functional port; module split deferred, see below)
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

## Deviation from the plan

The functional port is done, but the mesher/sampler/player still live in `src/dc_main.zig` rather
than being split into `src/world/dc_world.zig`, `src/gfx/dc_renderer.zig` and
`src/player/dc_player.zig`. The executable has no block dependency and the build is DC-only, so this
is a code-organisation follow-up, not a blocker; it is left as a separate task.

## Acceptance (met)

`voxel-zig` starts in the DC world at 60 fps/4K; the block modules no longer compile into anything;
`zig build test` green; dig/place, save and reload verified; docs updated.
