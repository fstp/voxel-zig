const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;

/// Sun shadow map (3.8).
///
/// A single orthographic depth map fitted to the loaded area around the player,
/// rendered with a depth-only shader over the same chunk VAOs the main pass uses.
/// The light-space origin is snapped to texel increments, which is what stops the
/// shadow edges crawling while the player walks.
///
/// Sampling lives in the chunk shader (3x3 PCF with a normal offset); this file
/// only produces the map and the matrix to read it with.
const VERT_SRC: [:0]const u8 = @embedFile("../shaders/shadow_vert.vert");

/// Depth only: the FBO has no colour attachment, so there is nothing to write.
const FRAG_SRC: [:0]const u8 = @embedFile("../shaders/shadow_frag.frag");

pub const ShadowRenderer = struct {
    fbo: gl.uint = 0,
    texture: gl.uint = 0,
    shader: Shader,
    size: i32 = 2048,
    /// Half extent of the orthographic box, in blocks. Load radius 6 = 192, plus
    /// margin so the corners of the area are inside the map.
    half_extent: f32 = 230.0,
    distance: f32 = 420.0,
    light_vp: Mat4 = Mat4.identity,
    query: gl.uint = 0,
    /// Milliseconds the shadow pass took on the GPU last frame.
    last_ms: f32 = 0,

    pub fn init() !ShadowRenderer {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var size: i32 = 2048;
        var renderer = ShadowRenderer{ .shader = shader, .size = size };

        gl.GenTextures(1, @ptrCast(&renderer.texture));
        gl.BindTexture(gl.TEXTURE_2D, renderer.texture);
        gl.TexImage2D(
            gl.TEXTURE_2D,
            0,
            gl.DEPTH_COMPONENT24,
            size,
            size,
            0,
            gl.DEPTH_COMPONENT,
            gl.FLOAT,
            null,
        );
        // NEAREST: the shader does its own PCF, so filtering here would fight it.
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        gl.GenQueries(1, @ptrCast(&renderer.query));
        gl.GenFramebuffers(1, @ptrCast(&renderer.fbo));
        gl.BindFramebuffer(gl.FRAMEBUFFER, renderer.fbo);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, renderer.texture, 0);
        gl.DrawBuffer(gl.NONE);
        gl.ReadBuffer(gl.NONE);
        const status = gl.CheckFramebufferStatus(gl.FRAMEBUFFER);
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            std.debug.print("shadow map framebuffer incomplete: 0x{x}\n", .{status});
            return error.FramebufferIncomplete;
        }
        _ = &size;
        return renderer;
    }

    pub fn deinit(self: *ShadowRenderer) void {
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
        if (self.fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        self.shader.deinit();
    }

    pub fn texelSize(self: ShadowRenderer) f32 {
        return (2.0 * self.half_extent) / @as(f32, @floatFromInt(self.size));
    }

    /// Fits the map around `centre`, snaps it to texels, and binds it for drawing.
    pub fn begin(self: *ShadowRenderer, centre: Vec3, sun_dir: Vec3) void {
        const up: Vec3 = if (@abs(sun_dir.y) > 0.99) .{ .x = 0, .y = 0, .z = 1 } else .{ .x = 0, .y = 1, .z = 0 };
        const eye = centre.add(sun_dir.scale(self.distance));

        const view = Mat4.lookAt(eye, centre, up);
        // Snap the centre to whole texels in light space, or shadow edges crawl
        // as the player walks. Round trip through the view keeps the maths local.
        const texel = self.texelSize();
        const centre_view = view.transformPoint(centre);
        const snapped_view = Vec3.init(
            @floor(centre_view.x / texel) * texel,
            @floor(centre_view.y / texel) * texel,
            centre_view.z,
        );
        const view_inverse = view.inverse() orelse view;
        const snapped_centre = view_inverse.transformPoint(snapped_view);

        const light_view = Mat4.lookAt(eye.add(snapped_centre.sub(centre)), snapped_centre, up);
        const ortho = Mat4.ortho(
            -self.half_extent,
            self.half_extent,
            -self.half_extent,
            self.half_extent,
            1.0,
            self.distance * 2.0,
        );
        self.light_vp = ortho.mul(light_view);

        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.Viewport(0, 0, self.size, self.size);
        if (self.query != 0) gl.BeginQuery(gl.TIME_ELAPSED, self.query);
        gl.Clear(gl.DEPTH_BUFFER_BIT);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        // Front faces culled: with the light behind the terrain, back faces are
        // what a shadow caster needs, and this halves the acne.
        gl.Enable(gl.CULL_FACE);
        gl.CullFace(gl.FRONT);

        self.shader.use();
        self.shader.setMat4("u_light_vp", self.light_vp.m);
    }

    pub fn drawMesh(self: *ShadowRenderer, vao: gl.uint, index_count: u32, origin: Vec3) void {
        if (index_count == 0) return;
        self.shader.setMat4("u_model", Mat4.translate(origin).m);
        gl.BindVertexArray(vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(index_count), gl.UNSIGNED_INT, 0);
    }

    /// Back to the default framebuffer and the cull direction the world expects.
    pub fn end(self: *ShadowRenderer, width: i32, height: i32) void {
        if (self.query != 0) {
            gl.EndQuery(gl.TIME_ELAPSED);
            var nanoseconds = [_]u64{0};
            gl.GetQueryObjectui64v(self.query, gl.QUERY_RESULT, &nanoseconds);
            self.last_ms = @as(f32, @floatFromInt(nanoseconds[0])) / 1_000_000.0;
        }
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.Viewport(0, 0, width, height);
        gl.CullFace(gl.BACK);
    }

    /// Texture unit 1 carries the map, so unit 0 stays the block texture array.
    pub fn bind(self: ShadowRenderer, unit: u32) void {
        gl.ActiveTexture(gl.TEXTURE0 + unit);
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
    }
};
