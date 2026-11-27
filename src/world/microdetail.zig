//! Shared micro-height field for the ground. The terrain shader evaluates the same formula for
//! relief and normals; the grass scatter samples it on the CPU so a blade base sits on the
//! pebble/bump surface instead of the smooth macro-height field.

const std = @import("std");

fn hash21(x: f32, z: f32) f32 {
    const v = std.math.sin(x * 12.9898 + z * 78.233) * 43758.5453;
    return v - @floor(v);
}

fn pebble(x: f32, z: f32) f32 {
    const step: f32 = 0.62;
    const cx = @floor(x / step);
    const cz = @floor(z / step);
    const jx = hash21(cx + 1.7, cz + 3.1);
    const jz = hash21(cx + 8.3, cz + 5.7);
    const r = 0.10 + 0.14 * hash21(cx + 4.9, cz + 9.2);
    const px = (cx + 0.5) * step + (jx - 0.5) * step * 0.48;
    const pz = (cz + 0.5) * step + (jz - 0.5) * step * 0.48;
    const d = @sqrt((x - px) * (x - px) + (z - pz) * (z - pz));
    return (1.0 - std.math.clamp(d / r, 0.0, 1.0));
}

/// Centimetre-scale height above the macro terrain, in metres. Keep this in sync with
/// `microHeight()` in `dc_renderer.zig`; both use the same constants and operation order.
pub fn height(x: f32, z: f32) f32 {
    var h: f32 = 0.0;
    h += 0.016 * std.math.sin(x * 2.7 + z * 0.7) * std.math.cos(z * 2.1 - x * 0.3);
    h += 0.009 * std.math.sin(x * 7.3 + 1.7) * std.math.cos(z * 6.1 + 0.4);
    h += 0.032 * pebble(x, z);
    return h;
}

/// The strength of the pebble mask. Grass scatter uses this to leave gravel patches bare.
pub fn pebbleMask(x: f32, z: f32) f32 {
    return pebble(x, z);
}

/// Local height gradient sampled at a finite-difference step.
pub fn gradient(x: f32, z: f32) [2]f32 {
    const e: f32 = 0.025;
    return .{
        (height(x + e, z) - height(x - e, z)) / (2.0 * e),
        (height(x, z + e) - height(x, z - e)) / (2.0 * e),
    };
}

test "micro-height is deterministic and bounded" {
    const h1 = height(12.3, -4.7);
    const h2 = height(12.3, -4.7);
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(@abs(h1) < 0.08);
    try std.testing.expect(pebbleMask(12.3, -4.7) >= 0.0);
    try std.testing.expect(pebbleMask(12.3, -4.7) <= 1.0);
}
