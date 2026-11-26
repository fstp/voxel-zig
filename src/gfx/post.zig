const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Vec3 = @import("../math/vec.zig").Vec3;

const VERT_SRC: [:0]const u8 = @embedFile("../shaders/post_vert.vert");

const FRAG_SRC: [:0]const u8 = @embedFile("../shaders/post_frag.frag");

/// HDR render target and the tone-map pass that resolves it to the window.
///
/// Why this exists (4.1): the scene used to be shaded straight into an sRGB
/// framebuffer, so every value above 1.0 was clipped and there was nowhere to
/// put an exposure control. Rendering linear light into RGBA16F, then applying
/// exposure and a filmic curve on the way to the window, is what makes bright
/// surfaces roll off instead of blowing out.
pub const Post = struct {
    /// The resolve target: single-sample colour and depth, which the tone map and
    /// SSAO read. The scene is drawn into `msaa_fbo` and blitted here.
    fbo: gl.uint = 0,
    /// Multisample scene target (5.3).
    msaa_fbo: gl.uint = 0,
    msaa_colour: gl.uint = 0,
    msaa_depth: gl.uint = 0,
    samples: i32 = 4,
    colour: gl.uint = 0,
    /// Depth as a texture rather than a renderbuffer, so SSAO can read it.
    depth: gl.uint = 0,
    /// Set by the app each frame: the blurred AO and how much of it to apply.
    ao_texture: gl.uint = 0,
    ao_strength: f32 = 0.85,
    ao_enabled: bool = true,
    shader: Shader,
    vao: gl.uint = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Exposure the player sets, before eye adaptation. 1.0 is the value the
    /// light rig was tuned around; less is darker.
    /// Raised from 0.62 when albedo started being uploaded as sRGB (4.7): the
    /// textures had been shaded as if their bytes were linear, which is about
    /// 2.3x too bright for a mid tone, and the old value was tuned against that.
    exposure_base: f32 = 1.45,
    /// Effective exposure used by the resolve: `exposure_base` times the night
    /// adaptation written each frame by the app.
    exposure: f32 = 0.62,
    tonemap: bool = true,
    /// Kept as a fallback and an A/B; MSAA is the default antialiasing now.
    fxaa: bool = false,
    query: gl.uint = 0,
    /// Milliseconds the resolve took on the GPU last frame.
    last_ms: f32 = 0,

    pub fn init(width: i32, height: i32) !Post {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var vao: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));

        var query: gl.uint = 0;
        gl.GenQueries(1, @ptrCast(&query));

        var post = Post{
            .shader = shader,
            .vao = vao,
            .query = query,
            .width = width,
            .height = height,
        };
        try post.createTargets();
        return post;
    }

    fn createMsaaTargets(self: *Post) !void {
        gl.GenTextures(1, @ptrCast(&self.msaa_colour));
        gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.msaa_colour);
        gl.TexImage2DMultisample(gl.TEXTURE_2D_MULTISAMPLE, self.samples, gl.RGBA16F, self.width, self.height, 1);

        gl.GenTextures(1, @ptrCast(&self.msaa_depth));
        gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.msaa_depth);
        gl.TexImage2DMultisample(gl.TEXTURE_2D_MULTISAMPLE, self.samples, gl.DEPTH_COMPONENT24, self.width, self.height, 1);

        gl.GenFramebuffers(1, @ptrCast(&self.msaa_fbo));
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.msaa_fbo);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D_MULTISAMPLE, self.msaa_colour, 0);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D_MULTISAMPLE, self.msaa_depth, 0);
        const status = gl.CheckFramebufferStatus(gl.FRAMEBUFFER);
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            std.debug.print("msaa framebuffer incomplete: 0x{x}\n", .{status});
            return error.FramebufferIncomplete;
        }
    }

    fn createTargets(self: *Post) !void {
        gl.GenTextures(1, @ptrCast(&self.colour));
        gl.BindTexture(gl.TEXTURE_2D, self.colour);
        gl.TexImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA16F,
            self.width,
            self.height,
            0,
            gl.RGBA,
            gl.FLOAT,
            null,
        );
        // LINEAR: the resolve samples texel centres 1:1, but resizing the window
        // can leave a fractional texel and NEAREST would show it as a seam.
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        gl.GenTextures(1, @ptrCast(&self.depth));
        gl.BindTexture(gl.TEXTURE_2D, self.depth);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, self.width, self.height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, null);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.NEAREST));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.NEAREST));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));

        gl.GenFramebuffers(1, @ptrCast(&self.fbo));
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.colour, 0);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, self.depth, 0);

        const status = gl.CheckFramebufferStatus(gl.FRAMEBUFFER);
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            std.debug.print("hdr framebuffer incomplete: 0x{x}\n", .{status});
            return error.FramebufferIncomplete;
        }
        try self.createMsaaTargets();
    }

    fn destroyTargets(self: *Post) void {
        if (self.msaa_fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.msaa_fbo));
        if (self.msaa_colour != 0) gl.DeleteTextures(1, @ptrCast(&self.msaa_colour));
        if (self.msaa_depth != 0) gl.DeleteTextures(1, @ptrCast(&self.msaa_depth));
        self.msaa_fbo = 0;
        self.msaa_colour = 0;
        self.msaa_depth = 0;
        if (self.fbo != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.fbo));
        if (self.colour != 0) gl.DeleteTextures(1, @ptrCast(&self.colour));
        if (self.depth != 0) gl.DeleteTextures(1, @ptrCast(&self.depth));
        self.fbo = 0;
        self.colour = 0;
        self.depth = 0;
    }

    pub fn deinit(self: *Post) void {
        if (self.query != 0) gl.DeleteQueries(1, @ptrCast(&self.query));
        self.destroyTargets();
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    pub fn resize(self: *Post, width: i32, height: i32) !void {
        if (width == self.width and height == self.height) return;
        self.width = width;
        self.height = height;
        self.destroyTargets();
        try self.createTargets();
    }

    /// Bind the HDR target and clear it to `clear` (linear).
    pub fn begin(self: *Post, clear: Vec3) void {
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.msaa_fbo);
        gl.Viewport(0, 0, self.width, self.height);
        gl.ClearColor(clear.x, clear.y, clear.z, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    }

    /// Blit the multisample scene into the single-sample textures. Split out of
    /// `end` because SSAO reads the resolved depth and runs before the tone map.
    pub fn resolve(self: *Post) void {
        gl.BindFramebuffer(gl.READ_FRAMEBUFFER, self.msaa_fbo);
        gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, self.fbo);
        gl.BlitFramebuffer(
            0, 0, self.width, self.height,
            0, 0, self.width, self.height,
            gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT,
            gl.NEAREST,
        );
        gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0);
        gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0);
    }

    /// Resolve to the window. `width`/`height` are the drawable size, which can
    /// differ from the target while a resize is in flight.
    pub fn end(self: *Post, width: i32, height: i32) void {
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.Viewport(0, 0, width, height);

        gl.Disable(gl.DEPTH_TEST);
        gl.DepthMask(gl.FALSE);
        gl.Disable(gl.CULL_FACE);

        self.shader.use();
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.colour);
        self.shader.setInt("u_hdr", 0);
        gl.ActiveTexture(gl.TEXTURE1);
        gl.BindTexture(gl.TEXTURE_2D, self.ao_texture);
        self.shader.setInt("u_ao", 1);
        self.shader.setFloat("u_ao_strength", self.ao_strength);
        self.shader.setFloat("u_ao_enabled", if (self.ao_enabled and self.ao_texture != 0) 1.0 else 0.0);
        self.shader.setFloat("u_exposure", self.exposure);
        self.shader.setFloat("u_tonemap", if (self.tonemap) 1.0 else 0.0);
        self.shader.setFloat2("u_texel", .{ 1.0 / @as(f32, @floatFromInt(@max(self.width, 1))), 1.0 / @as(f32, @floatFromInt(@max(self.height, 1))) });
        self.shader.setFloat("u_fxaa", if (self.fxaa) 1.0 else 0.0);

        if (self.query != 0) gl.BeginQuery(gl.TIME_ELAPSED, self.query);
        gl.BindVertexArray(self.vao);
        gl.DrawArrays(gl.TRIANGLES, 0, 3);
        if (self.query != 0) {
            gl.EndQuery(gl.TIME_ELAPSED);
            var nanoseconds = [_]u64{0};
            gl.GetQueryObjectui64v(self.query, gl.QUERY_RESULT, &nanoseconds);
            self.last_ms = @as(f32, @floatFromInt(nanoseconds[0])) / 1_000_000.0;
        }

        // Leave the state the 2D passes (HUD, crosshair) expect.
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
    }
};
