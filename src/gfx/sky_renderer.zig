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
const VERT_SRC: [:0]const u8 = @embedFile("../shaders/sky_vert.vert");

const FRAG_SRC: [:0]const u8 = @embedFile("../shaders/sky_frag.frag");

pub const SkyRenderer = struct {
    shader: Shader,
    vao: gl.uint,
    query: gl.uint = 0,
    /// Milliseconds the sky pass took on the GPU last frame, for the HUD.
    last_ms: f32 = 0,
    /// Optional atmospheric horizon haze + Mie glow (ADR 0021). Off by default so the engine's
    /// accepted sky look is unchanged; the DC viewer turns it on for the atmosphere pass.
    atmosphere: bool = false,
    /// Cloud march steps. Was 22; measured at 4K the sky pass costs 8.12 ms median at 22 and
    /// 5.77 ms at 10, with a mean pixel difference of 1.9 against the 22-step frame (ADR 0044).
    cloud_steps: i32 = 10,

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
        self.shader.setInt("u_cloud_steps", self.cloud_steps);
        self.shader.setVec3("u_cloud_shift", .{ cloud_shift.x, cloud_shift.y, cloud_shift.z });
        self.shader.setFloat("u_cloud_bottom", 380.0);
        self.shader.setFloat("u_cloud_top", 700.0);
        // Cloud light is the sun colour warmed by the phase term, plus the sky.
        self.shader.setVec3("u_cloud_light", .{
            cloud_ramp.sun.x + 0.15,
            cloud_ramp.sun.y + 0.14,
            cloud_ramp.sun.z + 0.12,
        });
        self.shader.setFloat("u_atmosphere", if (self.atmosphere) 1.0 else 0.0);

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
