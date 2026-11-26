const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Vec3 = @import("../math/vec.zig").Vec3;

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\// Fullscreen triangle from gl_VertexID, no vertex buffer - the same trick
    \\// the sky pass uses.
    \\out vec2 v_uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    v_uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2D u_hdr;
    \\uniform sampler2D u_ao;      // blurred SSAO, unit 1 (4.9)
    \\uniform float u_ao_strength;
    \\uniform float u_ao_enabled;
    \\uniform float u_exposure;
    \\uniform float u_tonemap; // 0 = clip only, 1 = ACES (F11 A/B)
    \\uniform vec2 u_texel;    // one pixel in uv
    \\uniform float u_fxaa;    // 0 off, 1 on (F13)
    \\in vec2 v_uv;
    \\out vec4 f_colour;
    \\
    \\// ACES fitted (Narkowicz). A filmic curve with a shoulder: values above 1
    \\// roll off toward white instead of clipping to flat colour, which is what
    \\// made the old pipeline read as "too bright" wherever the sun landed.
    \\vec3 aces(vec3 x) {
    \\    const float a = 2.51;
    \\    const float b = 0.03;
    \\    const float c = 2.43;
    \\    const float d = 0.59;
    \\    const float e = 0.14;
    \\    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    \\}
    \\
    \\// The full resolve for one uv: AO, exposure, curve. FXAA needs the final
    \\// colour at neighbouring pixels, so it has to be a function.
    \\vec3 scene(vec2 uv) {
    \\    vec3 hdr = texture(u_hdr, uv).rgb;
    \\    if (u_ao_enabled > 0.5) {
    \\        float ao = texture(u_ao, uv).r;
    \\        hdr *= mix(1.0, ao, u_ao_strength);
    \\    }
    \\    hdr *= u_exposure;
    \\    return mix(clamp(hdr, 0.0, 1.0), aces(hdr), u_tonemap);
    \\}
    \\
    \\vec3 toSrgb(vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }
    \\float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
    \\
    \\// FXAA, edge-direction variant. Cheaper and blunter than SMAA or MSAA, and it
    \\// is the only one that costs nothing in the pipeline: no multisample target, no
    \\// history buffer, one extra pass over the pixels the resolve already touched.
    \\vec3 fxaa() {
    \\    // Work in perceptual space: FXAA's thresholds mean nothing in linear light.
    \\    vec3 m = toSrgb(scene(v_uv));
    \\    vec3 nw = toSrgb(scene(v_uv + vec2(-1.0, -1.0) * u_texel));
    \\    vec3 ne = toSrgb(scene(v_uv + vec2( 1.0, -1.0) * u_texel));
    \\    vec3 sw = toSrgb(scene(v_uv + vec2(-1.0,  1.0) * u_texel));
    \\    vec3 se = toSrgb(scene(v_uv + vec2( 1.0,  1.0) * u_texel));
    \\
    \\    float lNW = luma(nw), lNE = luma(ne), lSW = luma(sw), lSE = luma(se), lM = luma(m);
    \\    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    \\    float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    \\    // Flat area: nothing to do, which is most of the screen.
    \\    if (lMax - lMin < max(0.0312, lMax * 0.125)) return m;
    \\
    \\    vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)), ((lNW + lSW) - (lNE + lSE)));
    \\    float reduce = max((lNW + lNE + lSW + lSE) * 0.03125, 0.0078125);
    \\    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), vec2(-8.0), vec2(8.0));
    \\    vec3 a = toSrgb(scene(v_uv + dir * u_texel * (1.0 / 8.0)));
    \\    vec3 b = toSrgb(scene(v_uv + dir * u_texel * (2.0 / 8.0)));
    \\    vec3 blended = (a + b) * 0.5;
    \\    return pow(mix(m, blended, 0.75), vec3(2.2));   // back to linear for the write
    \\}
    \\
    \\void main() {
    \\    if (u_fxaa > 0.5) {
    \\        f_colour = vec4(fxaa(), 1.0);
    \\        return;
    \\    }
    \\    vec3 hdr = texture(u_hdr, v_uv).rgb;
    \\    // 4.9: ambient occlusion, applied in linear light before exposure. It
    \\    // multiplies everything rather than just the ambient term, which is the
    \\    // standard screen-space approximation and the reason the strength is a
    \\    // knob rather than 1.0.
    \\    if (u_ao_enabled > 0.5) {
    \\        float ao = texture(u_ao, v_uv).r;
    \\        hdr *= mix(1.0, ao, u_ao_strength);
    \\    }
    \\    hdr *= u_exposure;
    \\    vec3 mapped = mix(clamp(hdr, 0.0, 1.0), aces(hdr), u_tonemap);
    \\    // Linear out: the default framebuffer has GL_FRAMEBUFFER_SRGB, so the
    \\    // hardware applies the transfer function (ADR 0008).
    \\    f_colour = vec4(mapped, 1.0);
    \\}
;

/// HDR render target and the tone-map pass that resolves it to the window.
///
/// Why this exists (4.1): the scene used to be shaded straight into an sRGB
/// framebuffer, so every value above 1.0 was clipped and there was nowhere to
/// put an exposure control. Rendering linear light into RGBA16F, then applying
/// exposure and a filmic curve on the way to the window, is what makes bright
/// surfaces roll off instead of blowing out.
pub const Post = struct {
    fbo: gl.uint = 0,
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
    fxaa: bool = true,
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
    }

    fn destroyTargets(self: *Post) void {
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
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.Viewport(0, 0, self.width, self.height);
        gl.ClearColor(clear.x, clear.y, clear.z, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
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
