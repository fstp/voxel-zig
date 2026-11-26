//! Draws a dual-contouring surface inside the engine's scene pass (ADR 0020 step 2).
//! Separate from ChunkRenderer on purpose: that one is built around a 256^2 texture array indexed by
//! block face id and per-layer uniforms, none of which a DC vertex has. Output is LINEAR - it goes
//! into the app's HDR/MSAA target and the post chain applies ACES and sRGB.

const std = @import("std");
const gl = @import("gl");
const dc = @import("../voxel/dc.zig");
const terrain = @import("../world/terrain.zig");
const Shader = @import("shader.zig").Shader;

pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    colour: [3]f32,
    material: f32,
};

pub const DcRenderer = struct {
    shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,
    ebo: u32 = 0,
    index_count: u32 = 0,
    vertex_count: u32 = 0,

    pub fn init() !DcRenderer {
        return .{ .shader = try Shader.init(vertex_src, fragment_src) };
    }

    pub fn deinit(self: *DcRenderer) void {
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        if (self.vbo != 0) gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        if (self.ebo != 0) gl.DeleteBuffers(1, @ptrCast(&self.ebo));
        self.shader.deinit();
    }

    /// Material id and base colour are derived from geometry alone - slope picks rock over ground,
    /// height picks the band - so they stay a pure function of world position (ADR 0019).
    pub fn upload(self: *DcRenderer, alloc: std.mem.Allocator, surf: dc.Surface) !void {
        const verts = try alloc.alloc(Vertex, surf.verts.len);
        defer alloc.free(verts);
        for (surf.verts, 0..) |v, i| {
            const slope: f32 = 1.0 - @abs(v.normal[1]);
            const rock = std.math.clamp((slope - 0.35) / 0.25, 0.0, 1.0);
            const mat: u8 = if (rock > 0.75) 2 else if (rock > 0.35) 1 else 0;
            const h = std.math.clamp((v.pos[1] - 45.0) / 30.0, 0.0, 1.0);
            const ground = .{ 0.30, 0.34, 0.20 };
            const stone = .{ 0.30, 0.29, 0.28 };
            verts[i] = .{
                .pos = v.pos,
                .normal = v.normal,
                .colour = .{
                    @as(f32, ground[0]) + (@as(f32, stone[0]) - @as(f32, ground[0])) * rock,
                    @as(f32, ground[1]) + (@as(f32, stone[1]) - @as(f32, ground[1])) * rock,
                    @as(f32, ground[2]) + (@as(f32, stone[2]) - @as(f32, ground[2])) * rock,
                },
                .material = @floatFromInt(mat),
            };
            _ = h;
        }

        if (self.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
            gl.GenBuffers(1, @ptrCast(&self.ebo));
        }
        gl.BindVertexArray(self.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(Vertex)), verts.ptr, gl.STATIC_DRAW);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(surf.indices.len * @sizeOf(u32)), surf.indices.ptr, gl.STATIC_DRAW);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), 0);
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32));
        gl.EnableVertexAttribArray(2);
        gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 2);
        gl.EnableVertexAttribArray(3);
        gl.VertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 3);
        gl.BindVertexArray(0);
        self.vertex_count = @intCast(verts.len);
        self.index_count = @intCast(surf.indices.len);
    }

    pub fn draw(self: *DcRenderer, view_proj: [16]f32, sun_dir: [3]f32, sun_colour: [3]f32) void {
        if (self.index_count == 0) return;
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_proj);
        self.shader.setVec3("u_sun_dir", sun_dir);
        self.shader.setVec3("u_sun_colour", sun_colour);
        gl.BindVertexArray(self.vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(self.index_count), gl.UNSIGNED_INT, 0);
        gl.BindVertexArray(0);
    }
};

