const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const Chunk = @import("chunk.zig").Chunk;
const noise = @import("noise.zig");

/// Terrain v1 (ADR 0005): a 2D heightmap from three fBm layers plus a layer
/// fill. Everything here is a pure function of `(seed, world position)` - no
/// chunk sees any other chunk - so chunks can generate in any order, on any
/// thread, and be re-generated later and compared.

pub const SEA_LEVEL: i32 = 62;
pub const MIN_HEIGHT: i32 = 8;
pub const MAX_HEIGHT: i32 = 120;

/// Base height plus continents, hills and detail.
pub fn heightAt(seed: u32, wx: i32, wz: i32) i32 {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);

    const continental = noise.fbm2(seed, x * 0.0045, z * 0.0045, 4, 2.0, 0.5) * 46.0;
    const hills = noise.fbm2(seed, x * 0.021, z * 0.021, 3, 2.0, 0.5) * 9.0;
    const detail = noise.fbm2(seed, x * 0.09, z * 0.09, 2, 2.0, 0.5) * 2.5;

    const h = 54.0 + continental + hills + detail;
    const clamped = std.math.clamp(@as(i32, @intFromFloat(@floor(h))), MIN_HEIGHT, MAX_HEIGHT);
    return clamped;
}

/// What a single voxel is, given the column's surface height.
pub fn blockForHeight(wy: i32, surface: i32) BlockId {
    if (wy > surface) return .air;
    if (wy == surface) return .grass;
    if (wy >= surface - 3) return .dirt;
    return .stone;
}

pub fn blockAt(seed: u32, wx: i32, wy: i32, wz: i32) BlockId {
    if (wy < 0 or wy >= coords.WORLD_HEIGHT) return .air;
    return blockForHeight(wy, heightAt(seed, wx, wz));
}

/// Fills one chunk. Pure in `(seed, chunk.pos)`: one height sample per column,
/// then the layer fill.
pub fn generateChunk(chunk: *Chunk, seed: u32) void {
    generateInto(&chunk.blocks, chunk.pos, seed);
    chunk.state = .ready;
    chunk.revision +%= 1;
}

/// The worker-safe half of generation: fills a raw 32^3 buffer for `pos` and
/// touches nothing else, so it can run off the main thread (1.13) while the
/// world map stays owned by the main thread.
pub fn generateInto(blocks: *[coords.CHUNK_VOLUME]BlockId, pos: coords.ChunkPos, seed: u32) void {
    const origin = pos.blockOrigin();
    @memset(blocks, .air);

    var lz: i32 = 0;
    while (lz < coords.CHUNK_SIZE) : (lz += 1) {
        var lx: i32 = 0;
        while (lx < coords.CHUNK_SIZE) : (lx += 1) {
            const surface = heightAt(seed, origin.x + lx, origin.z + lz);
            // Local y of the surface; negative means the whole chunk is above it.
            const top = surface - origin.y;
            if (top < 0) continue;
            const last: i32 = @min(top, coords.CHUNK_SIZE - 1);

            var ly: i32 = 0;
            while (ly <= last) : (ly += 1) {
                blocks[coords.localIndex(lx, ly, lz)] = blockForHeight(origin.y + ly, surface);
            }
        }
    }
}

/// True when every column of the chunk sits below nothing at all: a cheap
/// pre-check so a streaming loader can skip generating pure air chunks.
pub fn chunkIsAir(seed: u32, pos: coords.ChunkPos) bool {
    const origin = pos.blockOrigin();
    if (origin.y + coords.CHUNK_SIZE - 1 <= MIN_HEIGHT) return false;
    var lz: i32 = 0;
    while (lz < coords.CHUNK_SIZE) : (lz += 1) {
        var lx: i32 = 0;
        while (lx < coords.CHUNK_SIZE) : (lx += 1) {
            if (heightAt(seed, origin.x + lx, origin.z + lz) >= origin.y) return false;
        }
    }
    return true;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn hashChunk(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0x5EED);
    hasher.update(std.mem.sliceAsBytes(chunk.blocks[0..]));
    return hasher.final();
}

test "heights stay inside the terrain clamp and vary" {
    var min: i32 = std.math.maxInt(i32);
    var max: i32 = std.math.minInt(i32);
    var wx: i32 = -400;
    while (wx < 400) : (wx += 3) {
        var wz: i32 = -400;
        while (wz < 400) : (wz += 3) {
            const h = heightAt(12345, wx, wz);
            try testing.expect(h >= MIN_HEIGHT);
            try testing.expect(h <= MAX_HEIGHT);
            min = @min(min, h);
            max = @max(max, h);
        }
    }
    // Rolling hills, not a plane and not noise: the spread is tens of blocks.
    try testing.expect(max - min > 30);
    try testing.expect(max > SEA_LEVEL);
    try testing.expect(min < SEA_LEVEL);
}

