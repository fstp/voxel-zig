const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const World = @import("world.zig").World;
const terrain = @import("terrain.zig");
const Change = @import("undo.zig").Change;
const BlockPos = coords.BlockPos;

/// Sculpting brushes (2.5). Each stroke collects the blocks it changed so the
/// caller can push one undo record per stroke.
pub const Mode = enum(u8) {
    /// Fill air inside the sphere with the selected block.
    raise,
    /// Carve solid blocks out of the sphere.
    lower,
    /// Pull each column in the disc towards the average surface height.
    smooth,
    /// Box brush: fill a cube instead of a sphere.
    box_fill,
};

pub const Stroke = struct {
    changes: []Change,
    centre: BlockPos,
    mode: Mode,
    radius: i32,

    pub fn deinit(self: Stroke, allocator: std.mem.Allocator) void {
        allocator.free(self.changes);
    }
};

/// Applies a brush stroke centred on `centre` (the block the crosshair hit).
/// Returns the change list; the caller pushes it to the undo stack and re-meshes.
pub fn apply(
    allocator: std.mem.Allocator,
    world: *World,
    centre: BlockPos,
    radius: i32,
    mode: Mode,
    block: BlockId,
) !Stroke {
    var list: std.ArrayList(Change) = .empty;
    errdefer list.deinit(allocator);

    const r: i32 = @max(1, radius);
    const radius_sq = r * r;

    if (mode == .smooth) {
        try smoothColumns(allocator, world, centre, r, &list);
    } else {
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            var dy: i32 = -r;
            while (dy <= r) : (dy += 1) {
                var dx: i32 = -r;
                while (dx <= r) : (dx += 1) {
                    const inside = switch (mode) {
                        .box_fill => true,
                        else => dx * dx + dy * dy + dz * dz <= radius_sq,
                    };
                    if (!inside) continue;

                    const pos = BlockPos.init(centre.x + dx, centre.y + dy, centre.z + dz);
                    if (!pos.inWorld()) continue;
                    const current = world.getBlock(pos.x, pos.y, pos.z);

                    const target: BlockId = switch (mode) {
                        .raise, .box_fill => if (current == .air) block else current,
                        .lower => if (current != .air and current != .water) .air else current,
                        .smooth => current,
                    };
                    if (target == current) continue;
                    if (world.setBlock(pos.x, pos.y, pos.z, target)) {
                        try list.append(allocator, .{ .pos = pos, .before = current, .after = target });
                    }
                }
            }
        }
    }

    return .{
        .changes = try list.toOwnedSlice(allocator),
        .centre = centre,
        .mode = mode,
        .radius = r,
    };
}

/// Smoothing: for every column in the horizontal disc, find the surface height,
/// compare it with the average of the neighbouring columns, and add or remove
/// blocks to close the gap. Only ever touches a few blocks per column.
fn smoothColumns(
    allocator: std.mem.Allocator,
    world: *World,
    centre: BlockPos,
    r: i32,
    list: *std.ArrayList(Change),
) !void {
    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dz * dz > r * r) continue;
            const wx = centre.x + dx;
            const wz = centre.z + dz;

            // Average surface height of the 3x3 neighbourhood around this column.
            var sum: i32 = 0;
            var samples: i32 = 0;
            var sz: i32 = -1;
            while (sz <= 1) : (sz += 1) {
                var sx: i32 = -1;
                while (sx <= 1) : (sx += 1) {
                    sum += columnSurface(world, wx + sx, wz + sz, centre.y);
                    samples += 1;
                }
            }
            const target = @divTrunc(sum, samples);
            const current = columnSurface(world, wx, wz, centre.y);
            if (target == current) continue;

            if (target > current) {
                var y = current + 1;
                while (y <= target) : (y += 1) {
                    const pos = BlockPos.init(wx, y, wz);
                    if (!pos.inWorld()) break;
                    const before = world.getBlock(wx, y, wz);
                    if (before == .air and world.setBlock(wx, y, wz, .grass)) {
                        try list.append(allocator, .{ .pos = pos, .before = before, .after = .grass });
                    }
                }
            } else {
                var y = current;
                while (y > target) : (y -= 1) {
                    const pos = BlockPos.init(wx, y, wz);
                    if (!pos.inWorld()) break;
                    const before = world.getBlock(wx, y, wz);
                    if (before != .air and before != .water and world.setBlock(wx, y, wz, .air)) {
                        try list.append(allocator, .{ .pos = pos, .before = before, .after = .air });
                    }
                }
            }
        }
    }
}

