const std = @import("std");
const Vec3 = @import("../math/vec.zig").Vec3;
const Aabb = @import("../math/aabb.zig").Aabb;
const World = @import("../world/world.zig").World;
const BlockId = @import("../voxel/block.zig").BlockId;

/// First-person player with axis-separated AABB collision against the voxel grid.
///
/// `position` is the centre of the feet. Movement is resolved one axis at a time
/// (x, then y, then z) and sub-stepped so a fast move cannot tunnel through a
/// block: at 7 m/s and 60 Hz a tick covers 0.117 m, well under a block.
pub const Player = struct {
    position: Vec3 = .{ .x = 144, .y = 140, .z = 400 },
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = false,
    /// Debug fly mode (F). No gravity, no collision.
    flying: bool = false,

    pub const WIDTH: f32 = 0.6;
    pub const HEIGHT: f32 = 1.8;
    pub const EYE: f32 = 1.62;
    pub const GRAVITY: f32 = 32.0;
    pub const TERMINAL_VELOCITY: f32 = 60.0;
    pub const JUMP_IMPULSE: f32 = 9.0;
    pub const WALK_SPEED: f32 = 4.5;
    pub const SPRINT_SPEED: f32 = 7.0;
    pub const FLY_SPEED: f32 = 24.0;
    /// Auto step-up height. 1.05 lets the player walk up a full block.
    pub const STEP_HEIGHT: f32 = 1.05;
    /// Ground probe distance so `on_ground` is stable on a resting player.
    pub const GROUND_EPSILON: f32 = 0.02;
    /// No sub-step moves further than this.
    pub const MAX_SUBSTEP: f32 = 0.25;

    pub fn eyePosition(self: Player) Vec3 {
        return .{ .x = self.position.x, .y = self.position.y + EYE, .z = self.position.z };
    }

    pub fn forward(self: Player) Vec3 {
        const cp = @cos(self.pitch);
        return .{ .x = @sin(self.yaw) * cp, .y = @sin(self.pitch), .z = -@cos(self.yaw) * cp };
    }

    pub fn aabbAt(position: Vec3) Aabb {
        return Aabb.fromCenterSize(
            Vec3.init(position.x, position.y + HEIGHT * 0.5, position.z),
            Vec3.init(WIDTH, HEIGHT, WIDTH),
        );
    }

    /// True when the player box at `position` overlaps any solid block.
    pub fn collidesAt(world: *const World, position: Vec3) bool {
        return blocksOverlap(world, position);
    }

    /// One fixed-timestep tick. `wish` is the desired horizontal direction in
    /// world space (already yaw-relative, length 0..1), `up` is +1 for jump /
    /// fly-up and -1 for fly-down.
    pub fn update(self: *Player, world: *const World, dt: f32, wish: Vec3, up: f32, sprint: bool) void {
        if (self.flying) {
            const speed = if (sprint) FLY_SPEED * 3.0 else FLY_SPEED;
            self.velocity = Vec3.init(wish.x * speed, up * speed, wish.z * speed);
            self.position = self.position.add(self.velocity.scale(dt));
            self.on_ground = false;
            return;
        }

        // Horizontal: snap to the walk speed rather than accelerating, which
        // keeps the controller predictable and testable.
        const speed = if (sprint) SPRINT_SPEED else WALK_SPEED;
        const horizontal = Vec3.init(wish.x, 0, wish.z);
        const length = @sqrt(horizontal.x * horizontal.x + horizontal.z * horizontal.z);
        if (length > 0.0001) {
            self.velocity.x = horizontal.x / length * speed;
            self.velocity.z = horizontal.z / length * speed;
        } else {
            self.velocity.x = 0;
            self.velocity.z = 0;
        }

        if (up > 0 and self.on_ground) self.velocity.y = JUMP_IMPULSE;
        self.velocity.y = @max(self.velocity.y - GRAVITY * dt, -TERMINAL_VELOCITY);

        self.on_ground = false;
        self.moveX(world, self.velocity.x * dt);
        self.moveZ(world, self.velocity.z * dt);
        self.moveY(world, self.velocity.y * dt);

        // Stable ground flag: probe just below the feet.
        if (collidesAt(world, .{ .x = self.position.x, .y = self.position.y - GROUND_EPSILON, .z = self.position.z })) {
            self.on_ground = true;
            if (self.velocity.y < 0) self.velocity.y = 0;
        }
    }

    fn moveX(self: *Player, world: *const World, delta: f32) void {
        if (delta == 0) return;
        var remaining = delta;
        while (@abs(remaining) > 0.00001) {
            const step = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            const candidate = Vec3.init(self.position.x + step, self.position.y, self.position.z);
            if (!blocksOverlap(world, candidate)) {
                self.position = candidate;
                remaining -= step;
                continue;
            }
            // Blocked: try stepping up over a ledge, otherwise stop on this axis.
            if (self.tryStepUp(world, step, .x)) return;
            self.velocity.x = 0;
            return;
        }
    }

    fn moveZ(self: *Player, world: *const World, delta: f32) void {
        if (delta == 0) return;
        var remaining = delta;
        while (@abs(remaining) > 0.00001) {
            const step = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            const candidate = Vec3.init(self.position.x, self.position.y, self.position.z + step);
            if (!blocksOverlap(world, candidate)) {
                self.position = candidate;
                remaining -= step;
                continue;
            }
            if (self.tryStepUp(world, step, .z)) return;
            self.velocity.z = 0;
            return;
        }
    }

    fn moveY(self: *Player, world: *const World, delta: f32) void {
        if (delta == 0) return;
        var remaining = delta;
        while (@abs(remaining) > 0.00001) {
            const step = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            const candidate = Vec3.init(self.position.x, self.position.y + step, self.position.z);
            if (!blocksOverlap(world, candidate)) {
                self.position = candidate;
                remaining -= step;
                continue;
            }
            if (step < 0) {
                // Landed: refine the contact point so the feet rest exactly on
                // the surface instead of a sub-step above it.
                self.settleDown(world, candidate.y);
                self.on_ground = true;
            }
            self.velocity.y = 0;
            return;
        }
    }

    /// Binary-searches the contact height between a blocked position and the
    /// current one; `blocked_y` must overlap.
    fn settleDown(self: *Player, world: *const World, blocked_y: f32) void {
        var lo = blocked_y;
        var hi = self.position.y;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const mid = (lo + hi) * 0.5;
            if (blocksOverlap(world, .{ .x = self.position.x, .y = mid, .z = self.position.z })) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        self.position.y = hi;
    }

    const Axis = enum { x, z };

    /// Lifts by up to STEP_HEIGHT, moves sideways, and drops back down. Only
    /// worth trying while grounded, and only if the destination is clear.
    fn tryStepUp(self: *Player, world: *const World, step: f32, axis: Axis) bool {
        if (!self.on_ground and self.velocity.y > 0) return false;
        const start = self.position;
        var lift: f32 = 0.05;
        while (lift <= STEP_HEIGHT) : (lift += 0.05) {
            var raised = start;
            raised.y = start.y + lift;
            if (blocksOverlap(world, raised)) break;

            var moved = raised;
            if (axis == .x) moved.x += step else moved.z += step;
            if (blocksOverlap(world, moved)) continue;

            // Settle back onto the ledge (never float).
            var settled = moved;
            var drop: f32 = 0;
            while (drop < lift + 0.05) : (drop += 0.05) {
                const lower = Vec3.init(moved.x, moved.y - drop, moved.z);
                if (blocksOverlap(world, lower)) break;
                settled = lower;
            }
            self.position = settled;
            self.on_ground = true;
            return true;
        }
        return false;
    }
};

