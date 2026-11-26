const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const TextureArray = @import("texture.zig").TextureArray;
const mesher = @import("../voxel/mesher.zig");
const block = @import("../voxel/block.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;

/// Shader.setVec3 takes a plain array; the engine passes Vec3 everywhere else.
fn asArray(v: Vec3) [3]f32 {
    return .{ v.x, v.y, v.z };
}
const Aabb = @import("../math/aabb.zig").Aabb;

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in float a_layer;
    \\layout(location = 3) in float a_ao;
    \\layout(location = 4) in float a_face;
    \\uniform mat4 u_vp;
    \\uniform mat4 u_model;
    \\out vec2 v_uv;
    \\out float v_layer;
    \\out float v_ao;
    \\out float v_face;
    \\out vec3 v_normal;
    \\out vec3 v_world;
    \\// Face id -> outward normal (3.3). Same order as block.faceNormal().
    \\vec3 normalFromFace(float id) {
    \\    if (id < 0.5) return vec3(1.0, 0.0, 0.0);
    \\    if (id < 1.5) return vec3(-1.0, 0.0, 0.0);
    \\    if (id < 2.5) return vec3(0.0, 1.0, 0.0);
    \\    if (id < 3.5) return vec3(0.0, -1.0, 0.0);
    \\    if (id < 4.5) return vec3(0.0, 0.0, 1.0);
    \\    return vec3(0.0, 0.0, -1.0);
    \\}
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_layer = a_layer;
    \\    v_ao = a_ao;
    \\    v_face = a_face;
    \\    v_normal = normalFromFace(a_face);
    \\    v_world = (u_model * vec4(a_pos, 1.0)).xyz;
    \\    gl_Position = u_vp * u_model * vec4(a_pos, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2DArray u_tex;
    \\uniform float u_legacy;  // 1 = the old face table, 0 = sun lighting (F4 A/B)
    \\uniform float u_normals; // 1 = debug view: colour by normal (F6)
    \\uniform vec3 u_sun_dir;  // toward the sun, unit
    \\uniform vec3 u_sun_colour;    // linear, scaled by sun height
    \\uniform vec3 u_ambient_sky;   // linear hemisphere ambient, up
    \\uniform vec3 u_ambient_ground;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sky_horizon;  // same ramp the sky pass draws with
    \\uniform vec3 u_sky_zenith;
    \\uniform float u_fog_start;
    \\uniform float u_fog_end;
    \\uniform float u_fog_enabled;
    \\uniform sampler2D u_shadow;   // depth from the sun, unit 1
    \\uniform mat4 u_light_vp;
    \\uniform vec2 u_shadow_texel;
    \\uniform float u_shadow_bias;
    \\uniform float u_shadow_normal_offset;
    \\uniform float u_shadow_pcf_radius; // in texels (3.12: soft edges)
    \\uniform int u_shadow_kernel;       // 1 = 3x3, 2 = 5x5 taps
    \\uniform float u_shadows_enabled;
\\uniform vec4 u_material[8];   // per layer: x roughness, y metallic, z diffuse, w unused
\\uniform samplerCube u_env;    // sky probe (4.4), unit 2
\\uniform float u_env_max_mip;
    \\in vec2 v_uv;
    \\in float v_layer;
    \\in float v_ao;
    \\in float v_face;
    \\in vec3 v_normal;
    \\in vec3 v_world;
    \\out vec4 f_colour;
    \\
    \\// Cheap directional stand-in for lighting: face order is px, nx, py, ny, pz, nz.
    \\float faceBrightness(float id) {
    \\    if (id < 0.5) return 0.80; // +x
    \\    if (id < 1.5) return 0.80; // -x
    \\    if (id < 2.5) return 1.00; // +y
    \\    if (id < 3.5) return 0.50; // -y
    \\    if (id < 4.5) return 0.65; // +z
    \\    return 0.65;               // -z
    \\}
    \\// 3x3 PCF with a normal offset: offsetting along the normal is what kills
    \\// the acne that a depth bias alone leaves on large flat voxel faces.
    \\float sunVisibility(vec3 world, vec3 normal) {
    \\    if (u_shadows_enabled < 0.5) return 1.0;
    \\    vec4 light_position = u_light_vp * vec4(world + normal * u_shadow_normal_offset, 1.0);
    \\    vec3 p = light_position.xyz / light_position.w * 0.5 + 0.5;
    \\    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    \\    float sum = 0.0;
    \\    float taps = 0.0;
    \\    for (int y = -u_shadow_kernel; y <= u_shadow_kernel; ++y) {
    \\        for (int x = -u_shadow_kernel; x <= u_shadow_kernel; ++x) {
    \\            taps += 1.0;
    \\            float depth = texture(u_shadow, p.xy + vec2(float(x), float(y)) * u_shadow_texel * u_shadow_pcf_radius).r;
    \\            sum += (p.z - u_shadow_bias <= depth) ? 1.0 : 0.0;
    \\        }
    \\    }
    \\    return sum / taps;
    \\}
    \\
    \\const float PI = 3.14159265;
    \\
    \\// GGX / Trowbridge-Reitz: the shape of the specular lobe. Rough surfaces
    \\// spread the highlight, smooth ones keep it tight.
    \\float D_GGX(float noh, float roughness) {
    \\    float a = roughness * roughness;
    \\    float a2 = a * a;
    \\    float d = noh * noh * (a2 - 1.0) + 1.0;
    \\    return a2 / max(PI * d * d, 1e-7);
    \\}
    \\
    \\// Smith height-correlated visibility. Returns 1/(4 N.V N.L) folded in, which
    \\// is why the specular term below has no denominator of its own.
    \\float V_SmithGGX(float nov, float nol, float roughness) {
    \\    float a = roughness * roughness;
    \\    float a2 = a * a;
    \\    float gv = nol * sqrt(nov * nov * (1.0 - a2) + a2);
    \\    float gl = nov * sqrt(nol * nol * (1.0 - a2) + a2);
    \\    return 0.5 / max(gv + gl, 1e-7);
    \\}
    \\
    \\vec3 F_Schlick(vec3 f0, float voh) {
    \\    return f0 + (vec3(1.0) - f0) * pow(clamp(1.0 - voh, 0.0, 1.0), 5.0);
    \\}
    \\
    \\void main() {
    \\    vec4 c = texture(u_tex, vec3(v_uv, v_layer));
    \\    if (c.a < 0.5) discard; // alpha cutout (leaves, ADR 0002)
    \\    // AO 0..15 (3.12) with a curve: more bands than the old 0..3, and the
    \\    // curve keeps the darkest step from reading as a black line.
    \\    float ao = mix(0.42, 1.0, pow(clamp(v_ao / 15.0, 0.0, 1.0), 0.85));
    \\    if (u_normals > 0.5) {
    \\        // Debug: -1..1 mapped to 0..1, so +Y is green, +X red, +Z blue.
    \\        // The framebuffer is sRGB (ADR 0008), so encode here or the colours
    \\        // come out washed out.
    \\        f_colour = vec4(pow(v_normal * 0.5 + 0.5, vec3(2.2)), 1.0);
    \\        return;
    \\    }
    \\    // Physical shading (ADR 0011): metallic-roughness, one directional light
    \\    // plus the sky as ambient. The material comes from the texture layer, so
    \\    // the vertex format and the mesher are untouched.
    \\    vec4 material = u_material[int(v_layer + 0.5)];
    \\    float roughness = clamp(material.x, 0.06, 1.0);
    \\    float metallic = clamp(material.y, 0.0, 1.0);
    \\    // 4.4: water sets this near zero, so its bright albedo stops drowning the
    \\    // reflection it is supposed to show.
    \\    float diffuse_scale = clamp(material.z, 0.0, 1.0);
    \\    vec3 albedo = c.rgb * diffuse_scale;
    \\
    \\    vec3 N = normalize(v_normal);
    \\    vec3 V = normalize(u_eye - v_world);
    \\    vec3 L = u_sun_dir;
    \\    vec3 H = normalize(V + L);
    \\    float ndl = max(dot(N, L), 0.0);
    \\    float ndv = max(dot(N, V), 1e-4);
    \\    float ndh = max(dot(N, H), 0.0);
    \\    float vdh = max(dot(V, H), 0.0);
    \\
    \\    // A dielectric reflects 4 percent at normal incidence; a metal reflects its
    \\    // own albedo and has no diffuse lobe at all.
    \\    vec3 f0 = mix(vec3(0.04), c.rgb, metallic);
    \\    vec3 fresnel = F_Schlick(f0, vdh);
    \\    vec3 specular = D_GGX(ndh, roughness) * V_SmithGGX(ndv, ndl, roughness) * fresnel;
    \\    // Energy conservation: whatever is reflected specularly cannot also diffuse.
    \\    vec3 diffuse = (vec3(1.0) - fresnel) * (1.0 - metallic) * albedo / PI;
    \\
    \\    // u_sun_colour is scaled for the old Lambert path, so it carries an implicit
    \\    // PI: multiply it back here rather than retuning the sky that shares it.
    \\    float visibility = sunVisibility(v_world, N);
    \\    vec3 direct = (diffuse + specular) * u_sun_colour * PI * ndl * visibility;
    \\
    \\    vec3 hemi = mix(u_ambient_ground, u_ambient_sky, N.y * 0.5 + 0.5);
    \\    // 4.4: the reflected ray is looked up in the sky probe with the mip chosen
    \\    // by roughness, so a polished face mirrors the gradient and the sun while
    \\    // a rough one averages to a soft sheen.
    \\    vec3 R = reflect(-V, N);
    \\    vec3 environment = textureLod(u_env, R, roughness * u_env_max_mip).rgb;
    \\    vec3 ambient_specular = environment * F_Schlick(f0, ndv);
    \\    vec3 ambient = (hemi * albedo * (1.0 - metallic) + ambient_specular) * ao;
    \\
    \\    // AO darkens the ambient fully and the direct sun only partly: the shadow
    \\    // map is what should darken a lit face that is in shadow, and multiplying
    \\    // both factors at full strength made corners twice as dark as either.
    \\    vec3 lit = direct * mix(0.55, 1.0, ao) + ambient;
    \\    // F4 A/B: the old hardcoded table, kept so 3.9 can show the difference.
    \\    vec3 legacy = vec3(faceBrightness(v_face) * ao);
    \\    vec3 rgb = mix(c.rgb * lit, c.rgb * legacy, u_legacy);
    \\
    \\    // Distance fog, in linear space, coloured by the same sky gradient the sky
    \\    // pass draws (3.7). Duplicated on purpose: two lines and one pair of
    \\    // uniforms is cheaper than a texture lookup, and the uniforms come from
    \\    // the same sun.ramp() call, so they cannot drift.
    \\    if (u_fog_enabled > 0.5) {
    \\        vec3 to_fragment = v_world - u_eye;
    \\        float distance = length(to_fragment);
    \\        vec3 dir = to_fragment / max(distance, 1e-4);
    \\        vec3 fog_colour = mix(u_sky_horizon, u_sky_zenith, pow(clamp(dir.y, 0.0, 1.0), 0.45));
    \\        float fog = smoothstep(u_fog_start, u_fog_end, distance);
    \\        rgb = mix(rgb, fog_colour, fog);
    \\    }
    \\    f_colour = vec4(rgb, c.a);
    \\}
;

pub const ChunkRenderer = struct {
    shader: Shader,

    /// One uploaded chunk: its own VAO/VBO/EBO and the world-space box it occupies,
    /// which is what the frustum test uses.
    pub const Mesh = struct {
        vao: gl.uint = 0,
        vbo: gl.uint = 0,
        ebo: gl.uint = 0,
        index_count: u32 = 0,
        bounds: Aabb = Aabb.fromCenterSize(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 0 }),
        /// Chunk origin in world space, used as the model translation.
        origin: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    };

    pub fn init() !ChunkRenderer {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();
        return .{ .shader = shader };
    }

    pub fn deinit(self: *ChunkRenderer) void {
        self.shader.deinit();
    }

    /// Sets up the shared state for a frame: program, view-projection, texture
    /// array on unit 0. Depth test and backface culling are enabled here so a
    /// missing GL state setup cannot produce the "see the inside of the world"
    /// bug.
    /// Everything a frame needs. A struct, because a seventh positional argument
    /// is how state gets passed to the wrong place.
    pub const FrameParams = struct {
        view_projection: Mat4,
        eye: Vec3,
        lighting: @import("../world/sun.zig").Lighting,
        /// The same two colours the sky pass draws with (3.6), so fog matches.
        sky_horizon: Vec3,
        sky_zenith: Vec3,
        fog_start: f32,
        fog_end: f32,
        fog_enabled: bool,
        legacy: bool,
        normals: bool,
        /// 3.8: the sun's depth map plus the matrix that reads it.
        shadow_enabled: bool,
        light_vp: Mat4,
        shadow_texture: gl.uint,
        shadow_texel: f32,
        shadow_bias: f32,
        shadow_normal_offset: f32,
        /// 3.12: PCF spread in texels, and the kernel radius in taps (1 = 3x3,
        /// 2 = 5x5). Both matter: nine taps spread wider is still nine taps.
        shadow_pcf_radius: f32,
        shadow_kernel: i32,
        /// 4.4: the sky probe and the highest mip a roughness-1 surface samples.
        env_texture: gl.uint,
        env_max_mip: f32,
    };

    pub fn begin(self: *ChunkRenderer, textures: *const TextureArray, params: FrameParams) void {
        self.shader.use();
        // Materials are fixed per texture layer, so they ride with the other
        // frame-constant uniforms instead of adding a mesher field (ADR 0011).
        // Literal names: Zig 0.17 dropped bufPrintZ, and an array indexed by the
        // layer keeps the uniform names and the table the same length.
        const material_uniforms = [_][:0]const u8{
            "u_material[0]", "u_material[1]", "u_material[2]", "u_material[3]",
            "u_material[4]", "u_material[5]", "u_material[6]", "u_material[7]",
        };
        comptime std.debug.assert(material_uniforms.len == block.layer_materials.len);
        for (block.layer_materials, material_uniforms) |m, name| {
            self.shader.setFloat4(name, .{ m.roughness, m.metallic, m.diffuse, 0.0 });
        }
        self.shader.setMat4("u_vp", params.view_projection.m);
        self.shader.setVec3("u_eye", asArray(params.eye));
        self.shader.setVec3("u_sky_horizon", asArray(params.sky_horizon));
        self.shader.setVec3("u_sky_zenith", asArray(params.sky_zenith));
        self.shader.setFloat("u_fog_start", params.fog_start);
        self.shader.setFloat("u_fog_end", params.fog_end);
        self.shader.setFloat("u_fog_enabled", if (params.fog_enabled) 1.0 else 0.0);
        self.shader.setInt("u_tex", 0);
        self.shader.setFloat("u_legacy", if (params.legacy) 1.0 else 0.0);
        self.shader.setFloat("u_normals", if (params.normals) 1.0 else 0.0);
        self.shader.setVec3("u_sun_dir", asArray(params.lighting.sun_dir));
        self.shader.setVec3("u_sun_colour", asArray(params.lighting.sun_colour));
        self.shader.setVec3("u_ambient_sky", asArray(params.lighting.ambient_sky));
        self.shader.setVec3("u_ambient_ground", asArray(params.lighting.ambient_ground));
        textures.bind(0);
        if (params.shadow_texture != 0) {
            gl.ActiveTexture(gl.TEXTURE1);
            gl.BindTexture(gl.TEXTURE_2D, params.shadow_texture);
            gl.ActiveTexture(gl.TEXTURE0);
        }
        self.shader.setInt("u_shadow", 1);
        // 4.4: the sky probe, unit 2. A zero texture (probe not ready) still
        // samples as black rather than leaving the sampler unbound.
        gl.ActiveTexture(gl.TEXTURE2);
        gl.BindTexture(gl.TEXTURE_CUBE_MAP, params.env_texture);
        self.shader.setInt("u_env", 2);
        self.shader.setFloat("u_env_max_mip", params.env_max_mip);
        self.shader.setMat4("u_light_vp", params.light_vp.m);
        self.shader.setFloat("u_shadows_enabled", if (params.shadow_enabled) 1.0 else 0.0);
        self.shader.setFloat("u_shadow_texel", params.shadow_texel);
        self.shader.setFloat("u_shadow_bias", params.shadow_bias);
        self.shader.setFloat("u_shadow_normal_offset", params.shadow_normal_offset);
        self.shader.setFloat("u_shadow_pcf_radius", params.shadow_pcf_radius);
        self.shader.setInt("u_shadow_kernel", params.shadow_kernel);

        gl.Enable(gl.DEPTH_TEST);
        // Explicit, not inherited: the sky pass runs with depth writes off and a
        // restore bug there must not silently break occlusion here.
        gl.DepthMask(gl.TRUE);
        gl.Enable(gl.CULL_FACE);
        gl.CullFace(gl.BACK);
        gl.FrontFace(gl.CCW);
    }

    /// Uploads a mesh, creating or resizing its buffers as needed. Vertex data
    /// is chunk-local (0..32); `bounds` is in world space.
    pub fn upload(self: *ChunkRenderer, mesh: *Mesh, chunk_origin: Vec3, vertices: []const mesher.Vertex, indices: []const u32) void {
        _ = self;
        if (mesh.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&mesh.vao));
            gl.GenBuffers(1, @ptrCast(&mesh.vbo));
            gl.GenBuffers(1, @ptrCast(&mesh.ebo));
        }
        mesh.origin = chunk_origin;
        mesh.index_count = @intCast(indices.len);
        mesh.bounds = Aabb.fromCenterSize(
            Vec3.init(chunk_origin.x + 16, chunk_origin.y + 16, chunk_origin.z + 16),
            Vec3.init(32, 32, 32),
        );

        gl.BindVertexArray(mesh.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(mesher.Vertex)), vertices.ptr, gl.STATIC_DRAW);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, mesh.ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(indices.len * @sizeOf(u32)), indices.ptr, gl.STATIC_DRAW);

        const stride: gl.sizei = @intCast(@sizeOf(mesher.Vertex));
        // pos: vec3 float at 0
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, stride, 0);
        gl.EnableVertexAttribArray(0);
        // uv: vec2 float at 12
        gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, stride, @offsetOf(mesher.Vertex, "uv"));
        gl.EnableVertexAttribArray(1);
        // layer: one unsigned byte at 20, converted to float (not normalised)
        gl.VertexAttribPointer(2, 1, gl.UNSIGNED_BYTE, gl.FALSE, stride, @offsetOf(mesher.Vertex, "layer"));
        gl.EnableVertexAttribArray(2);
        // ao: 0..3, face: 0..5 - both raw bytes, used as floats in the shader
        gl.VertexAttribPointer(3, 1, gl.UNSIGNED_BYTE, gl.FALSE, stride, @offsetOf(mesher.Vertex, "ao"));
        gl.EnableVertexAttribArray(3);
        gl.VertexAttribPointer(4, 1, gl.UNSIGNED_BYTE, gl.FALSE, stride, @offsetOf(mesher.Vertex, "_pad"));
        gl.EnableVertexAttribArray(4);
    }

    pub fn draw(self: *ChunkRenderer, mesh: *const Mesh) void {
        if (mesh.index_count == 0) return;
        self.shader.setMat4("u_model", Mat4.translate(mesh.origin).m);
        gl.BindVertexArray(mesh.vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(mesh.index_count), gl.UNSIGNED_INT, 0);
    }

    pub fn destroyMesh(self: *ChunkRenderer, mesh: *Mesh) void {
        _ = self;
        if (mesh.vao == 0) return;
        gl.DeleteBuffers(1, @ptrCast(&mesh.ebo));
        gl.DeleteBuffers(1, @ptrCast(&mesh.vbo));
        gl.DeleteVertexArrays(1, @ptrCast(&mesh.vao));
        mesh.vao = 0;
        mesh.index_count = 0;
    }
};
