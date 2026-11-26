const std = @import("std");
const Vec3 = @import("../math/vec.zig").Vec3;
const World = @import("../world/world.zig").World;
const coords = @import("coords.zig");
const BlockPos = coords.BlockPos;

/// A voxel hit: which block, the face the ray entered through, and how far away.
pub const Hit = struct {
    block: BlockPos,
    /// Face normal pointing back towards the ray origin, e.g. (0,0,1) for a
    /// hit on the +Z face. Used for placing blocks.
    normal: [3]i32,
    distance: f32,
};

/// Amanatides-Woo DDA voxel traversal (1.10).
///
/// Walks the exact set of blocks the ray passes through, so there are no
/// missed blocks at steep angles and no per-step epsilon to tune. Stops at the
/// first solid block within `max_distance`.
pub fn raycast(world: *const World, origin: Vec3, direction: Vec3, max_distance: f32) ?Hit {
    const length = @sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z);
    if (length < 1e-6) return null;
    const d = Vec3.init(direction.x / length, direction.y / length, direction.z / length);

    var x: i32 = @intFromFloat(@floor(origin.x));
    var y: i32 = @intFromFloat(@floor(origin.y));
    var z: i32 = @intFromFloat(@floor(origin.z));

    const step_x: i32 = if (d.x > 0) 1 else if (d.x < 0) -1 else 0;
    const step_y: i32 = if (d.y > 0) 1 else if (d.y < 0) -1 else 0;
    const step_z: i32 = if (d.z > 0) 1 else if (d.z < 0) -1 else 0;

    const inf = std.math.inf(f32);
    const delta_x = if (d.x == 0) inf else @abs(1.0 / d.x);
    const delta_y = if (d.y == 0) inf else @abs(1.0 / d.y);
    const delta_z = if (d.z == 0) inf else @abs(1.0 / d.z);

    // Distance to the first grid plane on each axis.
    var max_x = if (d.x == 0) inf else distanceToPlane(origin.x, x, d.x, step_x);
    var max_y = if (d.y == 0) inf else distanceToPlane(origin.y, y, d.y, step_y);
    var max_z = if (d.z == 0) inf else distanceToPlane(origin.z, z, d.z, step_z);

    var normal: [3]i32 = .{ 0, 0, 0 };

    // Starting inside a block counts as a hit on the face the ray came in
    // through; without this, standing in a wall would shoot through it.
    if (world.getBlock(x, y, z).isSolid()) {
        return .{ .block = BlockPos.init(x, y, z), .normal = normal, .distance = 0 };
    }

    var travelled: f32 = 0;
    while (travelled <= max_distance) {
        if (max_x < max_y and max_x < max_z) {
            x += step_x;
            travelled = max_x;
            max_x += delta_x;
            normal = .{ -step_x, 0, 0 };
        } else if (max_y < max_z) {
            y += step_y;
            travelled = max_y;
            max_y += delta_y;
            normal = .{ 0, -step_y, 0 };
        } else {
            z += step_z;
            travelled = max_z;
            max_z += delta_z;
            normal = .{ 0, 0, -step_z };
        }
        if (travelled > max_distance) break;
        if (world.getBlock(x, y, z).isSolid()) {
            return .{ .block = BlockPos.init(x, y, z), .normal = normal, .distance = travelled };
        }
    }
    return null;
}

/// Distance along the ray from `coordinate` to the next grid plane in the
/// direction of travel.
fn distanceToPlane(coordinate: f32, cell: i32, direction: f32, step: i32) f32 {
    if (step > 0) {
        return (@as(f32, @floatFromInt(cell + 1)) - coordinate) / direction;
    }
    return (coordinate - @as(f32, @floatFromInt(cell))) / -direction;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const BlockId = @import("block.zig").BlockId;

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
    return world;
}

test "a ray down -Z hits the +Z face of the block in front" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(4, 4, 2, .stone);

    const hit = raycast(&world, .{ .x = 4.5, .y = 4.5, .z = 10.5 }, .{ .x = 0, .y = 0, .z = -1 }, 20) orelse return error.NoHit;
    try testing.expectEqual(BlockPos.init(4, 4, 2), hit.block);
    try testing.expectEqual([3]i32{ 0, 0, 1 }, hit.normal);
    try testing.expectApproxEqAbs(@as(f32, 7.5), hit.distance, 0.001);
}

