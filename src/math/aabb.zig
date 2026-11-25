const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;

/// Axis-aligned bounding box, used for chunk culling and (later) player physics.
pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn init(min: Vec3, max: Vec3) Aabb {
        return .{ .min = min, .max = max };
    }

    pub fn fromCenterSize(centre: Vec3, extents: Vec3) Aabb {
        const half = extents.scale(0.5);
        return .{ .min = centre.sub(half), .max = centre.add(half) };
    }

    pub fn size(self: Aabb) Vec3 {
        return self.max.sub(self.min);
    }

    pub fn center(self: Aabb) Vec3 {
        return self.min.add(self.max).scale(0.5);
    }

    pub fn volume(self: Aabb) f32 {
        const s = self.size();
        return s.x * s.y * s.z;
    }

    pub fn containsPoint(self: Aabb, p: Vec3) bool {
        return p.x >= self.min.x and p.x <= self.max.x and
            p.y >= self.min.y and p.y <= self.max.y and
            p.z >= self.min.z and p.z <= self.max.z;
    }

    pub fn intersects(self: Aabb, other: Aabb) bool {
        return self.min.x <= other.max.x and self.max.x >= other.min.x and
            self.min.y <= other.max.y and self.max.y >= other.min.y and
            self.min.z <= other.max.z and self.max.z >= other.min.z;
    }

    /// Smallest box containing both.
    pub fn expand(self: Aabb, other: Aabb) Aabb {
        return .{ .min = Vec3.min(self.min, other.min), .max = Vec3.max(self.max, other.max) };
    }

    pub fn expandPoint(self: Aabb, p: Vec3) Aabb {
        return .{ .min = Vec3.min(self.min, p), .max = Vec3.max(self.max, p) };
    }

    pub fn intersection(self: Aabb, other: Aabb) ?Aabb {
        if (!self.intersects(other)) return null;
        return .{ .min = Vec3.max(self.min, other.min), .max = Vec3.min(self.max, other.max) };
    }

    pub const RayHit = struct {
        /// Parameter along the ray where it enters the box (may be negative
        /// when the origin is inside).
        t_enter: f32,
        t_exit: f32,
    };

    /// Slab test. Returns null when the ray misses or the box is behind it.
    pub fn rayHit(self: Aabb, origin: Vec3, direction: Vec3) ?RayHit {
        var t_enter: f32 = -std.math.inf(f32);
        var t_exit: f32 = std.math.inf(f32);

        const axes = [3]struct { o: f32, d: f32, lo: f32, hi: f32 }{
            .{ .o = origin.x, .d = direction.x, .lo = self.min.x, .hi = self.max.x },
            .{ .o = origin.y, .d = direction.y, .lo = self.min.y, .hi = self.max.y },
            .{ .o = origin.z, .d = direction.z, .lo = self.min.z, .hi = self.max.z },
        };

        for (axes) |a| {
            if (@abs(a.d) < 1e-9) {
                // Parallel to this slab: miss unless the origin is inside it.
                if (a.o < a.lo or a.o > a.hi) return null;
                continue;
            }
            var t0 = (a.lo - a.o) / a.d;
            var t1 = (a.hi - a.o) / a.d;
            if (t0 > t1) {
                const tmp = t0;
                t0 = t1;
                t1 = tmp;
            }
            t_enter = @max(t_enter, t0);
            t_exit = @min(t_exit, t1);
            if (t_enter > t_exit) return null;
        }

        if (t_exit < 0) return null;
        return .{ .t_enter = t_enter, .t_exit = t_exit };
    }
};

// ------------------------------------------------------------------ tests

test "size, center and volume" {
    const box = Aabb.init(Vec3.init(-1, -2, -3), Vec3.init(1, 2, 3));
    try std.testing.expect(box.size().eqlApprox(Vec3.init(2, 4, 6), 1e-6));
    try std.testing.expect(box.center().eqlApprox(Vec3.zero, 1e-6));
    try std.testing.expectApproxEqAbs(@as(f32, 48), box.volume(), 1e-5);
}

test "fromCenterSize matches min and max" {
    const box = Aabb.fromCenterSize(Vec3.init(10, 0, -5), Vec3.init(2, 2, 2));
    try std.testing.expect(box.min.eqlApprox(Vec3.init(9, -1, -6), 1e-6));
    try std.testing.expect(box.max.eqlApprox(Vec3.init(11, 1, -4), 1e-6));
}

test "intersects is inclusive at touching faces" {
    const a = Aabb.init(Vec3.init(0, 0, 0), Vec3.init(1, 1, 1));
    const b = Aabb.init(Vec3.init(1, 0, 0), Vec3.init(2, 1, 1));
    const c = Aabb.init(Vec3.init(1.01, 0, 0), Vec3.init(2, 1, 1));
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(!a.intersects(c));
}

test "expand and expandPoint grow the box" {
    const a = Aabb.init(Vec3.zero, Vec3.one);
    const b = a.expand(Aabb.init(Vec3.init(-5, 0, 0), Vec3.init(0, 0.5, 0.5)));
    try std.testing.expectEqual(@as(f32, -5), b.min.x);
    const p = a.expandPoint(Vec3.init(0, 4, 0));
    try std.testing.expectEqual(@as(f32, 4), p.max.y);
}

test "ray hits the box from outside" {
    const box = Aabb.init(Vec3.splat(-1), Vec3.splat(1));
    const hit = box.rayHit(Vec3.init(0, 0, 5), Vec3.init(0, 0, -1)) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 4), hit.t_enter, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6), hit.t_exit, 1e-5);
}

test "ray misses when passing beside the box" {
    const box = Aabb.init(Vec3.splat(-1), Vec3.splat(1));
    try std.testing.expectEqual(@as(?Aabb.RayHit, null), box.rayHit(Vec3.init(5, 0, 5), Vec3.init(0, 0, -1)));
    // parallel to a slab and outside it
    try std.testing.expectEqual(@as(?Aabb.RayHit, null), box.rayHit(Vec3.init(5, 0, 5), Vec3.init(0, 1, 0)));
}

test "ray starting inside reports a negative enter and positive exit" {
    const box = Aabb.init(Vec3.splat(-1), Vec3.splat(1));
    const hit = box.rayHit(Vec3.zero, Vec3.init(0, 0, -1)) orelse return error.ExpectedHit;
    try std.testing.expect(hit.t_enter < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hit.t_exit, 1e-5);
}

test "ray pointing away from the box misses" {
    const box = Aabb.init(Vec3.splat(-1), Vec3.splat(1));
    try std.testing.expectEqual(@as(?Aabb.RayHit, null), box.rayHit(Vec3.init(0, 0, 5), Vec3.init(0, 0, 1)));
}
