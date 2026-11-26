const std = @import("std");

/// Floor division / modulo for world coordinates.
///
/// The trap this exists for: chunk-local coordinates must tile seamlessly
/// across x = 0, so -1 has to land in chunk -1 at local 31. Integer division
/// in Zig truncates toward zero, which would put -1 at chunk 0 local -1.
pub fn floorDiv(value: i32, divisor: i32) i32 {
    std.debug.assert(divisor > 0);
    return @divFloor(value, divisor);
}

pub fn floorMod(value: i32, divisor: i32) i32 {
    std.debug.assert(divisor > 0);
    return @mod(value, divisor);
}

test "coordinates tile across the origin" {
    const chunk = 32;
    try std.testing.expectEqual(@as(i32, 0), floorDiv(0, chunk));
    try std.testing.expectEqual(@as(i32, 0), floorMod(0, chunk));

    try std.testing.expectEqual(@as(i32, -1), floorDiv(-1, chunk));
    try std.testing.expectEqual(@as(i32, 31), floorMod(-1, chunk));

    try std.testing.expectEqual(@as(i32, -1), floorDiv(-32, chunk));
    try std.testing.expectEqual(@as(i32, 0), floorMod(-32, chunk));

    try std.testing.expectEqual(@as(i32, -2), floorDiv(-33, chunk));
    try std.testing.expectEqual(@as(i32, 31), floorMod(-33, chunk));
}

test "chunk and local reconstruct the world coordinate" {
    const chunk = 32;
    const samples = [_]i32{ -97, -33, -32, -31, -1, 0, 1, 31, 32, 33, 97 };
    for (samples) |world| {
        const rebuilt = floorDiv(world, chunk) * chunk + floorMod(world, chunk);
        try std.testing.expectEqual(world, rebuilt);
    }
}

// ------------------------------------------------------------------ ADR 0003 constants

/// Cubes per chunk edge (ADR 0003: 32^3 cubes, u8 block ids).
pub const CHUNK_SIZE: i32 = 32;
pub const CHUNK_VOLUME: usize = @intCast(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE);

/// World height in blocks: 4 chunks tall.
pub const WORLD_HEIGHT: i32 = 128;
pub const CHUNK_COUNT_Y: i32 = WORLD_HEIGHT / CHUNK_SIZE;

/// Index inside a chunk buffer: `(y * 32 + z) * 32 + x` (ADR 0003).
pub fn localIndex(x: i32, y: i32, z: i32) usize {
    std.debug.assert(x >= 0 and x < CHUNK_SIZE);
    std.debug.assert(y >= 0 and y < CHUNK_SIZE);
    std.debug.assert(z >= 0 and z < CHUNK_SIZE);
    return @intCast((y * CHUNK_SIZE + z) * CHUNK_SIZE + x);
}

test "local index matches the ADR 0003 layout" {
    try std.testing.expectEqual(@as(usize, 0), localIndex(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), localIndex(1, 0, 0));
    try std.testing.expectEqual(@as(usize, 32), localIndex(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1024), localIndex(0, 1, 0));
    try std.testing.expectEqual(CHUNK_VOLUME - 1, localIndex(31, 31, 31));
}

/// A position in world block space.
pub const BlockPos = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn init(x: i32, y: i32, z: i32) BlockPos {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn inWorld(self: BlockPos) bool {
        return self.y >= 0 and self.y < WORLD_HEIGHT;
    }

    pub fn chunk(self: BlockPos) ChunkPos {
        return ChunkPos.fromBlock(self);
    }

    pub fn local(self: BlockPos) BlockPos {
        return .{
            .x = localOf(self.x, CHUNK_SIZE),
            .y = localOf(self.y, CHUNK_SIZE),
            .z = localOf(self.z, CHUNK_SIZE),
        };
    }
};

