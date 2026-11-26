//! Mesher benchmark: `zig build bench -Doptimize=ReleaseFast`.
//!
//! Debug builds are ~100x slower (ADR 0004), so the numbers only mean anything
//! in a release build; the mode is printed and a debug run says so loudly.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("voxel_zig");
const mesher = engine.voxel.mesher;

const ITERATIONS: usize = 2000;

/// Deterministic heightmap standing in for terrain until 1.8 lands: the point
/// is a chunk with a realistic surface, not a good-looking world.
fn heightAt(wx: i32, wz: i32) i32 {
    var h: u32 = @as(u32, @bitCast(wx)) *% 0x1f123bb5 ^ @as(u32, @bitCast(wz)) *% 0x27d4eb2d;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    return 30 + @as(i32, @intCast(h % 10));
}

fn fillTerrain(padded: *mesher.PaddedBlocks, origin_y: i32) void {
    var z: i32 = -1;
    while (z <= 32) : (z += 1) {
        var x: i32 = -1;
        while (x <= 32) : (x += 1) {
            const surface = heightAt(x, z);
            var y: i32 = 0;
            while (y < 32) : (y += 1) {
                const wy = origin_y + y;
                if (wy > surface) break;
                const block: engine.voxel.BlockId = if (wy == surface)
                    .grass
                else if (wy > surface - 4)
                    .dirt
                else
                    .stone;
                padded.set(x, y, z, block);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var padded = mesher.PaddedBlocks.init();
    fillTerrain(&padded, 0);

    const vertices = try allocator.alloc(mesher.Vertex, mesher.MAX_VERTICES);
    defer allocator.free(vertices);
    const indices = try allocator.alloc(u32, mesher.MAX_INDICES);
    defer allocator.free(indices);

    const stats = try mesher.mesh(&padded, vertices, indices);

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u64 = 0;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const t0 = std.Io.Timestamp.now(init.io, .awake);
        _ = try mesher.mesh(&padded, vertices, indices);
        const t1 = std.Io.Timestamp.now(init.io, .awake);
        const dt: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
        if (dt < best_ns) best_ns = dt;
        total_ns += dt;
    }

    const avg_ns = total_ns / ITERATIONS;
    std.debug.print("mesher bench ({s})\n", .{@tagName(builtin.mode)});
    if (builtin.mode == .debug) {
        std.debug.print("WARNING: debug build - ADR 0004 says these numbers are ~100x slow. Use -Doptimize=ReleaseFast.\n", .{});
    }
    std.debug.print("  quads      {d}\n", .{stats.quads});
    std.debug.print("  vertices   {d} ({d} B each)\n", .{ stats.vertices, @sizeOf(mesher.Vertex) });
    std.debug.print("  geometry   {d:.1} KB\n", .{@as(f64, @floatFromInt(stats.bytes())) / 1024.0});
    std.debug.print("  best       {d:.2} us\n", .{@as(f64, @floatFromInt(best_ns)) / 1000.0});
    std.debug.print("  average    {d:.2} us  ({d} iterations)\n", .{ @as(f64, @floatFromInt(avg_ns)) / 1000.0, ITERATIONS });
}
