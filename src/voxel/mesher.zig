const std = @import("std");
const BlockId = @import("block.zig").BlockId;
const Face = @import("block.zig").Face;
const blocks = @import("block.zig");
const coords = @import("coords.zig");
const Chunk = @import("../world/chunk.zig").Chunk;

/// 24-byte vertex (ADR 0004): chunk-local position, per-corner UV, texture
/// array layer and two AO bits. `_pad` is reserved for the face id that 1.12
/// needs for per-face shading; keeping it now means the vertex stride does not
/// change when that lands.
pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    layer: u8,
    ao: u8,
    _pad: [2]u8 = .{ 0, 0 },
};

/// The chunk plus a one-block border sampled from its neighbours, so boundary
/// faces are culled by exactly the same code as interior ones (ADR 0004).
pub const PADDED_SIZE: i32 = coords.CHUNK_SIZE + 2;
pub const PADDED_VOLUME: usize = @intCast(PADDED_SIZE * PADDED_SIZE * PADDED_SIZE);

pub const PaddedBlocks = struct {
    blocks: [PADDED_VOLUME]BlockId,

    pub fn init() PaddedBlocks {
        return .{ .blocks = @splat(.air) };
    }

    pub fn index(x: i32, y: i32, z: i32) usize {
        std.debug.assert(x >= -1 and x <= coords.CHUNK_SIZE);
        std.debug.assert(y >= -1 and y <= coords.CHUNK_SIZE);
        std.debug.assert(z >= -1 and z <= coords.CHUNK_SIZE);
        return @intCast(((y + 1) * PADDED_SIZE + (z + 1)) * PADDED_SIZE + (x + 1));
    }

    /// Chunk-local coordinates, -1 .. CHUNK_SIZE inclusive.
    pub fn get(self: *const PaddedBlocks, x: i32, y: i32, z: i32) BlockId {
        return self.blocks[index(x, y, z)];
    }

    pub fn set(self: *PaddedBlocks, x: i32, y: i32, z: i32, block: BlockId) void {
        self.blocks[index(x, y, z)] = block;
    }

    /// Copies a chunk's 32^3 blocks into the middle; the border is left as is.
    pub fn fillFromChunk(self: *PaddedBlocks, chunk: *const Chunk) void {
        var z: i32 = 0;
        while (z < coords.CHUNK_SIZE) : (z += 1) {
            var y: i32 = 0;
            while (y < coords.CHUNK_SIZE) : (y += 1) {
                var x: i32 = 0;
                while (x < coords.CHUNK_SIZE) : (x += 1) {
                    self.set(x, y, z, chunk.getBlock(x, y, z));
                }
            }
        }
    }

    /// True when the chunk body (border excluded) is entirely air.
    pub fn chunkIsEmpty(self: *const PaddedBlocks) bool {
        var z: i32 = 0;
        while (z < coords.CHUNK_SIZE) : (z += 1) {
            var y: i32 = 0;
            while (y < coords.CHUNK_SIZE) : (y += 1) {
                var x: i32 = 0;
                while (x < coords.CHUNK_SIZE) : (x += 1) {
                    if (self.get(x, y, z) != .air) return false;
                }
            }
        }
        return true;
    }
};

pub const mesh_error = error{VertexBufferTooSmall};

pub const MeshStats = struct {
    quads: usize,
    vertices: usize,
    indices: usize,

    pub fn bytes(self: MeshStats) usize {
        return self.vertices * @sizeOf(Vertex) + self.indices * @sizeOf(u32);
    }
};

/// Faces in the order of `Face`: px, nx, py, ny, pz, nz. Corner order is
/// counter-clockwise seen from outside, with UV (0,0) at the bottom-left, so
/// `v` runs up the face - the grass cap lands on top (verified in 1.4).
const FaceInfo = struct {
    normal: [3]i32,
    corners: [4][3]f32,
    /// Tangential axes used for the AO samples (0 = x, 1 = y, 2 = z).
    u: usize,
    v: usize,
};

const CORNER_UV = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

const faces = [6]FaceInfo{
    .{ .normal = .{ 1, 0, 0 }, .corners = .{ .{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 } }, .u = 1, .v = 2 },
    .{ .normal = .{ -1, 0, 0 }, .corners = .{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 } }, .u = 1, .v = 2 },
    .{ .normal = .{ 0, 1, 0 }, .corners = .{ .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } }, .u = 0, .v = 2 },
    .{ .normal = .{ 0, -1, 0 }, .corners = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } }, .u = 0, .v = 2 },
    .{ .normal = .{ 0, 0, 1 }, .corners = .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } }, .u = 0, .v = 1 },
    .{ .normal = .{ 0, 0, -1 }, .corners = .{ .{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 } }, .u = 0, .v = 1 },
};

