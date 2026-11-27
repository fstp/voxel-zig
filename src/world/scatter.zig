//! Deterministic scatter for foliage and props (ADR 0024). One build per patch: a 2 m height
//! grid feeds jittered candidate cells for grass/flowers, trees and rocks. Every candidate is a
//! pure function of its integer cell and a salt, so a rebuild reproduces the same field, and any
//! sphere edit removes the candidates inside its footprint.

const std = @import("std");
const dcw = @import("dc_world.zig");
const noise = @import("noise.zig");

/// Grass and flower blades: one instance per blade.
pub const Blade = extern struct {
    pos: [3]f32,
    yaw: f32,
    scale: f32,
    tint: f32,
    kind: f32, // 0 grass, 1 flower
};

/// Trees and rocks: one instance per mesh.
pub const Prop = extern struct {
    pos: [3]f32,
    yaw: f32,
    scale: f32,
    tint: f32,
};

pub const Scatter = struct {
    blades: std.ArrayList(Blade) = .empty,
    trees: std.ArrayList(Prop) = .empty,
    rocks: std.ArrayList(Prop) = .empty,
    snow: std.ArrayList(Prop) = .empty,
    shore: std.ArrayList(Prop) = .empty,

    pub fn deinit(self: *Scatter, alloc: std.mem.Allocator) void {
        self.blades.deinit(alloc);
        self.trees.deinit(alloc);
        self.rocks.deinit(alloc);
        self.snow.deinit(alloc);
        self.shore.deinit(alloc);
    }
};

const GRID_STEP: f32 = 2.0;
const GRID_N: usize = 129; // 256 m patch / 2 m + 1

const HeightGrid = struct {
    h: [GRID_N * GRID_N]f32,
    dens: [GRID_N * GRID_N]f32,
    min_x: f32,
    min_z: f32,

    fn at(self: *const HeightGrid, x: f32, z: f32) f32 {
        const fx = std.math.clamp((x - self.min_x) / GRID_STEP, 0, @as(f32, @floatFromInt(GRID_N - 1)) - 0.001);
        const fz = std.math.clamp((z - self.min_z) / GRID_STEP, 0, @as(f32, @floatFromInt(GRID_N - 1)) - 0.001);
        const ix: usize = @intFromFloat(fx);
        const iz: usize = @intFromFloat(fz);
        const tx = fx - @as(f32, @floatFromInt(ix));
        const tz = fz - @as(f32, @floatFromInt(iz));
        const h00 = self.h[iz * GRID_N + ix];
        const h10 = self.h[iz * GRID_N + ix + 1];
        const h01 = self.h[(iz + 1) * GRID_N + ix];
        const h11 = self.h[(iz + 1) * GRID_N + ix + 1];
        return (h00 * (1 - tx) + h10 * tx) * (1 - tz) + (h01 * (1 - tx) + h11 * tx) * tz;
    }

    fn density(self: *const HeightGrid, x: f32, z: f32) f32 {
        const fx = std.math.clamp((x - self.min_x) / GRID_STEP, 0, @as(f32, @floatFromInt(GRID_N - 1)) - 0.001);
        const fz = std.math.clamp((z - self.min_z) / GRID_STEP, 0, @as(f32, @floatFromInt(GRID_N - 1)) - 0.001);
        const ix: usize = @intFromFloat(fx);
        const iz: usize = @intFromFloat(fz);
        const tx = fx - @as(f32, @floatFromInt(ix));
        const tz = fz - @as(f32, @floatFromInt(iz));
        const d00 = self.dens[iz * GRID_N + ix];
        const d10 = self.dens[iz * GRID_N + ix + 1];
        const d01 = self.dens[(iz + 1) * GRID_N + ix];
        const d11 = self.dens[(iz + 1) * GRID_N + ix + 1];
        return (d00 * (1 - tx) + d10 * tx) * (1 - tz) + (d01 * (1 - tx) + d11 * tx) * tz;
    }

    /// Upward component of the normal (1 flat, 0 vertical) from central differences.
    fn normalY(self: *const HeightGrid, x: f32, z: f32) f32 {
        const d = 1.5;
        const gx = (self.at(x + d, z) - self.at(x - d, z)) / (2 * d);
        const gz = (self.at(x, z + d) - self.at(x, z - d)) / (2 * d);
        return 1.0 / @sqrt(1.0 + gx * gx + gz * gz);
    }
};

