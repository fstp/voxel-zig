const std = @import("std");
const Vec3 = @import("../math/vec.zig").Vec3;
const World = @import("../world/world.zig").World;

/// Rigid boxes in the voxel world (2.3).
///
/// Jolt Physics is the production answer, but pulling a C++ physics engine into
/// the PoC for a "throw boxes down a hill" toy is a second project; this is the
/// small version: axis-aligned boxes, no rotation, axis-separated resolution
/// against the voxel grid, a little bounce and friction, and sleep when a body
/// has settled. It is enough to throw 50 boxes around and watch them tumble
/// down a hillside.
pub const Body = struct {
    position: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    /// Half extents.
    half: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
    resting: bool = false,
    /// Counts up while the body is settled; past SLEEP_TICKS it stops stepping.
    still_ticks: u16 = 0,
};

pub const GRAVITY: f32 = 24.0;
pub const RESTITUTION: f32 = 0.25;
pub const FRICTION: f32 = 0.82;
pub const SLEEP_TICKS: u16 = 30;
pub const MAX_SUBSTEP: f32 = 0.4;

pub const Bodies = struct {
    items: []Body,
    count: usize = 0,

    pub fn init(items: []Body) Bodies {
        return .{ .items = items };
    }

    pub fn spawn(self: *Bodies, position: Vec3, half: Vec3, velocity: Vec3) bool {
        if (self.count == self.items.len) return false;
        self.items[self.count] = .{ .position = position, .half = half, .velocity = velocity };
        self.count += 1;
        return true;
    }

    pub fn clear(self: *Bodies) void {
        self.count = 0;
    }

    pub fn step(self: *Bodies, world: *const World, dt: f32) void {
        for (self.items[0..self.count]) |*body| {
            if (body.resting) continue;

            body.velocity.y -= GRAVITY * dt;
            self.moveAxis(world, body, .x, body.velocity.x * dt);
            self.moveAxis(world, body, .z, body.velocity.z * dt);
            self.moveAxis(world, body, .y, body.velocity.y * dt);

            // Ground friction, and sleep once it has been slow for a while.
            if (body.velocity.y == 0) {
                body.velocity.x *= FRICTION;
                body.velocity.z *= FRICTION;
            }
            const speed_sq = body.velocity.x * body.velocity.x + body.velocity.y * body.velocity.y + body.velocity.z * body.velocity.z;
            if (speed_sq < 0.02 and body.velocity.y == 0) {
                body.still_ticks +|= 1;
                if (body.still_ticks > SLEEP_TICKS) {
                    body.resting = true;
                    body.velocity = .{ .x = 0, .y = 0, .z = 0 };
                }
            } else {
                body.still_ticks = 0;
            }
        }
    }

    const Axis = enum { x, y, z };

    fn moveAxis(self: *Bodies, world: *const World, body: *Body, axis: Axis, delta: f32) void {
        _ = self;
        if (delta == 0) return;
        var remaining = delta;
        while (@abs(remaining) > 0.0001) {
            const move = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            var candidate = body.position;
            switch (axis) {
                .x => candidate.x += move,
                .y => candidate.y += move,
                .z => candidate.z += move,
            }
            if (!overlapsWorld(world, candidate, body.half)) {
                body.position = candidate;
                remaining -= move;
                continue;
            }

            // Resolve against the block face we ran into.
            switch (axis) {
                .x => {
                    if (move > 0) {
                        body.position.x = @floor(candidate.x + body.half.x) - body.half.x - 0.001;
                    } else {
                        body.position.x = @ceil(candidate.x - body.half.x) + body.half.x + 0.001;
                    }
                    body.velocity.x *= -RESTITUTION;
                },
                .z => {
                    if (move > 0) {
                        body.position.z = @floor(candidate.z + body.half.z) - body.half.z - 0.001;
                    } else {
                        body.position.z = @ceil(candidate.z - body.half.z) + body.half.z + 0.001;
                    }
                    body.velocity.z *= -RESTITUTION;
                },
                .y => {
                    if (move > 0) {
                        body.position.y = @floor(candidate.y + body.half.y) - body.half.y - 0.001;
                    } else {
                        body.position.y = @ceil(candidate.y - body.half.y) + body.half.y + 0.001;
                        // Settling: kill the bounce once it is small.
                        if (@abs(body.velocity.y) < 2.0) body.velocity.y = 0 else body.velocity.y *= -RESTITUTION;
                        body.velocity.x *= FRICTION;
                        body.velocity.z *= FRICTION;
                    }
                    if (body.velocity.y > 0) body.velocity.y = 0;
                },
            }
            return;
        }
    }
};

