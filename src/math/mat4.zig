const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Vec4 = @import("vec.zig").Vec4;

/// 4x4 matrix, column-major, right-handed, GL conventions (clip z in -1..1).
/// Storage is `m[column * 4 + row]`, which is what glUniformMatrix4fv expects
/// with transpose = false.
pub const Mat4 = struct {
    m: [16]f32,

    pub const identity: Mat4 = .{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                out.m[col * 4 + row] = sum;
            }
        }
        return out;
    }

    pub fn mulVec4(self: Mat4, v: Vec4) Vec4 {
        return .{
            .x = self.m[0] * v.x + self.m[4] * v.y + self.m[8] * v.z + self.m[12] * v.w,
            .y = self.m[1] * v.x + self.m[5] * v.y + self.m[9] * v.z + self.m[13] * v.w,
            .z = self.m[2] * v.x + self.m[6] * v.y + self.m[10] * v.z + self.m[14] * v.w,
            .w = self.m[3] * v.x + self.m[7] * v.y + self.m[11] * v.z + self.m[15] * v.w,
        };
    }

    /// Point transform with the perspective divide.
    pub fn transformPoint(self: Mat4, p: Vec3) Vec3 {
        const r = self.mulVec4(Vec4.fromVec3(p, 1));
        if (r.w == 0 or r.w == 1) return r.toVec3();
        return r.toVec3().scale(1 / r.w);
    }

    /// Direction transform, ignoring translation (w = 0).
    pub fn transformDirection(self: Mat4, d: Vec3) Vec3 {
        return self.mulVec4(Vec4.fromVec3(d, 0)).toVec3();
    }

    pub fn translate(t: Vec3) Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            t.x, t.y, t.z, 1,
        } };
    }

    pub fn scale(s: Vec3) Mat4 {
        return .{ .m = .{
            s.x, 0, 0, 0,
            0, s.y, 0, 0,
            0, 0, s.z, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn rotateX(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            1, 0, 0, 0,
            0, c, s, 0,
            0, -s, c, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn rotateY(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c, 0, -s, 0,
            0, 1, 0, 0,
            s, 0, c, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn rotateZ(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c, s, 0, 0,
            -s, c, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    /// GL-style perspective projection. `fovy` in radians.
    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(aspect != 0 and near > 0 and far > near);
        const f = 1.0 / @tan(fovy / 2.0);
        return .{ .m = .{
            f / aspect, 0, 0, 0,
            0, f, 0, 0,
            0, 0, (far + near) / (near - far), -1,
            0, 0, (2 * far * near) / (near - far), 0,
        } };
    }

    /// Right-handed look-at view matrix.
    /// Orthographic projection with GL clip depth -1..1, same column-major
    /// layout as `perspective`. Needed by the sun shadow map (3.8).
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(right != left and top != bottom and far != near);
        return .{ .m = .{
            2.0 / (right - left), 0, 0, 0,
            0, 2.0 / (top - bottom), 0, 0,
            0, 0, -2.0 / (far - near), 0,
            -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1,
        } };
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).normalized();
        const s = f.cross(up).normalized();
        const u = s.cross(f);
        return .{ .m = .{
            s.x, u.x, -f.x, 0,
            s.y, u.y, -f.y, 0,
            s.z, u.z, -f.z, 0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
        } };
    }

    pub fn transposed(self: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                out.m[col * 4 + row] = self.m[row * 4 + col];
            }
        }
        return out;
    }

    /// General inverse via cofactor expansion (MESA gluInvertMatrix). Returns
    /// null for a singular matrix. There is a cheaper rigid-body inverse for
    /// view matrices; this one is for tests and mixed transforms.
    pub fn inverse(self: Mat4) ?Mat4 {
        const m = self.m;
        var inv: [16]f32 = undefined;

        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

        const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (@abs(det) < 1e-12) return null;
        const inv_det = 1.0 / det;

        var out: Mat4 = undefined;
        for (0..16) |i| out.m[i] = inv[i] * inv_det;
        return out;
    }

    pub fn eqlApprox(self: Mat4, other: Mat4, epsilon: f32) bool {
        for (self.m, other.m) |a, b| {
            if (@abs(a - b) > epsilon) return false;
        }
        return true;
    }
};

// ------------------------------------------------------------------ tests

test "identity is neutral" {
    const t = Mat4.translate(Vec3.init(3, -2, 5));
    try std.testing.expect(Mat4.identity.mul(t).eqlApprox(t, 1e-6));
    try std.testing.expect(t.mul(Mat4.identity).eqlApprox(t, 1e-6));
}