const face_order = [6]Face{ .px, .nx, .py, .ny, .pz, .nz };

/// Whether a face between `block` and `neighbour` should be emitted.
/// Water is decoration in the PoC (ADR 0005 scopes fluids out), so it only draws
/// where it meets air: no faces inside a water body, and none against terrain.
fn faceVisible(block: BlockId, neighbour: BlockId) bool {
    if (block.isSolid()) return !neighbour.isOpaque();
    if (block == .water) return neighbour == .air;
    return false;
}

fn isRenderable(block: BlockId) bool {
    return block.isSolid() or block == .water;
}

/// Builds the geometry of one chunk (ADR 0004: naive face culling, one quad
/// per visible face, no merging).
///
/// A face is emitted unless the neighbour is opaque, so air, water and leaves
/// all leave the face in place. The caller writes the padded border: sampling
/// the real neighbour blocks is what makes an interior chunk cheap, and leaving
/// the border as air reproduces the isolated-chunk case.
pub fn mesh(padded: *const PaddedBlocks, out_vertices: []Vertex, out_indices: []u32) mesh_error!MeshStats {
    var vertex_count: usize = 0;
    var index_count: usize = 0;
    var quad_count: usize = 0;

    var z: i32 = 0;
    while (z < coords.CHUNK_SIZE) : (z += 1) {
        var y: i32 = 0;
        while (y < coords.CHUNK_SIZE) : (y += 1) {
            var x: i32 = 0;
            while (x < coords.CHUNK_SIZE) : (x += 1) {
                const block = padded.get(x, y, z);
                if (!isRenderable(block)) continue;

                inline for (faces, face_order) |info, face| {
                    const n = info.normal;
                    // An opaque neighbour hides the face; air, water and leaves
                    // do not (ADR 0004's boundary table). Water has its own rule.
                    if (faceVisible(block, padded.get(x + n[0], y + n[1], z + n[2]))) {
                        if (vertex_count + 4 > out_vertices.len) return error.VertexBufferTooSmall;
                        const face_id: u8 = @intCast(@intFromEnum(face));
                        const layer = block.layerFor(face);
                        const base: u32 = @intCast(vertex_count);
                        const ox: f32 = @floatFromInt(x);
                        const oy: f32 = @floatFromInt(y);
                        const oz: f32 = @floatFromInt(z);
                        for (info.corners, 0..) |c, k| {
                            out_vertices[vertex_count + k] = .{
                                .pos = .{ ox + c[0], oy + c[1], oz + c[2] },
                                .uv = CORNER_UV[k],
                                .layer = layer,
                                .ao = cornerOcclusion(padded, x + n[0], y + n[1], z + n[2], c, info.u, info.v),
                                ._pad = .{ face_id, 0 },
                            };
                        }
                        out_indices[index_count + 0] = base + 0;
                        out_indices[index_count + 1] = base + 1;
                        out_indices[index_count + 2] = base + 2;
                        out_indices[index_count + 3] = base + 0;
                        out_indices[index_count + 4] = base + 2;
                        out_indices[index_count + 5] = base + 3;

                        vertex_count += 4;
                        index_count += 6;
                        quad_count += 1;
                    }
                }
            }
        }
    }

    return .{ .quads = quad_count, .vertices = vertex_count, .indices = index_count };
}

/// Per-corner ambient occlusion, 0 (fully occluded) .. 3 (open). Samples the
/// two edge neighbours and the diagonal one in the plane just outside the face
/// (`bx, by, bz` is the neighbour block), which is the classic "0fps" method.
fn cornerOcclusion(padded: *const PaddedBlocks, bx: i32, by: i32, bz: i32, corner: [3]f32, u: usize, v: usize) u8 {
    var du = [3]i32{ 0, 0, 0 };
    var dv = [3]i32{ 0, 0, 0 };
    du[u] = if (corner[u] == 0) -1 else 1;
    dv[v] = if (corner[v] == 0) -1 else 1;

    const side1 = padded.get(bx + du[0], by + du[1], bz + du[2]).isOpaque();
    const side2 = padded.get(bx + dv[0], by + dv[1], bz + dv[2]).isOpaque();
    const diagonal = padded.get(bx + du[0] + dv[0], by + du[1] + dv[1], bz + du[2] + dv[2]).isOpaque();

    if (side1 and side2) return 0;
    const occluders: u8 = @as(u8, @intFromBool(side1)) + @as(u8, @intFromBool(side2)) + @as(u8, @intFromBool(diagonal));
    return 3 - occluders;
}