/// A chunk's position in chunk space. Chunk (0,0,0) covers blocks 0..31 on
/// every axis, so the chunk holding x = -1 is (-1,0,0).
pub const ChunkPos = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn init(x: i32, y: i32, z: i32) ChunkPos {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn fromBlock(pos: BlockPos) ChunkPos {
        return .{
            .x = floorDiv(pos.x, CHUNK_SIZE),
            .y = floorDiv(pos.y, CHUNK_SIZE),
            .z = floorDiv(pos.z, CHUNK_SIZE),
        };
    }

    /// World position of this chunk's (0,0,0) block.
    pub fn blockOrigin(self: ChunkPos) BlockPos {
        return .{
            .x = self.x * CHUNK_SIZE,
            .y = self.y * CHUNK_SIZE,
            .z = self.z * CHUNK_SIZE,
        };
    }

    pub fn offset(self: ChunkPos, dx: i32, dy: i32, dz: i32) ChunkPos {
        return .{ .x = self.x + dx, .y = self.y + dy, .z = self.z + dz };
    }

    pub fn eql(a: ChunkPos, b: ChunkPos) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    /// Wyhash over the three components, per ADR 0003.
    pub const Context = struct {
        pub fn hash(_: Context, pos: ChunkPos) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&pos.x));
            h.update(std.mem.asBytes(&pos.y));
            h.update(std.mem.asBytes(&pos.z));
            return h.final();
        }

        pub fn eql(_: Context, a: ChunkPos, b: ChunkPos) bool {
            return ChunkPos.eql(a, b);
        }
    };
};

test "chunk positions land on the right side of the origin" {
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(-1, 0, 0), BlockPos.init(-1, 0, 0).chunk()));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(-1, 0, 0), BlockPos.init(-32, 0, 0).chunk()));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(-2, 0, 0), BlockPos.init(-33, 0, 0).chunk()));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(0, 0, 0), BlockPos.init(31, 0, 0).chunk()));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(1, 2, 3), BlockPos.init(32, 64, 96).chunk()));
    try std.testing.expectEqual(@as(i32, 31), BlockPos.init(-1, 0, 0).local().x);
}

test "chunk origin and offset round-trip" {
    const pos = ChunkPos.init(-3, 1, 7);
    const origin = pos.blockOrigin();
    try std.testing.expectEqual(@as(i32, -96), origin.x);
    try std.testing.expectEqual(@as(i32, 32), origin.y);
    try std.testing.expectEqual(@as(i32, 224), origin.z);
    try std.testing.expect(ChunkPos.eql(pos, origin.chunk()));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(-2, 1, 7), pos.offset(1, 0, 0)));
}

test "chunk hash separates neighbours" {
    const ctx = ChunkPos.Context{};
    const a = ChunkPos.init(1, 2, 3);
    const b = ChunkPos.init(3, 2, 1);
    // Three components must not collapse into one (a + b + c style hash).
    try std.testing.expect(ctx.hash(a) != ctx.hash(b));
    try std.testing.expectEqual(ctx.hash(a), ctx.hash(ChunkPos.init(1, 2, 3)));
}

/// Chunk coordinate that contains `world`.
pub fn chunkOf(world: i32, chunk_size: i32) i32 {
    return floorDiv(world, chunk_size);
}

/// Offset of `world` inside its chunk, always in `0..chunk_size`.
pub fn localOf(world: i32, chunk_size: i32) i32 {
    return floorMod(world, chunk_size);
}

test "chunkOf and localOf agree with the ADR 0003 cases" {
    const size = 32;
    const cases = [_]struct { world: i32, chunk: i32, local: i32 }{
        .{ .world = -1, .chunk = -1, .local = 31 },
        .{ .world = -32, .chunk = -1, .local = 0 },
        .{ .world = -33, .chunk = -2, .local = 31 },
        .{ .world = -64, .chunk = -2, .local = 0 },
        .{ .world = 0, .chunk = 0, .local = 0 },
        .{ .world = 31, .chunk = 0, .local = 31 },
        .{ .world = 32, .chunk = 1, .local = 0 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.chunk, chunkOf(c.world, size));
        try std.testing.expectEqual(c.local, localOf(c.world, size));
    }
}

test "truncating division is the bug this replaces" {
    // @divTrunc round-trips toward zero, so -1 lands in chunk 0 at local -1.
    try std.testing.expectEqual(@as(i32, 0), @divTrunc(@as(i32, -1), 32));
    try std.testing.expectEqual(@as(i32, -1), chunkOf(-1, 32));
}
