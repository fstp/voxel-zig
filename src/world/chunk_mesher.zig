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

    var z: i32 = 0;
    while (z < coords.CHUNK_SIZE) : (z += 1) {
        var y: i32 = 0;
        while (y < coords.CHUNK_SIZE) : (y += 1) {
            var x: i32 = 0;
            while (x < coords.CHUNK_SIZE) : (x += 1) {
                padded.set(x, y, z, world.getBlock(origin.x + x, origin.y + y, origin.z + z));
            }
        }
    }

    // The six border planes. Only these matter for face culling; the twelve
    // edges and eight corners are left as air (1.12's AO will sample them).
    const directions = [_][3]i32{
        .{ -1, 0, 0 }, .{ 1, 0, 0 },
        .{ 0, -1, 0 }, .{ 0, 1, 0 },
        .{ 0, 0, -1 }, .{ 0, 0, 1 },
    };
    for (directions) |d| {
        const neighbour = pos.offset(d[0], d[1], d[2]);
        const loaded = neighbour.y >= 0 and neighbour.y < coords.CHUNK_COUNT_Y and world.isLoaded(neighbour);
        const border_block: BlockId = if (loaded) .air else .stone;

        var a: i32 = 0;
        while (a < coords.CHUNK_SIZE) : (a += 1) {
            var b: i32 = 0;
            while (b < coords.CHUNK_SIZE) : (b += 1) {
                var cell = [_]i32{ 0, 0, 0 };
                if (d[0] != 0) {
                    cell = .{ if (d[0] < 0) -1 else coords.CHUNK_SIZE, a, b };
                } else if (d[1] != 0) {
                    cell = .{ a, if (d[1] < 0) -1 else coords.CHUNK_SIZE, b };
                } else {
                    cell = .{ a, b, if (d[2] < 0) -1 else coords.CHUNK_SIZE };
                }
                const block = if (loaded) world.getBlock(origin.x + cell[0], origin.y + cell[1], origin.z + cell[2]) else border_block;
                padded.set(cell[0], cell[1], cell[2], block);
            }
        }
    }
}

/// Meshes one loaded chunk into caller-provided buffers.
pub fn meshChunk(
    world: *const World,
    pos: ChunkPos,
    padded: *mesher.PaddedBlocks,
    vertices: []mesher.Vertex,
    indices: []u32,
) !mesher.MeshStats {
    fillPadded(world, pos, padded);
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

    const stats = try meshChunk(&world, ChunkPos.init(0, 0, 0), &padded, buffers, ibuffers);
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

    const stats = try meshChunk(&world, ChunkPos.init(0, 0, 0), &padded, buffers, ibuffers);
    try testing.expectEqual(@as(usize, 5), stats.quads);
}