// ------------------------------------------------------------------ greedy

/// One cell of a greedy sweep: the block whose face is visible there, the layer
/// that face uses and the four corner AO values. Two cells only merge when all
/// of it matches, which is the AO constraint ADR 0004 warned about.
const Cell = struct {
    present: bool = false,
    block: BlockId = .air,
    layer: u8 = 0,
    ao: [4]u8 = .{ 3, 3, 3, 3 },
};

/// Merge rule: same block and same layer. AO is deliberately *not* part of it -
/// requiring equal corner AO caps the gain near 2.5x on rugged terrain - so the
/// merged quad takes its four corner AO values from the cells that own those
/// corners instead. That is the standard trade: coarser AO, much better merging.
fn cellMatches(a: Cell, b: Cell) bool {
    if (!a.present or !b.present) return false;
    return a.block == b.block and a.layer == b.layer;
}

/// Corner positions in the face plane as (du, dv) in 0..1, derived from the
/// same corner table the naive mesher uses so the winding is identical.
fn cornerUv(face_index: usize) [4][2]f32 {
    const info = faces[face_index];
    var out: [4][2]f32 = undefined;
    for (info.corners, 0..) |c, i| {
        out[i] = .{ c[info.u], c[info.v] };
    }
    return out;
}

/// Greedy meshing (2.1): sweep each of the six face directions slice by slice,
/// build a mask of visible faces and merge equal neighbours into rectangles.
/// Same vertex format and same culling rules as `mesh`, so callers can switch
/// between them with a flag.
pub fn meshGreedy(padded: *const PaddedBlocks, out_vertices: []Vertex, out_indices: []u32) mesh_error!MeshStats {
    var vertex_count: usize = 0;
    var index_count: usize = 0;
    var quad_count: usize = 0;

    inline for (faces, face_order, 0..) |info, face, face_index| {
        const n = info.normal;
        // Axis the face points along, and the two axes that span the slice.
        const axis: usize = if (n[0] != 0) 0 else if (n[1] != 0) 1 else 2;
        const sign: i32 = n[axis];
        const u_axis = info.u;
        const v_axis = info.v;

        var slice: i32 = 0;
        while (slice < coords.CHUNK_SIZE) : (slice += 1) {
            // Build the 32x32 mask for this slice.
            var mask: [coords.CHUNK_SIZE * coords.CHUNK_SIZE]Cell = undefined;
            for (&mask) |*cell| cell.* = .{};

            var v: i32 = 0;
            while (v < coords.CHUNK_SIZE) : (v += 1) {
                var u: i32 = 0;
                while (u < coords.CHUNK_SIZE) : (u += 1) {
                    var coord = [_]i32{ 0, 0, 0 };
                    coord[axis] = slice;
                    coord[u_axis] = u;
                    coord[v_axis] = v;
                    const block = padded.get(coord[0], coord[1], coord[2]);
                    if (!isRenderable(block)) continue;
                    if (!faceVisible(block, padded.get(coord[0] + n[0], coord[1] + n[1], coord[2] + n[2]))) continue;

                    var cell = Cell{ .present = true, .block = block, .layer = block.layerFor(face) };
                    for (info.corners, 0..) |c, k| {
                        cell.ao[k] = cornerOcclusion(padded, coord[0] + n[0], coord[1] + n[1], coord[2] + n[2], c, u_axis, v_axis);
                    }
                    mask[@intCast(v * coords.CHUNK_SIZE + u)] = cell;
                }
            }

            // Merge rectangles.
            v = 0;
            while (v < coords.CHUNK_SIZE) : (v += 1) {
                var u: i32 = 0;
                while (u < coords.CHUNK_SIZE) : (u += 1) {
                    const index: usize = @intCast(v * coords.CHUNK_SIZE + u);
                    if (!mask[index].present) continue;

                    // Width along u.
                    var width: i32 = 1;
                    while (u + width < coords.CHUNK_SIZE and cellMatches(mask[index], mask[@intCast(v * coords.CHUNK_SIZE + u + width)])) width += 1;
                    // Height along v, every cell of the row equal to the first.
                    var height: i32 = 1;
                    outer: while (v + height < coords.CHUNK_SIZE) : (height += 1) {
                        var k: i32 = 0;
                        while (k < width) : (k += 1) {
                            const other = mask[@intCast((v + height) * coords.CHUNK_SIZE + u + k)];
                            if (!cellMatches(mask[index], other)) break :outer;
                        }
                    }

                    // AO for the merged rect comes from the four cells that own
                    // its corners, so a merged quad still shades like one cell.
                    var merged_ao = [4]u8{ 3, 3, 3, 3 };
                    if (width == 1 and height == 1) {
                        merged_ao = mask[index].ao;
                    } else {
                        const bottom_right: usize = @intCast(v * coords.CHUNK_SIZE + u + width - 1);
                        const top_right: usize = @intCast((v + height - 1) * coords.CHUNK_SIZE + u + width - 1);
                        const top_left: usize = @intCast((v + height - 1) * coords.CHUNK_SIZE + u);
                        merged_ao[0] = mask[index].ao[0];
                        merged_ao[1] = mask[bottom_right].ao[1];
                        merged_ao[2] = mask[top_right].ao[2];
                        merged_ao[3] = mask[top_left].ao[3];
                    }

                    // Emit the merged quad.
                    if (vertex_count + 4 > out_vertices.len) return error.VertexBufferTooSmall;
                    const plane: f32 = @floatFromInt(slice);
                    const offset: f32 = if (sign > 0) 1.0 else 0.0;
                    const uvs = cornerUv(face_index);
                    const base: u32 = @intCast(vertex_count);
                    for (uvs, 0..) |c, k| {
                        var pos = [_]f32{ 0, 0, 0 };
                        pos[axis] = plane + offset;
                        pos[u_axis] = @as(f32, @floatFromInt(u)) + c[0] * @as(f32, @floatFromInt(width));
                        pos[v_axis] = @as(f32, @floatFromInt(v)) + c[1] * @as(f32, @floatFromInt(height));
                        out_vertices[vertex_count + k] = .{
                            .pos = .{ pos[0], pos[1], pos[2] },
                            // UVs tile per block, so the array texture repeats.
                            .uv = .{ c[0] * @as(f32, @floatFromInt(width)), c[1] * @as(f32, @floatFromInt(height)) },
                            .layer = mask[index].layer,
                            .ao = merged_ao[k],
                            ._pad = .{ @intCast(@intFromEnum(face)), 0 },
                        };
                    }
                    out_indices[index_count + 0] = base + 0;
                    out_indices[index_count + 1] = base + 1;
                    out_indices[index_count + 2] = base + 2;
                    out_indices[index_count + 3] = base + 0;
                    out_indices[index_count + 4] = base + 2;
                    out_indices[index_count + 5] = base + 3;

                    vertex_count += 4;
                    index_count += 6;
                    quad_count += 1;

                    // Clear the consumed cells.
                    var dv: i32 = 0;
                    while (dv < height) : (dv += 1) {
                        var du: i32 = 0;
                        while (du < width) : (du += 1) {
                            mask[@intCast((v + dv) * coords.CHUNK_SIZE + u + du)] = .{};
                        }
                    }
                    u += width - 1;
                }
            }
        }
    }

    return .{ .quads = quad_count, .vertices = vertex_count, .indices = index_count };
}

