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
    \\uniform float u_clouds;        // 0 off, 1 on (3.11)
    \\uniform float u_cloud_coverage;// 0..1, higher = fewer gaps
    \\uniform vec3 u_cloud_shift;    // wind offset in cloud space
    \\uniform float u_cloud_bottom;
    \\uniform float u_cloud_top;
    \\uniform vec3 u_cloud_light;    // sun colour at cloud height
    \\in vec2 v_ndc;
    \\out vec4 f_colour;
    \\
    \\float hash13(vec3 p) {
    \\    p = fract(p * 0.1031);
    \\    p += dot(p, p.yzx + 33.33);
    \\    return fract((p.x + p.y) * p.z);
    \\}
    \\
    \\float hash31(vec3 p) {
    \\    p = fract(p * 0.3183099 + vec3(0.11, 0.23, 0.37));
    \\    p *= 17.0;
    \\    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    \\}
    \\
    \\float vnoise(vec3 x) {
    \\    vec3 i = floor(x);
    \\    vec3 f = fract(x);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    return mix(
    \\        mix(mix(hash31(i), hash31(i + vec3(1,0,0)), f.x),
    \\            mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
    \\        mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x),
    \\            mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y),
    \\        f.z);
    \\}
    \\
    \\float cloudDensity(vec3 p) {
    \\    vec3 q = p * 0.0038 + u_cloud_shift;
    \\    // Three octaves: the third is what breaks the edge into ragged detail
    \\    // instead of a smooth blob.
    \\    float n = vnoise(q) * 0.55 + vnoise(q * 2.6) * 0.29 + vnoise(q * 6.3) * 0.16;
    \\    // Coverage is weather, not a constant: a low-frequency field puts clear
    \\    // spells next to heavy patches, which is most of what makes a cloudscape
    \\    // look unplanned.
    \\    float weather = vnoise(q * 0.19 + 13.0);
    \\    float cover = u_cloud_coverage + (weather - 0.5) * 0.34;
    \\    // The base is uneven: offsetting the fade by the same weather field costs
    \\    // nothing and stops the deck reading as a table top at the horizon.
    \\    float base = u_cloud_bottom + (weather - 0.5) * 70.0;
    \\    float vertical = smoothstep(base, base + 70.0, p.y)
    \\                   * (1.0 - smoothstep(u_cloud_top - 70.0, u_cloud_top, p.y));
    \\    float d = clamp((n - cover) / max(1.0 - cover, 0.05), 0.0, 1.0);
    \\    // A linear ramp reads as fog; the curve gives the puffs a defined edge.
    \\    return pow(d, 1.35) * 1.7 * vertical;
    \\}
    \\
    \\// Single scattering through one slab: 20 march steps, two light taps each.
    \\// Hash noise instead of a 3D texture keeps it self-contained.
    \\vec4 clouds(vec3 dir) {
    \\    if (u_clouds < 0.5 || dir.y < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    \\    float t0 = max((u_cloud_bottom - u_eye.y) / dir.y, 0.0);
    \\    // Stop the ray after a fixed distance. Seen edge-on the slab is thousands
    \\    // of blocks deep, and marching that with a fixed step budget averages the
    \\    // density into a flat band on the horizon; cutting the ray short and
    \\    // fading what is left into haze is both cheaper and what the eye expects.
    \\    const float MAX_TRAVEL = 3000.0;
    \\    float t1 = min((u_cloud_top - u_eye.y) / dir.y, t0 + MAX_TRAVEL);
    \\    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);
    \\
    \\    const int STEPS = 22;
    \\    float dt = (t1 - t0) / float(STEPS);
    \\    float cos_angle = dot(dir, u_sun_dir);
    \\    // Henyey-Greenstein, forward peaked: thin edges glow when backlit.
    \\    float g = 0.55;
    \\    float phase = (1.0 - g * g) / (4.0 * 3.14159 * pow(1.0 + g * g - 2.0 * g * cos_angle, 1.5));
    \\
    \\    float transmittance = 1.0;
    \\    vec3 scattered = vec3(0.0);
    \\    // Per-pixel offset on the march: without it the fixed step shows as
    \\    // banding rings near the horizon, which is the classic raymarch tell.
    \\    float jitter = hash31(vec3(gl_FragCoord.xy, 7.0));
    \\    for (int i = 0; i < STEPS; ++i) {
    \\        vec3 p = u_eye + dir * (t0 + (float(i) + jitter) * dt);
    \\        float distance = t0 + (float(i) + jitter) * dt;
    \\        float density = cloudDensity(p);
    \\        if (density > 0.002) {
    \\            float shadow = cloudDensity(p + u_sun_dir * 45.0)
    \\                         + cloudDensity(p + u_sun_dir * 110.0) * 0.6;
    \\            float light = exp(-shadow * 2.2);
    \\            // Extinction per block: the layer has to be thin enough to see through
    \\            // at the edges and thick enough to read as cloud in the middle.
    \\            float extinction = exp(-density * dt * 0.02);
    \\            // Aerial perspective: air between the eye and a distant puff washes
    \\            // it toward the sky, and it stops occluding at the same rate.
    \\            float aerial = 1.0 - smoothstep(2200.0, MAX_TRAVEL, distance);
    \\            vec3 lit = u_cloud_light * light * phase * 9.0 + u_zenith * 0.7;
    \\            scattered += transmittance * (1.0 - extinction) * lit * aerial;
    \\            transmittance *= mix(1.0, extinction, aerial);
    \\        }
    \\    }
    \\    return vec4(scattered, transmittance);
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
    \\    // Clouds composite over the gradient and the disc: a cloud in front of the
    \\    // sun dims it, which is the whole point of drawing them here.
    \\    vec4 cloud = clouds(dir);
    \\    col = col * cloud.a + cloud.rgb;
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
    /// `cloud_shift` is the wind offset in cloud space, advanced by the caller on
    /// the fixed step so the drift does not depend on frame rate.
    pub fn draw(
        self: *SkyRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun: *const sun_mod.Sun,
        clouds_enabled: bool,
        cloud_shift: Vec3,
    ) void {
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

        // 3.11: clouds sit in a 380..700 block slab, so from the ground they are
        // well above the terrain and from a hilltop still overhead.
        const cloud_ramp = sun.ramp();
        self.shader.setFloat("u_clouds", if (clouds_enabled) 1.0 else 0.0);
        self.shader.setFloat("u_cloud_coverage", 0.43);
        self.shader.setVec3("u_cloud_shift", .{ cloud_shift.x, cloud_shift.y, cloud_shift.z });
        self.shader.setFloat("u_cloud_bottom", 380.0);
        self.shader.setFloat("u_cloud_top", 700.0);
        // Cloud light is the sun colour warmed by the phase term, plus the sky.
        self.shader.setVec3("u_cloud_light", .{
            cloud_ramp.sun.x + 0.15,
            cloud_ramp.sun.y + 0.14,
            cloud_ramp.sun.z + 0.12,
        });

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
