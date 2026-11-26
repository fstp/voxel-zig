const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const sun_mod = @import("../world/sun.zig");

/// Per-face resolution. 64 is enough for a smooth sky gradient: the probe is
/// sampled with LOD by roughness, so its detail budget is about the blurriest
/// reflection that still needs to look like a gradient, not like a photo.
const SIZE: i32 = 64;
const MIPS: i32 = 7;

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\out vec2 v_uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    v_uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

/// Mirrors sky_renderer's gradient: the colours come from the same `sun.ramp()`
/// call, so the probe and the visible sky agree unless the disc/glow constants
/// here drift. Clouds are deliberately absent - they move every second and the
/// probe only re-renders when the sun does.
const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform mat4 u_inv_vp;
    \\uniform vec3 u_zenith;
    \\uniform vec3 u_horizon;
    \\uniform vec3 u_sun_colour;
    \\uniform vec3 u_sun_dir;
    \\uniform float u_night; // 1 at night, for the star-free ambient floor
    \\in vec2 v_uv;
    \\out vec4 f_colour;
    \\void main() {
    \\    vec4 far = u_inv_vp * vec4(v_uv * 2.0 - 1.0, 1.0, 1.0);
    \\    vec3 dir = normalize(far.xyz / far.w);
    \\    float up = pow(max(dir.y, 0.0), 0.45);
    \\    vec3 colour = mix(u_horizon, u_zenith, up);
    \\    // Sun disc and glow, same constants as the sky pass (ADR 0009): this is
    \\    // what puts a highlight in the reflection at water roughness.
    \\    float d = dot(dir, u_sun_dir);
    \\    colour += u_sun_colour * smoothstep(0.99985, 0.99995, d);
    \\    colour += u_sun_colour * pow(max(d, 0.0), 220.0) * 0.55;
    \\    // Below the horizon the probe is dark ground, not sky, or a metal face
    \\    // pointing down would reflect daylight from the floor.
    \\    colour *= mix(1.0, 0.18, smoothstep(0.0, -0.35, dir.y));
    \\    f_colour = vec4(colour, 1.0);
    \\}
;

