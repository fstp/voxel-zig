# voxel-zig

A voxel sandbox engine written from scratch in Zig. Inspired by BFS
(multiplayer voxel sandbox), scoped down to a single-player proof of concept:
a streamed noise-generated world you can walk around and edit at 60 fps.

Planning lives in Vikunja, project **Voxel engine in Zig** (tasks 0.x research,
1.x build, 2.x stretch). Decisions are recorded as short ADRs in `docs/adr/`.

## Requirements

- Zig **0.17.1** (pinned in `.tool-versions`, installed with asdf)
- Linux x86_64, OpenGL 4.6-capable GPU
- SDL3 (vendored through the Zig package manager, see `docs/adr/0001-window-backend.md`)

```sh
asdf install        # picks up .tool-versions
zig version         # must print 0.17.1
```

## Commands

```sh
zig build           # compile to zig-out/bin/voxel-zig
zig build run       # build and run
zig build test      # the gate: all unit tests from the engine module and the exe
```

## Layout

| Path        | Holds                                              | Task |
|-------------|----------------------------------------------------|------|
| `src/main.zig` | executable entry point                          | 0.1 |
| `src/root.zig` | engine module root, re-exports the public API   | 0.1 |
| `src/math/` | vectors, matrices, AABB, frustum                    | 1.2, 1.3 |
| `src/voxel/` | block ids, coordinates, mesher                     | 1.4 - 1.6 |
| `src/world/` | chunk storage, terrain gen, save/load              | 1.5, 1.8, 1.14 |
| `src/gfx/`  | window, GL wrapper, shaders, textures               | 1.1, 1.4 |
| `src/player/` | controller, collision, raycast                    | 1.9, 1.10 |

The engine is a module (`voxel_zig` in `build.zig`) so anything in it can be
unit tested without a window. The exe only wires the pieces together.

## Rules of engagement

- Check std APIs against the compiler in `.tool-versions`; 0.13/0.14 tutorial
  code will not compile. Zig 0.17 moved `std.Io`, `std.ArrayList` and the
  `main` signature (`std.process.Init`).
- Tests before the next task: `zig build test` green, then commit.
- New decisions go in `docs/adr/NNNN-title.md` before the code that depends on
  them.