test "each face direction reports the right normal" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(5, 5, 5, .stone);

    const cases = [_]struct { origin: Vec3, dir: Vec3, normal: [3]i32 }{
        // From -X looking +X: enters the -X face, normal points back at the ray.
        .{ .origin = .{ .x = 0.5, .y = 5.5, .z = 5.5 }, .dir = .{ .x = 1, .y = 0, .z = 0 }, .normal = .{ -1, 0, 0 } },
        .{ .origin = .{ .x = 10.5, .y = 5.5, .z = 5.5 }, .dir = .{ .x = -1, .y = 0, .z = 0 }, .normal = .{ 1, 0, 0 } },
        .{ .origin = .{ .x = 5.5, .y = 0.5, .z = 5.5 }, .dir = .{ .x = 0, .y = 1, .z = 0 }, .normal = .{ 0, -1, 0 } },
        .{ .origin = .{ .x = 5.5, .y = 12.5, .z = 5.5 }, .dir = .{ .x = 0, .y = -1, .z = 0 }, .normal = .{ 0, 1, 0 } },
        .{ .origin = .{ .x = 5.5, .y = 5.5, .z = 0.5 }, .dir = .{ .x = 0, .y = 0, .z = 1 }, .normal = .{ 0, 0, -1 } },
        .{ .origin = .{ .x = 5.5, .y = 5.5, .z = 10.5 }, .dir = .{ .x = 0, .y = 0, .z = -1 }, .normal = .{ 0, 0, 1 } },
    };
    for (cases) |case| {
        const hit = raycast(&world, case.origin, case.dir, 20) orelse return error.NoHit;
        try testing.expectEqual(BlockPos.init(5, 5, 5), hit.block);
        try testing.expectEqual(case.normal, hit.normal);
    }
}

test "max distance is respected" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(4, 4, 2, .stone);
    // The block is 7.5 away; a 6-block reach must not see it.
    try testing.expectEqual(@as(?Hit, null), raycast(&world, .{ .x = 4.5, .y = 4.5, .z = 10.5 }, .{ .x = 0, .y = 0, .z = -1 }, 6));
    try testing.expect(raycast(&world, .{ .x = 4.5, .y = 4.5, .z = 10.5 }, .{ .x = 0, .y = 0, .z = -1 }, 8) != null);
}

test "a diagonal ray lands on the block it crosses first" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    // Fill a wall at z = 6 so the diagonal ray has to pick the entry block.
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var y: i32 = 0;
        while (y < 16) : (y += 1) _ = world.setBlock(x, y, 6, .stone);
    }
    const hit = raycast(&world, .{ .x = 2.5, .y = 3.5, .z = 0.5 }, .{ .x = 1, .y = 1, .z = 2 }, 30) orelse return error.NoHit;
    try testing.expectEqual(@as(i32, 6), hit.block.z);
    // Travelling +Z into the wall means the ray enters its -Z face.
    try testing.expectEqual([3]i32{ 0, 0, -1 }, hit.normal);
}

test "starting inside a solid block hits immediately" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(3, 3, 3, .stone);
    const hit = raycast(&world, .{ .x = 3.5, .y = 3.5, .z = 3.5 }, .{ .x = 1, .y = 0, .z = 0 }, 6) orelse return error.NoHit;
    try testing.expectEqual(BlockPos.init(3, 3, 3), hit.block);
    try testing.expectEqual(@as(f32, 0), hit.distance);
}

test "an empty world has no hit" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    try testing.expectEqual(@as(?Hit, null), raycast(&world, .{ .x = 1.5, .y = 1.5, .z = 1.5 }, .{ .x = 1, .y = 0, .z = 0 }, 6));
}

test "leaves are solid enough to hit but water is not" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    _ = world.setBlock(2, 2, 2, .leaves);
    _ = world.setBlock(3, 2, 2, .water);
    const hit = raycast(&world, .{ .x = 8.5, .y = 2.5, .z = 2.5 }, .{ .x = -1, .y = 0, .z = 0 }, 10) orelse return error.NoHit;
    try testing.expectEqual(BlockPos.init(2, 2, 2), hit.block);
}
