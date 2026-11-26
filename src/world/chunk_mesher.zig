const std = @import("std");
const coords = @import("../voxel/coords.zig");
const mesher = @import("../voxel/mesher.zig");
const BlockId = @import("../voxel/block.zig").BlockId;
const World = @import("world.zig").World;
const ChunkPos = coords.ChunkPos;

/// Samples a chunk and its one-block border out of the world into the mesher's
/// padded buffer (ADR 0004).
///
/// A neighbour that is not loaded counts as **opaque**, so the frontier does not
/// emit a wall of faces that would be re-emitted as soon as the neighbour
/// arrives; a chunk that loads marks its neighbours dirty so the seam opens.
/// The same rule covers the world floor (y < 0), which is why the underside of
/// the world costs no quads.
pub fn fillPadded(world: *const World, pos: ChunkPos, padded: *mesher.PaddedBlocks) void {
    const origin = pos.blockOrigin();

    var iz: i32 = 0;
    while (iz < coords.CHUNK_SIZE) : (iz += 1) {
        var iy: i32 = 0;
        while (iy < coords.CHUNK_SIZE) : (iy += 1) {
            var ix: i32 = 0;
            while (ix < coords.CHUNK_SIZE) : (ix += 1) {
                padded.set(ix, iy, iz, world.getBlock(origin.x + ix, origin.y + iy, origin.z + iz));
            }
        }
    }

    // The one-block border. A cell whose only out-of-range axis is the face
    // normal sits on a face plane: there, an unloaded neighbour counts as
    // opaque so the frontier emits no wall of faces. Cells on an edge or a
    // corner (two or three axes out of range) only feed 1.12's AO, so they are
    // sampled when their diagonal chunk is loaded and left as air otherwise,
    // which keeps a freshly loaded chunk bright instead of shadowed.
    var plane_loaded = [_]bool{ false, false, false, false, false, false };
    const directions = [_][3]i32{
        .{ -1, 0, 0 }, .{ 1, 0, 0 },
        .{ 0, -1, 0 }, .{ 0, 1, 0 },
        .{ 0, 0, -1 }, .{ 0, 0, 1 },
    };
    for (directions, 0..) |d, i| {
        const neighbour = pos.offset(d[0], d[1], d[2]);
        plane_loaded[i] = neighbour.y >= 0 and neighbour.y < coords.CHUNK_COUNT_Y and world.isLoaded(neighbour);
    }

    var bz_i: i32 = -1;
    while (bz_i <= coords.CHUNK_SIZE) : (bz_i += 1) {
        var by_i: i32 = -1;
        while (by_i <= coords.CHUNK_SIZE) : (by_i += 1) {
            var bx_i: i32 = -1;
            while (bx_i <= coords.CHUNK_SIZE) : (bx_i += 1) {
                const x = bx_i;
                const y = by_i;
                const z = bz_i;
                const outside: u8 = @as(u8, @intFromBool(x < 0 or x >= coords.CHUNK_SIZE)) +
                    @as(u8, @intFromBool(y < 0 or y >= coords.CHUNK_SIZE)) +
                    @as(u8, @intFromBool(z < 0 or z >= coords.CHUNK_SIZE));
                if (outside == 0) continue; // interior already copied above

                var block: BlockId = .air;
                if (outside == 1) {
                    // Which face plane is this?
                    const index: usize = if (x < 0) 0 else if (x >= coords.CHUNK_SIZE) 1 else if (y < 0) 2 else if (y >= coords.CHUNK_SIZE) 3 else if (z < 0) 4 else 5;
                    if (plane_loaded[index]) {
                        block = world.getBlock(origin.x + x, origin.y + y, origin.z + z);
                    } else {
                        block = .stone;
                    }
                } else {
                    const chunk_pos = ChunkPos.init(
                        @divFloor(origin.x + x, coords.CHUNK_SIZE),
                        @divFloor(origin.y + y, coords.CHUNK_SIZE),
                        @divFloor(origin.z + z, coords.CHUNK_SIZE),
                    );
                    if (chunk_pos.y >= 0 and chunk_pos.y < coords.CHUNK_COUNT_Y and world.isLoaded(chunk_pos)) {
                        block = world.getBlock(origin.x + x, origin.y + y, origin.z + z);
                    }
                }
                padded.set(x, y, z, block);
            }
        }
    }
}

/// Meshes one loaded chunk into caller-provided buffers. `greedy` selects the
/// 2.1 mesher; both emit the same vertex format and obey the same culling rules.
pub fn meshChunk(
    world: *const World,
    pos: ChunkPos,
    padded: *mesher.PaddedBlocks,
    vertices: []mesher.Vertex,
    indices: []u32,
    greedy: bool,
) !mesher.MeshStats {
    fillPadded(world, pos, padded);
    if (greedy) return mesher.meshGreedy(padded, vertices, indices);
    return mesher.mesh(padded, vertices, indices);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;

test "the border is sampled from a loaded neighbour" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const left = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    left.setBlock(31, 5, 5, .stone);
    _ = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));

    var padded = mesher.PaddedBlocks.init();
    fillPadded(&world, ChunkPos.init(0, 0, 0), &padded);
    try testing.expectEqual(BlockId.stone, padded.get(-1, 5, 5));
    try testing.expectEqual(BlockId.air, padded.get(0, 5, 5));
}

test "an unloaded neighbour counts as opaque, so the frontier is culled" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const chunk = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    chunk.setBlock(31, 5, 5, .stone);

    var padded = mesher.PaddedBlocks.init();
    const buffers = try testing.allocator.alloc(mesher.Vertex, 64);
    defer testing.allocator.free(buffers);
    const ibuffers = try testing.allocator.alloc(u32, 96);
    defer testing.allocator.free(ibuffers);

    const stats = try meshChunk(&world, ChunkPos.init(0, 0, 0), &padded, buffers, ibuffers, false);
    // Five faces: the +x one faces an unloaded chunk and is treated as hidden.
    try testing.expectEqual(@as(usize, 5), stats.quads);
}

test "the world floor is opaque and costs no quads" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const chunk = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    chunk.setBlock(4, 0, 4, .stone);

    var padded = mesher.PaddedBlocks.init();
    fillPadded(&world, ChunkPos.init(0, 0, 0), &padded);
    try testing.expectEqual(BlockId.stone, padded.get(4, -1, 4));
}

test "an interior border block culls the chunk's face" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const right = try world.getOrCreateChunk(ChunkPos.init(1, 0, 0));
    right.setBlock(0, 5, 5, .stone);
    const chunk = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    chunk.setBlock(31, 5, 5, .stone);

    var padded = mesher.PaddedBlocks.init();
    const buffers = try testing.allocator.alloc(mesher.Vertex, 64);
    defer testing.allocator.free(buffers);
    const ibuffers = try testing.allocator.alloc(u32, 96);
    defer testing.allocator.free(ibuffers);

    const stats = try meshChunk(&world, ChunkPos.init(0, 0, 0), &padded, buffers, ibuffers, false);
    try testing.expectEqual(@as(usize, 5), stats.quads);
}
