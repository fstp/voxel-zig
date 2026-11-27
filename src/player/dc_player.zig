//! The player motion model for the DC world: the engine's walk/fly constants against the height
//! field instead of the block grid (ADR 0022).

const std = @import("std");
const Vec3 = @import("../math/vec.zig").Vec3;
const heightAt = @import("../world/dc_world.zig").heightAt;

pub const DcPlayer = struct {
    position: Vec3,
    velocity: Vec3 = Vec3.zero,
    yaw: f32,
    pitch: f32,
    flying: bool = false,
    on_ground: bool = false,
    /// Fly-mode speed in m/s, changed by the scroll wheel like `vz.Camera.adjustSpeed`.
    fly_speed: f32 = FLY_SPEED,

    const EYE: f32 = 1.62;
    const GRAVITY: f32 = 32.0;
    const TERMINAL_VELOCITY: f32 = 60.0;
    const JUMP_IMPULSE: f32 = 9.0;
    const WALK_SPEED: f32 = 4.5;
    const SPRINT_SPEED: f32 = 7.0;
    const FLY_SPEED: f32 = 24.0;
    const STEP_HEIGHT: f32 = 1.05;
    const RADIUS: f32 = 0.3;
    const MAX_SUBSTEP: f32 = 0.25;

    pub fn eyePosition(self: DcPlayer) Vec3 {
        return Vec3.init(self.position.x, self.position.y + EYE, self.position.z);
    }

    pub fn forward(self: DcPlayer) Vec3 {
        const cp = @cos(self.pitch);
        return Vec3.init(@sin(self.yaw) * cp, @sin(self.pitch), -@cos(self.yaw) * cp);
    }

    pub fn groundAt(x: f32, z: f32) f32 {
        var h = heightAt(x - RADIUS, z - RADIUS);
        h = @max(h, heightAt(x + RADIUS, z - RADIUS));
        h = @max(h, heightAt(x - RADIUS, z + RADIUS));
        h = @max(h, heightAt(x + RADIUS, z + RADIUS));
        return h;
    }

    fn blockedAt(self: DcPlayer, x: f32, z: f32) bool {
        return groundAt(x, z) > self.position.y + STEP_HEIGHT;
    }

    const Axis = enum { x, z };

    fn moveAxis(self: *DcPlayer, axis: Axis, delta: f32) void {
        var remaining = delta;
        while (@abs(remaining) > 0.00001) {
            const step = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            const nx = if (axis == .x) self.position.x + step else self.position.x;
            const nz = if (axis == .z) self.position.z + step else self.position.z;
            if (self.blockedAt(nx, nz)) {
                self.velocity.x = 0;
                self.velocity.z = 0;
                return;
            }
            self.position.x = nx;
            self.position.z = nz;
            // Walk up a gentle rise without a jump. The engine does this by lifting and testing the
            // block ledge; here the surface is continuous, so the rise itself is the test.
            const ground = groundAt(nx, nz);
            if (ground > self.position.y and ground <= self.position.y + STEP_HEIGHT and self.velocity.y <= 0) {
                self.position.y = ground;
                self.on_ground = true;
            }
            remaining -= step;
        }
    }

    /// One fixed 60 Hz tick. `wish` is the yaw-relative horizontal direction (length 0 or 1),
    /// `up` is +1 for Space and -1 for Ctrl in fly mode.
    pub fn update(self: *DcPlayer, dt: f32, wish: Vec3, up: f32, sprint: bool) void {
        if (self.flying) {
            const speed = self.fly_speed * (if (sprint) @as(f32, 3.0) else 1.0);
            self.velocity = Vec3.init(wish.x * speed, up * speed, wish.z * speed);
            self.position = self.position.add(self.velocity.scale(dt));
            self.on_ground = false;
            return;
        }

        const speed = if (sprint) SPRINT_SPEED else WALK_SPEED;
        self.velocity.x = wish.x * speed;
        self.velocity.z = wish.z * speed;

        if (up > 0 and self.on_ground) self.velocity.y = JUMP_IMPULSE;
        self.velocity.y = @max(self.velocity.y - GRAVITY * dt, -TERMINAL_VELOCITY);

        self.on_ground = false;
        self.moveAxis(.x, self.velocity.x * dt);
        self.moveAxis(.z, self.velocity.z * dt);
        self.position.y += self.velocity.y * dt;

        const ground = groundAt(self.position.x, self.position.z);
        if (self.position.y <= ground) {
            self.position.y = ground;
            self.velocity.y = 0;
            self.on_ground = true;
        }
    }
};
