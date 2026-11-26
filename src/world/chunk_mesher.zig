const std = @import("std");
const coords = @import("../voxel/coords.zig");
const mesher = @import("../voxel/mesher.zig");
const World = @import("world.zig").World;
const ChunkPos = coords.ChunkPos;

/// Samples a chunk and its one-block border out of the world into the mesher's
/// padded buffer (ADR 0004).
///
/// A chunk that is not loaded reads as air, so the outer ring of a fixed field
/// emits its shell and the world looks solid from outside. Streaming (1.11)
/// flips that border to "treat as opaque" for the same reason the ADR gives:
/// the frontier should not emit a wall of faces it will re-emit on load.
pub fn fillPadded(world: *const World, pos: ChunkPos, padded: *mesher.PaddedBlocks) void {
    const origin = pos.blockOrigin();
    var z: i32 = -1;
    while (z <= coords.CHUNK_SIZE) : (z += 1) {
        var y: i32 = -1;
        while (y <= coords.CHUNK_SIZE) : (y += 1) {
            var x: i32 = -1;
            while (x <= coords.CHUNK_SIZE) : (x += 1) {
                padded.set(x, y, z, world.getBlock(origin.x + x, origin.y + y, origin.z + z));
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
const BlockId = @import("../voxel/block.zig").BlockId;

test "the border is sampled from the neighbouring chunk" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const left = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    left.setBlock(31, 5, 5, .stone); // touches x = 0 from the left
    _ = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));

    var padded = mesher.PaddedBlocks.init();
    fillPadded(&world, ChunkPos.init(0, 0, 0), &padded);
    try testing.expectEqual(BlockId.stone, padded.get(-1, 5, 5));
    try testing.expectEqual(BlockId.air, padded.get(0, 5, 5));
}

test "an interior border block culls the chunk's face" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const right = try world.getOrCreateChunk(ChunkPos.init(1, 0, 0));
    right.setBlock(0, 5, 5, .stone); // world x = 32, one step past our chunk
    const chunk = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    chunk.setBlock(31, 5, 5, .stone);

    var padded = mesher.PaddedBlocks.init();
    const buffers = try testing.allocator.alloc(mesher.Vertex, 64);
    defer testing.allocator.free(buffers);
    const ibuffers = try testing.allocator.alloc(u32, 96);
    defer testing.allocator.free(ibuffers);

    const stats = try meshChunk(&world, ChunkPos.init(0, 0, 0), &padded, buffers, ibuffers);
    // One block with a neighbour on +x: five faces, not six.
    try testing.expectEqual(@as(usize, 5), stats.quads);
}

test "an unloaded neighbour leaves the face visible" {
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
    try testing.expectEqual(@as(usize, 6), stats.quads);
}