test "heightAt is deterministic and seed dependent" {
    try testing.expectEqual(heightAt(1, 100, -250), heightAt(1, 100, -250));
    try testing.expect(heightAt(1, 100, -250) != heightAt(2, 100, -250));
    // Neighbouring columns are correlated (continuity), distant ones are not.
    const h = heightAt(1, 100, -250);
    try testing.expect(@abs(heightAt(1, 101, -250) - h) <= 3);
}

test "surface layer order is grass, dirt, dirt, dirt, stone" {
    const seed: u32 = 99;
    for ([_]i32{ 0, 37, -128, 512 }) |wx| {
        for ([_]i32{ 0, -61, 250 }) |wz| {
            const h = heightAt(seed, wx, wz);
            try testing.expectEqual(BlockId.air, blockAt(seed, wx, h + 1, wz));
            try testing.expectEqual(BlockId.grass, blockAt(seed, wx, h, wz));
            try testing.expectEqual(BlockId.dirt, blockAt(seed, wx, h - 1, wz));
            try testing.expectEqual(BlockId.dirt, blockAt(seed, wx, h - 3, wz));
            try testing.expectEqual(BlockId.stone, blockAt(seed, wx, h - 4, wz));
            try testing.expectEqual(BlockId.stone, blockAt(seed, wx, 0, wz));
        }
    }
}

test "generating the same chunk twice produces identical voxels" {
    // The 1.8 acceptance: hash 1,000 sampled voxels twice and compare.
    const seed: u32 = 0xC0FFEE;
    var a = Chunk.init(coords.ChunkPos.init(3, 1, -2));
    generateChunk(&a, seed);
    var b = Chunk.init(coords.ChunkPos.init(3, 1, -2));
    generateChunk(&b, seed);
    try testing.expectEqual(hashChunk(&a), hashChunk(&b));

    var sampled: usize = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = @as(i32, @intCast(i % 32));
        const y = @as(i32, @intCast((i * 7) % 32));
        const z = @as(i32, @intCast((i * 13) % 32));
        try testing.expectEqual(a.getBlock(x, y, z), b.getBlock(x, y, z));
        sampled += 1;
    }
    try testing.expectEqual(@as(usize, 1000), sampled);
}

test "generation order does not matter" {
    const seed: u32 = 4242;
    const p1 = coords.ChunkPos.init(0, 1, 0);
    const p2 = coords.ChunkPos.init(1, 1, 0);

    var first = Chunk.init(p1);
    generateChunk(&first, seed);
    var other = Chunk.init(p2);
    generateChunk(&other, seed);
    const first_hash = hashChunk(&first);

    // Reverse order: p2 then p1.
    var other2 = Chunk.init(p2);
    generateChunk(&other2, seed);
    var first2 = Chunk.init(p1);
    generateChunk(&first2, seed);

    try testing.expectEqual(first_hash, hashChunk(&first2));
    try testing.expectEqual(hashChunk(&other), hashChunk(&other2));
}

test "chunks above the surface are air and the surface chunk is not" {
    const seed: u32 = 7;
    const top = coords.ChunkPos.init(0, 3, 0); // y 96..127
    var chunk = Chunk.init(top);
    generateChunk(&chunk, seed);
    const air_only = chunk.hasOnly(.air);
    try testing.expectEqual(chunkIsAir(seed, top), air_only);

    // The bottom layer is solid everywhere (min height is 8).
    var bottom = Chunk.init(coords.ChunkPos.init(0, 0, 0));
    generateChunk(&bottom, seed);
    try testing.expect(bottom.countBlocks(.air) == 0);
    try testing.expect(bottom.countBlocks(.stone) > 0);
}

test "a generated chunk matches blockAt voxel for voxel" {
    const seed: u32 = 555;
    const pos = coords.ChunkPos.init(-2, 1, 4);
    var chunk = Chunk.init(pos);
    generateChunk(&chunk, seed);

    const origin = pos.blockOrigin();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const lx = @as(i32, @intCast(i % 32));
        const ly = @as(i32, @intCast((i * 5) % 32));
        const lz = @as(i32, @intCast((i * 11) % 32));
        try testing.expectEqual(
            blockAt(seed, origin.x + lx, origin.y + ly, origin.z + lz),
            chunk.getBlock(lx, ly, lz),
        );
    }
}
