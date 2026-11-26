const std = @import("std");

/// Stateless hashed gradient noise (ADR 0005).
///
/// There is no permutation table: every lattice point's gradient comes from
/// hashing `(seed, ix, iz)`, so a sample is a pure function of its inputs.
/// That is what lets chunks generate in any order on any thread and lets a
/// saved chunk be verified against a regeneration.

/// Three-round integer mix over (seed, ix, iz).
pub fn hash(seed: u32, ix: i32, iz: i32) u32 {
    var h: u32 = seed;
    h ^= @as(u32, @bitCast(ix));
    h = (h ^ (h >> 16)) *% 0x7FEB352D;
    h ^= @as(u32, @bitCast(iz));
    h = (h ^ (h >> 15)) *% 0x846CA68B;
    h ^= h >> 16;
    return h;
}

/// Eight unit gradients, the classic 2D Perlin set.
const gradients = [8][2]f32{
    .{ 1, 0 },     .{ -1, 0 },    .{ 0, 1 },      .{ 0, -1 },
    .{ 0.7071, 0.7071 }, .{ -0.7071, 0.7071 }, .{ 0.7071, -0.7071 }, .{ -0.7071, -0.7071 },
};

fn dotGradient(seed: u32, ix: i32, iz: i32, x: f32, z: f32) f32 {
    const g = gradients[hash(seed, ix, iz) & 7];
    return g[0] * x + g[1] * z;
}

/// Quintic fade, 6t^5 - 15t^4 + 10t^3: zero first and second derivatives at 0
/// and 1, which is what keeps the noise free of lattice creases.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// 2D Perlin noise, normalised to roughly -1..1 (the raw range for eight unit
/// gradients is +-sqrt(2)/2).
pub fn perlin2(seed: u32, x: f32, z: f32) f32 {
    const floor_x = @floor(x);
    const floor_z = @floor(z);
    const ix: i32 = @intFromFloat(floor_x);
    const iz: i32 = @intFromFloat(floor_z);
    const fx = x - floor_x;
    const fz = z - floor_z;

    const u = fade(fx);
    const v = fade(fz);

    const n00 = dotGradient(seed, ix, iz, fx, fz);
    const n10 = dotGradient(seed, ix + 1, iz, fx - 1.0, fz);
    const n01 = dotGradient(seed, ix, iz + 1, fx, fz - 1.0);
    const n11 = dotGradient(seed, ix + 1, iz + 1, fx - 1.0, fz - 1.0);

    const nx0 = lerp(n00, n10, u);
    const nx1 = lerp(n01, n11, u);
    return lerp(nx0, nx1, v) * 1.4142135;
}

/// Fractal Brownian motion over `perlin2`, normalised to -1..1 so callers can
/// scale it by an amplitude directly. Each octave gets its own seed
/// (`seed + i * 7919`) so the octaves are independent.
pub fn fbm2(seed: u32, x: f32, z: f32, octaves: u8, lacunarity: f32, gain: f32) f32 {
    var sum: f32 = 0;
    var amplitude: f32 = 1;
    var total_amplitude: f32 = 0;
    var frequency: f32 = 1;
    var i: u8 = 0;
    while (i < octaves) : (i += 1) {
        const octave_seed = seed +% @as(u32, i) *% 7919;
        sum += amplitude * perlin2(octave_seed, x * frequency, z * frequency);
        total_amplitude += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    if (total_amplitude == 0) return 0;
    return sum / total_amplitude;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "hash is deterministic and separates its inputs" {
    try testing.expectEqual(hash(1, 2, 3), hash(1, 2, 3));
    try testing.expect(hash(1, 2, 3) != hash(1, 3, 2));
    try testing.expect(hash(1, 2, 3) != hash(2, 2, 3));
    try testing.expect(hash(0, -1, 0) != hash(0, 0, 0));
    // No constant-ish outputs over a small neighbourhood.
    var same: usize = 0;
    const first = hash(7, 0, 0);
    for (0..64) |i| {
        if (hash(7, @intCast(i), 3) == first) same += 1;
    }
    try testing.expect(same < 3);
}

test "perlin is zero at lattice points" {
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        var z: i32 = -8;
        while (z <= 8) : (z += 1) {
            const value = perlin2(1234, @floatFromInt(x), @floatFromInt(z));
            try testing.expectApproxEqAbs(@as(f32, 0), value, 1e-5);
        }
    }
}

test "perlin stays inside its range and is continuous" {
    var min: f32 = std.math.inf(f32);
    var max: f32 = -std.math.inf(f32);
    var x: f32 = -200;
    while (x < 200) : (x += 0.37) {
        const value = perlin2(99, x, x * 0.61);
        min = @min(min, value);
        max = @max(max, value);
    }
    try testing.expect(min >= -1.001);
    try testing.expect(max <= 1.001);
    // It actually uses the range rather than staying near zero.
    try testing.expect(max > 0.4);
    try testing.expect(min < -0.4);

    // A step of 0.001 must not jump: a broken fade shows up as a discontinuity.
    var prev = perlin2(99, 3.0, 4.0);
    var t: f32 = 3.0;
    while (t < 4.0) : (t += 0.001) {
        const value = perlin2(99, t, 4.0);
        try testing.expect(@abs(value - prev) < 0.02);
        prev = value;
    }
}

test "fbm is bounded, deterministic and seed dependent" {
    var min: f32 = std.math.inf(f32);
    var max: f32 = -std.math.inf(f32);
    var x: f32 = -50;
    while (x < 50) : (x += 0.83) {
        const value = fbm2(7, x, x * 0.5, 3, 2.0, 0.5);
        min = @min(min, value);
        max = @max(max, value);
        try testing.expectEqual(value, fbm2(7, x, x * 0.5, 3, 2.0, 0.5));
    }
    try testing.expect(min >= -1.001);
    try testing.expect(max <= 1.001);
    try testing.expect(fbm2(7, 1.5, 2.5, 3, 2.0, 0.5) != fbm2(8, 1.5, 2.5, 3, 2.0, 0.5));
}

test "more octaves add detail without leaving the range" {
    const coarse = fbm2(3, 10.3, 7.7, 1, 2.0, 0.5);
    const fine = fbm2(3, 10.3, 7.7, 4, 2.0, 0.5);
    try testing.expect(@abs(coarse) <= 1.001);
    try testing.expect(@abs(fine) <= 1.001);
    try testing.expect(coarse != fine);
}