/// Builds a patch from the engine's own generator, so DC is compared against blocks on the SAME
/// terrain. Height is interpolated bilinearly: the generator's height is an integer and at 1 m cells
/// on an integer origin every sample lands on a lattice point, where DC just reproduces the steps.
pub fn buildTerrainPatch(alloc: std.mem.Allocator, seed: u32, chunks: i32) !dc.Surface {
    const cells: usize = 32;
    const cell: f32 = 1.0;
    const side = cells + 3;

    var verts: std.ArrayList(dc.Vertex) = .empty;
    errdefer verts.deinit(alloc);
    var idx: std.ArrayList(u32) = .empty;
    errdefer idx.deinit(alloc);

    var cz: i32 = 0;
    while (cz < chunks) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < chunks) : (cx += 1) {
            const vals = try alloc.alloc(f32, side * side * side);
            defer alloc.free(vals);
            var k: usize = 0;
            while (k < side) : (k += 1) {
                var j: usize = 0;
                while (j < side) : (j += 1) {
                    var i: usize = 0;
                    while (i < side) : (i += 1) {
                        const gx: i32 = cx * @as(i32, @intCast(cells)) + @as(i32, @intCast(i)) - 1;
                        const gy: i32 = @as(i32, @intCast(j)) - 1;
                        const gz: i32 = cz * @as(i32, @intCast(cells)) + @as(i32, @intCast(k)) - 1;
                        const xf = @as(f32, @floatFromInt(gx)) * cell;
                        const zf = @as(f32, @floatFromInt(gz)) * cell;
                        // bilinear height over the block generator
                        const x0: i32 = @intFromFloat(@floor(xf));
                        const z0: i32 = @intFromFloat(@floor(zf));
                        const fx = xf - @floor(xf);
                        const fz = zf - @floor(zf);
                        const h00: f32 = @floatFromInt(terrain.heightAt(seed, x0, z0));
                        const h10: f32 = @floatFromInt(terrain.heightAt(seed, x0 + 1, z0));
                        const h01: f32 = @floatFromInt(terrain.heightAt(seed, x0, z0 + 1));
                        const h11: f32 = @floatFromInt(terrain.heightAt(seed, x0 + 1, z0 + 1));
                        const ha = h00 + (h10 - h00) * fx;
                        const hb = h01 + (h11 - h01) * fx;
                        const h = ha + (hb - ha) * fz;
                        const yw = 40.0 + @as(f32, @floatFromInt(gy)) * cell;
                        vals[i + side * (j + side * k)] = yw - h;
                    }
                }
            }
            const field = dc.Field{
                .values = vals,
                .n = cells,
                .skirt = 1,
                .origin = .{
                    @as(f32, @floatFromInt(cx * @as(i32, @intCast(cells)))),
                    40.0,
                    @as(f32, @floatFromInt(cz * @as(i32, @intCast(cells)))),
                },
                .cell = cell,
            };
            const surf = try dc.extract(alloc, field);
            defer surf.deinit(alloc);
            const base: u32 = @intCast(verts.items.len);
            try verts.appendSlice(alloc, surf.verts);
            for (surf.indices) |v| try idx.append(alloc, base + v);
        }
    }
    return .{ .verts = try verts.toOwnedSlice(alloc), .indices = try idx.toOwnedSlice(alloc) };
}

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\layout(location = 2) in vec3 a_col;
    \\layout(location = 3) in float a_mat;
    \\uniform mat4 u_view_proj;
    \\out vec3 v_nrm;
    \\out vec3 v_pos;
    \\out vec3 v_col;
    \\out float v_mat;
    \\void main() {
    \\    v_nrm = a_nrm; v_pos = a_pos; v_col = a_col; v_mat = a_mat;
    \\    gl_Position = u_view_proj * vec4(a_pos, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_nrm;
    \\in vec3 v_pos;
    \\in vec3 v_col;
    \\in float v_mat;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_sun_colour;
    \\out vec4 frag;
    \\float hash13(vec3 p) {
    \\    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    \\    p *= 17.0;
    \\    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    \\}
    \\vec4 noised(vec3 x) {
    \\    vec3 p = floor(x); vec3 w = fract(x);
    \\    vec3 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    \\    vec3 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    \\    float a = hash13(p); float b = hash13(p + vec3(1,0,0));
    \\    float c = hash13(p + vec3(0,1,0)); float d = hash13(p + vec3(1,1,0));
    \\    float e = hash13(p + vec3(0,0,1)); float f = hash13(p + vec3(1,0,1));
    \\    float g = hash13(p + vec3(0,1,1)); float h = hash13(p + vec3(1,1,1));
    \\    float k0 = a, k1 = b-a, k2 = c-a, k3 = e-a;
    \\    float k4 = a-b-c+d, k5 = a-c-e+g, k6 = a-b-e+f, k7 = -a+b+c-d+e-f-g+h;
    \\    float v = k0 + k1*u.x + k2*u.y + k3*u.z + k4*u.x*u.y + k5*u.y*u.z + k6*u.z*u.x + k7*u.x*u.y*u.z;
    \\    vec3 gr = du * vec3(k1 + k4*u.y + k6*u.z + k7*u.y*u.z,
    \\                        k2 + k5*u.z + k4*u.x + k7*u.z*u.x,
    \\                        k3 + k6*u.x + k5*u.y + k7*u.x*u.y);
    \\    return vec4(v, gr);
    \\}
    \\void main() {
    \\    vec3 wp = v_pos * 0.35;
    \\    vec4 o1 = noised(wp);
    \\    vec4 o2 = noised(wp * 2.7 + 11.0);
    \\    float detail = o1.x * 0.65 + o2.x * 0.35;
    \\    vec3 grad = o1.yzw * 0.65 + o2.yzw * 2.7 * 0.35;
    \\    float bump = v_mat < 0.5 ? 0.10 : (v_mat < 1.5 ? 0.22 : 0.34);
    \\    vec3 n = normalize(v_nrm + grad * bump);
    \\    vec3 albedo = v_col * (0.86 + 0.30 * detail);
    \\    float ndl = max(dot(n, normalize(u_sun_dir)), 0.0);
    \\    vec3 amb = mix(vec3(0.10, 0.11, 0.09), vec3(0.22, 0.28, 0.36), n.y * 0.5 + 0.5);
    \\    frag = vec4(albedo * (amb + u_sun_colour * ndl), 1.0);
    \\}
;