/// Upper bound on quads for one chunk. The worst case is not a solid chunk
/// (6 x 32^2 = 6,144 surface faces) but a checkerboard: half the cells solid,
/// each of them fully exposed, so 16,384 x 6 = 98,304. Buffers sized for that
/// are ~11 MB, so callers should size for what they expect and handle
/// `error.VertexBufferTooSmall` instead of always reserving the bound.
pub const MAX_QUADS: usize = 6 * coords.CHUNK_SIZE * coords.CHUNK_SIZE * coords.CHUNK_SIZE / 2;
pub const MAX_VERTICES: usize = MAX_QUADS * 4;
pub const MAX_INDICES: usize = MAX_QUADS * 6;

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn meshAll(padded: *const PaddedBlocks, vertices: []Vertex, indices: []u32) !MeshStats {
    return mesh(padded, vertices, indices);
}

/// Test scratch: geometry buffers for `quads` quads, on the heap because the
/// worst-case bounds are far too big for a test stack frame.
const Buffers = struct {
    vertices: []Vertex,
    indices: []u32,

    fn init(allocator: std.mem.Allocator, quads: usize) !Buffers {
        return .{
            .vertices = try allocator.alloc(Vertex, quads * 4),
            .indices = try allocator.alloc(u32, quads * 6),
        };
    }

    fn deinit(self: Buffers, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

fn singleBlock(block: BlockId) PaddedBlocks {
    var padded = PaddedBlocks.init();
    padded.set(0, 0, 0, block);
    return padded;
}

test "vertex layout is 24 bytes per ADR 0004" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(Vertex));
    try testing.expectEqual(@as(usize, 4), @alignOf(Vertex));
}

