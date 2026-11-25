const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Vec2 = .{};

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, factor: f32) Vec2 {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn lengthSquared(self: Vec2) f32 {
        return self.dot(self);
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.lengthSquared());
    }

    pub fn normalized(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return .zero;
        return self.scale(1 / len);
    }

    pub fn eqlApprox(self: Vec2, other: Vec2, epsilon: f32) bool {
        return @abs(self.x - other.x) <= epsilon and @abs(self.y - other.y) <= epsilon;
    }
};

/// 3D vector, f32, used for positions, directions and extents.
pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
    pub const up: Vec3 = .{ .x = 0, .y = 1, .z = 0 };
    pub const forward: Vec3 = .{ .x = 0, .y = 0, .z = -1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn splat(v: f32) Vec3 {
        return .{ .x = v, .y = v, .z = v };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn mul(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x * other.x, .y = self.y * other.y, .z = self.z * other.z };
    }

    pub fn scale(self: Vec3, factor: f32) Vec3 {
        return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor };
    }

    pub fn negate(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn lengthSquared(self: Vec3) f32 {
        return self.dot(self);
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSquared());
    }

    /// Returns a unit vector. Returns `zero` for a zero-length input rather
    /// than producing NaN.
    pub fn normalized(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return .zero;
        return self.scale(1 / len);
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }

    pub fn min(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
    }

    pub fn max(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
    }

    pub fn floor(self: Vec3) Vec3 {
        return .{ .x = @floor(self.x), .y = @floor(self.y), .z = @floor(self.z) };
    }

    pub fn eqlApprox(self: Vec3, other: Vec3, epsilon: f32) bool {
        return @abs(self.x - other.x) <= epsilon and
            @abs(self.y - other.y) <= epsilon and
            @abs(self.z - other.z) <= epsilon;
    }
};

pub const Vec4 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const zero: Vec4 = .{ .x = 0, .y = 0, .z = 0, .w = 0 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn fromVec3(v: Vec3, w: f32) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    pub fn toVec3(self: Vec4) Vec3 {
        return .{ .x = self.x, .y = self.y, .z = self.z };
    }

    pub fn add(self: Vec4, other: Vec4) Vec4 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z, .w = self.w + other.w };
    }

    pub fn sub(self: Vec4, other: Vec4) Vec4 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z, .w = self.w - other.w };
    }

    pub fn scale(self: Vec4, factor: f32) Vec4 {
        return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor, .w = self.w * factor };
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
    }

    pub fn eqlApprox(self: Vec4, other: Vec4, epsilon: f32) bool {
        return @abs(self.x - other.x) <= epsilon and
            @abs(self.y - other.y) <= epsilon and
            @abs(self.z - other.z) <= epsilon and
            @abs(self.w - other.w) <= epsilon;
    }
};

// ------------------------------------------------------------------ tests

test "add and sub are inverse" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(-4, 0.5, 7);
    try std.testing.expect(a.add(b).sub(b).eqlApprox(a, 1e-6));
}

test "dot of axes" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    try std.testing.expectEqual(@as(f32, 0), x.dot(y));
    try std.testing.expectEqual(@as(f32, 1), x.dot(x));
}

test "cross follows right-hand rule" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    try std.testing.expect(x.cross(y).eqlApprox(Vec3.init(0, 0, 1), 1e-6));
    try std.testing.expect(y.cross(x).eqlApprox(Vec3.init(0, 0, -1), 1e-6));
}

test "normalized has unit length and zero is safe" {
    const len = Vec3.init(3, 4, 12).normalized().length();
    try std.testing.expect(@abs(len - 1) < 1e-5);
    try std.testing.expectEqual(@as(f32, 0), Vec3.zero.normalized().length());
}

test "min, max, lerp and floor" {
    const a = Vec3.init(-1, 5, 0.5);
    const b = Vec3.init(3, 2, -7);
    try std.testing.expect(Vec3.min(a, b).eqlApprox(Vec3.init(-1, 2, -7), 1e-6));
    try std.testing.expect(Vec3.max(a, b).eqlApprox(Vec3.init(3, 5, 0.5), 1e-6));
    try std.testing.expect(Vec3.lerp(a, b, 0.5).eqlApprox(Vec3.init(1, 3.5, -3.25), 1e-6));
    try std.testing.expect(Vec3.init(1.7, -0.2, 2).floor().eqlApprox(Vec3.init(1, -1, 2), 1e-6));
}

test "vec2 and vec4 basics" {
    try std.testing.expectEqual(@as(f32, 5), Vec2.init(3, 4).length());
    try std.testing.expectEqual(@as(f32, 11), Vec4.init(1, 2, 3, 5).dot(Vec4.init(1, 1, 1, 1)));
    try std.testing.expect(Vec4.fromVec3(Vec3.init(1, 2, 3), 1).toVec3().eqlApprox(Vec3.init(1, 2, 3), 1e-6));
}