test "translate applies after scale" {
    // M = T * S: scale first, then move. (1,0,0) -> (2,0,0) -> (3,2,3)
    const m = Mat4.translate(Vec3.init(1, 2, 3)).mul(Mat4.scale(Vec3.splat(2)));
    const p = m.transformPoint(Vec3.init(1, 0, 0));
    try std.testing.expect(p.eqlApprox(Vec3.init(3, 2, 3), 1e-6));
}

test "direction transform ignores translation" {
    const m = Mat4.translate(Vec3.init(100, 0, 0));
    try std.testing.expect(m.transformDirection(Vec3.init(0, 0, -1)).eqlApprox(Vec3.init(0, 0, -1), 1e-6));
}

test "perspective maps near and far planes to -1 and +1" {
    const p = Mat4.perspective(std.math.degreesToRadians(90), 1.0, 1.0, 10.0);
    const near = p.transformPoint(Vec3.init(0, 0, -1));
    const far = p.transformPoint(Vec3.init(0, 0, -10));
    try std.testing.expect(@abs(near.z - (-1.0)) < 1e-5);
    try std.testing.expect(@abs(far.z - 1.0) < 1e-5);
    // 90 degree vertical fov at aspect 1: x = -z at the edge
    const edge = p.transformPoint(Vec3.init(1, 1, -1));
    try std.testing.expect(@abs(edge.x - 1.0) < 1e-5);
    try std.testing.expect(@abs(edge.y - 1.0) < 1e-5);
}

test "lookAt puts the eye at the origin and the target down -Z" {
    const eye = Vec3.init(3, 4, 5);
    const target = Vec3.init(0, 0, 0);
    const view = Mat4.lookAt(eye, target, Vec3.up);

    const eye_in_view = view.transformPoint(eye);
    try std.testing.expect(eye_in_view.eqlApprox(Vec3.zero, 1e-5));

    const target_in_view = view.transformPoint(target);
    const distance = eye.sub(target).length();
    try std.testing.expect(@abs(target_in_view.z + distance) < 1e-5);
    try std.testing.expect(@abs(target_in_view.x) < 1e-5);
    try std.testing.expect(@abs(target_in_view.y) < 1e-5);
}

test "lookAt rotation part is orthonormal" {
    const view = Mat4.lookAt(Vec3.init(-4, 2, 7), Vec3.init(1, 0, -3), Vec3.up);
    // rows of the rotation block
    const r0 = Vec3.init(view.m[0], view.m[4], view.m[8]);
    const r1 = Vec3.init(view.m[1], view.m[5], view.m[9]);
    const r2 = Vec3.init(view.m[2], view.m[6], view.m[10]);
    const eps = 1e-5;
    try std.testing.expect(@abs(r0.length() - 1) < eps);
    try std.testing.expect(@abs(r1.length() - 1) < eps);
    try std.testing.expect(@abs(r2.length() - 1) < eps);
    try std.testing.expect(@abs(r0.dot(r1)) < eps);
    try std.testing.expect(@abs(r0.dot(r2)) < eps);
    try std.testing.expect(@abs(r1.dot(r2)) < eps);
}

test "inverse roundtrips a mixed transform" {
    const m = Mat4.translate(Vec3.init(5, -2, 9))
        .mul(Mat4.rotateY(0.7))
        .mul(Mat4.rotateX(-0.3))
        .mul(Mat4.scale(Vec3.init(2, 3, 4)));
    const inv = m.inverse() orelse return error.Singular;
    try std.testing.expect(m.mul(inv).eqlApprox(Mat4.identity, 1e-4));
    try std.testing.expect(inv.mul(m).eqlApprox(Mat4.identity, 1e-4));
}

test "singular matrix has no inverse" {
    try std.testing.expectEqual(@as(?Mat4, null), Mat4.scale(Vec3.init(1, 0, 1)).inverse());
}

test "transpose twice is the original" {
    const m = Mat4.translate(Vec3.init(1, 2, 3)).mul(Mat4.rotateZ(0.4));
    try std.testing.expect(m.transposed().transposed().eqlApprox(m, 1e-6));
}

test "ortho maps the box corners onto the clip cube" {
    const projection = Mat4.ortho(-10, 10, -5, 5, 1, 101);
    // Centre of the box maps to the origin.
    const centre = projection.transformPoint(Vec3.init(0, 0, -51));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), centre.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), centre.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), centre.z, 1e-5);
    // Corner (10, 5, -1) maps to (1, 1, -1): the near plane is the front face.
    const corner = projection.transformPoint(Vec3.init(10, 5, -1));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), corner.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), corner.z, 1e-5);
    // And the far plane is +1.
    const far_corner = projection.transformPoint(Vec3.init(-10, -5, -101));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_corner.z, 1e-4);
}
