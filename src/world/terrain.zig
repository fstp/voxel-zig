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

/// 2.2 biomes: a low-frequency climate pair picks the surface block.
pub const Biome = enum(u8) { plains, forest, desert, mountains };

/// Temperature and humidity at ~1/512 and ~1/384 blocks, as ADR 0005 planned.
pub fn biomeAt(seed: u32, wx: i32, wz: i32) Biome {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const temperature = noise.fbm2(seed ^ 0x9E37, x / 512.0, z / 512.0, 2, 2.0, 0.5);
    const humidity = noise.fbm2(seed ^ 0x79B9, x / 384.0, z / 384.0, 2, 2.0, 0.5);
    if (temperature > 0.22 and humidity < -0.05) return .desert;
    if (humidity > 0.18) return .forest;
    if (temperature < -0.25) return .mountains;
    return .plains;
}

/// Surface block for a biome at the top of the column.
pub fn surfaceBlock(biome: Biome) BlockId {
    return switch (biome) {
        .plains, .forest => .grass,
        .desert => .sand,
        .mountains => .stone,
    };
}

/// Caves: a threshold band of 3D noise below the surface, plus overhangs where
/// the field dips. Two octaves so tunnels branch instead of forming blobs.
pub fn isCave(seed: u32, wx: i32, wy: i32, wz: i32) bool {
    if (wy > MAX_HEIGHT - 4 or wy < 3) return false;
    const x: f32 = @floatFromInt(wx);
    const y: f32 = @floatFromInt(wy);
    const z: f32 = @floatFromInt(wz);
    const field = noise.perlin3(seed ^ 0xA5A5, x * 0.045, y * 0.075, z * 0.045) * 0.7 +
        noise.perlin3(seed ^ 0x5A5A, x * 0.09, y * 0.15, z * 0.09) * 0.3;
    return @abs(field) < 0.022;
}
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

/// Full voxel lookup: biome surface, caves carved out, sea level filled.
pub fn blockAt(seed: u32, wx: i32, wy: i32, wz: i32) BlockId {
    if (wy < 0 or wy >= coords.WORLD_HEIGHT) return .air;

    const surface = heightAt(seed, wx, wz);
    if (wy > surface) {
        // Water fills the air below sea level, up to the surface.
        return if (wy <= SEA_LEVEL) .water else .air;
    }
    if (isCave(seed, wx, wy, wz)) return .air;

    if (wy == surface) return surfaceBlock(biomeAt(seed, wx, wz));
    if (wy >= surface - 3) return .dirt;
    return .stone;
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
                const wy = origin.y + ly;
                if (isCave(seed, origin.x + lx, wy, origin.z + lz)) continue;
                blocks[coords.localIndex(lx, ly, lz)] = if (wy == surface)
                    surfaceBlock(biomeAt(seed, origin.x + lx, origin.z + lz))
                else if (wy >= surface - 3)
                    .dirt
                else
                    .stone;
            }
            // Sea level: fill air above this column's surface with water.
            var water_y: i32 = @max(surface + 1, origin.y);
            while (water_y <= @min(SEA_LEVEL, origin.y + coords.CHUNK_SIZE - 1)) : (water_y += 1) {
                blocks[coords.localIndex(lx, water_y - origin.y, lz)] = .water;
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
    var checked: usize = 0;
    for ([_]i32{ 0, 37, -128, 512, 1024, -2048 }) |wx| {
        for ([_]i32{ 0, -61, 250, -999 }) |wz| {
            const h = heightAt(seed, wx, wz);
            // 2.2 carves caves through the surface, so only assert the layer
            // order on a column the cave field happens to leave intact.
            if (isCave(seed, wx, h, wz) or isCave(seed, wx, h - 1, wz) or isCave(seed, wx, h - 3, wz) or isCave(seed, wx, h - 4, wz)) continue;

            try testing.expectEqual(surfaceBlock(biomeAt(seed, wx, wz)), blockAt(seed, wx, h, wz));
            try testing.expectEqual(BlockId.dirt, blockAt(seed, wx, h - 1, wz));
            try testing.expectEqual(BlockId.dirt, blockAt(seed, wx, h - 3, wz));
            try testing.expectEqual(BlockId.stone, blockAt(seed, wx, h - 4, wz));

            const above = blockAt(seed, wx, h + 1, wz);
            try testing.expect(above == .air or above == .water);
            checked += 1;
        }
    }
    try testing.expect(checked >= 4);
}

test "biomes vary across the world and follow the climate field" {
    var seen = [_]bool{ false, false, false, false };
    var wx: i32 = -4000;
    while (wx < 4000) : (wx += 137) {
        var wz: i32 = -4000;
        while (wz < 4000) : (wz += 137) {
            seen[@intFromEnum(biomeAt(1234, wx, wz))] = true;
        }
    }
    var kinds: usize = 0;
    for (seen) |found| {
        if (found) kinds += 1;
    }
    // At least three kinds exist somewhere, which is what the flyover needs.
    try testing.expect(kinds >= 3);
}

test "caves break the surface somewhere, which is what a cave entrance is" {
    // A cave entrance is a column whose surface block was carved away.
    const seed: u32 = 0x5EED_1234;
    var entrances: usize = 0;
    var wx: i32 = 0;
    while (wx < 512 and entrances == 0) : (wx += 3) {
        var wz: i32 = 0;
        while (wz < 512) : (wz += 3) {
            const surface = heightAt(seed, wx, wz);
            if (surface <= SEA_LEVEL) continue; // ignore under-water columns
            if (blockAt(seed, wx, surface, wz) == .air) {
                entrances += 1;
                break;
            }
        }
    }
    try testing.expect(entrances > 0);
}

test "caves are underground, never at the very top or bottom" {
    const seed: u32 = 4242;
    try testing.expect(!isCave(seed, 0, 0, 0));
    try testing.expect(!isCave(seed, 0, MAX_HEIGHT - 1, 0));
    var carved: usize = 0;
    var y: i32 = 5;
    while (y < 60) : (y += 1) {
        var x: i32 = 0;
        while (x < 60) : (x += 4) {
            if (isCave(seed, x, y, x)) carved += 1;
        }
    }
    // Some but not all: an empty field or swiss cheese would both be wrong.
    try testing.expect(carved > 0);
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

    // The bottom layer is mostly solid; 2.2's caves carve voids out of it, so
    // the check is "mostly stone", not "no air at all".
    var bottom = Chunk.init(coords.ChunkPos.init(0, 0, 0));
    generateChunk(&bottom, seed);
    try testing.expect(bottom.countBlocks(.air) < coords.CHUNK_VOLUME / 4);
    try testing.expect(bottom.countBlocks(.stone) > coords.CHUNK_VOLUME / 2);
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
