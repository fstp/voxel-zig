//! Flat sea surface for the DC world. One two-triangle quad over the current patch at
//! `dc_world.SEA_LEVEL`; the waves live in the fragment normal, so the geometry stays trivial
//! while the surface reads as water (9.1).

const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;

const vertex_src =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_xz;
    \\uniform mat4 u_view_proj;
    \\uniform float u_min_x;
    \\uniform float u_min_z;
    \\uniform float u_size;
    \\uniform float u_sea;
    \\out vec3 v_world;
    \\void main() {
    \\    vec3 p = vec3(u_min_x + a_xz.x * u_size, u_sea, u_min_z + a_xz.y * u_size);
    \\    v_world = p;
    \\    gl_Position = u_view_proj * vec4(p, 1.0);
    \\}
;

const fragment_src =
    \\#version 330 core
    \\in vec3 v_world;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\uniform float u_time;
    \\out vec4 frag_colour;
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
    \\
    \\    vec3 deep = vec3(0.012, 0.055, 0.075);
    \\    vec3 shallow = vec3(0.030, 0.140, 0.160);
    \\    vec3 sky = vec3(0.360, 0.520, 0.700);
    \\    vec3 col = mix(deep, shallow, 0.35) + sky * fresnel * 0.55;
    \\
    \\    vec3 half_dir = normalize(view + u_sun_dir);
    \\    float spec = pow(max(dot(n, half_dir), 0.0), 90.0);
    \\    col += vec3(1.0, 0.94, 0.80) * spec * 0.35;
    \\
    \\    // Gamma-encode first, then blend the fog in display space: exactly the terrain shader's
    \\    // convention (ADR 0021), so the sea and the land meet with the same haze at the shoreline.
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
    \\    frag_colour = vec4(outc, 1.0);
    \\}
;

/// Owns the sea program and a unit quad expanded to the patch by the vertex shader.
pub const WaterRenderer = struct {
    shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,

    pub fn init() !WaterRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        return .{ .shader = shader };
    }

    pub fn deinit(self: *WaterRenderer) void {
        if (self.vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
            gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        }
        self.shader.deinit();
    }

    pub fn draw(
        self: *WaterRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
        min_x: f32,
        min_z: f32,
        size: f32,
        sea_level: f32,
    ) void {
        if (self.vao == 0) {
            const quad = [6][2]f32{
                .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 },
                .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 },
            };
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
            gl.BindVertexArray(self.vao);
            gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
            gl.BufferData(gl.ARRAY_BUFFER, @intCast(quad.len * @sizeOf([2]f32)), &quad, gl.STATIC_DRAW);
            gl.EnableVertexAttribArray(0);
            gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf([2]f32), 0);
            gl.BindVertexArray(0);
        }

        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setFloat("u_min_x", min_x);
        self.shader.setFloat("u_min_z", min_z);
        self.shader.setFloat("u_size", size);
        self.shader.setFloat("u_sea", sea_level);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_time", time);
        gl.BindVertexArray(self.vao);
        gl.DrawArrays(gl.TRIANGLES, 0, 6);
    }
};
