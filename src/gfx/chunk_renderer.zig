const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const TextureArray = @import("texture.zig").TextureArray;
const mesher = @import("../voxel/mesher.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
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
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_layer = a_layer;
    \\    v_ao = a_ao;
    \\    v_face = a_face;
    \\    gl_Position = u_vp * u_model * vec4(a_pos, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2DArray u_tex;
    \\uniform float u_shading; // 1 = AO + face shading, 0 = flat (A/B toggle)
    \\in vec2 v_uv;
    \\in float v_layer;
    \\in float v_ao;
    \\in float v_face;
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
    \\void main() {
    \\    vec4 c = texture(u_tex, vec3(v_uv, v_layer));
    \\    if (c.a < 0.5) discard; // alpha cutout (leaves, ADR 0002)
    \\    // AO 0..3 -> 0.45..1.0, the concave-corner darkening from 1.12.
    \\    float ao = mix(0.45, 1.0, v_ao / 3.0);
    \\    float lit = mix(1.0, faceBrightness(v_face) * ao, u_shading);
    \\    f_colour = vec4(c.rgb * lit, c.a);
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
    pub fn begin(self: *ChunkRenderer, view_projection: Mat4, textures: *const TextureArray, shading: bool) void {
        self.shader.use();
        self.shader.setMat4("u_vp", view_projection.m);
        self.shader.setInt("u_tex", 0);
        self.shader.setFloat("u_shading", if (shading) 1.0 else 0.0);
        textures.bind(0);

        gl.Enable(gl.DEPTH_TEST);
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