/// AABB vs voxel grid. The box is the player's; every block it overlaps is
/// tested, so a box straddling four columns sees all four.
fn blocksOverlap(world: *const World, position: Vec3) bool {
    const half = Player.WIDTH * 0.5;
    const min_x = position.x - half;
    const max_x = position.x + half;
    const min_y = position.y;
    const max_y = position.y + Player.HEIGHT;
    const min_z = position.z - half;
    const max_z = position.z + half;

    // A hair inside the max edge: a box exactly flush with a face must not
    // register the block on the far side of it.
    const eps: f32 = 1e-4;
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

/// A world with a stone floor at y = 0..0 (top surface y = 1) over a 5x5 block
/// footprint, optionally with a wall or a step.
fn testWorld(allocator: std.mem.Allocator) !World {
    var world = World.init(allocator);
    errdefer world.deinit();
    var cx: i32 = -2;
    while (cx <= 2) : (cx += 1) {
        var cz: i32 = -2;
        while (cz <= 2) : (cz += 1) {
            _ = try world.getOrCreateChunk(coords.ChunkPos.init(cx, 0, cz));
        }
    }
    return world;
}

fn fillColumn(world: *World, x: i32, y: i32, z: i32, block: BlockId) void {
    _ = world.setBlock(x, y, z, block);
}

test "gravity lands the player on the floor and stops" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }

    var player = Player{ .position = .{ .x = 0, .y = 6, .z = 0 } };
    var tick: usize = 0;
    while (tick < 120) : (tick += 1) player.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = 0 }, 0, false);

    try testing.expectApproxEqAbs(@as(f32, 1.0), player.position.y, 0.05);
    try testing.expect(player.on_ground);
    try testing.expect(!Player.collidesAt(&world, player.position));
}

test "the player never falls through the floor" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    var player = Player{ .position = .{ .x = 0, .y = 40, .z = 0 } };
    var tick: usize = 0;
    while (tick < 600) : (tick += 1) {
        player.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = 0 }, 0, false);
        try testing.expect(player.position.y >= 0.99);
    }
}

