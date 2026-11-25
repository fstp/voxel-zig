const std = @import("std");
const Vec3 = @import("math/vec.zig").Vec3;
const Mat4 = @import("math/mat4.zig").Mat4;

/// Free-fly camera. The player controller (1.9) will drive the same struct;
/// until then WASD moves it directly.
pub const Camera = struct {
    position: Vec3 = .{ .x = 0, .y = 10, .z = 22 },
    /// Radians. 0 looks down -Z, positive turns towards +X.
    yaw: f32 = 0,
    /// Radians, positive looks up, clamped to +-MAX_PITCH.
    pitch: f32 = -0.12,
    fov_y_deg: f32 = 70,
    near: f32 = 0.1,
    far: f32 = 1000,
    /// Fly speed in units (metres) per second, changed by the scroll wheel.
    speed: f32 = 12,

    pub const MAX_PITCH: f32 = 1.55; // ~89 degrees
    pub const SENSITIVITY: f32 = 0.0022; // radians per pixel of mouse movement

    pub fn forward(self: Camera) Vec3 {
        const cp = @cos(self.pitch);
        return .{
            .x = @sin(self.yaw) * cp,
            .y = @sin(self.pitch),
            .z = -@cos(self.yaw) * cp,
        };
    }

    pub fn right(self: Camera) Vec3 {
        return self.forward().cross(Vec3.up).normalized();
    }

    pub fn up(self: Camera) Vec3 {
        return self.right().cross(self.forward()).normalized();
    }

    pub fn view(self: Camera) Mat4 {
        return Mat4.lookAt(self.position, self.position.add(self.forward()), Vec3.up);
    }

    pub fn projection(self: Camera, aspect: f32) Mat4 {
        return Mat4.perspective(std.math.degreesToRadians(self.fov_y_deg), aspect, self.near, self.far);
    }

    pub fn viewProjection(self: Camera, aspect: f32) Mat4 {
        return self.projection(aspect).mul(self.view());
    }

    /// Mouse look. `dx`/`dy` are relative mouse pixels for the frame.
    pub fn look(self: *Camera, dx: f32, dy: f32) void {
        self.yaw += dx * SENSITIVITY;
        self.pitch -= dy * SENSITIVITY;
        if (self.pitch > MAX_PITCH) self.pitch = MAX_PITCH;
        if (self.pitch < -MAX_PITCH) self.pitch = -MAX_PITCH;
    }

    pub fn adjustSpeed(self: *Camera, wheel_delta: f32) void {
        self.speed *= std.math.pow(f32, 1.25, wheel_delta);
        self.speed = std.math.clamp(self.speed, 1, 400);
    }

    /// `wish` is local: x = right, y = up, z = forward. Diagonals do not
    /// outrun a straight line.
    pub fn fly(self: *Camera, wish: Vec3, dt: f32, sprint: bool) void {
        var local = wish;
        if (local.lengthSquared() > 1) local = local.normalized();
        const boost: f32 = if (sprint) 3.0 else 1.0;
        const world = self.right().scale(local.x)
            .add(self.up().scale(local.y))
            .add(self.forward().scale(local.z));
        self.position = self.position.add(world.scale(self.speed * boost * dt));
    }
};

// ------------------------------------------------------------------ tests

test "forward follows yaw and pitch" {
    var cam: Camera = .{ .yaw = 0, .pitch = 0 };
    try std.testing.expect(cam.forward().eqlApprox(Vec3.init(0, 0, -1), 1e-6));

    cam.yaw = std.math.pi / 2.0;
    try std.testing.expect(cam.forward().eqlApprox(Vec3.init(1, 0, 0), 1e-5));

    cam.yaw = 0;
    cam.pitch = std.math.pi / 2.0;
    try std.testing.expect(cam.forward().eqlApprox(Vec3.init(0, 1, 0), 1e-5));
}

test "pitch is clamped" {
    var cam: Camera = .{};
    cam.look(0, -100000);
    try std.testing.expectEqual(Camera.MAX_PITCH, cam.pitch);
    cam.look(0, 200000);
    try std.testing.expectEqual(-Camera.MAX_PITCH, cam.pitch);
}

test "right and up are orthonormal with forward" {
    const cam: Camera = .{ .yaw = 0.9, .pitch = -0.4 };
    const f = cam.forward();
    const r = cam.right();
    const u = cam.up();
    try std.testing.expectApproxEqAbs(@as(f32, 1), f.length(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.length(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), u.length(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.dot(r), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.dot(u), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.dot(u), 1e-5);
}

test "view matrix puts the camera at the origin" {
    const cam: Camera = .{ .position = .{ .x = 3, .y = 10, .z = -7 } };
    const p = cam.view().transformPoint(cam.position);
    try std.testing.expect(p.eqlApprox(Vec3.zero, 1e-5));
}

test "flying forward moves along forward only" {
    var cam: Camera = .{ .position = Vec3.zero, .yaw = 0, .pitch = 0, .speed = 10 };
    cam.fly(Vec3.init(0, 0, 1), 1.0, false);
    try std.testing.expect(cam.position.eqlApprox(Vec3.init(0, 0, -10), 1e-5));
}

test "diagonal input is not faster than straight input" {
    var straight: Camera = .{ .position = Vec3.zero, .speed = 10 };
    var diagonal: Camera = .{ .position = Vec3.zero, .speed = 10 };
    straight.fly(Vec3.init(0, 0, 1), 1.0, false);
    diagonal.fly(Vec3.init(1, 0, 1), 1.0, false);
    try std.testing.expectApproxEqAbs(@as(f32, 10), straight.position.length(), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), diagonal.position.length(), 1e-5);
}

test "sprint triples the distance" {
    var cam: Camera = .{ .position = Vec3.zero, .speed = 10 };
    cam.fly(Vec3.init(0, 0, 1), 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, 15), cam.position.length(), 1e-5);
}

test "scroll wheel changes speed within bounds" {
    var cam: Camera = .{ .speed = 12 };
    cam.adjustSpeed(1);
    try std.testing.expect(cam.speed > 12);
    cam.adjustSpeed(-1000);
    try std.testing.expectEqual(@as(f32, 1), cam.speed);
    cam.adjustSpeed(1000);
    try std.testing.expectEqual(@as(f32, 400), cam.speed);
}
