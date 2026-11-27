//! Instanced ground cover (ADR 0024, 10.3/10.4): one 7-vertex triangle strip per blade generated
//! in the vertex shader from `gl_VertexID`, wind and distance thinning in the shader. Opaque, no
//! alpha, no sorting.

const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const Blade = @import("../world/scatter.zig").Blade;

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec4 a_misc; // yaw, scale, tint, kind
    \\uniform mat4 u_view_proj;
    \\uniform vec3 u_eye;
    \\uniform float u_time;
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
    \\    float h = (kind > 0.5 ? 0.08 : 0.14) + (kind > 0.5 ? 0.14 : 0.40) * scale;
    \\    float w = kind > 0.5 ? 0.014 : 0.020;
    \\    float near = smoothstep(0.15, 1.40, length(a_pos.xz - u_eye.xz));
    \\    h *= mix(0.30, 1.0, near);
    \\
    \\    // Hash thinning: full density near, gone by 95 m. Stable per instance, so no flicker.
    \\    float dist = length(a_pos.xz - u_eye.xz);
    \\    float keep = 1.0 - smoothstep(35.0, 85.0, dist);
    \\    float r = hash11(float(gl_InstanceID) * 0.731 + tint * 17.0);
    \\    if (r > keep) {
    \\        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    \\        return;
    \\    }
    \\
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
    \\    float taper = 1.0 - t * 0.92;
    \\    vec3 local = vec3(side * w * taper, t * h, 0.0);
    \\    float c = cos(yaw);
    \\    float s = sin(yaw);
    \\    vec3 world = a_pos + vec3(local.x * c - local.z * s, local.y, local.x * s + local.z * c);
    \\
    \\    float phase = a_pos.x * 0.35 + a_pos.z * 0.27 + tint * 6.2831;
    \\    float sway = sin(u_time * 1.7 + phase) * 0.5 + sin(u_time * 2.9 + phase * 1.7) * 0.2;
    \\    float bend = sway * 0.16 * t * t * (kind > 0.5 ? 1.4 : 1.0);
    \\    world.x += bend;
    \\    world.z += bend * 0.35;
    \\
    \\    v_world = world;
    \\    vec3 n_local = normalize(vec3(side * 0.25, 0.70, 0.66));
    \\    v_nrm = vec3(n_local.x * c - n_local.z * s, n_local.y, n_local.x * s + n_local.z * c);
    \\
    \\    vec3 base = kind > 0.5
    \\        ? mix(vec3(0.55, 0.50, 0.38), vec3(0.78, 0.45, 0.52), tint)
    \\        : mix(vec3(0.05, 0.14, 0.03), vec3(0.22, 0.36, 0.09), tint);
    \\    vec3 tipc = kind > 0.5
    \\        ? vec3(0.92, 0.86, 0.74)
    \\        : mix(vec3(0.18, 0.38, 0.08), vec3(0.42, 0.52, 0.16), tint);
    \\    v_col = mix(base, tipc, t * (kind > 0.5 ? 1.0 : 0.85));
    \\
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
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\out vec4 frag;
    \\void main() {
    \\    vec3 n = normalize(v_nrm);
    \\    if (!gl_FrontFacing) n = -n;
    \\    float ndl = max(dot(n, u_sun_dir), 0.0);
    \\    float back = max(-dot(n, u_sun_dir), 0.0) * 0.22;
    \\    vec3 c = v_col * (0.45 + ndl * 0.80 + back) * 0.20;
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

/// Owns the blade program and the instance buffer. One draw for grass + flowers.
pub const GrassRenderer = struct {
    shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,
    count: usize = 0,

    pub fn init() !GrassRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        return .{ .shader = shader };
    }

    pub fn deinit(self: *GrassRenderer) void {
        if (self.vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
            gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        }
        self.shader.deinit();
    }

    pub fn upload(self: *GrassRenderer, blades: []const Blade) void {
        self.count = blades.len;
        if (self.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
            gl.BindVertexArray(self.vao);
            gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
            gl.EnableVertexAttribArray(0);
            gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Blade), 0);
            gl.VertexAttribDivisor(0, 1);
            gl.EnableVertexAttribArray(1);
            gl.VertexAttribPointer(1, 4, gl.FLOAT, gl.FALSE, @sizeOf(Blade), @sizeOf([3]f32));
            gl.VertexAttribDivisor(1, 1);
            gl.BindVertexArray(0);
        }
        if (blades.len == 0) return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(blades.len * @sizeOf(Blade)), blades.ptr, gl.STATIC_DRAW);
    }

    pub fn draw(
        self: *GrassRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
    ) void {
        if (self.vao == 0 or self.count == 0) return;
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_time", time);
        gl.BindVertexArray(self.vao);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 7, @intCast(self.count));
    }
};