test "walking into a wall stops without clipping" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    // Wall at x = 3, two blocks high.
    var z: i32 = -4;
    while (z <= 4) : (z += 1) {
        fillColumn(&world, 3, 1, z, .stone);
        fillColumn(&world, 3, 2, z, .stone);
    }

    var player = Player{ .position = .{ .x = 0, .y = 1, .z = 0 }, .on_ground = true };
    var tick: usize = 0;
    while (tick < 180) : (tick += 1) {
        player.update(&world, 1.0 / 60.0, .{ .x = 1, .y = 0, .z = 0 }, 0, true);
        try testing.expect(!Player.collidesAt(&world, player.position));
    }
    // Stopped in front of the wall (wall face at x = 3, half width 0.3).
    try testing.expect(player.position.x <= 2.7 + 0.01);
    try testing.expect(player.position.x > 2.0);
}

test "the player walks up a one-block step" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    // A one-block-high ledge starting at x = 2.
    x = 2;
    while (x <= 8) : (x += 1) {
        var z: i32 = -4;
        while (z <= 4) : (z += 1) fillColumn(&world, x, 1, z, .stone);
    }

    var player = Player{ .position = .{ .x = 0, .y = 1, .z = 0 }, .on_ground = true };
    var tick: usize = 0;
    // 60 ticks is ~4.5 blocks: enough to climb and stand on the ledge, short
    // enough not to walk off its far end (x = 8).
    while (tick < 60) : (tick += 1) {
        player.update(&world, 1.0 / 60.0, .{ .x = 1, .y = 0, .z = 0 }, 0, false);
        try testing.expect(!Player.collidesAt(&world, player.position));
    }
    // Up on the ledge and past its edge.
    try testing.expect(player.position.y >= 1.99);
    try testing.expect(player.position.x > 2.5);
}

test "jumping gains height and a ceiling stops it" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    var player = Player{ .position = .{ .x = 0, .y = 1, .z = 0 }, .on_ground = true };
    player.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = 0 }, 1, false);
    try testing.expect(player.velocity.y > 5);
    var peak: f32 = player.position.y;
    var tick: usize = 0;
    while (tick < 120) : (tick += 1) {
        player.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = 0 }, 0, false);
        peak = @max(peak, player.position.y);
    }
    // v^2 / 2g = 9^2 / 64 = 1.27 blocks above the floor.
    try testing.expect(peak > 2.0);
    try testing.expect(peak < 2.6);

    // Ceiling at y = 3 (player is 1.8 tall, feet at 1 -> head at 2.8).
    var z: i32 = -8;
    while (z <= 8) : (z += 1) fillColumn(&world, 0, 4, z, .stone);
    var capped = Player{ .position = .{ .x = 0, .y = 1, .z = 0 }, .on_ground = true };
    tick = 0;
    while (tick < 120) : (tick += 1) {
        capped.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = 0 }, 1, false);
        try testing.expect(capped.position.y + Player.HEIGHT <= 4.001);
    }
}

test "sprint-jumping into an inside corner never clips into blocks" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    // Two walls meeting at the corner (3, 3).
    x = 3;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 3) : (z += 1) {
            fillColumn(&world, x, 1, z, .stone);
            fillColumn(&world, x, 2, z, .stone);
        }
    }
    var z: i32 = 3;
    while (z <= 8) : (z += 1) {
        var xi: i32 = -8;
        while (xi <= 8) : (xi += 1) fillColumn(&world, xi, 1, z, .stone);
    }

    var player = Player{ .position = .{ .x = 0, .y = 1, .z = 0 }, .on_ground = true };
    var tick: usize = 0;
    while (tick < 300) : (tick += 1) {
        const jump: f32 = if (tick % 20 == 0) 1 else 0;
        player.update(&world, 1.0 / 60.0, .{ .x = 1, .y = 0, .z = 1 }, jump, true);
        try testing.expect(!Player.collidesAt(&world, player.position));
    }
}

test "fly mode ignores gravity and blocks" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var player = Player{ .position = .{ .x = 0, .y = 50, .z = 0 }, .flying = true };
    var tick: usize = 0;
    while (tick < 60) : (tick += 1) player.update(&world, 1.0 / 60.0, .{ .x = 0, .y = 0, .z = -1 }, 0, false);
    try testing.expectApproxEqAbs(@as(f32, 50), player.position.y, 0.001);
    try testing.expect(player.position.z < 40);
}

test "sub-stepping keeps fast moves out of blocks" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) fillColumn(&world, x, 0, z, .stone);
    }
    var z: i32 = -4;
    while (z <= 4) : (z += 1) {
        fillColumn(&world, 1, 1, z, .stone);
        fillColumn(&world, 1, 2, z, .stone);
    }
    var player = Player{ .position = .{ .x = -2, .y = 1, .z = 0 }, .on_ground = true };
    // A deliberately huge tick: 200 m/s for 0.1 s would cross the wall without
    // sub-stepping.
    player.update(&world, 0.1, .{ .x = 1, .y = 0, .z = 0 }, 0, true);
    try testing.expect(!Player.collidesAt(&world, player.position));
    try testing.expect(player.position.x < 1.0);
}