/// A six-face cube map of the sky, re-rendered only when the sun moves.
///
/// Why: the analytic environment in 4.2 was a two-colour hemisphere with no idea
/// where the sun was, so smooth surfaces had nothing to reflect and water stayed
/// flat at every angle. Six 64x64 sky renders per sun update cost far less than a
/// planar reflection pass and give metal and water a real horizon to mirror.
pub const EnvProbe = struct {
    texture: gl.uint = 0,
    fbo: gl.uint = 0,
    shader: Shader,
    vao: gl.uint = 0,
    query: gl.uint = 0,
    /// Milliseconds the last re-render took on the GPU.
    last_ms: f32 = 0,
    /// Sun elevation the cube currently holds; the re-render trigger.
    last_elevation: f32 = 999.0,
    last_azimuth: f32 = 999.0,
    updates: u32 = 0,
    max_mip: f32 = @floatFromInt(MIPS - 1),

    pub fn init() !EnvProbe {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var vao: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));

        var query: gl.uint = 0;
        gl.GenQueries(1, @ptrCast(&query));

        var probe = EnvProbe{ .shader = shader, .vao = vao, .query = query };

        gl.GenTextures(1, @ptrCast(&probe.texture));
        gl.BindTexture(gl.TEXTURE_CUBE_MAP, probe.texture);
        var face: u32 = 0;
        while (face < 6) : (face += 1) {
            gl.TexImage2D(
                gl.TEXTURE_CUBE_MAP_POSITIVE_X + face,
                0,
                gl.RGBA16F,
                SIZE,
                SIZE,
                0,
                gl.RGBA,
                gl.FLOAT,
                null,
            );
        }
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, MIPS - 1);

        gl.GenFramebuffers(1, @ptrCast(&probe.fbo));
        gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0);
        return probe;
    }

    pub fn deinit(self: *EnvProbe) void {
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
        if (self.fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    /// Re-render only when the sun has actually moved: the probe is a function of
    /// the sun and nothing else, so a static sun costs nothing.
    pub fn updateIfNeeded(self: *EnvProbe, sun: *const sun_mod.Sun) void {
        const elevation = sun.elevation();
        const azimuth = sun.azimuth();
        const moved = @abs(elevation - self.last_elevation) > 0.15 or
            @abs(azimuth - self.last_azimuth) > 0.15;
        if (!moved and self.updates > 0) return;
        self.render(sun);
        self.last_elevation = elevation;
        self.last_azimuth = azimuth;
        self.updates += 1;
    }

    fn render(self: *EnvProbe, sun: *const sun_mod.Sun) void {
        const ramp = sun.ramp();
        const sun_dir = sun.direction();

        // Face view/projections: the six axis directions, 90 degrees each.
        const dirs = [_]Vec3{
            .{ .x = 1, .y = 0, .z = 0 },
            .{ .x = -1, .y = 0, .z = 0 },
            .{ .x = 0, .y = 1, .z = 0 },
            .{ .x = 0, .y = -1, .z = 0 },
            .{ .x = 0, .y = 0, .z = 1 },
            .{ .x = 0, .y = 0, .z = -1 },
        };
        const ups = [_]Vec3{
            .{ .x = 0, .y = 1, .z = 0 },
            .{ .x = 0, .y = 1, .z = 0 },
            .{ .x = 0, .y = 0, .z = -1 }, // +Y looks down the -Z axis
            .{ .x = 0, .y = 0, .z = 1 },
            .{ .x = 0, .y = 1, .z = 0 },
            .{ .x = 0, .y = 1, .z = 0 },
        };

        self.shader.use();
        self.shader.setVec3("u_zenith", .{ ramp.zenith.x, ramp.zenith.y, ramp.zenith.z });
        self.shader.setVec3("u_horizon", .{ ramp.horizon.x, ramp.horizon.y, ramp.horizon.z });
        // The disc is drawn at full strength: the ramp already dims the sun with
        // elevation, and a reflection of a dim sun is still a reflection.
        self.shader.setVec3("u_sun_colour", .{ ramp.sun.x, ramp.sun.y, ramp.sun.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });

        const projection = Mat4.perspective(std.math.pi * 0.5, 1.0, 0.1, 100.0);

        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.Viewport(0, 0, SIZE, SIZE);
        gl.Disable(gl.DEPTH_TEST);
        gl.BindVertexArray(self.vao);
        if (self.query != 0) gl.BeginQuery(gl.TIME_ELAPSED, self.query);

        for (dirs, ups, 0..) |dir, up, face| {
            const view = Mat4.lookAt(Vec3.init(0, 0, 0), dir, up);
            const vp = projection.mul(view);
            const inv = vp.inverse() orelse Mat4.identity;
            self.shader.setMat4("u_inv_vp", inv.m);
            gl.FramebufferTexture2D(
                gl.FRAMEBUFFER,
                gl.COLOR_ATTACHMENT0,
                gl.TEXTURE_CUBE_MAP_POSITIVE_X + @as(u32, @intCast(face)),
                self.texture,
                0,
            );
            gl.DrawArrays(gl.TRIANGLES, 0, 3);
        }

        if (self.query != 0) {
            gl.EndQuery(gl.TIME_ELAPSED);
            var nanoseconds = [_]u64{0};
            gl.GetQueryObjectui64v(self.query, gl.QUERY_RESULT, &nanoseconds);
            self.last_ms = @as(f32, @floatFromInt(nanoseconds[0])) / 1_000_000.0;
        }

        gl.BindTexture(gl.TEXTURE_CUBE_MAP, self.texture);
        gl.GenerateMipmap(gl.TEXTURE_CUBE_MAP);
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.Enable(gl.DEPTH_TEST);
    }

    /// Bind to a texture unit for the chunk shader.
    pub fn bind(self: *const EnvProbe, unit: u32) void {
        gl.ActiveTexture(gl.TEXTURE0 + unit);
        gl.BindTexture(gl.TEXTURE_CUBE_MAP, self.texture);
    }
};
