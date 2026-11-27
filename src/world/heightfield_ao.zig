//! Terrain-scale horizon AO for the DC world (ADR 0030, 11.4). A 4 m grid over the patch,
//! 16 azimuths, 32 m horizon radius. The result is a 64x64 R8 texture sampled by the terrain
//! shader; it is deliberately low frequency and does not try to resolve rocks or tree roots.

const std = @import("std");
const dcw = @import("dc_world.zig");

pub const N: usize = 64;
pub const STEP: f32 = 4.0;
pub const SIZE: f32 = 256.0;
pub const RADIUS: f32 = 32.0;
pub const DIRS: usize = 12;

fn sample(grid: []const f32, x: f32, z: f32, min_x: f32, min_z: f32) f32 {
    const fx = std.math.clamp((x - min_x) / STEP, 0, @as(f32, @floatFromInt(N - 1)) - 0.001);
    const fz = std.math.clamp((z - min_z) / STEP, 0, @as(f32, @floatFromInt(N - 1)) - 0.001);
    const ix: usize = @intFromFloat(fx);
    const iz: usize = @intFromFloat(fz);
    const tx = fx - @as(f32, @floatFromInt(ix));
    const tz = fz - @as(f32, @floatFromInt(iz));
    const a = grid[iz * N + ix] * (1 - tx) + grid[iz * N + ix + 1] * tx;
    const b = grid[(iz + 1) * N + ix] * (1 - tx) + grid[(iz + 1) * N + ix + 1] * tx;
    return a * (1 - tz) + b * tz;
}

fn aoAt(grid: []const f32, ix: usize, iz: usize, min_x: f32, min_z: f32) f32 {
    const x0 = min_x + @as(f32, @floatFromInt(ix)) * STEP;
    const z0 = min_z + @as(f32, @floatFromInt(iz)) * STEP;
    const h0 = grid[iz * N + ix];
    var sum: f32 = 0;
    for (0..DIRS) |d| {
        const ang = @as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(DIRS)) * std.math.tau;
        const dx = @cos(ang);
        const dz = @sin(ang);
        var max_slope: f32 = 0;
        var r: f32 = STEP;
        while (r <= RADIUS) : (r += STEP) {
            const hs = sample(grid, x0 + dx * r, z0 + dz * r, min_x, min_z);
            const slope = (hs - h0) / r;
            if (slope > max_slope) max_slope = slope;
        }
        sum += max_slope / @sqrt(1.0 + max_slope * max_slope);
    }
    return 1.0 - sum / @as(f32, @floatFromInt(DIRS));
}

/// Builds the AO map for a square patch. Caller owns the returned bytes (N*N, row-major z then x).
pub fn build(alloc: std.mem.Allocator, min_x: f32, min_z: f32, size: f32) ![]u8 {
    _ = size; // the grid is fixed to the 256 m patch; the parameter documents the contract
    const grid = try alloc.alloc(f32, N * N);
    defer alloc.free(grid);
    for (0..N) |iz| {
        for (0..N) |ix| {
            grid[iz * N + ix] = dcw.heightAt(min_x + @as(f32, @floatFromInt(ix)) * STEP, min_z + @as(f32, @floatFromInt(iz)) * STEP);
        }
    }
    const out = try alloc.alloc(u8, N * N);
    for (0..N) |iz| {
        for (0..N) |ix| {
            const a = std.math.clamp(aoAt(grid, ix, iz, min_x, min_z), 0.0, 1.0);
            out[iz * N + ix] = @intFromFloat(a * 255.0 + 0.5);
        }
    }
    return out;
}
