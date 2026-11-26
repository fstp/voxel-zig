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

const VERT_SRC: [:0]const u8 = @embedFile("../shaders/chunk_vert.vert");

const FRAG_SRC: [:0]const u8 = @embedFile("../shaders/chunk_frag.frag");


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
        /// 5.1: PCSS inputs.
        shadow_uv_per_block: f32,
        shadow_depth_range: f32,
        shadow_light_size: f32,
        shadow_quality: i32,
        /// 5.6: water animation.
        time: f32,
        water_layer: f32,
        wave_amp: f32,
        waves: bool,
        foam: bool,
        /// 6.3: flat-colour water for diagnosing seams.
        debug_flat_water: bool,
        /// 4.4: the sky probe and the highest mip a roughness-1 surface samples.
        env_texture: gl.uint,
        env_max_mip: f32,
        /// 4.7: material maps for the same layers as the albedo array.
        normal_texture: gl.uint,
        rough_texture: gl.uint,
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
        gl.ActiveTexture(gl.TEXTURE3);
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, params.normal_texture);
        self.shader.setInt("u_normal", 3);
        gl.ActiveTexture(gl.TEXTURE4);
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, params.rough_texture);
        self.shader.setInt("u_rough", 4);
        self.shader.setMat4("u_light_vp", params.light_vp.m);
        self.shader.setFloat("u_shadows_enabled", if (params.shadow_enabled) 1.0 else 0.0);
        self.shader.setFloat("u_shadow_texel", params.shadow_texel);
        self.shader.setFloat("u_shadow_bias", params.shadow_bias);
        self.shader.setFloat("u_shadow_normal_offset", params.shadow_normal_offset);
        self.shader.setFloat("u_shadow_pcf_radius", params.shadow_pcf_radius);
        self.shader.setInt("u_shadow_kernel", params.shadow_kernel);
        self.shader.setFloat("u_shadow_uv_per_block", params.shadow_uv_per_block);
        self.shader.setFloat("u_shadow_depth_range", params.shadow_depth_range);
        self.shader.setFloat("u_shadow_light_size", params.shadow_light_size);
        self.shader.setInt("u_shadow_quality", params.shadow_quality);
        self.shader.setFloat("u_time", params.time);
        self.shader.setFloat("u_water_layer", params.water_layer);
        self.shader.setFloat("u_water_layer_f", params.water_layer);
        self.shader.setFloat("u_wave_amp", params.wave_amp);
        self.shader.setFloat("u_waves", if (params.waves) 1.0 else 0.0);
        self.shader.setFloat("u_foam", if (params.foam) 1.0 else 0.0);
        self.shader.setFloat("u_debug_flat", if (params.debug_flat_water) 1.0 else 0.0);

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