test "one block gives six quads" {
    const padded = singleBlock(.stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 6), stats.quads);
    try testing.expectEqual(@as(usize, 24), stats.vertices);
    try testing.expectEqual(@as(usize, 36), stats.indices);
    try testing.expectEqual(@as(usize, 6 * 4 * 24 + 6 * 6 * 4), stats.bytes());
    for (buffers.indices[0..stats.indices]) |i| try testing.expect(i < stats.vertices);
}

test "a 2x2x2 solid block gives 24 quads" {
    var padded = PaddedBlocks.init();
    for (0..2) |x| for (0..2) |y| for (0..2) |z| padded.set(@intCast(x), @intCast(y), @intCast(z), .stone);
    const buffers = try Buffers.init(testing.allocator, 24);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 24), stats.quads);
    try testing.expectEqual(@as(usize, 96), stats.vertices);
}

test "a fully solid chunk gives 6144 quads (6 per surface face)" {
    var padded = PaddedBlocks.init();
    for (0..coords.CHUNK_SIZE) |x| {
        for (0..coords.CHUNK_SIZE) |y| {
            for (0..coords.CHUNK_SIZE) |z| {
                padded.set(@intCast(x), @intCast(y), @intCast(z), .stone);
            }
        }
    }
    const buffers = try Buffers.init(testing.allocator, 6144);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 6 * 32 * 32), stats.quads);
}

test "a face shared by two opaque blocks is culled" {
    var padded = PaddedBlocks.init();
    padded.set(0, 0, 0, .stone);
    padded.set(1, 0, 0, .stone);
    const buffers = try Buffers.init(testing.allocator, 12);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    // 12 faces minus the two facing each other.
    try testing.expectEqual(@as(usize, 10), stats.quads);
}

test "air, water and leaves do not occlude" {
    const neighbours = [_]BlockId{ .air, .water, .leaves };
    for (neighbours) |n| {
        var padded = PaddedBlocks.init();
        padded.set(0, 0, 0, .stone);
        padded.set(1, 0, 0, n);
        const buffers = try Buffers.init(testing.allocator, 12);
        defer buffers.deinit(testing.allocator);
        const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
        // Leaves are solid and add five faces (the one facing the stone is
        // culled); water draws only against air, so it adds five as well.
        const expected: usize = switch (n) {
            .air => 6,
            else => 11,
        };
        try testing.expectEqual(expected, stats.quads);
    }
}

test "air emits nothing and water only draws where it meets air" {
    var air = PaddedBlocks.init();
    air.set(5, 5, 5, .air);
    {
        const buffers = try Buffers.init(testing.allocator, 1);
        defer buffers.deinit(testing.allocator);
        const stats = try meshAll(&air, buffers.vertices, buffers.indices);
        try testing.expectEqual(@as(usize, 0), stats.quads);
    }

    // A lone water block is all surface.
    var water = PaddedBlocks.init();
    water.set(5, 5, 5, .water);
    {
        const buffers = try Buffers.init(testing.allocator, 8);
        defer buffers.deinit(testing.allocator);
        const stats = try meshAll(&water, buffers.vertices, buffers.indices);
        try testing.expectEqual(@as(usize, 6), stats.quads);
    }

    // Water against water has no internal faces; against stone it is hidden.
    var pooled = PaddedBlocks.init();
    pooled.set(5, 5, 5, .water);
    pooled.set(6, 5, 5, .water);
    pooled.set(7, 5, 5, .stone);
    {
        const buffers = try Buffers.init(testing.allocator, 32);
        defer buffers.deinit(testing.allocator);
        const stats = try meshAll(&pooled, buffers.vertices, buffers.indices);
        // 10 faces between the two waters minus the two touching each other,
        // plus the stone's five exposed faces.
        try testing.expectEqual(@as(usize, 15), stats.quads);
    }
}