/// True when the box at `centre` (half extents `half`) overlaps any solid block.
pub fn overlapsWorld(world: *const World, centre: Vec3, half: Vec3) bool {
    const eps: f32 = 1e-4;
    const min_x = centre.x - half.x;
    const max_x = centre.x + half.x;
    const min_y = centre.y - half.y;
    const max_y = centre.y + half.y;
    const min_z = centre.z - half.z;
    const max_z = centre.z + half.z;

    var bx: i32 = @intFromFloat(@floor(min_x + eps));
    const bx_end: i32 = @intFromFloat(@floor(max_x - eps));
    while (bx <= bx_end) : (bx += 1) {
        var by: i32 = @intFromFloat(@floor(min_y + eps));
        const by_end: i32 = @intFromFloat(@floor(max_y - eps));
        while (by <= by_end) : (by += 1) {
            var bz: i32 = @intFromFloat(@floor(min_z + eps));
            const bz_end: i32 = @intFromFloat(@floor(max_z - eps));
            while (bz <= bz_end) : (bz += 1) {
                if (world.getBlock(bx, by, bz).isSolid()) return true;
            }
        }
    }
    return false;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const coords = @import("../voxel/coords.zig");

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

fn floorAt(world: *World, y: i32) void {
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) _ = world.setBlock(x, y, z, .stone);
    }
}

test "a box falls and comes to rest on the floor" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    floorAt(&world, 0);

    var items: [4]Body = undefined;
    var bodies = Bodies.init(&items);
    _ = bodies.spawn(.{ .x = 0.5, .y = 6, .z = 0.5 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = 0, .z = 0 });

    var tick: usize = 0;
    while (tick < 240) : (tick += 1) bodies.step(&world, 1.0 / 60.0);

    const body = bodies.items[0];
    // Floor top is y = 1, half extent 0.5, so the centre rests at about 1.5.
    try testing.expectApproxEqAbs(@as(f32, 1.5), body.position.y, 0.05);
    try testing.expect(body.resting);
    try testing.expect(!overlapsWorld(&world, body.position, body.half));
}

test "a box never falls through the floor" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    floorAt(&world, 0);

    var items: [4]Body = undefined;
    var bodies = Bodies.init(&items);
    _ = bodies.spawn(.{ .x = 0.5, .y = 30, .z = 0.5 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = -40, .z = 0 });

    var tick: usize = 0;
    while (tick < 400) : (tick += 1) {
        bodies.step(&world, 1.0 / 60.0);
        try testing.expect(bodies.items[0].position.y > 0.9);
    }
}

test "a box thrown at a wall bounces instead of passing through" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    floorAt(&world, 0);
    var z: i32 = -8;
    while (z <= 8) : (z += 1) {
        _ = world.setBlock(4, 1, z, .stone);
        _ = world.setBlock(4, 2, z, .stone);
    }

    var items: [4]Body = undefined;
    var bodies = Bodies.init(&items);
    _ = bodies.spawn(.{ .x = 0.5, .y = 1.5, .z = 0.5 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 20, .y = 0, .z = 0 });

    var tick: usize = 0;
    while (tick < 120) : (tick += 1) {
        bodies.step(&world, 1.0 / 60.0);
        try testing.expect(!overlapsWorld(&world, bodies.items[0].position, bodies.items[0].half));
    }
    try testing.expect(bodies.items[0].position.x < 4.0);
}

test "spawn is capped and clear resets" {
    var items: [3]Body = undefined;
    var bodies = Bodies.init(&items);
    try testing.expect(bodies.spawn(.{ .x = 0, .y = 8, .z = 0 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = 0, .z = 0 }));
    try testing.expect(bodies.spawn(.{ .x = 1, .y = 8, .z = 0 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = 0, .z = 0 }));
    try testing.expect(bodies.spawn(.{ .x = 2, .y = 8, .z = 0 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = 0, .z = 0 }));
    try testing.expect(!bodies.spawn(.{ .x = 3, .y = 8, .z = 0 }, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 0, .y = 0, .z = 0 }));
    try testing.expectEqual(@as(usize, 3), bodies.count);
    bodies.clear();
    try testing.expectEqual(@as(usize, 0), bodies.count);
}
