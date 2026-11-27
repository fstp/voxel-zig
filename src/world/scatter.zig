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

    pub fn deinit(self: *Scatter, alloc: std.mem.Allocator) void {
        self.blades.deinit(alloc);
        self.trees.deinit(alloc);
        self.rocks.deinit(alloc);
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

    // Grass and flowers: two bands. The inner band is dense because that is what the camera
    // actually resolves; the outer band fills the midground and is hash-thinned by the shader.
    const bands = [_]struct { radius: f32, step: f32, accept: f32 }{
        .{ .radius = 25.0, .step = 0.22, .accept = 0.92 },
        .{ .radius = 55.0, .step = 0.45, .accept = 0.80 },
        .{ .radius = 95.0, .step = 1.00, .accept = 0.70 },
    };
    for (bands, 1..) |band, band_i| {
        var z = center_z - band.radius;
        while (z <= center_z + band.radius) : (z += band.step) {
            if (out.blades.items.len >= 70000) break;
            var x = center_x - band.radius;
            while (x <= center_x + band.radius) : (x += band.step) {
                const dx = x - center_x;
                const dz = z - center_z;
                const r2 = dx * dx + dz * dz;
                if (band_i == 2 and r2 < 25.0 * 25.0) continue;
                if (band_i == 3 and r2 < 55.0 * 55.0) continue; // outer band only in the ring

                const ix: i32 = @intFromFloat(@divFloor(x - min_x, band.step));
                const iz: i32 = @intFromFloat(@divFloor(z - min_z, band.step));
                const jx = (rand01(ix, iz, 0x51ED) - 0.5) * band.step * 0.9;
                const jz = (rand01(ix, iz, 0x9E37) - 0.5) * band.step * 0.9;
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
                if (!flower and rand01(ix, iz, 0x6A55) > band.accept) continue;
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
        var z = min_z + 4.0;
        while (z < min_z + size) : (z += step) {
            var x = min_x + 4.0;
            while (x < min_x + size) : (x += step) {
                const ix: i32 = @intFromFloat(@divFloor(x - min_x, step));
                const iz: i32 = @intFromFloat(@divFloor(z - min_z, step));
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
        var z = min_z + 3.0;
        while (z < min_z + size) : (z += step) {
            var x = min_x + 3.0;
            while (x < min_x + size) : (x += step) {
                const ix: i32 = @intFromFloat(@divFloor(x - min_x, step));
                const iz: i32 = @intFromFloat(@divFloor(z - min_z, step));
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

    return out;
}