/// Highest non-air block in a column within reach of `near_y`.
fn columnSurface(world: *const World, wx: i32, wz: i32, near_y: i32) i32 {
    var y = @min(coords.WORLD_HEIGHT - 1, near_y + 8);
    const bottom = @max(0, near_y - 8);
    while (y >= bottom) : (y -= 1) {
        if (world.getBlock(wx, y, wz) != .air) return y;
    }
    return bottom;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testWorld(allocator: std.mem.Allocator) !World {
    var world = World.init(allocator);
    errdefer world.deinit();
    for (0..2) |cy| {
        for (0..2) |cz| {
            for (0..2) |cx| {
                _ = try world.getOrCreateChunk(coords.ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz)));
            }
        }
    }
    // A flat stone floor at y = 0 so brushes have something to work against.
    for (0..40) |x| {
        for (0..40) |z| _ = world.setBlock(@intCast(x), 0, @intCast(z), .stone);
    }
    return world;
}

test "raise fills air inside the sphere and nothing outside" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();

    const stroke = try apply(testing.allocator, &world, BlockPos.init(10, 2, 10), 2, .raise, .stone);
    defer stroke.deinit(testing.allocator);

    try testing.expect(stroke.changes.len > 0);
    try testing.expectEqual(BlockId.stone, world.getBlock(10, 2, 10));
    // Inside the radius but diagonal, still inside the sphere.
    try testing.expectEqual(BlockId.stone, world.getBlock(11, 2, 10));
    // Outside the sphere.
    try testing.expectEqual(BlockId.air, world.getBlock(13, 2, 10));
    try testing.expectEqual(BlockId.air, world.getBlock(10, 5, 10));
    // Every recorded change really happened and only touched air.
    for (stroke.changes) |change| {
        try testing.expectEqual(BlockId.air, change.before);
        try testing.expectEqual(BlockId.stone, change.after);
    }
}

test "lower carves solid blocks and leaves air alone" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(10, 1, 10, .dirt);
    _ = world.setBlock(10, 2, 10, .dirt);

    const stroke = try apply(testing.allocator, &world, BlockPos.init(10, 1, 10), 2, .lower, .stone);
    defer stroke.deinit(testing.allocator);

    try testing.expectEqual(BlockId.air, world.getBlock(10, 1, 10));
    try testing.expectEqual(BlockId.air, world.getBlock(10, 0, 10));
    // Air gaps in the same sphere are not recorded.
    for (stroke.changes) |change| try testing.expect(change.before != .air);
}

test "box_fill fills a cube rather than a sphere" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    const stroke = try apply(testing.allocator, &world, BlockPos.init(10, 4, 10), 2, .box_fill, .wood);
    defer stroke.deinit(testing.allocator);

    // The corner of the cube is outside a sphere of the same radius.
    try testing.expectEqual(BlockId.wood, world.getBlock(12, 6, 12));
    try testing.expectEqual(BlockId.air, world.getBlock(13, 4, 10));
}

test "smooth pulls a spike down towards its neighbours" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    // Flat floor at y = 0, then a 3-block spike at (10, 10).
    var y: i32 = 1;
    while (y <= 3) : (y += 1) _ = world.setBlock(10, y, 10, .stone);

    const stroke = try apply(testing.allocator, &world, BlockPos.init(10, 3, 10), 3, .smooth, .grass);
    defer stroke.deinit(testing.allocator);

    // The spike loses at least its top block.
    try testing.expect(world.getBlock(10, 3, 10) == .air);
    for (stroke.changes) |change| try testing.expect(change.before != change.after);
}

test "a stroke records exactly the blocks it changed" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    const stroke = try apply(testing.allocator, &world, BlockPos.init(20, 2, 20), 2, .raise, .sand);
    defer stroke.deinit(testing.allocator);

    var counted: usize = 0;
    for (stroke.changes) |change| {
        try testing.expectEqual(BlockId.sand, world.getBlock(change.pos.x, change.pos.y, change.pos.z));
        counted += 1;
    }
    try testing.expectEqual(stroke.changes.len, counted);
}
