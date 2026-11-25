# 0001 - Window, input and GL context backend

- Status: accepted
- Date: 2026-11-25
- Decides for: tasks 1.1 (main loop), 1.3 (camera input), 1.4 (GL wrapper)

## Decision

Use **SDL3 3.4.18** through the **allyourcodebase/SDL3 1.0.13** Zig package for the
window, input and the OpenGL context. Create a GL 4.6 core context with `SDL_GL_*`
and draw with OpenGL.

```sh
zig fetch --save git+https://github.com/allyourcodebase/SDL3
```

## Context

Linux desktop (X11 today, Wayland not excluded), Zig 0.17.1, no engine, no renderer
off the shelf. The backend has to give us: a window that resizes, a GL context we can
draw into, keyboard/mouse state with relative mouse mode (camera), timing, and later a
gamepad and audio. Everything above that is ours.

## Options

| Option | What it costs | What it brings |
|---|---|---|
| SDL3 via Zig package | one dependency, builds X11/Wayland/xkbcommon/dbus from source | window, input, gamepad, audio, timing, `SDL_GL_*` |
| GLFW 3.3.10 system lib | `libglfw3-dev` (repo version is 3.3.10, upstream is newer), plus translate-c for GLFW and a modern-GL loader | window, input; no audio, no gamepad |
| raw X11/EGL + hand-rolled input | weeks of work | nothing SDL does not already give |

## The finding that decided it

**Zig 0.17 removed `@cImport`.** `const c = @cImport(...)` is now a hard error
("invalid builtin function"). Every C API has to arrive either as a package that
ships pre-translated bindings, or through `b.addTranslateC(...)` in `build.zig`.

- SDL3's package hands over a working `sdl3` module in one `zig fetch --save`.
- GLFW needs us to write the translate-c step ourselves: usable, and it worked, but it
  is one more mechanical layer between the code and the library, and it still leaves
  modern GL unbound (the translate-c of `<GL/gl.h>` only exposes GL 1.1, no VAOs and
  no shaders).

## Spike results (both measured, on burken, X11 :0)

Both spikes open a window, clear it, handle resize and quit on Esc; both run at the
monitor refresh with vsync (120 fps on the RX 9070 XT, Mesa 25.2.8, GL 4.6).

| | SDL3 | GLFW |
|---|---|---|
| build | 12 s after the first fetch, no system packages | 27 s, needs `libglfw3-dev`, translate-c of `GLFW/glfw3.h` |
| binary (debug) | 82 MB | 12 MB |
| resize | `SDL_EVENT_WINDOW_RESIZED`, viewport updated | `glfwGetFramebufferSize`, no event |
| Esc | `SDL_EVENT_KEY_DOWN`, a quick tap exits | state polling (`glfwGetKey`), a synthetic 1-frame tap is missed, a real 300 ms press works |
| extras | gamepad, audio, timing, relative mouse mode | window and input only |

SDL3's 82 MB debug binary is statically linked C in debug mode; a release build strips
most of it. Size was not a deciding factor.

## Consequences

- 1.1 builds the real window and main loop on SDL3; `SDL_GetTicks` in the spike becomes
  a proper frame clock.
- 1.4 still has to choose the GL binding layer: prefer `zigglgen`
  (https://github.com/castholm/zigglgen) once its 0.17 support is confirmed, otherwise a
  small hand-written loader over `SDL_GL_GetProcAddress` for the ~40 entry points we
  actually use. The spike only needed GL 1.1 (`glClearColor`, `glClear`, `glViewport`),
  which links straight from `libGL`.
- The package must stay pinned by commit and hash in `build.zig.zon`.
- SDL3 dlopens its video/audio backends at runtime: fine on Mint, a footgun on NixOS
  (set `LD_LIBRARY_PATH` or `SDL_VIDEODRIVER`).
- Throwaway spikes stay outside the repo at `~/voxel-spikes/{sdl3,glfw}` on burken.
