const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Vec4 = @import("vec.zig").Vec4;
const Mat4 = @import("mat4.zig").Mat4;
const Aabb = @import("aabb.zig").Aabb;

pub const Plane = struct {
    /// Unit normal pointing into the frustum.
    normal: Vec3,
    d: f32,

    pub fn distanceTo(self: Plane, p: Vec3) f32 {
        return self.normal.dot(p) + self.d;
    }
};

/// View frustum extracted from a view-projection matrix (Gribb-Hartmann).
/// Six planes; an AABB is visible if it is on the inside of every plane.
pub const Frustum = struct {
    planes: [6]Plane,

    fn row(m: Mat4, index: usize) Vec4 {
        return .{
            .x = m.m[0 * 4 + index],
            .y = m.m[1 * 4 + index],
            .z = m.m[2 * 4 + index],
            .w = m.m[3 * 4 + index],
        };
    }

    fn plane(a: Vec4) Plane {
        const len = @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
        std.debug.assert(len > 0);
        return .{ .normal = .{ .x = a.x / len, .y = a.y / len, .z = a.z / len }, .d = a.w / len };
    }

    pub fn fromViewProjection(vp: Mat4) Frustum {
        const r0 = row(vp, 0);
        const r1 = row(vp, 1);
        const r2 = row(vp, 2);
        const r3 = row(vp, 3);
        return .{ .planes = .{
            plane(r3.add(r0)), // left
            plane(r3.sub(r0)), // right
            plane(r3.add(r1)), // bottom
            plane(r3.sub(r1)), // top
            plane(r3.add(r2)), // near
            plane(r3.sub(r2)), // far
        } };
    }

    pub fn containsPoint(self: Frustum, p: Vec3) bool {
        for (self.planes) |plane_| {
            if (plane_.distanceTo(p) < 0) return false;
        }
        return true;
    }

    /// Positive-vertex test: for each plane, only the box corner furthest along
    /// the plane normal has to be checked. Touching a plane counts as visible.
    pub fn containsAabb(self: Frustum, box: Aabb) bool {
        for (self.planes) |plane_| {
            const p = Vec3.init(
                if (plane_.normal.x >= 0) box.max.x else box.min.x,
                if (plane_.normal.y >= 0) box.max.y else box.min.y,
                if (plane_.normal.z >= 0) box.max.z else box.min.z,
            );
            if (plane_.distanceTo(p) < 0) return false;
        }
        return true;
    }
};

// ------------------------------------------------------------------ tests

fn testFrustum() Frustum {
    const view = Mat4.lookAt(Vec3.zero, Vec3.init(0, 0, -1), Vec3.up);
    const proj = Mat4.perspective(std.math.degreesToRadians(70), 16.0 / 9.0, 0.1, 100.0);
    return Frustum.fromViewProjection(proj.mul(view));
}

test "box in front of the camera is visible" {
    const f = testFrustum();
    const box = Aabb.fromCenterSize(Vec3.init(0, 0, -10), Vec3.splat(2));
    try std.testing.expect(f.containsAabb(box));
}

test "box behind the camera is culled" {
    const f = testFrustum();
    const box = Aabb.fromCenterSize(Vec3.init(0, 0, 10), Vec3.splat(2));
    try std.testing.expect(!f.containsAabb(box));
}

test "box beyond the far plane is culled" {
    const f = testFrustum();
    const box = Aabb.fromCenterSize(Vec3.init(0, 0, -150), Vec3.splat(2));
    try std.testing.expect(!f.containsAabb(box));
}

test "box far off to the side is culled" {
    const f = testFrustum();
    const box = Aabb.fromCenterSize(Vec3.init(300, 0, -10), Vec3.splat(2));
    try std.testing.expect(!f.containsAabb(box));
    const up = Aabb.fromCenterSize(Vec3.init(0, 300, -10), Vec3.splat(2));
    try std.testing.expect(!f.containsAabb(up));
}

test "box straddling the near plane is still visible" {
    const f = testFrustum();
    const box = Aabb.fromCenterSize(Vec3.init(0, 0, 0.05), Vec3.splat(1));
    try std.testing.expect(f.containsAabb(box));
}

test "points inside and outside the frustum" {
    const f = testFrustum();
    try std.testing.expect(f.containsPoint(Vec3.init(0, 0, -5)));
    try std.testing.expect(!f.containsPoint(Vec3.init(0, 0, 5)));
    try std.testing.expect(!f.containsPoint(Vec3.init(0, 0, -200)));
}

test "a box that only touches the plane is visible" {
    const f = testFrustum();
    // far plane at z = -100: box whose far face sits exactly on it
    const box = Aabb.fromCenterSize(Vec3.init(0, 0, -100), Vec3.init(2, 2, 0));
    try std.testing.expect(f.containsAabb(box));
}