fn rand01(x: i32, z: i32, salt: u32) f32 {
    var hasher = std.hash.Wyhash.init(salt);
    hasher.update(std.mem.asBytes(&x));
    hasher.update(std.mem.asBytes(&z));
    const v = hasher.final();
    return @as(f32, @floatFromInt(v & 0xFFFFFF)) / 16777216.0;
}

fn blocked(edits: []const dcw.Edit, x: f32, z: f32) bool {
    for (edits) |e| {
        const dx = x - e.x;
        const dz = z - e.z;
        const r = e.r + 1.0;
        if (dx * dx + dz * dz < r * r) return true;
    }
    return false;
}

/// Builds grass/flowers, trees and rocks for the patch whose south-west corner is
/// `(min_x, min_z)` and whose side is `size` (normally 256 m). Caller owns the result.
pub fn build(
    alloc: std.mem.Allocator,
    edits: []const dcw.Edit,
    min_x: f32,
    min_z: f32,
    size: f32,
) !Scatter {
    var grid: HeightGrid = undefined;
    grid.min_x = min_x;
    grid.min_z = min_z;
    for (0..GRID_N) |iz| {
        for (0..GRID_N) |ix| {
            const x = min_x + @as(f32, @floatFromInt(ix)) * GRID_STEP;
            const z = min_z + @as(f32, @floatFromInt(iz)) * GRID_STEP;
            grid.h[iz * GRID_N + ix] = dcw.heightAt(x, z);
            grid.dens[iz * GRID_N + ix] = noise.fbm2(9001, x * 0.03, z * 0.03, 3, 2.0, 0.5);
        }
    }

    var out = Scatter{};
    errdefer out.deinit(alloc);

    const center_x = min_x + size * 0.5;
    const center_z = min_z + size * 0.5;

    // Grass and flowers: one world-anchored lattice. The step never changes with the patch
    // centre, so a given world cell always produces the same jitter; only the acceptance
    // probability fades with distance from the patch centre. This is what keeps blades static
    // while the streaming patch moves underneath them.
    {
        const radius: f32 = 95.0;
        const step: f32 = 0.25;
        const ix0: i32 = @intFromFloat(@floor((center_x - radius) / step));
        const ix1: i32 = @intFromFloat(@ceil((center_x + radius) / step));
        const iz0: i32 = @intFromFloat(@floor((center_z - radius) / step));
        const iz1: i32 = @intFromFloat(@ceil((center_z + radius) / step));
        var iz = iz0;
        while (iz <= iz1) : (iz += 1) {
            const z = (@as(f32, @floatFromInt(iz)) + 0.5) * step;
            var ix = ix0;
            while (ix <= ix1) : (ix += 1) {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) * step;
                const dx = x - center_x;
                const dz = z - center_z;
                const r2 = dx * dx + dz * dz;
                if (r2 > radius * radius) continue;
                // World-constant thinning: the same cell is accepted or rejected in every patch.
                // Distance only affects the radius cutoff, never the cell's hash.
                if (rand01(ix, iz, 0x6A55) > 0.26) continue;

                const jx = (rand01(ix, iz, 0x51ED) - 0.5) * step * 0.9;
                const jz = (rand01(ix, iz, 0x9E37) - 0.5) * step * 0.9;
                const px = x + jx;
                const pz = z + jz;
                if (blocked(edits, px, pz)) continue;
                const h_grid = grid.at(px, pz);
                if (h_grid < dcw.SEA_LEVEL + 0.35) continue;
                if (h_grid > 66.0) continue; // below the 10.8 snow line, so blades do not poke through snow
                const ny = grid.normalY(px, pz);
                if (ny < 0.70) continue;
                const density = grid.density(px, pz);
                if (density < -0.45) continue;

                const flower = rand01(ix, iz, 0xF10A) < 0.02 and ny > 0.82;
                const tint = rand01(ix, iz, 0x1234);
                const h = dcw.heightAt(px, pz);
                try out.blades.append(alloc, .{
                    .pos = .{ px, h - 0.05, pz },
                    .yaw = rand01(ix, iz, 0xA5A5) * std.math.tau,
                    .scale = 0.55 + 0.85 * tint,
                    .tint = tint,
                    .kind = if (flower) 1 else 0,
                });
            }
        }
    }

    // Trees: gentle slopes below the treeline, clustered, with a 4 m footprint.
    {
        const step: f32 = 8.0;
        const ix0: i32 = @intFromFloat(@floor(min_x / step));
        const ix1: i32 = @intFromFloat(@floor((min_x + size - 0.001) / step));
        const iz0: i32 = @intFromFloat(@floor(min_z / step));
        const iz1: i32 = @intFromFloat(@floor((min_z + size - 0.001) / step));
        var iz = iz0;
        while (iz <= iz1) : (iz += 1) {
            const z = (@as(f32, @floatFromInt(iz)) + 0.5) * step;
            var ix = ix0;
            while (ix <= ix1) : (ix += 1) {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) * step;
                const px = x + (rand01(ix, iz, 0x7EE1) - 0.5) * step * 0.8;
                const pz = z + (rand01(ix, iz, 0x7EE2) - 0.5) * step * 0.8;
                if (blocked(edits, px, pz)) continue;
                const h_grid = grid.at(px, pz);
                if (h_grid < dcw.SEA_LEVEL + 1.0 or h_grid > 66.0) continue; // treeline below the snow line
                const ny = grid.normalY(px, pz);
                if (ny < 0.86) continue;
                const density = noise.fbm2(9101, px * 0.018, pz * 0.018, 3, 2.0, 0.5);
                if (density < 0.02) continue;
                if (rand01(ix, iz, 0x7EE3) > 0.55) continue;
                var clear = true;
                for (out.trees.items) |t| {
                    const dx = t.pos[0] - px;
                    const dz = t.pos[2] - pz;
                    if (dx * dx + dz * dz < 16.0) {
                        clear = false;
                        break;
                    }
                }
                if (!clear) continue;
                const tint = rand01(ix, iz, 0x7EE4);
                const h = dcw.heightAt(px, pz);
                try out.trees.append(alloc, .{
                    .pos = .{ px, h - 0.1, pz },
                    .yaw = rand01(ix, iz, 0x7EE5) * std.math.tau,
                    .scale = 0.75 + 0.55 * tint,
                    .tint = tint,
                });
            }
        }
    }

    // Rocks: scree on steeper ground, a few boulders elsewhere.
    {
        const step: f32 = 6.0;
        const ix0: i32 = @intFromFloat(@floor(min_x / step));
        const ix1: i32 = @intFromFloat(@floor((min_x + size - 0.001) / step));
        const iz0: i32 = @intFromFloat(@floor(min_z / step));
        const iz1: i32 = @intFromFloat(@floor((min_z + size - 0.001) / step));
        var iz = iz0;
        while (iz <= iz1) : (iz += 1) {
            const z = (@as(f32, @floatFromInt(iz)) + 0.5) * step;
            var ix = ix0;
            while (ix <= ix1) : (ix += 1) {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) * step;
                const px = x + (rand01(ix, iz, 0x0CC1) - 0.5) * step * 0.9;
                const pz = z + (rand01(ix, iz, 0x0CC2) - 0.5) * step * 0.9;
                if (blocked(edits, px, pz)) continue;
                const h_grid = grid.at(px, pz);
                if (h_grid < dcw.SEA_LEVEL - 0.2) continue;
                const ny = grid.normalY(px, pz);
                const steep = ny < 0.80;
                if (!steep and rand01(ix, iz, 0x0CC3) > 0.18) continue;
                if (rand01(ix, iz, 0x0CC4) > 0.35) continue;
                const tint = rand01(ix, iz, 0x0CC5);
                const h = dcw.heightAt(px, pz);
                try out.rocks.append(alloc, .{
                    .pos = .{ px, h - 0.15, pz },
                    .yaw = rand01(ix, iz, 0x0CC6) * std.math.tau,
                    .scale = 0.35 + 1.1 * tint,
                    .tint = tint,
                });
            }
        }
    }

    // Snow clumps and ice shards: only on the high, up-facing part of the snow cap. The local
    // snow line carries the same low-frequency warp as the shader, so the props start where the
    // white surface starts rather than on a hard altitude contour.
    {
        const step: f32 = 3.0;
        const ix0: i32 = @intFromFloat(@floor(min_x / step));
        const ix1: i32 = @intFromFloat(@floor((min_x + size - 0.001) / step));
        const iz0: i32 = @intFromFloat(@floor(min_z / step));
        const iz1: i32 = @intFromFloat(@floor((min_z + size - 0.001) / step));
        var iz = iz0;
        while (iz <= iz1) : (iz += 1) {
            if (out.snow.items.len >= 1100) break;
            const z = (@as(f32, @floatFromInt(iz)) + 0.5) * step;
            var ix = ix0;
            while (ix <= ix1) : (ix += 1) {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) * step;
                const px = x + (rand01(ix, iz, 0x5A01) - 0.5) * step * 0.9;
                const pz = z + (rand01(ix, iz, 0x5A02) - 0.5) * step * 0.9;
                if (blocked(edits, px, pz)) continue;
                if (rand01(ix, iz, 0x5A03) > 0.55) continue;
                const h = dcw.heightAt(px, pz);
                const warp = noise.fbm2(9109, px * 0.055, pz * 0.055, 2, 2.0, 0.5);
                const snow_h = 68.0 + (warp - 0.5) * 2.0;
                if (h < snow_h + 0.4) continue;
                const ny = grid.normalY(px, pz);
                if (ny < 0.80) continue;
                const tint = rand01(ix, iz, 0x5A04);
                try out.snow.append(alloc, .{
                    .pos = .{ px, h - 0.05, pz },
                    .yaw = rand01(ix, iz, 0x5A05) * std.math.tau,
                    .scale = 0.35 + 0.65 * tint,
                    .tint = tint,
                });
            }
        }
    }

    // Shore detail: pebbles, reeds and driftwood in the mud band. The waterline itself gets the
    // densest reeds; the band tapers into the bare mud. Reusing the same deterministic cell hashes
    // keeps the band stable across rebuilds.
    {
        const step: f32 = 2.6;
        const ix0: i32 = @intFromFloat(@floor(min_x / step));
        const ix1: i32 = @intFromFloat(@floor((min_x + size - 0.001) / step));
        const iz0: i32 = @intFromFloat(@floor(min_z / step));
        const iz1: i32 = @intFromFloat(@floor((min_z + size - 0.001) / step));
        var iz = iz0;
        while (iz <= iz1) : (iz += 1) {
            if (out.shore.items.len >= 700) break;
            const z = (@as(f32, @floatFromInt(iz)) + 0.5) * step;
            var ix = ix0;
            while (ix <= ix1) : (ix += 1) {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) * step;
                const px = x + (rand01(ix, iz, 0x5B01) - 0.5) * step * 0.9;
                const pz = z + (rand01(ix, iz, 0x5B02) - 0.5) * step * 0.9;
                if (blocked(edits, px, pz)) continue;
                if (rand01(ix, iz, 0x5B03) > 0.42) continue;
                const h = dcw.heightAt(px, pz);
                const shore_dist = @abs(h - dcw.SEA_LEVEL);
                if (shore_dist > 1.4) continue;
                const ny = grid.normalY(px, pz);
                if (ny < 0.60) continue;
                // Bias the taller reeds to the waterline; the outer mud keeps pebbles/sparse reeds.
                if (shore_dist > 0.9 and rand01(ix, iz, 0x5B04) > 0.30) continue;
                const tint = rand01(ix, iz, 0x5B05);
                try out.shore.append(alloc, .{
                    .pos = .{ px, h - 0.08, pz },
                    .yaw = rand01(ix, iz, 0x5B06) * std.math.tau,
                    .scale = 0.55 + 0.85 * tint,
                    .tint = tint,
                });
            }
        }
    }

    return out;
}

