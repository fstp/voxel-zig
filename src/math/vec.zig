const std = @import("std");

/// 3D vector, f32, used for positions, directions and extents.
pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const up: Vec3 = .{ .x = 0, .y = 1, .z = 0 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn scale(self: Vec3, factor: f32) Vec3 {
        return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor };
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

    pub fn eqlApprox(self: Vec3, other: Vec3, epsilon: f32) bool {
        return @abs(self.x - other.x) <= epsilon and
            @abs(self.y - other.y) <= epsilon and
            @abs(self.z - other.z) <= epsilon;
    }
};

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
}

test "normalized has unit length and zero is safe" {
    const len = Vec3.init(3, 4, 12).normalized().length();
    try std.testing.expect(@abs(len - 1) < 1e-5);
    try std.testing.expectEqual(@as(f32, 0), Vec3.zero.normalized().length());
}
