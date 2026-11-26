const std = @import("std");
const gl = @import("gl");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Aabb = @import("../math/aabb.zig").Aabb;

const VERT_SRC: [:0]const u8 = @embedFile("../shaders/debugdraw_vert.vert");

const FRAG_SRC: [:0]const u8 = @embedFile("../shaders/debugdraw_frag.frag");

/// Minimal wireframe box renderer for debugging the camera and culling.
/// Throwaway-grade: one shader, one static VBO of unit-cube edges.
pub const DebugDraw = struct {
    program: gl.uint,
    vao: gl.uint,
    vbo: gl.uint,
    u_vp: gl.int,
    u_model: gl.int,
    u_colour: gl.int,

    const CUBE_EDGES = [12][2][3]f32{
        .{ .{ -0.5, -0.5, -0.5 }, .{ 0.5, -0.5, -0.5 } },
        .{ .{ 0.5, -0.5, -0.5 }, .{ 0.5, 0.5, -0.5 } },
        .{ .{ 0.5, 0.5, -0.5 }, .{ -0.5, 0.5, -0.5 } },
        .{ .{ -0.5, 0.5, -0.5 }, .{ -0.5, -0.5, -0.5 } },
        .{ .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 } },
        .{ .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 } },
        .{ .{ 0.5, 0.5, 0.5 }, .{ -0.5, 0.5, 0.5 } },
        .{ .{ -0.5, 0.5, 0.5 }, .{ -0.5, -0.5, 0.5 } },
        .{ .{ -0.5, -0.5, -0.5 }, .{ -0.5, -0.5, 0.5 } },
        .{ .{ 0.5, -0.5, -0.5 }, .{ 0.5, -0.5, 0.5 } },
        .{ .{ 0.5, 0.5, -0.5 }, .{ 0.5, 0.5, 0.5 } },
        .{ .{ -0.5, 0.5, -0.5 }, .{ -0.5, 0.5, 0.5 } },
    };

    pub fn init() !DebugDraw {
        const vs = try compile(gl.VERTEX_SHADER, VERT_SRC);
        const fs = try compile(gl.FRAGMENT_SHADER, FRAG_SRC);
        const program = gl.CreateProgram();
        gl.AttachShader(program, vs);
        gl.AttachShader(program, fs);
        gl.LinkProgram(program);

        var ok: [1]gl.int = .{0};
        gl.GetProgramiv(program, gl.LINK_STATUS, &ok);
        if (ok[0] == 0) {
            var log_buf: [1024]u8 = undefined;
            var n: gl.sizei = 0;
            gl.GetProgramInfoLog(program, log_buf.len, &n, &log_buf);
            std.debug.print("debug_draw link error: {s}\n", .{log_buf[0..@intCast(n)]});
            return error.Link;
        }
        gl.DeleteShader(vs);
        gl.DeleteShader(fs);

        var vao: gl.uint = 0;
        var vbo: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));
        gl.GenBuffers(1, @ptrCast(&vbo));
        gl.BindVertexArray(vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(CUBE_EDGES)), &CUBE_EDGES, gl.STATIC_DRAW);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf([3]f32), 0);
        gl.EnableVertexAttribArray(0);

        return .{
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .u_vp = gl.GetUniformLocation(program, "u_vp"),
            .u_model = gl.GetUniformLocation(program, "u_model"),
            .u_colour = gl.GetUniformLocation(program, "u_colour"),
        };
    }

    pub fn deinit(self: *DebugDraw) void {
        gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        gl.DeleteProgram(self.program);
    }

    pub fn begin(self: *DebugDraw, view_projection: Mat4) void {
        gl.UseProgram(self.program);
        setMat4(self.u_vp, view_projection);
        gl.BindVertexArray(self.vao);
    }

    pub fn box(self: *DebugDraw, bounds: Aabb, colour: [3]f32) void {
        const model = Mat4.translate(bounds.center()).mul(Mat4.scale(bounds.size()));
        setMat4(self.u_model, model);
        gl.Uniform3f(self.u_colour, colour[0], colour[1], colour[2]);
        gl.DrawArrays(gl.LINES, 0, 24);
    }

    fn setMat4(location: gl.int, mat: Mat4) void {
        var rows = [1][16]f32{mat.m};
        gl.UniformMatrix4fv(location, 1, gl.FALSE, &rows);
    }

    fn compile(kind: gl.@"enum", src: [:0]const u8) !gl.uint {
        const shader = gl.CreateShader(kind);
        var ptrs = [1][*]const u8{src.ptr};
        var lens = [1]gl.int{@intCast(src.len)};
        gl.ShaderSource(shader, 1, &ptrs, &lens);
        gl.CompileShader(shader);
        var ok: [1]gl.int = .{0};
        gl.GetShaderiv(shader, gl.COMPILE_STATUS, &ok);
        if (ok[0] == 0) {
            var log_buf: [1024]u8 = undefined;
            var n: gl.sizei = 0;
            gl.GetShaderInfoLog(shader, log_buf.len, &n, &log_buf);
            std.debug.print("debug_draw shader error: {s}\n", .{log_buf[0..@intCast(n)]});
            return error.Shader;
        }
        return shader;
    }
};
