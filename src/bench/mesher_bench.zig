//! Mesher benchmark: `zig build bench -Doptimize=ReleaseFast`.
//!
//! Debug builds are ~100x slower (ADR 0004), so the numbers only mean anything
//! in a release build; the mode is printed and a debug run says so loudly.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("voxel_zig");
const mesher = engine.voxel.mesher;
const ChunkPos = engine.voxel.ChunkPos;
const terrain = engine.world.terrain;

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

/// Fills the padded buffer (chunk body plus the six face planes) from the real
/// world generator, so the bench measures the geometry the game actually draws.
fn buildFromWorldgen(padded: *mesher.PaddedBlocks, pos: ChunkPos, seed: u32) void {
    const origin = pos.blockOrigin();
    var blocks: [32768]engine.voxel.BlockId = undefined;
    terrain.generateInto(&blocks, pos, seed);

    var z: i32 = 0;
    while (z < 32) : (z += 1) {
        var y: i32 = 0;
        while (y < 32) : (y += 1) {
            var x: i32 = 0;
            while (x < 32) : (x += 1) {
                padded.set(x, y, z, blocks[@intCast((y * 32 + z) * 32 + x)]);
            }
        }
    }
    // One-block border from the four horizontal neighbours and the two above.
    const dirs = [_][3]i32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
    for (dirs) |d| {
        var a: i32 = 0;
        while (a < 32) : (a += 1) {
            var b: i32 = 0;
            while (b < 32) : (b += 1) {
                var cell = [_]i32{ 0, 0, 0 };
                if (d[0] != 0) {
                    cell = .{ if (d[0] < 0) -1 else 32, a, b };
                } else if (d[1] != 0) {
                    cell = .{ a, if (d[1] < 0) -1 else 32, b };
                } else {
                    cell = .{ a, b, if (d[2] < 0) -1 else 32 };
                }
                const world_x = origin.x + cell[0];
                const world_y = origin.y + cell[1];
                const world_z = origin.z + cell[2];
                padded.set(cell[0], cell[1], cell[2], terrain.blockAt(seed, world_x, world_y, world_z));
            }
        }
    }
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
    buildFromWorldgen(&padded, ChunkPos.init(4, 2, 4), 0x5EED_1234);

    const vertices = try allocator.alloc(mesher.Vertex, mesher.MAX_VERTICES);
    defer allocator.free(vertices);
    const indices = try allocator.alloc(u32, mesher.MAX_INDICES);
    defer allocator.free(indices);

    std.debug.print("mesher bench ({s})\n", .{@tagName(builtin.mode)});
    if (builtin.mode == .debug) {
        std.debug.print("WARNING: debug build - ADR 0004 says these numbers are ~100x slow. Use -Doptimize=ReleaseFast.\n", .{});
    }

    // Naive first, then greedy on exactly the same padded chunk.
    const naive = try mesher.mesh(&padded, vertices, indices);
    const naive_ns = try timeMeshes(init.io, &padded, vertices, indices, false);
    const greedy = try mesher.meshGreedy(&padded, vertices, indices);
    const greedy_ns = try timeMeshes(init.io, &padded, vertices, indices, true);

    std.debug.print("  naive   quads {d:6}  best {d:7.2} us\n", .{ naive.quads, @as(f64, @floatFromInt(naive_ns)) / 1000.0 });
    std.debug.print("  greedy  quads {d:6}  best {d:7.2} us\n", .{ greedy.quads, @as(f64, @floatFromInt(greedy_ns)) / 1000.0 });
    std.debug.print("  ratio   {d:.2}x fewer quads, {d:.1}x the CPU\n", .{
        @as(f64, @floatFromInt(naive.quads)) / @as(f64, @floatFromInt(greedy.quads)),
        @as(f64, @floatFromInt(greedy_ns)) / @as(f64, @floatFromInt(naive_ns)),
    });
    std.debug.print("  greedy geometry {d:.1} KB at {d} B/vertex\n", .{@as(f64, @floatFromInt(greedy.bytes())) / 1024.0, @sizeOf(mesher.Vertex)});

    if (naive.quads < greedy.quads * 3) {
        std.debug.print("WARNING: greedy is below the 3x acceptance target on this fixture.\n", .{});
    }
}

fn timeMeshes(io: std.Io, padded: *const mesher.PaddedBlocks, vertices: []mesher.Vertex, indices: []u32, greedy: bool) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        _ = if (greedy) try mesher.meshGreedy(padded, vertices, indices) else try mesher.mesh(padded, vertices, indices);
        const t1 = std.Io.Timestamp.now(io, .awake);
        const dt: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
        if (dt < best) best = dt;
    }
    return best;
}
