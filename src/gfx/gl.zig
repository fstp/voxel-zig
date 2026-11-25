const std = @import("std");
const sdl = @import("sdl3");

pub const gl = @import("gl");

var procs: gl.ProcTable = undefined;

/// Loads every OpenGL entry point through SDL, then makes the table current on
/// this thread. Call once after the context exists.
pub fn init() !void {
    if (!procs.init(loader)) return error.GlLoad;
    gl.makeProcTableCurrent(&procs);
}

fn loader(name: [*:0]const u8) ?gl.PROC {
    const p = sdl.SDL_GL_GetProcAddress(name);
    return @ptrCast(@alignCast(p));
}

pub fn rendererString() []const u8 {
    const p = gl.GetString(gl.RENDERER);
    if (p == null) return "?";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}
