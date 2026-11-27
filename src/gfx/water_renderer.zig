//! Sea surface for the DC world: a patch-sized grid whose vertices carry the water depth, so the
//! fragment shader can fade from shallow teal to deep blue, raise alpha with depth and draw a
//! shoreline foam band (9.2). Depth = SEA_LEVEL - heightAt(x,z); no depth texture is involved.

const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const dcw = @import("../world/dc_world.zig");
const ShadowRenderer = @import("shadow_renderer.zig").ShadowRenderer;

/// Cells per side. 96 over a 256 m patch is 2.67 m; fine enough for a shoreline band, cheap
/// enough to rebuild synchronously when the patch swaps.
const GRID: usize = 96;
const VERTS: usize = GRID + 1;

const vertex_src =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_xz;
    \\layout(location = 1) in float a_depth;
    \\uniform mat4 u_view_proj;
    \\uniform float u_min_x;
    \\uniform float u_min_z;
    \\uniform float u_size;
    \\uniform float u_sea;
    \\out vec3 v_world;
    \\out float v_depth;
    \\void main() {
    \\    vec3 p = vec3(u_min_x + a_xz.x * u_size, u_sea, u_min_z + a_xz.y * u_size);
    \\    v_world = p;
    \\    v_depth = a_depth;
    \\    gl_Position = u_view_proj * vec4(p, 1.0);
    \\}
;

const fragment_src =
    \\#version 330 core
    \\in vec3 v_world;
    \\in float v_depth;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_sun_colour;
    \\uniform mat4 u_light_vp[2];
    \\uniform sampler2D u_shadow0;
    \\uniform sampler2D u_shadow1;
    \\uniform float u_shadow_enabled;
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\uniform float u_time;
    \\out vec4 frag_colour;
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
    \\
    \\vec3 wave_normal(vec2 p, float t) {
    \\    vec2 d1 = normalize(vec2(1.0, 0.35));
    \\    vec2 d2 = normalize(vec2(-0.4, 1.0));
    \\    vec2 d3 = normalize(vec2(0.7, -0.6));
    \\    float s1 = cos(dot(p, d1) * 0.45 + t * 1.1) * 0.045;
    \\    float s2 = cos(dot(p, d2) * 1.05 + t * 1.7) * 0.022;
    \\    float s3 = cos(dot(p, d3) * 2.70 + t * 2.3) * 0.012;
    \\    return normalize(vec3(-(d1.x * s1 + d2.x * s2 + d3.x * s3), 1.0,
    \\                          -(d1.y * s1 + d2.y * s2 + d3.y * s3)));
    \\}
    \\
    \\void main() {
    \\    vec3 n = wave_normal(v_world.xz, u_time);
    \\    vec3 view = normalize(u_eye - v_world);
    \\    float ndv = max(dot(n, view), 0.0);
    \\    float fresnel = pow(1.0 - ndv, 4.0);
    \\    float depth = max(v_depth, 0.0);
    \\
    \\    vec3 shallow = vec3(0.070, 0.220, 0.200);
    \\    vec3 deep = vec3(0.008, 0.035, 0.055);
    \\    vec3 body = mix(shallow, deep, clamp(depth / 8.0, 0.0, 1.0));
    \\    vec3 sky = vec3(0.360, 0.520, 0.700);
    \\    vec3 col = body + sky * fresnel * 0.55;
    \\
    \\    vec3 half_dir = normalize(view + u_sun_dir);
    \\    float spec = pow(max(dot(n, half_dir), 0.0), 90.0);
    \\    float shadow = sunShadow(v_world, n);
    \\    body *= mix(0.72, 1.0, shadow);
    \\    col += u_sun_colour * spec * shadow * 0.35;
    \\
    \\    // Shallow water shows the bed; the deep is nearly opaque; a grazing view reflects more.
    \\    float alpha = mix(0.30, 0.92, clamp(depth / 3.0, 0.0, 1.0));
    \\    alpha = clamp(alpha + fresnel * 0.35, 0.0, 1.0);
    \\
    \\    // A soft, moving foam band right at the shoreline (depth < 0.6 m).
    \\    float foam = 1.0 - smoothstep(0.0, 0.6, depth);
    \\    foam *= 0.55 + 0.45 * sin(v_world.x * 0.9 + v_world.z * 0.7 + u_time * 1.6);
    \\    foam = max(foam, 0.0);
    \\    col = mix(col, vec3(0.74, 0.80, 0.78), foam * 0.55);
    \\    alpha = max(alpha, foam * 0.65);
    \\
    \\    // Gamma-encode first, then mix the fog in display space, matching the terrain shader.
    \\    vec3 outc = pow(max(col, 0.0), vec3(0.4545));
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
    \\
    \\    frag_colour = vec4(outc, alpha);
    \\}
