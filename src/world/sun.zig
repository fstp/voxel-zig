const std = @import("std");
const Vec3 = @import("../math/vec.zig").Vec3;

/// The sun (3.4, ADR 0009).
///
/// One source of truth for time of day, the direction the light comes from, and
/// the colours that go with it. Everything downstream - the terrain shader
/// (3.5), the sky pass (3.6), the fog (3.7), the HUD, the screenshot keys - reads
/// this and nothing else, so those cannot disagree about where the sun is.
///
/// The path is deliberately stylised, not astronomical: the sun rises in the
/// east, peaks due south at `max_elevation`, sets in the west and spends the
/// other half of the cycle below the horizon. Two numbers a person can reason
/// about, and no ephemeris.
pub const Sun = struct {
    /// Position in the cycle, 0..1. 0 sunrise, 0.25 noon, 0.5 sunset, 0.75 midnight.
    time: f32 = 0.0,
    /// Seconds for a full cycle.
    cycle_seconds: f32 = 600.0,
    /// Highest elevation, degrees. 62 is a Swedish summer noon.
    max_elevation: f32 = 62.0,
    paused: bool = false,

    pub const default_start: f32 = 0.18;

    pub fn init() Sun {
        return .{ .time = default_start };
    }

    /// Advances the clock on the fixed simulation step, so the sun does not move
    /// faster on a machine that renders more frames.
    pub fn update(self: *Sun, dt: f32) void {
        if (self.paused) return;
        if (self.cycle_seconds <= 0) return;
        self.time = wrap01(self.time + dt / self.cycle_seconds);
    }

    pub fn setTime(self: *Sun, t: f32) void {
        self.time = wrap01(t);
    }

    pub fn togglePaused(self: *Sun) void {
        self.paused = !self.paused;
    }

    /// Sun elevation above the horizon, degrees. Negative at night.
    pub fn elevation(self: Sun) f32 {
        return self.max_elevation * @sin(self.time * 2.0 * std.math.pi);
    }

    /// Azimuth from north, clockwise, normalised to 0..360: 90 east (sunrise),
    /// 180 south (noon), 270 west (sunset), 0 north (midnight).
    pub fn azimuth(self: Sun) f32 {
        const raw = 90.0 + 360.0 * self.time;
        const wrapped = @mod(raw, 360.0);
        return wrapped;
    }

    /// Unit vector pointing from the world toward the sun. +X east, +Y up, +Z south.
    pub fn direction(self: Sun) Vec3 {
        const el = self.elevation() * std.math.pi / 180.0;
        const az = self.azimuth() * std.math.pi / 180.0;
        const horizontal = @cos(el);
        return Vec3.init(horizontal * @sin(az), @sin(el), -horizontal * @cos(az));
    }

    /// How much of the sky's light there is, 0 at night and 1 in daylight.
    pub fn daylight(self: Sun) f32 {
        return smoothstep(-18.0, -6.0, self.elevation());
    }

    /// 24 hour clock for the HUD: t = 0 is 06:00 (sunrise), 0.25 is noon.
    pub fn clockHours(self: Sun) f32 {
        return wrap01(self.time + 0.25) * 24.0;
    }

    pub fn ramp(self: Sun) Ramp {
        return rampAt(self.elevation());
    }
};

pub const Ramp = struct {
    /// Linear-space colours (ADR 0008: everything downstream shades in linear).
    zenith: Vec3,
    horizon: Vec3,
    sun: Vec3,
    daylight: f32,
};

fn wrap01(value: f32) f32 {
    var v = value;
    while (v < 0) v += 1;
    while (v >= 1) v -= 1;
    return v;
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

/// Palette stops in sRGB 0..1, exactly as recorded in ADR 0009.
const night_zenith = Vec3.init(8.0 / 255.0, 10.0 / 255.0, 23.0 / 255.0);
const night_horizon = Vec3.init(15.0 / 255.0, 17.0 / 255.0, 28.0 / 255.0);
const twilight_zenith = Vec3.init(25.0 / 255.0, 35.0 / 255.0, 76.0 / 255.0);
const dawn_horizon = Vec3.init(229.0 / 255.0, 119.0 / 255.0, 61.0 / 255.0);
const day_zenith = Vec3.init(81.0 / 255.0, 127.0 / 255.0, 204.0 / 255.0);
const day_horizon = Vec3.init(173.0 / 255.0, 198.0 / 255.0, 229.0 / 255.0);
const dawn_sun = Vec3.init(255.0 / 255.0, 140.0 / 255.0, 71.0 / 255.0);
const day_sun = Vec3.init(255.0 / 255.0, 242.0 / 255.0, 224.0 / 255.0);

fn toLinear(c: f32) f32 {
    return std.math.pow(f32, @max(c, 0), 2.2);
}

fn linear(v: Vec3) Vec3 {
    return Vec3.init(toLinear(v.x), toLinear(v.y), toLinear(v.z));
}

/// sRGB for display or for a clear colour, from a linear colour.
pub fn toSrgb(c: Vec3) Vec3 {
    return Vec3.init(
        std.math.pow(f32, @max(c.x, 0), 1.0 / 2.2),
        std.math.pow(f32, @max(c.y, 0), 1.0 / 2.2),
        std.math.pow(f32, @max(c.z, 0), 1.0 / 2.2),
    );
}

fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a.add(b.sub(a).scale(t));
}

