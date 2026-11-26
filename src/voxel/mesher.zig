const std = @import("std");
const BlockId = @import("block.zig").BlockId;
const Face = @import("block.zig").Face;
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
                if (!block.isSolid()) continue;

                inline for (faces, face_order) |info, face| {
                    const n = info.normal;
                    // An opaque neighbour hides the face; air, water and leaves
                    // do not (ADR 0004's boundary table).
                    if (!padded.get(x + n[0], y + n[1], z + n[2]).isOpaque()) {
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
        // Water is not solid so it emits nothing; leaves are solid, so they add
        // five faces (the one facing the stone is culled by the stone itself).
        const expected: usize = if (n == .leaves) 11 else 6;
        try testing.expectEqual(expected, stats.quads);
    }
}

test "transparent and non-solid blocks emit nothing of their own" {
    const blocks = [_]BlockId{ .air, .water };
    for (blocks) |b| {
        var padded = PaddedBlocks.init();
        padded.set(5, 5, 5, b);
        const buffers = try Buffers.init(testing.allocator, 1);
        defer buffers.deinit(testing.allocator);
        const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
        try testing.expectEqual(@as(usize, 0), stats.quads);
    }
}

test "grass uses the top layer above and the side layer around" {
    const padded = singleBlock(.grass);
    const buffers = try Buffers.init(testing.allocator, 8);
    defer buffers.deinit(testing.allocator);
    const stats = try meshAll(&padded, buffers.vertices, buffers.indices);
    try testing.expectEqual(@as(usize, 6), stats.quads);

    // Face order is px, nx, py, ny, pz, nz: the third quad is the top.
    const block = @import("block.zig");
    try testing.expectEqual(block.LAYER_GRASS_SIDE, buffers.vertices[0].layer); // +x
    try testing.expectEqual(block.LAYER_GRASS_SIDE, buffers.vertices[4].layer); // -x
    try testing.expectEqual(block.LAYER_GRASS_TOP, buffers.vertices[8].layer); // +y
    try testing.expectEqual(block.LAYER_DIRT, buffers.vertices[12].layer); // -y
    try testing.expectEqual(block.LAYER_GRASS_SIDE, buffers.vertices[16].layer); // +z
    try testing.expectEqual(block.LAYER_GRASS_SIDE, buffers.vertices[20].layer); // -z
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
