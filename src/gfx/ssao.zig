const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;

const AO_VERT: [:0]const u8 =
    \\#version 460 core
    \\out vec2 v_uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    v_uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

/// Screen-space ambient occlusion from depth alone (4.9).
///
/// Depth only, no G-buffer: the view-space normal is rebuilt from the gradients of
/// the reconstructed position. On flat voxel faces that is exact, and at silhouette
/// edges the reconstruction is wrong in a way that reads as a soft corner rather
/// than an artefact, because the blur pass runs after it.
const AO_FRAG: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2D u_depth;
    \\uniform mat4 u_projection;
    \\uniform mat4 u_inv_projection;
    \\uniform vec2 u_texel;      // size of one AO pixel in uv units
    \\uniform float u_radius;    // in view-space units (blocks)
    \\uniform float u_bias;
    \\uniform float u_power;     // contrast curve
    \\uniform float u_near;
    \\uniform float u_far;
    \\in vec2 v_uv;
    \\out vec4 f_colour;
    \\
    \\const int SAMPLES = 12;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\
    \\// Depth buffer to view-space position. The projection is the engine's own, so
    \\// this stays correct if the near plane ever moves.
    \\vec3 viewPosition(vec2 uv, float depth) {
    \\    vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    \\    vec4 view = u_inv_projection * clip;
    \\    return view.xyz / view.w;
    \\}
    \\
    \\void main() {
    \\    float depth = texture(u_depth, v_uv).r;
    \\    if (depth >= 1.0) {              // sky: nothing to occlude
    \\        f_colour = vec4(1.0);
    \\        return;
    \\    }
    \\    vec3 position = viewPosition(v_uv, depth);
    \\
    \\    // Normal from the depth gradients. Cheap and stable on the flat faces this
    \\    // world is made of.
    \\    vec3 right = viewPosition(v_uv + vec2(u_texel.x, 0.0), texture(u_depth, v_uv + vec2(u_texel.x, 0.0)).r);
    \\    vec3 up = viewPosition(v_uv + vec2(0.0, u_texel.y), texture(u_depth, v_uv + vec2(0.0, u_texel.y)).r);
    \\    // View space looks down -Z, so cross(up, right) points away from the eye.
    \\    // Negating makes the hemisphere face the camera, which is the difference
    \\    // between contact shadow and an evenly grey frame.
    \\    vec3 normal = normalize(cross(right - position, up - position));
    \\
    \\    // A per-pixel rotation, hashed from the fragment coordinate, turns twelve
    \\    // samples into a much denser-looking pattern than twelve fixed directions.
    \\    float angle = hash12(gl_FragCoord.xy) * 6.2831853;
    \\    float ca = cos(angle), sa = sin(angle);
    \\    mat2 rot = mat2(ca, -sa, sa, ca);
    \\
    \\    float occlusion = 0.0;
    \\    for (int i = 0; i < SAMPLES; ++i) {
    \\        // A spiral on the sphere: cheap, evenly spread, no kernel buffer.
    \\        float fi = float(i) + 0.5;
    \\        float phi = fi * 2.39996323;          // golden angle
    \\        float z = 1.0 - fi / float(SAMPLES);  // hemisphere, biased to the normal
    \\        float r = sqrt(max(0.0, 1.0 - z * z));
    \\        vec3 dir = vec3(cos(phi) * r, sin(phi) * r, z);
    \\        dir.xy = rot * dir.xy;
    \\        // Build the tangent frame around the normal.
    \\        vec3 tangent = normalize(abs(normal.z) < 0.9 ? cross(normal, vec3(0, 0, 1)) : cross(normal, vec3(1, 0, 0)));
    \\        vec3 bitangent = cross(normal, tangent);
    \\        vec3 sample_pos = position + (tangent * dir.x + bitangent * dir.y + normal * dir.z) * u_radius;
    \\
    \\        vec4 offset = u_projection * vec4(sample_pos, 1.0);
    \\        vec2 sample_uv = offset.xy / offset.w * 0.5 + 0.5;
    \\        if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;
    \\
    \\        float scene_depth = texture(u_depth, sample_uv).r;
    \\        vec3 scene_pos = viewPosition(sample_uv, scene_depth);
    \\        // Occluded when the scene is closer to the eye than the sample, by more
    \\        // than the bias, and only within this sample's own reach.
    \\        float range = smoothstep(0.0, 1.0, u_radius / max(abs(position.z - scene_pos.z), 1e-4));
    \\        occlusion += (scene_pos.z > sample_pos.z + u_bias) ? range : 0.0;
    \\    }
    \\    float ao = 1.0 - occlusion / float(SAMPLES);
    \\    f_colour = vec4(vec3(pow(clamp(ao, 0.0, 1.0), u_power)), 1.0);
    \\}
;

/// 4x4 box blur. One pass at half resolution is enough because the AO itself is
/// noise-rotated; a separable gaussian would be more pixels for no visible gain.
const BLUR_FRAG: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2D u_source;
    \\uniform vec2 u_texel;
    \\in vec2 v_uv;
    \\out vec4 f_colour;
    \\void main() {
    \\    float sum = 0.0;
    \\    for (int y = -2; y < 2; ++y) {
    \\        for (int x = -2; x < 2; ++x) {
    \\            sum += texture(u_source, v_uv + vec2(float(x), float(y)) * u_texel).r;
    \\        }
    \\    }
    \\    f_colour = vec4(vec3(sum / 16.0), 1.0);
    \\}
;

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
