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
    \\uniform mat4 u_vp;
    \\uniform mat4 u_model;
    \\out vec2 v_uv;
    \\out float v_layer;
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_layer = a_layer;
    \\    gl_Position = u_vp * u_model * vec4(a_pos, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2DArray u_tex;
    \\in vec2 v_uv;
    \\in float v_layer;
    \\out vec4 f_colour;
    \\void main() {
    \\    vec4 c = texture(u_tex, vec3(v_uv, v_layer));
    \\    if (c.a < 0.5) discard; // alpha cutout (leaves, ADR 0002)
    \\    f_colour = c;
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
    pub fn begin(self: *ChunkRenderer, view_projection: Mat4, textures: *const TextureArray) void {
        self.shader.use();
        self.shader.setMat4("u_vp", view_projection.m);
        self.shader.setInt("u_tex", 0);
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
