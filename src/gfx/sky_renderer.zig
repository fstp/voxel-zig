const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const sun_mod = @import("../world/sun.zig");

/// Procedural sky (3.6, ADR 0009).
///
/// One fullscreen triangle drawn before anything else, with depth test and depth
/// write off. The view ray comes from unprojecting the NDC corner through the
/// inverse view-projection, so the sky is at infinity and the camera position
/// only matters for the ray's origin, never its parallax.
///
/// The colours are the same `sun.ramp()` values the terrain lighting uses, passed
/// in as uniforms, so sky and terrain cannot disagree about the time of day.
const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\const vec2 POS[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    \\out vec2 v_ndc;
    \\void main() {
    \\    vec2 p = POS[gl_VertexID];
    \\    v_ndc = p;
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform mat4 u_inv_vp;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_zenith;
    \\uniform vec3 u_horizon;
    \\uniform vec3 u_sun_colour;
    \\uniform float u_stars; // 0 day, 1 night
    \\in vec2 v_ndc;
    \\out vec4 f_colour;
    \\
    \\float hash13(vec3 p) {
    \\    p = fract(p * 0.1031);
    \\    p += dot(p, p.yzx + 33.33);
    \\    return fract((p.x + p.y) * p.z);
    \\}
    \\
    \\void main() {
    \\    // Unproject the far plane at this corner and take the direction from the eye.
    \\    vec4 far_point = u_inv_vp * vec4(v_ndc, 1.0, 1.0);
    \\    vec3 dir = normalize(far_point.xyz / far_point.w - u_eye);
    \\
    \\    float h = clamp(dir.y, 0.0, 1.0);
    \\    vec3 col = mix(u_horizon, u_zenith, pow(h, 0.45));
    \\
    \\    float c = dot(dir, u_sun_dir);
    \\    // 0.5 degree disc plus a wide glow, both in linear space (ADR 0008).
    \\    float disc = smoothstep(0.99985, 0.99995, c);
    \\    float glow = pow(max(c, 0.0), 220.0) * 0.55;
    \\    col += u_sun_colour * (disc * 3.0 + glow);
    \\
    \\    if (u_stars > 0.01) {
    \\        // Sparse point stars: one candidate per cell, drawn as a soft dot.
    \\        vec3 scaled = dir * 320.0;
    \\        vec3 cell = floor(scaled);
    \\        if (hash13(cell) > 0.9955) {
    \\            vec3 jitter = vec3(hash13(cell + 1.0), hash13(cell + 2.0), hash13(cell + 3.0));
    \\            float d = length(scaled - (cell + 0.5 + (jitter - 0.5) * 0.6));
    \\            float brightness = smoothstep(0.6, 0.0, d);
    \\            // Fade stars out near the horizon, where the sky glow is.
    \\            col += vec3(brightness * u_stars * smoothstep(0.02, 0.25, dir.y));
    \\        }
    \\    }
    \\    f_colour = vec4(col, 1.0);
    \\}
;

pub const SkyRenderer = struct {
    shader: Shader,
    vao: gl.uint,
    query: gl.uint = 0,
    /// Milliseconds the sky pass took on the GPU last frame, for the HUD.
    last_ms: f32 = 0,

    pub fn init() !SkyRenderer {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var vao: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));
        gl.BindVertexArray(vao);

        var query: gl.uint = 0;
        gl.GenQueries(1, @ptrCast(&query));

        return .{ .shader = shader, .vao = vao, .query = query };
    }

    pub fn deinit(self: *SkyRenderer) void {
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    /// Draws the sky over whatever is already in the colour buffer.
    pub fn draw(self: *SkyRenderer, view_projection: Mat4, eye: Vec3, sun: *const sun_mod.Sun) void {
        const inv = view_projection.inverse() orelse return;
        const ramp = sun.ramp();
        const lighting = sun.lighting();

        // Depth off: the sky is written everywhere and must never occlude terrain.
        gl.Disable(gl.DEPTH_TEST);
        gl.DepthMask(gl.FALSE);
        gl.Disable(gl.CULL_FACE);

        self.shader.use();
        self.shader.setMat4("u_inv_vp", inv.m);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ lighting.sun_dir.x, lighting.sun_dir.y, lighting.sun_dir.z });
        self.shader.setVec3("u_zenith", .{ ramp.zenith.x, ramp.zenith.y, ramp.zenith.z });
        self.shader.setVec3("u_horizon", .{ ramp.horizon.x, ramp.horizon.y, ramp.horizon.z });
        self.shader.setVec3("u_sun_colour", .{ ramp.sun.x, ramp.sun.y, ramp.sun.z });
        // Stars only once the sun is well down; smoothstep keeps the fade clean.
        const elevation = sun.elevation();
        self.shader.setFloat("u_stars", 1.0 - smoothstep(-8.0, -2.0, elevation));

        gl.BindVertexArray(self.vao);
        if (self.query != 0) gl.BeginQuery(gl.TIME_ELAPSED, self.query);
        gl.DrawArrays(gl.TRIANGLES, 0, 3);
        if (self.query != 0) gl.EndQuery(gl.TIME_ELAPSED);

        if (self.query != 0) {
            // The binding wants a many-pointer, so hand it a one-element array.
            var nanoseconds = [_]u64{0};
            gl.GetQueryObjectui64v(self.query, gl.QUERY_RESULT, &nanoseconds);
            self.last_ms = @as(f32, @floatFromInt(nanoseconds[0])) / 1_000_000.0;
        }

        // Give the state back. Leaving depth writes off here is what made the
        // world see-through: the terrain then never wrote depth and chunks drew
        // over each other.
        gl.DepthMask(gl.TRUE);
        gl.Enable(gl.DEPTH_TEST);
    }
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}
