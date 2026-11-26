const std = @import("std");
const gl = @import("gl");

/// A linked GL program with a small uniform-location cache.
pub const Shader = struct {
    program: gl.uint,
    cache: [16]Entry = undefined,
    cache_len: usize = 0,

    const Entry = struct { name: []const u8, location: gl.int };

    pub fn init(vertex_src: [:0]const u8, fragment_src: [:0]const u8) !Shader {
        const vs = try compile(gl.VERTEX_SHADER, vertex_src);
        errdefer gl.DeleteShader(vs);
        const fs = try compile(gl.FRAGMENT_SHADER, fragment_src);
        errdefer gl.DeleteShader(fs);

        const program = gl.CreateProgram();
        gl.AttachShader(program, vs);
        gl.AttachShader(program, fs);
        gl.LinkProgram(program);
        gl.DeleteShader(vs);
        gl.DeleteShader(fs);

        var ok: [1]gl.int = .{0};
        gl.GetProgramiv(program, gl.LINK_STATUS, &ok);
        if (ok[0] == 0) {
            var log_buf: [2048]u8 = undefined;
            var n: gl.sizei = 0;
            gl.GetProgramInfoLog(program, log_buf.len, &n, &log_buf);
            std.debug.print("shader link error: {s}\n", .{log_buf[0..@intCast(n)]});
            gl.DeleteProgram(program);
            return error.ShaderLink;
        }

        return .{ .program = program };
    }

    pub fn deinit(self: *Shader) void {
        gl.DeleteProgram(self.program);
    }

    pub fn use(self: *Shader) void {
        gl.UseProgram(self.program);
    }

    /// Locations are cached by name; the names are comptime literals, so the
    /// cache is a tiny linear list, not a hash map.
    fn location(self: *Shader, name: [:0]const u8) gl.int {
        for (self.cache[0..self.cache_len]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.location;
        }
        const loc = gl.GetUniformLocation(self.program, name);
        if (self.cache_len < self.cache.len) {
            self.cache[self.cache_len] = .{ .name = name, .location = loc };
            self.cache_len += 1;
        }
        return loc;
    }

    pub fn setMat4(self: *Shader, name: [:0]const u8, mat: [16]f32) void {
        var rows = [1][16]f32{mat};
        gl.UniformMatrix4fv(self.location(name), 1, gl.FALSE, &rows);
    }

    pub fn setFloat2(self: *Shader, name: [:0]const u8, value: [2]f32) void {
        gl.Uniform2f(self.location(name), value[0], value[1]);
    }

    pub fn setFloat4(self: *Shader, name: [:0]const u8, value: [4]f32) void {
        gl.Uniform4f(self.location(name), value[0], value[1], value[2], value[3]);
    }

    pub fn setFloat(self: *Shader, name: [:0]const u8, value: f32) void {
        gl.Uniform1f(self.location(name), value);
    }

    pub fn setInt(self: *Shader, name: [:0]const u8, value: i32) void {
        gl.Uniform1i(self.location(name), value);
    }

    pub fn setVec3(self: *Shader, name: [:0]const u8, value: [3]f32) void {
        gl.Uniform3f(self.location(name), value[0], value[1], value[2]);
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
            var log_buf: [2048]u8 = undefined;
            var n: gl.sizei = 0;
            gl.GetShaderInfoLog(shader, log_buf.len, &n, &log_buf);
            std.debug.print("shader compile error: {s}\n", .{log_buf[0..@intCast(n)]});
            gl.DeleteShader(shader);
            return error.ShaderCompile;
        }
        return shader;
    }
};
