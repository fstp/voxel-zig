//! Sun shadow maps (ADR 0029). Two camera-fitted cascades, depth-only, with a shared PCSS/PCF
//! lookup in the consumer shaders. The terrain, trees, rocks, grass and detail props all draw
//! into the same two maps; water and every lit surface sample them.

const std = @import("std");
const gl = @import("gl");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const Shader = @import("shader.zig").Shader;

pub const CASCADES: usize = 2;
pub const SIZE: usize = 2048;

/// Near cascade covers the foreground, far cascade the middle distance. Both are fitted around
/// the ground at the camera's horizontal position, so a high flying camera does not waste the
/// map on empty air.
const near_offset: f32 = 30.0;
const far_offset: f32 = 95.0;
const near_extent: f32 = 58.0;
const far_extent: f32 = 125.0;
const ground_center: f32 = 61.0;
const light_back: f32 = 260.0;
const light_depth: f32 = 600.0;

pub const ShadowRenderer = struct {
    fbo: [CASCADES]u32 = .{ 0, 0 },
    tex: [CASCADES]u32 = .{ 0, 0 },
    vp: [CASCADES]Mat4 = .{ Mat4.identity, Mat4.identity },
    enabled: bool = true,

    pub fn init() !ShadowRenderer {
        var self = ShadowRenderer{};
        gl.GenTextures(CASCADES, @ptrCast(&self.tex));
        gl.GenFramebuffers(CASCADES, @ptrCast(&self.fbo));
        for (0..CASCADES) |i| {
            gl.BindTexture(gl.TEXTURE_2D, self.tex[i]);
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, SIZE, SIZE, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo[i]);
            gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, self.tex[i], 0);
            gl.DrawBuffer(gl.NONE);
            gl.ReadBuffer(gl.NONE);
            if (gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) return error.ShadowFramebuffer;
        }
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.BindTexture(gl.TEXTURE_2D, 0);
        return self;
    }

    pub fn deinit(self: *ShadowRenderer) void {
        for (0..CASCADES) |i| {
            if (self.fbo[i] != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo[i]));
            if (self.tex[i] != 0) gl.DeleteTextures(1, @ptrCast(&self.tex[i]));
        }
    }

    /// Recompute both light matrices for the current camera and sun. Call once per frame before
    /// any caster is drawn.
    pub fn update(self: *ShadowRenderer, eye: Vec3, forward: Vec3, sun_dir: Vec3) void {
        var f = Vec3.init(forward.x, 0, forward.z);
        if (f.x * f.x + f.z * f.z < 1e-6) f = Vec3.init(0, 0, -1);
        const flen = @sqrt(f.x * f.x + f.z * f.z);
        f = f.scale(1.0 / flen);
        const offsets = [CASCADES]f32{ near_offset, far_offset };
        const extents = [CASCADES]f32{ near_extent, far_extent };
        const up = if (@abs(sun_dir.y) > 0.98) Vec3.init(0, 0, 1) else Vec3.init(0, 1, 0);
        for (0..CASCADES) |i| {
            const center = Vec3.init(eye.x + f.x * offsets[i], ground_center, eye.z + f.z * offsets[i]);
            const light_eye = center.add(sun_dir.scale(light_back));
            const view = Mat4.lookAt(light_eye, center, up);
            // Snap the light-space centre to whole shadow texels. Without this the map slides
            // under the geometry as the camera moves and every edge crawls.
            var snapped_center = center;
            if (view.inverse()) |inv_view| {
                const texel = 2.0 * extents[i] / @as(f32, @floatFromInt(SIZE));
                var c = view.transformPoint(center);
                c.x = @round(c.x / texel) * texel;
                c.y = @round(c.y / texel) * texel;
                snapped_center = inv_view.transformPoint(c);
            }
            const snapped_eye = snapped_center.add(sun_dir.scale(light_back));
            const snapped_view = Mat4.lookAt(snapped_eye, snapped_center, up);
            const proj = Mat4.ortho(-extents[i], extents[i], -extents[i], extents[i], 1.0, light_depth);
            self.vp[i] = proj.mul(snapped_view);
        }
    }

    pub fn begin(self: *ShadowRenderer, cascade: usize) void {
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo[cascade]);
        gl.Viewport(0, 0, SIZE, SIZE);
        gl.Disable(gl.BLEND);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.CULL_FACE);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
    }

    pub fn end(self: *ShadowRenderer) void {
        _ = self;
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
    }

    /// Binds the two maps and sends the light matrices to a consumer shader. The sampler units are
    /// 1 and 2 so unit 0 is left for object textures (the impostor atlas).
    pub fn setUniforms(self: *ShadowRenderer, shader: *Shader) void {
        const names = [CASCADES][:0]const u8{ "u_light_vp[0]", "u_light_vp[1]" };
        for (names, 0..) |name, i| shader.setMat4(name, self.vp[i].m);
        shader.setFloat("u_shadow_enabled", if (self.enabled) 1.0 else 0.0);
        shader.setInt("u_shadow0", 1);
        shader.setInt("u_shadow1", 2);
        gl.ActiveTexture(gl.TEXTURE1);
        gl.BindTexture(gl.TEXTURE_2D, self.tex[0]);
        gl.ActiveTexture(gl.TEXTURE2);
        gl.BindTexture(gl.TEXTURE_2D, self.tex[1]);
        gl.ActiveTexture(gl.TEXTURE0);
    }
};