test "grass uses the top layer above and the side layer around" {
    const padded = singleBlock(.grass);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 6), stats.quads);

    // Face order is px, nx, py, ny, pz, nz: the third quad is the top.
    try testing.expectEqual(blocks.LAYER_GRASS_SIDE, buffers.vertices[0].layer); // +x
    try testing.expectEqual(blocks.LAYER_GRASS_SIDE, buffers.vertices[4].layer); // -x
    try testing.expectEqual(blocks.LAYER_GRASS_TOP, buffers.vertices[8].layer); // +y
    try testing.expectEqual(blocks.LAYER_DIRT, buffers.vertices[12].layer); // -y
    try testing.expectEqual(blocks.LAYER_GRASS_SIDE, buffers.vertices[16].layer); // +z
    try testing.expectEqual(blocks.LAYER_GRASS_SIDE, buffers.vertices[20].layer); // -z
}

test "the top face sits at y + 1 and its UVs run up the face" {
    const padded = singleBlock(.stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    _ = try meshAll(&padded, buffers.vertices, buffers.indices);

    // +y quad occupies vertices 8..11 (third face).
    for (buffers.vertices[8..12]) |v| try testing.expectEqual(@as(f32, 1), v.pos[1]);
    // Corners map to the four UV combinations, including (0,0) and (1,1).
    try testing.expectEqual(@as(f32, 0), buffers.vertices[8].uv[0]);
    try testing.expectEqual(@as(f32, 0), buffers.vertices[8].uv[1]);
    try testing.expectEqual(@as(f32, 1), buffers.vertices[10].uv[0]);
    try testing.expectEqual(@as(f32, 1), buffers.vertices[10].uv[1]);
    // 1.12 fills AO: a lone block has nothing occluding it, so it is fully open.
    try testing.expectEqual(@as(u8, 3), buffers.vertices[8].ao);
}

test "the padded buffer samples the border for culling" {
    var padded = PaddedBlocks.init();
    padded.set(0, 4, 0, .stone);
    // A neighbour chunk's block sits at x = -1, i.e. one step outside the chunk.
    padded.set(-1, 4, 0, .stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 5), stats.quads); // the -x face is culled
}

test "a full buffer reports the capacity error instead of overrunning" {
    var padded = PaddedBlocks.init();
    for (0..2) |x| for (0..2) |y| for (0..2) |z| padded.set(@intCast(x), @intCast(y), @intCast(z), .stone);
    var vertices: [23]Vertex = undefined;
    var indices: [64]u32 = undefined;
    try testing.expectError(error.VertexBufferTooSmall, mesh(&padded, &vertices, &indices));
}