;

/// Owns the sea program, the patch grid and its per-vertex depth buffer.
pub const WaterRenderer = struct {
    shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,
    ebo: u32 = 0,
    verts: [][3]f32,
    indices: []u32,
    built_min_x: f32 = -1e30,
    built_min_z: f32 = -1e30,
    built_size: f32 = 0,

    pub fn init() !WaterRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        const alloc = std.heap.page_allocator;
        const verts = try alloc.alloc([3]f32, VERTS * VERTS);
        errdefer alloc.free(verts);
        const indices = try alloc.alloc(u32, GRID * GRID * 6);
        errdefer alloc.free(indices);

        var k: usize = 0;
        for (0..GRID) |j| {
            for (0..GRID) |i| {
                const a: u32 = @intCast(j * VERTS + i);
                const b = a + 1;
                const c = a + @as(u32, @intCast(VERTS));
                const d = c + 1;
                indices[k + 0] = a;
                indices[k + 1] = c;
                indices[k + 2] = b;
                indices[k + 3] = b;
                indices[k + 4] = c;
                indices[k + 5] = d;
                k += 6;
            }
        }
        return .{ .shader = shader, .verts = verts, .indices = indices };
    }

    pub fn deinit(self: *WaterRenderer) void {
        if (self.vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
            gl.DeleteBuffers(1, @ptrCast(&self.vbo));
            gl.DeleteBuffers(1, @ptrCast(&self.ebo));
        }
        std.heap.page_allocator.free(self.verts);
        std.heap.page_allocator.free(self.indices);
        self.shader.deinit();
    }

    /// Rebuilds the grid when the patch moves. `min_x`/`min_z` are the patch's world minima.
    pub fn ensurePatch(self: *WaterRenderer, min_x: f32, min_z: f32, size: f32) void {
        if (self.built_size == size and self.built_min_x == min_x and self.built_min_z == min_z) return;
        const step = size / @as(f32, @floatFromInt(GRID));
        for (0..VERTS) |j| {
            for (0..VERTS) |i| {
                const fx: f32 = @floatFromInt(i);
                const fz: f32 = @floatFromInt(j);
                const x = min_x + fx * step;
                const z = min_z + fz * step;
                const depth = @max(dcw.SEA_LEVEL - dcw.heightAt(x, z), 0.0);
                self.verts[j * VERTS + i] = .{
                    fx / @as(f32, @floatFromInt(GRID)),
                    fz / @as(f32, @floatFromInt(GRID)),
                    depth,
                };
            }
        }
        self.built_min_x = min_x;
        self.built_min_z = min_z;
        self.built_size = size;

        if (self.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
            gl.GenBuffers(1, @ptrCast(&self.ebo));
            gl.BindVertexArray(self.vao);
            gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ebo);
            gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(self.indices.len * @sizeOf(u32)), self.indices.ptr, gl.STATIC_DRAW);
            gl.EnableVertexAttribArray(0);
            gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf([3]f32), 0);
            gl.EnableVertexAttribArray(1);
            gl.VertexAttribPointer(1, 1, gl.FLOAT, gl.FALSE, @sizeOf([3]f32), @sizeOf([2]f32));
            gl.BindVertexArray(0);
        }
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(self.verts.len * @sizeOf([3]f32)), self.verts.ptr, gl.STATIC_DRAW);
    }

    pub fn draw(
        self: *WaterRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        sun_colour: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
        min_x: f32,
        min_z: f32,
        size: f32,
        shadow: *ShadowRenderer,
    ) void {
        if (self.vao == 0) return;

        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setFloat("u_min_x", min_x);
        self.shader.setFloat("u_min_z", min_z);
        self.shader.setFloat("u_size", size);
        self.shader.setFloat("u_sea", dcw.SEA_LEVEL);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_sun_colour", .{ sun_colour.x, sun_colour.y, sun_colour.z });
        shadow.setUniforms(&self.shader);
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_time", time);
        gl.BindVertexArray(self.vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(self.indices.len), gl.UNSIGNED_INT, 0);
        gl.Disable(gl.BLEND);
    }
};
