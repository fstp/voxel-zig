const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const World = @import("world.zig").World;
const ChunkPos = coords.ChunkPos;

/// Stand-in terrain for 1.7: a 5 x 5 chunk field, two chunk layers tall, with a
/// smooth rolling surface so chunk seams are easy to spot. Real noise worldgen
/// replaces this in 1.8 - this file exists only so the renderer has something
/// to draw.
pub const FIELD_CHUNKS_X: i32 = 5;
pub const FIELD_CHUNKS_Z: i32 = 5;
pub const FIELD_CHUNKS_Y: i32 = 2;
pub const CHUNK_COUNT: usize = @intCast(FIELD_CHUNKS_X * FIELD_CHUNKS_Y * FIELD_CHUNKS_Z);

/// Surface height in blocks (world y), smooth over the field.
pub fn surfaceAt(wx: i32, wz: i32) i32 {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const h = 44.0 + 6.0 * @sin(x * 0.045) + 4.0 * @cos(z * 0.037) + 2.0 * @sin((x + z) * 0.021);
    return @intFromFloat(@floor(h));
}

pub fn blockAt(wx: i32, wy: i32, wz: i32) BlockId {
    if (wy < 0 or wy >= coords.WORLD_HEIGHT) return .air;
    const surface = surfaceAt(wx, wz);
    if (wy > surface) return .air;
    if (wy == surface) return .grass;
    if (wy > surface - 4) return .dirt;
    return .stone;
}

pub fn chunkPositions() [CHUNK_COUNT]ChunkPos {
    var positions: [CHUNK_COUNT]ChunkPos = undefined;
    var i: usize = 0;
    for (0..FIELD_CHUNKS_Y) |cy| {
        for (0..FIELD_CHUNKS_Z) |cz| {
            for (0..FIELD_CHUNKS_X) |cx| {
                positions[i] = ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz));
                i += 1;
            }
        }
    }
    return positions;
}

/// Fills the world with the fixture. Chunks are only created where the surface
/// crosses them, but the two layers here cover 0..63, which contains it.
pub fn build(world: *World) !void {
    for (chunkPositions()) |pos| {
        const chunk = try world.getOrCreateChunk(pos);
        const origin = pos.blockOrigin();
        var lz: i32 = 0;
        while (lz < coords.CHUNK_SIZE) : (lz += 1) {
            var lx: i32 = 0;
            while (lx < coords.CHUNK_SIZE) : (lx += 1) {
                var ly: i32 = 0;
                while (ly < coords.CHUNK_SIZE) : (ly += 1) {
                    const block = blockAt(origin.x + lx, origin.y + ly, origin.z + lz);
                    chunk.blocks[coords.localIndex(lx, ly, lz)] = block;
                }
            }
        }
        chunk.state = .ready;
    }
}

test "fixture surface is inside the two generated chunk layers" {
    var min_h: i32 = std.math.maxInt(i32);
    var max_h: i32 = 0;
    for (0..160) |x| {
        for (0..160) |z| {
            const h = surfaceAt(@intCast(x), @intCast(z));
            min_h = @min(min_h, h);
            max_h = @max(max_h, h);
        }
    }
    // Both generated chunk layers (world y 0..63) must contain the surface,
    // with at least a block to spare at each end.
    try std.testing.expect(min_h >= 1);
    try std.testing.expect(max_h <= 62);
}

test "fixture layers stone, dirt and grass in order" {
    const wx = 80;
    const wz = 80;
    const h = surfaceAt(wx, wz);
    try std.testing.expectEqual(BlockId.grass, blockAt(wx, h, wz));
    try std.testing.expectEqual(BlockId.dirt, blockAt(wx, h - 1, wz));
    try std.testing.expectEqual(BlockId.dirt, blockAt(wx, h - 3, wz));
    try std.testing.expectEqual(BlockId.stone, blockAt(wx, h - 4, wz));
    try std.testing.expectEqual(BlockId.air, blockAt(wx, h + 1, wz));
}

test "fixture builds 50 chunks with a solid core" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try build(&world);
    try std.testing.expectEqual(CHUNK_COUNT, world.count());

    // The bottom layer is below the surface everywhere, so it is fully solid.
    const bottom = world.getChunk(ChunkPos.init(2, 0, 2)).?;
    try std.testing.expectEqual(coords.CHUNK_VOLUME, bottom.countBlocks(.stone) + bottom.countBlocks(.dirt) + bottom.countBlocks(.grass));
    // The top layer has air above the surface.
    const top = world.getChunk(ChunkPos.init(2, 1, 2)).?;
    try std.testing.expect(top.countBlocks(.air) > 0);
}
