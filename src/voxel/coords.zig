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
