const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;

const AO_VERT: [:0]const u8 = @embedFile("../shaders/ssao_ao_vert.vert");

/// Screen-space ambient occlusion from depth alone (4.9).
///
/// Depth only, no G-buffer: the view-space normal is rebuilt from the gradients of
/// the reconstructed position. On flat voxel faces that is exact, and at silhouette
/// edges the reconstruction is wrong in a way that reads as a soft corner rather
/// than an artefact, because the blur pass runs after it.
const AO_FRAG: [:0]const u8 = @embedFile("../shaders/ssao_ao_frag.frag");

/// 4x4 box blur. One pass at half resolution is enough because the AO itself is
/// noise-rotated; a separable gaussian would be more pixels for no visible gain.
const BLUR_FRAG: [:0]const u8 = @embedFile("../shaders/ssao_blur_frag.frag");

pub const Ssao = struct {
    fbo: gl.uint = 0,
    texture: gl.uint = 0,
    blur_fbo: gl.uint = 0,
    blur_texture: gl.uint = 0,
    ao_shader: Shader,
    blur_shader: Shader,
    vao: gl.uint = 0,
    width: i32 = 0,
    height: i32 = 0,
    query: gl.uint = 0,
    last_ms: f32 = 0,
    enabled: bool = true,
    radius: f32 = 1.6,
    bias: f32 = 0.03,
    power: f32 = 1.4,
    strength: f32 = 0.85,

    pub fn init(width: i32, height: i32) !Ssao {
        var ao_shader = try Shader.init(AO_VERT, AO_FRAG);
        errdefer ao_shader.deinit();
        var blur_shader = try Shader.init(AO_VERT, BLUR_FRAG);
        errdefer blur_shader.deinit();

        var vao: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));

        var query: gl.uint = 0;
        gl.GenQueries(1, @ptrCast(&query));

        var ssao = Ssao{
            .ao_shader = ao_shader,
            .blur_shader = blur_shader,
            .vao = vao,
            .query = query,
            .width = @divTrunc(width, 2),
            .height = @divTrunc(height, 2),
        };
        try ssao.createTargets();
        return ssao;
    }

    fn makeTarget(texture: *gl.uint, fbo: *gl.uint, w: i32, h: i32) !void {
        gl.GenTextures(1, @ptrCast(texture));
        gl.BindTexture(gl.TEXTURE_2D, texture.*);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));

        gl.GenFramebuffers(1, @ptrCast(fbo));
        gl.BindFramebuffer(gl.FRAMEBUFFER, fbo.*);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture.*, 0);
        const status = gl.CheckFramebufferStatus(gl.FRAMEBUFFER);
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            std.debug.print("ssao framebuffer incomplete: 0x{x}\n", .{status});
            return error.FramebufferIncomplete;
        }
    }

    fn createTargets(self: *Ssao) !void {
        try makeTarget(&self.texture, &self.fbo, self.width, self.height);
        try makeTarget(&self.blur_texture, &self.blur_fbo, self.width, self.height);
    }

    pub fn deinit(self: *Ssao) void {
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
        if (self.fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
        if (self.blur_fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.blur_fbo));
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        if (self.blur_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.blur_texture));
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.ao_shader.deinit();
        self.blur_shader.deinit();
    }

    pub fn resize(self: *Ssao, width: i32, height: i32) !void {
        const w = @max(1, @divTrunc(width, 2));
        const h = @max(1, @divTrunc(height, 2));
        if (w == self.width and h == self.height) return;
        self.width = w;
        self.height = h;
        if (self.fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
        if (self.blur_fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.blur_fbo));
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        if (self.blur_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.blur_texture));
        try self.createTargets();
    }

    /// Runs the AO pass and the blur. Leaves the blurred AO in `blur_texture`.
    pub fn render(self: *Ssao, depth_texture: gl.uint, projection: Mat4, inv_projection: Mat4, near: f32, far: f32, full_width: i32, full_height: i32) void {
        if (!self.enabled) return;
        const w: f32 = @floatFromInt(full_width);
        const h: f32 = @floatFromInt(full_height);

        gl.Disable(gl.DEPTH_TEST);
        gl.DepthMask(gl.FALSE);
        gl.BindVertexArray(self.vao);
        if (self.query != 0) gl.BeginQuery(gl.TIME_ELAPSED, self.query);

        // 1. occlusion
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.Viewport(0, 0, self.width, self.height);
        self.ao_shader.use();
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, depth_texture);
        self.ao_shader.setInt("u_depth", 0);
        self.ao_shader.setMat4("u_projection", projection.m);
        self.ao_shader.setMat4("u_inv_projection", inv_projection.m);
        self.ao_shader.setFloat2("u_texel", .{ 1.0 / w, 1.0 / h });
        self.ao_shader.setFloat("u_radius", self.radius);
        self.ao_shader.setFloat("u_bias", self.bias);
        self.ao_shader.setFloat("u_power", self.power);
        self.ao_shader.setFloat("u_near", near);
        self.ao_shader.setFloat("u_far", far);
        gl.DrawArrays(gl.TRIANGLES, 0, 3);

        // 2. blur
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.blur_fbo);
        gl.Viewport(0, 0, self.width, self.height);
        self.blur_shader.use();
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
        self.blur_shader.setInt("u_source", 0);
        self.blur_shader.setFloat2("u_texel", .{ 1.0 / @as(f32, @floatFromInt(self.width)), 1.0 / @as(f32, @floatFromInt(self.height)) });
        gl.DrawArrays(gl.TRIANGLES, 0, 3);

        if (self.query != 0) {
            gl.EndQuery(gl.TIME_ELAPSED);
            var nanoseconds = [_]u64{0};
            gl.GetQueryObjectui64v(self.query, gl.QUERY_RESULT, &nanoseconds);
            self.last_ms = @as(f32, @floatFromInt(nanoseconds[0])) / 1_000_000.0;
        }

        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
    }
};