/// The ADR 0009 ramp: three blended bands, all continuous in elevation.
pub fn rampAt(elevation_deg: f32) Ramp {
    const el = elevation_deg;
    const t_night = smoothstep(-18, -6, el);
    const t_day = smoothstep(0, 25, el);
    const w_warm = smoothstep(-8, 0, el) * (1 - smoothstep(4, 16, el));

    const zenith_srgb = lerp(night_zenith, lerp(twilight_zenith, day_zenith, t_day), t_night);
    const base_horizon = lerp(dawn_horizon, day_horizon, t_day);
    const horizon_srgb = lerp(lerp(night_horizon, base_horizon, t_night), dawn_horizon, w_warm * t_night);
    const sun_srgb = lerp(Vec3.init(0, 0, 0), lerp(dawn_sun, day_sun, t_day), t_night);

    return .{
        .zenith = linear(zenith_srgb),
        .horizon = linear(horizon_srgb),
        .sun = linear(sun_srgb),
        .daylight = t_night,
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "direction is a unit vector all cycle" {
    var sun = Sun.init();
    var i: usize = 0;
    while (i <= 200) : (i += 1) {
        sun.setTime(@as(f32, @floatFromInt(i)) / 200.0);
        const d = sun.direction();
        try testing.expectApproxEqAbs(@as(f32, 1.0), d.length(), 1e-5);
    }
}

test "the sun rises east, peaks south, sets west, and is below at midnight" {
    var sun = Sun.init();
    sun.setTime(0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), sun.elevation(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 90.0), sun.azimuth(), 1e-4);

    sun.setTime(0.25);
    try testing.expectApproxEqAbs(@as(f32, 62.0), sun.elevation(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 180.0), sun.azimuth(), 1e-4);

    sun.setTime(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), sun.elevation(), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 270.0), sun.azimuth(), 1e-4);

    sun.setTime(0.75);
    try testing.expectApproxEqAbs(@as(f32, -62.0), sun.elevation(), 1e-4);
    // Normalised: midnight is due north, shown as 0 rather than 360.
    try testing.expectApproxEqAbs(@as(f32, 0.0), sun.azimuth(), 1e-4);
}

test "update advances by dt/cycle and wraps" {
    var sun = Sun.init();
    sun.cycle_seconds = 100;
    sun.setTime(0.0);
    sun.update(25.0);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sun.time, 1e-6);
    sun.update(90.0);
    try testing.expectApproxEqAbs(@as(f32, 0.15), sun.time, 1e-6);
}

test "a paused sun does not move" {
    var sun = Sun.init();
    sun.setTime(0.3);
    sun.togglePaused();
    sun.update(1000.0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), sun.time, 1e-6);
    sun.togglePaused();
    sun.update(30.0);
    try testing.expect(sun.time > 0.3);
}

test "setTime wraps out-of-range values instead of producing a bad sun" {
    var sun = Sun.init();
    sun.setTime(-0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.75), sun.time, 1e-6);
    sun.setTime(1.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sun.time, 1e-6);
}

test "the colour ramp is continuous across the whole cycle, including the wrap" {
    // Walk the cycle in fine steps; no single step may move a colour by more
    // than a small amount, or the sky would pop at sunrise.
    var previous = rampAt(elevationAt(0.0));
    var i: usize = 1;
    const steps: usize = 2000;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const current = rampAt(elevationAt(t));
        const dz = current.zenith.sub(previous.zenith).length();
        const dh = current.horizon.sub(previous.horizon).length();
        const ds = current.sun.sub(previous.sun).length();
        try testing.expect(dz < 0.02);
        try testing.expect(dh < 0.03);
        try testing.expect(ds < 0.05);
        previous = current;
    }
}

fn elevationAt(t: f32) f32 {
    return 62.0 * @sin(t * 2.0 * std.math.pi);
}

test "night has a floor: the sky never goes black" {
    const night = rampAt(-62.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), night.daylight, 1e-6);
    // Linear values are tiny (sRGB 8 is about 0.0007 linear) but not zero.
    try testing.expect(night.zenith.x > 0.0);
    try testing.expect(night.zenith.y > 0.0);
    try testing.expect(night.zenith.z > 0.0);
    // And the sun contributes nothing.
    try testing.expectApproxEqAbs(@as(f32, 0.0), night.sun.x, 1e-9);
}

test "ramp values match the ADR 0009 table after converting back to sRGB" {
    // Spot checks straight from the ADR, so the table and the code cannot drift.
    const cases = [_]struct { el: f32, zenith: [3]f32, horizon: [3]f32 }{
        .{ .el = -12, .zenith = .{ 16, 22, 49 }, .horizon = .{ 122, 68, 44 } },
        .{ .el = 0, .zenith = .{ 25, 35, 76 }, .horizon = .{ 229, 119, 61 } },
        .{ .el = 8, .zenith = .{ 39, 57, 107 }, .horizon = .{ 225, 124, 71 } },
        .{ .el = 45, .zenith = .{ 81, 127, 204 }, .horizon = .{ 173, 198, 229 } },
    };
    for (cases) |case| {
        const r = rampAt(case.el);
        const z = toSrgb(r.zenith);
        const h = toSrgb(r.horizon);
        try testing.expectApproxEqAbs(case.zenith[0] / 255.0, z.x, 0.01);
        try testing.expectApproxEqAbs(case.zenith[1] / 255.0, z.y, 0.01);
        try testing.expectApproxEqAbs(case.zenith[2] / 255.0, z.z, 0.01);
        try testing.expectApproxEqAbs(case.horizon[0] / 255.0, h.x, 0.01);
        try testing.expectApproxEqAbs(case.horizon[1] / 255.0, h.y, 0.01);
        try testing.expectApproxEqAbs(case.horizon[2] / 255.0, h.z, 0.01);
    }
}

test "the clock reads noon at t = 0.25" {
    var sun = Sun.init();
    sun.setTime(0.25);
    try testing.expectApproxEqAbs(@as(f32, 12.0), sun.clockHours(), 1e-5);
    sun.setTime(0.75);
    try testing.expectApproxEqAbs(@as(f32, 0.0), sun.clockHours(), 1e-5);
}
