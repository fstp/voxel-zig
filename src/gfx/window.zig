const std = @import("std");
const sdl = @import("sdl3");

pub const Config = struct {
    title: [:0]const u8 = "voxel-zig",
    width: i32 = 1280,
    height: i32 = 720,
    vsync: bool = true,
};

pub const Event = enum { none, quit, resize };

/// An SDL3 window with an OpenGL 4.6 core context. Owns both, nothing else.
pub const Window = struct {
    handle: *sdl.SDL_Window,
    ctx: sdl.SDL_GLContext,
    width: i32,
    height: i32,

    pub fn init(config: Config) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer sdl.SDL_Quit();

        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 4);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 6);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 24);
        // RenderDoc: a GL application must say which attributes it enabled explicitly, or the
        // capture/replay cannot reproduce the context. Harmless when nothing is capturing.
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_FLAGS, sdl.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_RELEASE_BEHAVIOR, sdl.SDL_GL_CONTEXT_RELEASE_BEHAVIOR_FLUSH);

        const handle = sdl.SDL_CreateWindow(
            config.title,
            config.width,
            config.height,
            sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.SDL_GetError()});
            return error.Window;
        };
        errdefer sdl.SDL_DestroyWindow(handle);

        const ctx = sdl.SDL_GL_CreateContext(handle) orelse {
            std.debug.print("SDL_GL_CreateContext failed: {s}\n", .{sdl.SDL_GetError()});
            return error.GlContext;
        };
        errdefer _ = sdl.SDL_GL_DestroyContext(ctx);

        if (config.vsync and !sdl.SDL_GL_SetSwapInterval(1)) {
            std.debug.print("warning: vsync request failed\n", .{});
        }

        var width: i32 = 0;
        var height: i32 = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(handle, &width, &height);

        var swap_interval: c_int = -1;
        _ = sdl.SDL_GL_GetSwapInterval(&swap_interval);
        std.debug.print(
            "window {d}x{d} flags=0x{x} swap_interval={d}\n",
            .{ width, height, sdl.SDL_GetWindowFlags(handle), swap_interval },
        );

        return .{ .handle = handle, .ctx = ctx, .width = width, .height = height };
    }

    pub fn deinit(self: *Window) void {
        _ = sdl.SDL_GL_DestroyContext(self.ctx);
        sdl.SDL_DestroyWindow(self.handle);
        sdl.SDL_Quit();
    }

    /// Re-reads the framebuffer size after a resize event.
    pub fn syncSize(self: *Window) void {
        var width: i32 = 0;
        var height: i32 = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.handle, &width, &height);
        self.width = width;
        self.height = height;
    }

    pub fn swap(self: *Window) void {
        _ = sdl.SDL_GL_SwapWindow(self.handle);
    }
};