test "world-anchored scatter keeps overlapping foliage fixed" {
    const alloc = std.testing.allocator;
    var a = try build(alloc, &.{}, 0.0, 0.0, 256.0);
    defer a.deinit(alloc);
    var b = try build(alloc, &.{}, 32.0, 0.0, 256.0);
    defer b.deinit(alloc);

    const Props = struct {
        fn key(p: [3]f32) u64 {
            const x: u32 = @bitCast(p[0]);
            const z: u32 = @bitCast(p[2]);
            return (@as(u64, x) << 32) | @as(u64, z);
        }
        fn check(list_a: []const Prop, list_b: []const Prop, label: []const u8) !void {
            var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
            defer seen.deinit();
            for (list_a) |p| {
                if (p.pos[0] >= 32.0 and p.pos[0] < 256.0 and p.pos[2] >= 0.0 and p.pos[2] < 256.0) {
                    try seen.put(key(p.pos), {});
                }
            }
            var matched: usize = 0;
            for (list_b) |p| {
                if (p.pos[0] >= 32.0 and p.pos[0] < 256.0 and p.pos[2] >= 0.0 and p.pos[2] < 256.0) {
                    if (seen.contains(key(p.pos))) matched += 1 else return error.TestExpectedEqual;
                }
            }
            if (matched == 0) {
                std.debug.print("scatter {s}: no overlapping instances\n", .{label});
                return error.TestExpectedEqual;
            }
            std.debug.print("scatter {s}: {d} overlapping instances exact\n", .{ label, matched });
        }
        fn checkBlades(list_a: []const Blade, list_b: []const Blade) !void {
            var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
            defer seen.deinit();
            for (list_a) |p| {
                if (p.pos[0] >= 96.0 and p.pos[0] < 192.0 and p.pos[2] >= 96.0 and p.pos[2] < 192.0) {
                    try seen.put(key(p.pos), {});
                }
            }
            var matched: usize = 0;
            for (list_b) |p| {
                if (p.pos[0] >= 96.0 and p.pos[0] < 192.0 and p.pos[2] >= 96.0 and p.pos[2] < 192.0) {
                    if (seen.contains(key(p.pos))) {
                        matched += 1;
                    } else {
                        std.debug.print("blade B not in A at ({d:.3},{d:.3})\n", .{ p.pos[0], p.pos[2] });
                        return error.TestExpectedEqual;
                    }
                }
            }
            if (matched == 0) return error.TestExpectedEqual;
            std.debug.print("scatter blades: {d} overlapping instances exact\n", .{matched});
        }
    };

    try Props.check(a.trees.items, b.trees.items, "trees");
    try Props.check(a.rocks.items, b.rocks.items, "rocks");
    try Props.check(a.snow.items, b.snow.items, "snow");
    try Props.check(a.shore.items, b.shore.items, "shore");
    try Props.checkBlades(a.blades.items, b.blades.items);
}