test "a lone block has no occlusion on any corner" {
    const padded = singleBlock(.stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    _ = try meshAll(&padded, buffers.vertices, buffers.indices);
    for (buffers.vertices[0..24]) |v| try testing.expectEqual(@as(u8, 3), v.ao);
}

test "an occluder darkens the corners it touches" {
    var padded = PaddedBlocks.init();
    padded.set(0, 0, 0, .stone);
    // A block diagonally above and to the side of the +y face.
    padded.set(1, 1, 0, .stone);
    const buffers = try Buffers.init(testing.allocator, 32);
    defer buffers.deinit(testing.allocator);
    _ = try meshAll(&padded, buffers.vertices, buffers.indices);

    var darker: usize = 0;
    for (buffers.vertices[0..24]) |v| {
        if (v.ao < 3) darker += 1;
    }
    try testing.expect(darker > 0);
}

test "a corner between two solid neighbours is fully occluded" {
    var padded = PaddedBlocks.init();
    padded.set(0, 0, 0, .stone);
    // Neighbours of the +y face: side at +x, side at +z.
    padded.set(1, 1, 0, .stone);
    padded.set(0, 1, 1, .stone);
    const buffers = try Buffers.init(testing.allocator, 32);
    defer buffers.deinit(testing.allocator);
    _ = try meshAll(&padded, buffers.vertices, buffers.indices);

    // The +y quad is vertices 8..11; the corner towards (+x,+z) must be 0.
    var darkest: u8 = 3;
    for (buffers.vertices[8..12]) |v| darkest = @min(darkest, v.ao);
    try testing.expectEqual(@as(u8, 0), darkest);
}

test "every quad carries its face id in the pad byte" {
    const padded = singleBlock(.stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    _ = try meshAll(&padded, buffers.vertices, buffers.indices);
    // Faces are emitted in order px, nx, py, ny, pz, nz.
    for (0..6) |face| {
        const id: u8 = @intCast(face);
        for (buffers.vertices[face * 4 .. face * 4 + 4]) |v| try testing.expectEqual(id, v._pad[0]);
    }
}

test "greedy merges a flat plane into one quad" {
    // A 32x32 slab with air around it: every top face is the same block, layer
    // and AO (3), so the whole surface merges into a single quad.
    var padded = PaddedBlocks.init();
    var z: i32 = 0;
    while (z < coords.CHUNK_SIZE) : (z += 1) {
        var x: i32 = 0;
        while (x < coords.CHUNK_SIZE) : (x += 1) padded.set(x, 0, z, .stone);
    }
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshGreedy(&padded, buffers.vertices, buffers.indices);
    // Top and bottom merge to one quad each; the four sides are one quad each.
    try testing.expectEqual(@as(usize, 6), stats.quads);
}

test "greedy keeps the same surface area as the naive mesher" {
    // Same chunk, two meshers: the summed quad area must match, which catches a
    // merge that swallowed or duplicated geometry.
    var padded = PaddedBlocks.init();
    var z: i32 = 0;
    while (z < 16) : (z += 1) {
        var y: i32 = 0;
        while (y < 6) : (y += 1) {
            var x: i32 = 0;
            while (x < 16) : (x += 1) {
                const block: BlockId = if (y == 5) .grass else if (y > 2) .dirt else .stone;
                padded.set(x, y, z, block);
            }
        }
    }
    const buffers = try Buffers.init(testing.allocator, 20000);
    defer buffers.deinit(testing.allocator);

    const naive = try mesh(&padded, buffers.vertices, buffers.indices);
    const naive_area = quadArea(buffers.vertices[0..naive.vertices]);
    const greedy = try meshGreedy(&padded, buffers.vertices, buffers.indices);
    const greedy_area = quadArea(buffers.vertices[0..greedy.vertices]);

    try testing.expect(naive.quads > greedy.quads);
    try testing.expectApproxEqRel(naive_area, greedy_area, 0.0001);
}

/// Sums the area of every quad in a vertex list (4 vertices per quad).
fn quadArea(vertices: []const Vertex) f64 {
    var total: f64 = 0;
    var i: usize = 0;
    while (i + 3 < vertices.len) : (i += 4) {
        const a = vertices[i].pos;
        const b = vertices[i + 1].pos;
        const c = vertices[i + 3].pos;
        const ab = [3]f64{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const ac = [3]f64{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const cross = [3]f64{
            ab[1] * ac[2] - ab[2] * ac[1],
            ab[2] * ac[0] - ab[0] * ac[2],
            ab[0] * ac[1] - ab[1] * ac[0],
        };
        total += @sqrt(cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]);
    }
    return total;
}

test "fillFromChunk copies the body and chunkIsEmpty sees it" {
    var padded = PaddedBlocks.init();
    try testing.expect(padded.chunkIsEmpty());

    var chunk = Chunk.init(coords.ChunkPos.init(0, 0, 0));
    chunk.setBlock(3, 7, 11, .sand);
    chunk.setBlock(31, 31, 31, .wood);
    padded.fillFromChunk(&chunk);
    try testing.expect(!padded.chunkIsEmpty());
    try testing.expectEqual(BlockId.sand, padded.get(3, 7, 11));
    try testing.expectEqual(BlockId.wood, padded.get(31, 31, 31));
    try testing.expectEqual(BlockId.air, padded.get(-1, 7, 11));
}

// ------------------------------------------------------------ normals (3.3)

/// Geometric normal of the triangle (v0, v1, v2), normalized.
fn triangleNormal(v0: Vertex, v1: Vertex, v2: Vertex) [3]f32 {
    const ax = v1.pos[0] - v0.pos[0];
    const ay = v1.pos[1] - v0.pos[1];
    const az = v1.pos[2] - v0.pos[2];
    const bx = v2.pos[0] - v0.pos[0];
    const by = v2.pos[1] - v0.pos[1];
    const bz = v2.pos[2] - v0.pos[2];
    const nx = ay * bz - az * by;
    const ny = az * bx - ax * bz;
    const nz = ax * by - ay * bx;
    const len = std.math.sqrt(nx * nx + ny * ny + nz * nz);
    return .{ nx / len, ny / len, nz / len };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

test "faceNormal is a unit outward normal with opposite pairs" {
    const all = [_]blocks.Face{ .px, .nx, .py, .ny, .pz, .nz };
    for (all) |face| {
        const n = blocks.faceNormal(face);
        const length_sq = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
        try testing.expectApproxEqAbs(@as(f32, 1.0), length_sq, 1e-6);
        // Exactly one axis set.
        var nonzero: usize = 0;
        for (n) |component| {
            if (component != 0) nonzero += 1;
        }
        try testing.expectEqual(@as(usize, 1), nonzero);
    }
    // px + nx = 0, and so on: the six are three opposite pairs, all distinct.
    for (0..3) |axis| {
        const positive = blocks.faceNormal(all[axis * 2]);
        const negative = blocks.faceNormal(all[axis * 2 + 1]);
        try testing.expectApproxEqAbs(@as(f32, 0.0), positive[0] + negative[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.0), positive[1] + negative[1], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.0), positive[2] + negative[2], 1e-6);
    }
}

test "the mesher's own normal table matches block.faceNormal" {
    // Two tables exist for one mapping (the mesher needs a normal per face for
    // its own bookkeeping, the shader needs the same six entries). This test is
    // the thing that stops them drifting apart.
    for (faces, face_order) |info, face| {
        const expected = blocks.faceNormal(face);
        // FaceInfo.normal is [3]i32, faceNormal returns [3]f32: compare as floats.
        try testing.expectEqual(expected[0], @as(f32, @floatFromInt(info.normal[0])));
        try testing.expectEqual(expected[1], @as(f32, @floatFromInt(info.normal[1])));
        try testing.expectEqual(expected[2], @as(f32, @floatFromInt(info.normal[2])));
    }
}

test "one block emits six distinct face ids, four vertices each" {
    const padded = singleBlock(.stone);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);

    var counts = [6]usize{ 0, 0, 0, 0, 0, 0 };
    for (buffers.vertices[0..stats.vertices]) |vertex| {
        const id = vertex._pad[0];
        try testing.expect(id < 6);
        counts[id] += 1;
    }
    for (counts) |count| try testing.expectEqual(@as(usize, 4), count);
}

test "every quad's winding agrees with its face id (naive)" {
    // A cube plus a step, so more than one face direction is present and the
    // geometry is not all axis-aligned to the origin.
    var padded = PaddedBlocks.init();
    padded.set(4, 4, 4, .stone);
    padded.set(5, 4, 4, .stone);
    padded.set(4, 5, 4, .stone);

    // Three blocks reach 18 faces at most; 32 quads is comfortably enough.
    const buffers = try Buffers.init(testing.allocator, 32);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expect(stats.quads > 0);

    var quad: usize = 0;
    while (quad < stats.quads) : (quad += 1) {
        const v0 = buffers.vertices[quad * 4];
        const v1 = buffers.vertices[quad * 4 + 1];
        const v2 = buffers.vertices[quad * 4 + 2];
        const id = v0._pad[0];
        // All four vertices of a quad share the face id.
        try testing.expectEqual(id, v1._pad[0]);
        try testing.expectEqual(id, v2._pad[0]);
        try testing.expectEqual(id, buffers.vertices[quad * 4 + 3]._pad[0]);

        const geometric = triangleNormal(v0, v1, v2);
        const expected = blocks.faceNormal(@enumFromInt(id));
        try testing.expect(dot(geometric, expected) > 0.999);
    }
}

test "greedy merged quads keep the right face id" {
    // The 32x32 slab merges each face into a single quad; a merged quad must
    // still carry the face id its geometry points along.
    var padded = PaddedBlocks.init();
    var z: i32 = 0;
    while (z < coords.CHUNK_SIZE) : (z += 1) {
        var x: i32 = 0;
        while (x < coords.CHUNK_SIZE) : (x += 1) padded.set(x, 0, z, .stone);
    }
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshGreedy(&padded, buffers.vertices, buffers.indices);

    var quad: usize = 0;
    while (quad < stats.quads) : (quad += 1) {
        const v0 = buffers.vertices[quad * 4];
        const v1 = buffers.vertices[quad * 4 + 1];
        const v2 = buffers.vertices[quad * 4 + 2];
        const geometric = triangleNormal(v0, v1, v2);
        const expected = blocks.faceNormal(@enumFromInt(v0._pad[0]));
        try testing.expect(dot(geometric, expected) > 0.999);
    }
}
