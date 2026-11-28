//! Instanced ground cover (ADR 0024, 10.3/10.4): one 7-vertex triangle strip per blade generated
//! in the vertex shader from `gl_VertexID`, wind and distance thinning in the shader. Opaque, no
//! alpha, no sorting.

const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const Blade = @import("../world/scatter.zig").Blade;
const ShadowRenderer = @import("shadow_renderer.zig").ShadowRenderer;

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec4 a_misc; // yaw, scale, tint, kind
    \\uniform mat4 u_view_proj;
    \\uniform vec3 u_eye;
    \\uniform float u_time;
    \\uniform float u_anim_cutoff;
    \\uniform float u_active_radius;   // ADR 0039: the stream drops blades past this, so the field fades by then
    \\uniform float u_active_fade;
    \\uniform vec2 u_field_centre;
    \\uniform float u_anim_fade;
    \\out vec3 v_col;
    \\out vec3 v_nrm;
    \\out vec3 v_world;
    \\float hash11(float p) {
    \\    p = fract(p * 0.1031);
    \\    p *= p + 33.33;
    \\    p *= p + p;
    \\    return fract(p);
    \\}
    \\void main() {
    \\    float yaw = a_misc.x;
    \\    float scale = a_misc.y;
    \\    float tint = a_misc.z;
    \\    float kind = a_misc.w;
    \\    bool is_flower = kind > 0.5 && kind < 1.5;
    \\    bool is_bush = kind >= 1.5 && kind < 2.5;
    \\    bool is_fern = kind >= 2.5;
    \\    float length_hash = hash11(a_pos.x * 0.917 + a_pos.z * 0.431 + yaw * 2.13);
    \\    float patch_tone = hash11(floor(a_pos.x / 3.2) * 0.731 + floor(a_pos.z / 3.2) * 1.917);
    \\    float strand_tone = hash11(a_pos.x * 0.371 + a_pos.z * 0.613 + yaw * 1.91);
    \\    float tone = mix(patch_tone, strand_tone, 0.35);
    \\    float base_h = 0.14 + 0.40 * scale;
    \\    float w = 0.020;
    \\    if (is_flower) { base_h = 0.35 + 0.35 * scale; w = 0.018; }
    \\    else if (is_bush) { base_h = 0.45 + 0.55 * scale; w = 0.035; }
    \\    else if (is_fern) { base_h = 0.50 + 0.60 * scale; w = 0.014; }
    \\    float h = base_h * (0.70 + 0.60 * length_hash) * 0.85;
    \\    int id = gl_VertexID;
    \\    float t = 0.0;
    \\    float side = 0.0;
    \\    if (id == 0) { t = 0.0; side = -1.0; }
    \\    else if (id == 1) { t = 0.0; side = 1.0; }
    \\    else if (id == 2) { t = 0.5; side = -1.0; }
    \\    else if (id == 3) { t = 0.5; side = 1.0; }
    \\    else if (id == 4) { t = 1.0; side = -1.0; }
    \\    else if (id == 5) { t = 1.0; side = 1.0; }
    \\    else { t = 1.02; side = 0.0; }
    \\
    \\    float taper = is_flower ? (1.0 - t * 0.35) : (1.0 - t * 0.92);
    \\    vec3 local = vec3(side * w * taper, t * h, 0.0);
    \\    float c = cos(yaw);
    \\    float s = sin(yaw);
    \\    vec3 world = a_pos + vec3(local.x * c - local.z * s, local.y, local.x * s + local.z * c);
    \\
    \\    vec2 clump_cell = floor(a_pos.xz / 2.6);
    \\    float clump_phase = fract(dot(clump_cell, vec2(12.9898, 78.233))) * 6.2831;
    \\    float blade_phase = (hash11(a_pos.x * 0.173 + a_pos.z * 0.911 + yaw * 3.17) - 0.5) * 1.2;
    \\    float phase = clump_phase + a_pos.x * 0.03 + a_pos.z * 0.02 + blade_phase;
    \\    float sway = sin(u_time * 1.7 + phase) * 0.5 + sin(u_time * 2.9 + phase * 1.7) * 0.2;
    \\    float anim = 1.0 - smoothstep(u_anim_cutoff - u_anim_fade, u_anim_cutoff, length(a_pos.xz - u_eye.xz));
    \\    float bend = sway * 0.16 * t * t * (kind > 0.5 ? 1.4 : 1.0) * anim;
    \\    world.x += bend;
    \\    world.z += bend * 0.35;
    \\
    \\    v_world = world;
    \\    vec3 n_local = normalize(vec3(side * 0.25, 0.70, 0.66));
    \\    v_nrm = vec3(n_local.x * c - n_local.z * s, n_local.y, n_local.x * s + n_local.z * c);
    \\
    \\    vec3 base = is_flower
    \\        ? mix(vec3(0.30, 0.22, 0.10), vec3(0.60, 0.30, 0.24), tint)
    \\        : mix(vec3(0.04, 0.12, 0.025), vec3(0.16, 0.27, 0.06), tint);
    \\    vec3 tipc = is_flower
    \\        ? mix(vec3(0.96, 0.82, 0.35), vec3(0.96, 0.55, 0.70), tint)
    \\        : mix(vec3(0.13, 0.30, 0.06), vec3(0.36, 0.48, 0.14), tint);
    \\    if (is_bush) {
    \\        base = mix(vec3(0.025, 0.070, 0.020), vec3(0.095, 0.16, 0.045), tint);
    \\        base = mix(base, vec3(0.14, 0.18, 0.05), smoothstep(0.55, 1.0, tone) * 0.30);
    \\        tipc = mix(vec3(0.08, 0.18, 0.04), vec3(0.22, 0.30, 0.08), tint);
    \\    } else if (is_fern) {
    \\        base = mix(vec3(0.045, 0.11, 0.025), vec3(0.15, 0.22, 0.05), tint);
    \\        base = mix(base, vec3(0.16, 0.19, 0.055), smoothstep(0.55, 1.0, tone) * 0.35);
    \\        tipc = mix(vec3(0.12, 0.26, 0.06), vec3(0.32, 0.38, 0.10), tint);
    \\    } else if (!is_flower) {
    \\        // Natural meadow: patch-scale colour plus a little per-strand variation. The
    \\        // palettes are derived from the natural grass ranges #345C1B/#436F21/#597A2E and
    \\        // keep the cool blue-green and dry yellow-green outliers sparse.
    \\        base = mix(base, vec3(0.055, 0.14, 0.07), (1.0 - tint) * tone * 0.50);
    \\        base = mix(base, vec3(0.20, 0.25, 0.08), smoothstep(0.60, 1.0, tone) * 0.45);
    \\        tipc = mix(tipc, vec3(0.27, 0.40, 0.12), tone * 0.35);
    \\    }
    \\    v_col = mix(base, tipc, t * (is_flower ? 1.0 : 0.85));
    \\
    \\    float field = length(a_pos.xz - u_field_centre);
    \\    world.y -= max(field - (u_active_radius - u_active_fade), 0.0) * 0.09;
    \\    gl_Position = u_view_proj * vec4(world, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_col;
    \\in vec3 v_nrm;
    \\in vec3 v_world;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_sun_colour;
    \\uniform vec3 u_ambient_sky;
    \\uniform vec3 u_ambient_ground;
    \\uniform mat4 u_light_vp[2];
    \\uniform sampler2D u_shadow0;
    \\uniform sampler2D u_shadow1;
    \\uniform float u_shadow_enabled;
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\out vec4 frag;
    \\float shadowCascade(mat4 lvp, sampler2D map, vec3 world, vec3 n) {
    \\    vec4 lp = lvp * vec4(world + n * 0.10, 1.0);
    \\    vec3 p = lp.xyz / max(lp.w, 1e-5) * 0.5 + 0.5;
    \\    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    \\    float bias = 0.0015;
    \\    float texel = 1.0 / 2048.0;
    \\    float blocker = 0.0;
    \\    int blocker_count = 0;
    \\    for (int i = 0; i < 8; ++i) {
    \\        float a = float(i) * 0.785398;
    \\        float d = texture(map, p.xy + vec2(cos(a), sin(a)) * texel * 4.0).r;
    \\        if (d < p.z - bias) {
    \\            blocker += d;
    \\            blocker_count += 1;
    \\        }
    \\    }
    \\    if (blocker_count == 0) return 1.0;
    \\    float avg = blocker / float(blocker_count);
    \\    float radius = clamp((p.z - avg) * 120.0, 0.75, 6.0);
    \\    float sum = 0.0;
    \\    for (int y = -2; y <= 2; ++y) {
    \\        for (int x = -2; x <= 2; ++x) {
    \\            float d = texture(map, p.xy + vec2(x, y) * texel * radius * 0.5).r;
    \\            sum += (p.z - bias <= d) ? 1.0 : 0.0;
    \\        }
    \\    }
    \\    return sum / 25.0;
    \\}
    \\float sunShadow(vec3 world, vec3 n) {
    \\    if (u_shadow_enabled < 0.5) return 1.0;
    \\    float d = length(world - u_eye);
    \\    float s0 = shadowCascade(u_light_vp[0], u_shadow0, world, n);
    \\    float s1 = shadowCascade(u_light_vp[1], u_shadow1, world, n);
    \\    return mix(s0, s1, smoothstep(55.0, 75.0, d));
    \\}
    \\void main() {
    \\    vec3 n = normalize(v_nrm);
    \\    if (!gl_FrontFacing) n = -n;
    \\    float ndl = max(dot(n, u_sun_dir), 0.0);
    \\    float back = max(-dot(n, u_sun_dir), 0.0) * 0.22;
    \\    vec3 amb = mix(u_ambient_ground, u_ambient_sky, n.y * 0.5 + 0.5);
    \\    float shadow = sunShadow(v_world, n);
    \\    amb *= mix(0.58, 1.0, shadow);
    \\    vec3 c = v_col * (amb * 2.0 + u_sun_colour * (ndl * 0.80 + back) * shadow) * 0.20;
    \\    c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    \\    vec3 outc = pow(max(c, 0.0), vec3(0.4545));
    \\
    \\    vec3 ray = v_world - u_eye;
    \\    float dist = length(ray);
    \\    float H = max(u_fog_height, 1.0);
    \\    float k = ray.y / H;
    \\    float d0 = u_fog_density * exp(-(u_eye.y - u_fog_base) / H);
    \\    float tau = abs(k) > 1e-4 ? d0 * dist * (1.0 - exp(-k)) / k : d0 * dist;
    \\    float fog = 1.0 - exp(-max(tau, 0.0));
    \\    float sun_amt = pow(max(dot(normalize(ray), u_sun_dir), 0.0), 6.0);
    \\    vec3 fogc = mix(u_fog_colour, u_fog_sun, 0.15 + 0.55 * sun_amt);
    \\    outc = mix(outc, fogc, fog);
    \\    frag = vec4(outc, 1.0);
    \\}
;

const depth_fragment_src: [:0]const u8 =
    \\#version 330 core
    \\void main() {}
;

/// Owns the blade program and the instance buffer. One draw for grass + flowers.
pub const GrassRenderer = struct {
    shader: Shader,
    depth_shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,
    count: usize = 0,
    capacity: usize = 0,
    animation_cutoff: f32 = 95.0,
    /// Blade field extent, mirrored from scatter.ACTIVE_RADIUS: the last cell centre sits at most
    /// this far out, so the fade ends by radius minus half a cell diagonal.
    active_radius: f32 = 96.0,
    active_fade: f32 = 22.0,
    field_centre: [2]f32 = .{ 0, 0 },
    animation_fade: f32 = 15.0,

    pub fn init() !GrassRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        var depth_shader = try Shader.init(vertex_src, depth_fragment_src);
        errdefer depth_shader.deinit();
        return .{ .shader = shader, .depth_shader = depth_shader };
    }

    pub fn deinit(self: *GrassRenderer) void {
        if (self.vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
            gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        }
        self.depth_shader.deinit();
        self.shader.deinit();
    }

    /// Depth-only shadow pass; the same blade vertex shader with an empty fragment shader.
    pub fn drawDepth(self: *GrassRenderer, view_projection: Mat4, eye: Vec3, time: f32) void {
        if (self.vao == 0 or self.count == 0) return;
        self.depth_shader.use();
        self.depth_shader.setMat4("u_view_proj", view_projection.m);
        self.depth_shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.depth_shader.setFloat("u_time", time);
        self.depth_shader.setFloat("u_anim_cutoff", self.animation_cutoff);
        self.depth_shader.setFloat("u_anim_fade", self.animation_fade);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        gl.BindVertexArray(self.vao);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 7, @intCast(self.count));
    }

    /// Allocate the instance buffer for `capacity` blades. Called once at startup and only again
    /// if the stream outgrows it; the contents are undefined until ranges are uploaded.
    pub fn ensureCapacity(self: *GrassRenderer, capacity: usize) void {
        if (self.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
        }
        if (capacity <= self.capacity) return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(capacity * @sizeOf(Blade)), null, gl.DYNAMIC_DRAW);
        self.capacity = capacity;
    }

    /// Copy one partition's blades into its persistent slot. This is the only upload a patch move
    /// performs for the partitions that entered; nothing else is re-sent.
    pub fn uploadRange(self: *GrassRenderer, offset: usize, blades: []const Blade) void {
        if (blades.len == 0) return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferSubData(
            gl.ARRAY_BUFFER,
            @intCast(offset * @sizeOf(Blade)),
            @intCast(blades.len * @sizeOf(Blade)),
            blades.ptr,
        );
    }

    /// Whole-buffer upload, kept for the one-shot startup path and the tests.
    pub fn upload(self: *GrassRenderer, blades: []const Blade) void {
        self.ensureCapacity(blades.len);
        self.count = blades.len;
        self.uploadRange(0, blades);
    }

    fn bindRange(self: *GrassRenderer, offset: usize) void {
        const bytes: usize = offset * @sizeOf(Blade);
        gl.BindVertexArray(self.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Blade), bytes);
        gl.VertexAttribDivisor(0, 1);
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribPointer(1, 4, gl.FLOAT, gl.FALSE, @sizeOf(Blade), bytes + @sizeOf([3]f32));
        gl.VertexAttribDivisor(1, 1);
        gl.BindVertexArray(0);
    }

    pub fn draw(
        self: *GrassRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        sun_colour: Vec3,
        ambient_sky: Vec3,
        ambient_ground: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
        shadow: *ShadowRenderer,
    ) void {
        self.drawRange(view_projection, eye, sun_dir, sun_colour, ambient_sky, ambient_ground, fog_colour, fog_sun, fog_density, fog_height, fog_base, time, shadow, 0, self.count);
    }

    /// Draw one partition slot: `offset` and `count` are in instances, not bytes.
    pub fn drawRange(
        self: *GrassRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        sun_colour: Vec3,
        ambient_sky: Vec3,
        ambient_ground: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
        shadow: *ShadowRenderer,
        offset: usize,
        count: usize,
    ) void {
        if (self.vao == 0 or count == 0) return;
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_sun_colour", .{ sun_colour.x, sun_colour.y, sun_colour.z });
        self.shader.setVec3("u_ambient_sky", .{ ambient_sky.x, ambient_sky.y, ambient_sky.z });
        self.shader.setVec3("u_ambient_ground", .{ ambient_ground.x, ambient_ground.y, ambient_ground.z });
        shadow.setUniforms(&self.shader);
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_time", time);
        self.shader.setFloat("u_anim_cutoff", self.animation_cutoff);
        self.shader.setFloat("u_anim_fade", self.animation_fade);
        self.bindRange(offset);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 7, @intCast(count));
    }
};
