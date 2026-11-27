//! Screen-space animation error and the distance at which a per-plant wind displacement is no
//! longer worth paying for. The paper's animation-error idea, reduced to one cheap projection:
//! a world-space displacement of `d` metres at distance `z` covers `d * f / z` pixels.

const std = @import("std");

/// Pixels per metre at distance `distance` for a vertical FOV and viewport height.
pub fn focalPixels(viewport_height: f32, fov_y_deg: f32) f32 {
    const fov = std.math.degreesToRadians(std.math.clamp(fov_y_deg, 1.0, 179.0));
    return 0.5 * viewport_height / @max(@tan(0.5 * fov), 1e-4);
}

/// Conservative projected displacement in pixels.
pub fn screenErrorPixels(world_displacement: f32, distance: f32, viewport_height: f32, fov_y_deg: f32) f32 {
    return @max(world_displacement, 0.0) * focalPixels(viewport_height, fov_y_deg) / @max(distance, 0.01);
}

/// Distance beyond which the projected displacement is at most `max_pixels`.
pub fn cutoffDistance(world_displacement: f32, max_pixels: f32, viewport_height: f32, fov_y_deg: f32) f32 {
    return @max(world_displacement, 0.0) * focalPixels(viewport_height, fov_y_deg) / @max(max_pixels, 0.01);
}

/// 1 inside the animation range, 0 past the cutoff, with a smooth fade band so the transition
/// cannot pop.
pub fn animationWeight(distance: f32, cutoff: f32, fade_band: f32) f32 {
    if (cutoff <= 0.0) return 0.0;
    const fade = std.math.clamp(fade_band, 0.0, cutoff);
    return 1.0 - smoothstep(cutoff - fade, cutoff, distance);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 <= edge0) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

test "screen error falls with distance and cutoff matches it" {
    const h: f32 = 2123.0;
    const fov: f32 = 70.0;
    const e_near = screenErrorPixels(0.25, 20.0, h, fov);
    const e_far = screenErrorPixels(0.25, 80.0, h, fov);
    try std.testing.expect(e_near > e_far);
    const cut = cutoffDistance(0.25, 2.0, h, fov);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), screenErrorPixels(0.25, cut, h, fov), 0.02);
}

/// Screen-space LOD thresholds in pixels at the current focal length. `prev` is the LOD used
/// in the previous frame; the small hysteresis band stops a tree at a boundary from flickering
/// between two LODs as the camera drifts.
pub fn lodForPixels(pixels: f32, prev: u8) u8 {
    const t0: f32 = 220.0;
    const t1: f32 = 110.0;
    const t2: f32 = 75.0;
    const h: f32 = 0.08;
    if (prev == 0 and pixels >= t0 * (1.0 - h)) return 0;
    if (prev == 1 and pixels >= t1 * (1.0 - h) and pixels <= t0 * (1.0 + h)) return 1;
    if (prev == 2 and pixels >= t2 * (1.0 - h) and pixels <= t1 * (1.0 + h)) return 2;
    if (pixels >= t0) return 0;
    if (pixels >= t1) return 1;
    if (pixels >= t2) return 2;
    return 3;
}

test "LOD selection uses projected pixels with hysteresis" {
    try std.testing.expectEqual(@as(u8, 0), lodForPixels(300.0, 255));
    try std.testing.expectEqual(@as(u8, 1), lodForPixels(150.0, 255));
    try std.testing.expectEqual(@as(u8, 2), lodForPixels(90.0, 255));
    try std.testing.expectEqual(@as(u8, 3), lodForPixels(40.0, 255));
    // Just above the LOD0 boundary, a previous LOD1 stays LOD1 inside the band.
    try std.testing.expectEqual(@as(u8, 1), lodForPixels(228.0, 1));
    try std.testing.expectEqual(@as(u8, 0), lodForPixels(228.0, 255));
}

test "animation weight fades to zero before the cutoff" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), animationWeight(50.0, 90.0, 15.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), animationWeight(90.0, 90.0, 15.0), 1e-5);
    const mid = animationWeight(82.5, 90.0, 15.0);
    try std.testing.expect(mid > 0.0 and mid < 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), animationWeight(10.0, 0.0, 15.0), 1e-5);
}
