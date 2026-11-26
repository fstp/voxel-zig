const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const TextureArray = @import("texture.zig").TextureArray;
const BlockId = @import("../voxel/block.zig").BlockId;
const block_mod = @import("../voxel/block.zig");
const Face = @import("../voxel/block.zig").Face;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;

/// Shader.setVec3 takes a plain array; the engine passes Vec3 everywhere else.
fn asArray(v: Vec3) [3]f32 {
    return .{ v.x, v.y, v.z };
}

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in float a_layer;
    \\layout(location = 3) in vec3 a_normal;
    \\uniform mat4 u_vp;
    \\uniform mat4 u_model;
    \\out vec2 v_uv;
    \\out float v_layer;
    \\out vec3 v_normal;
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_layer = a_layer;
    \\    v_normal = a_normal;
    \\    gl_Position = u_vp * u_model * vec4(a_pos, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2DArray u_tex;
    \\uniform float u_legacy;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_sun_colour;
    \\uniform vec3 u_ambient_sky;
    \\uniform vec3 u_ambient_ground;
    \\in vec2 v_uv;
    \\in float v_layer;
    \\in vec3 v_normal;
    \\out vec4 f_colour;
    \\void main() {
    \\    vec4 c = texture(u_tex, vec3(v_uv, v_layer));
    \\    if (c.a < 0.5) discard; // alpha cutout (leaves), ADR 0002
    \\    // Same model as the terrain (3.5, C22), without AO: a single block has no
    \\    // neighbours to occlude it.
    \\    float ndl = max(dot(v_normal, u_sun_dir), 0.0);
    \\    vec3 hemi = mix(u_ambient_ground, u_ambient_sky, v_normal.y * 0.5 + 0.5);
    \\    vec3 lit = hemi + u_sun_colour * ndl;
    \\    vec3 unlit = vec3(1.0);
    \\    f_colour = vec4(c.rgb * mix(lit, unlit, u_legacy), c.a);
    \\}
;

const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    layer: f32,
    normal: [3]f32,
};

const VERTICES_PER_FACE = 4;
const INDICES_PER_FACE = 6;
const FACE_COUNT = 6;

/// Draws single blocks as textured cubes. One VBO is reused for every block:
/// the cube is rebuilt on the stack per draw, which is fine for the handful of
/// cubes that exist before the chunk mesher (1.6) takes over.
pub const BlockRenderer = struct {
    shader: Shader,
    vao: gl.uint,
    vbo: gl.uint,
    ebo: gl.uint,

    pub fn init() !BlockRenderer {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var vao: gl.uint = 0;
        var vbo: gl.uint = 0;
        var ebo: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&vao));
        gl.GenBuffers(1, @ptrCast(&vbo));
        gl.GenBuffers(1, @ptrCast(&ebo));
        gl.BindVertexArray(vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), 0);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @offsetOf(Vertex, "uv"));
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribPointer(2, 1, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @offsetOf(Vertex, "layer"));
        gl.EnableVertexAttribArray(2);
        gl.VertexAttribPointer(3, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @offsetOf(Vertex, "normal"));
        gl.EnableVertexAttribArray(3);

        return .{ .shader = shader, .vao = vao, .vbo = vbo, .ebo = ebo };
    }

    pub fn deinit(self: *BlockRenderer) void {
        gl.DeleteBuffers(1, @ptrCast(&self.ebo));
        gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    pub fn begin(
        self: *BlockRenderer,
        view_projection: Mat4,
        textures: *TextureArray,
        lighting: @import("../world/sun.zig").Lighting,
        legacy: bool,
    ) void {
        self.shader.use();
        self.shader.setMat4("u_vp", view_projection.m);
        self.shader.setInt("u_tex", 0);
        self.shader.setFloat("u_legacy", if (legacy) 1.0 else 0.0);
        self.shader.setVec3("u_sun_dir", asArray(lighting.sun_dir));
        self.shader.setVec3("u_sun_colour", asArray(lighting.sun_colour));
        self.shader.setVec3("u_ambient_sky", asArray(lighting.ambient_sky));
        self.shader.setVec3("u_ambient_ground", asArray(lighting.ambient_ground));
        textures.bind(0);
        gl.BindVertexArray(self.vao);
    }

    /// `centre` is the block centre, `size` the edge length in world units.
    pub fn draw(self: *BlockRenderer, block: BlockId, centre: Vec3, size: f32, model_extra: Mat4) void {
        const half = size * 0.5;
        const x = centre.x;
        const y = centre.y;
        const z = centre.z;

        // Unit cube faces, counter-clockwise seen from outside, with the same
        // UV order on every face (0,0 bottom-left .. 1,1 top-right).
        const faces = [FACE_COUNT]struct {
            corners: [4][3]f32,
            face: Face,
        }{
            .{ .face = .px, .corners = .{
                .{ x + half, y - half, z + half }, .{ x + half, y - half, z - half },
                .{ x + half, y + half, z - half }, .{ x + half, y + half, z + half },
            } },
            .{ .face = .nx, .corners = .{
                .{ x - half, y - half, z - half }, .{ x - half, y - half, z + half },
                .{ x - half, y + half, z + half }, .{ x - half, y + half, z - half },
            } },
            .{ .face = .py, .corners = .{
                .{ x - half, y + half, z + half }, .{ x + half, y + half, z + half },
                .{ x + half, y + half, z - half }, .{ x - half, y + half, z - half },
            } },
            .{ .face = .ny, .corners = .{
                .{ x - half, y - half, z - half }, .{ x + half, y - half, z - half },
                .{ x + half, y - half, z + half }, .{ x - half, y - half, z + half },
            } },
            .{ .face = .pz, .corners = .{
                .{ x - half, y - half, z + half }, .{ x + half, y - half, z + half },
                .{ x + half, y + half, z + half }, .{ x - half, y + half, z + half },
            } },
            .{ .face = .nz, .corners = .{
                .{ x + half, y - half, z - half }, .{ x - half, y - half, z - half },
                .{ x - half, y + half, z - half }, .{ x + half, y + half, z - half },
            } },
        };

        var vertices: [FACE_COUNT * VERTICES_PER_FACE]Vertex = undefined;
        var indices: [FACE_COUNT * INDICES_PER_FACE]u32 = undefined;

        for (faces, 0..) |f, face_index| {
            const layer: f32 = @floatFromInt(block.layerFor(f.face));
            const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
            const normal = block_mod.faceNormal(f.face);
            for (f.corners, uvs, 0..) |corner, uv, corner_index| {
                vertices[face_index * VERTICES_PER_FACE + corner_index] = .{
                    .pos = corner,
                    .uv = uv,
                    .layer = layer,
                    .normal = normal,
                };
            }
            const base: u32 = @intCast(face_index * VERTICES_PER_FACE);
            const out = face_index * INDICES_PER_FACE;
            indices[out + 0] = base;
            indices[out + 1] = base + 1;
            indices[out + 2] = base + 2;
            indices[out + 3] = base;
            indices[out + 4] = base + 2;
            indices[out + 5] = base + 3;
        }

        self.shader.setMat4("u_model", model_extra.m);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.STREAM_DRAW);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, gl.STREAM_DRAW);
        gl.DrawElements(gl.TRIANGLES, indices.len, gl.UNSIGNED_INT, 0);
    }
};
