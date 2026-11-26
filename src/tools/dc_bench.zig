//! DC vs height-field benchmark (spike, ADR 0018).
//!
//! Meshes the project's real terrain as a signed distance field through the
//! dual-contouring kernel and reports quads and mesh time per 32-cell chunk, so the
//! choice between dual contouring and marching cubes rests on numbers. Writes an OBJ of
//! the first chunk so the surface can be inspected without a renderer.

const std = @import("std");
const vz = @import("voxel_zig");

const dc = vz.voxel.dc;
const terrain = vz.world.terrain;
const noise = vz.world.noise;

const CHUNK: usize = 32;

/// 0.17 moved timing out of std.time (no Timer, no nanoTimestamp), so take the clock from
/// libc directly: CLOCK_MONOTONIC on Linux.
const TimeSpec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;
// 0.17 also moved file I/O behind std.Io, so write the OBJ through libc.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
fn nowNs() i64 {
    var ts: TimeSpec = undefined;
    _ = clock_gettime(1, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}
const SEED: u32 = 1337;

/// Height from the project's own fBm, continuous everywhere. The block generator's height
/// is an integer, and at cell 1 m on an integer origin every sample lands exactly on a
/// block lattice point - so interpolating it is a no-op and DC faithfully reproduces the
/// staircase. A smooth field is a property of the field, not of the mesher.
fn heightAt(x: f32, z: f32) f32 {
    const base: f32 = 62.0;
    const big = noise.fbm2(SEED, x * 0.009, z * 0.009, 4, 2.0, 0.5);
    const detail = noise.fbm2(SEED + 7, x * 0.041, z * 0.041, 3, 2.0, 0.5);
    return base + 22.0 * big + 3.0 * detail;
}

/// Signed distance to the terrain surface: positive above ground. A height field has no
/// overhangs, which is the honest baseline - the blocky path cannot represent them either,
/// so like is compared with like.
fn terrainSdf(x: f32, y: f32, z: f32) f32 {
    return y - heightAt(x, z);
}

fn buildField(alloc: std.mem.Allocator, cx: i32, cz: i32, cell: f32) ![]f32 {
    const side = CHUNK + 1;
    const vals = try alloc.alloc(f32, side * side * side);
    const ox: f32 = @floatFromInt(cx * @as(i32, @intCast(CHUNK)));
    const oz: f32 = @floatFromInt(cz * @as(i32, @intCast(CHUNK)));
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const x = ox + @as(f32, @floatFromInt(i)) * cell;
                const y = 40.0 + @as(f32, @floatFromInt(j)) * cell;
                const z = oz + @as(f32, @floatFromInt(k)) * cell;
                vals[i + side * (j + side * k)] = terrainSdf(x, y, z);
            }
        }
    }
    return vals;
}

pub fn main() !void {
    // 0.17 dropped GeneralPurposeAllocator; a benchmark can leak, so page_allocator is
    // enough and has no API to get wrong.
    const alloc = std.heap.page_allocator;

    const cell: f32 = 1.0;
    const chunks_per_axis: i32 = 4;
    const total: usize = @intCast(chunks_per_axis * chunks_per_axis);

    var total_quads: usize = 0;
    var total_verts: usize = 0;
    var worst_ms: f64 = 0;
    var sum_ms: f64 = 0;
    var first: ?dc.Surface = null;
    defer if (first) |s| s.deinit(alloc);

    var cz: i32 = 0;
    while (cz < chunks_per_axis) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < chunks_per_axis) : (cx += 1) {
            const vals = try buildField(alloc, cx, cz, cell);
            defer alloc.free(vals);
            const field = dc.Field{
                .values = vals,
                .n = CHUNK,
                .origin = .{
                    @floatFromInt(cx * @as(i32, @intCast(CHUNK))),
                    40.0,
                    @floatFromInt(cz * @as(i32, @intCast(CHUNK))),
                },
                .cell = cell,
            };
            const t0 = nowNs();
            const surf = try dc.extract(alloc, field);
            const ms = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;
            sum_ms += ms;
            if (ms > worst_ms) worst_ms = ms;
            total_quads += surf.quadCount();
            total_verts += surf.verts.len;
            if (first == null) first = surf else surf.deinit(alloc);
        }
    }

    if (first) |surf| {
        try writeObj(alloc, surf);
        std.debug.print("wrote dc_chunk.obj: {d} verts, {d} quads\n", .{ surf.verts.len, surf.quadCount() });
    }

    const mean_ms = sum_ms / @as(f64, @floatFromInt(total));
    std.debug.print(
        \\DC terrain benchmark: cell {d:.2} m, {d} chunks of {d}^3 cells
        \\  quads total      {d}
        \\  quads per chunk  {d:.1}
        \\  verts per chunk  {d:.1}
        \\  mesh time        mean {d:.3} ms  worst {d:.3} ms  per chunk
        \\  quads emitted    {d}
        \\  skipped, no cell vertex on the edge  {d}
        \\  skipped, out of sample grid bounds   {d}
        \\  ambiguous cells (pinch candidates)   {d}
        \\  degenerate quads (area < 1e-5)       {d}
        \\  smallest triangle area seen          {d:.8}
        \\
    , .{
        cell,
        total,
        CHUNK,
        total_quads,
        @as(f64, @floatFromInt(total_quads)) / @as(f64, @floatFromInt(total)),
        @as(f64, @floatFromInt(total_verts)) / @as(f64, @floatFromInt(total)),
        mean_ms,
        worst_ms,
        dc.emitted_quads,
        dc.skipped_missing_cell,
        dc.skipped_bounds,
        dc.ambiguous_cells,
        dc.degenerate_quads,
        dc.min_quad_area_observed,
    });
}

fn writeObj(alloc: std.mem.Allocator, surf: dc.Surface) !void {
    // 0.17's ArrayList has no writer(alloc), so format into one buffer and write it out.
    // 64 MB covers a 32^3 chunk's OBJ with room to spare.
    const buf = try alloc.alloc(u8, 64 * 1024 * 1024);
    defer alloc.free(buf);
    var off: usize = 0;

    const put = struct {
        fn f(b: []u8, o: *usize, comptime fmt: []const u8, args: anytype) !void {
            const written = try std.fmt.bufPrint(b[o.*..], fmt, args);
            o.* += written.len;
        }
    }.f;

    try put(buf, &off, "# dual contouring spike, {d} verts {d} quads\n", .{ surf.verts.len, surf.quadCount() });
    for (surf.verts) |v| {
        try put(buf, &off, "v {d:.4} {d:.4} {d:.4}\n", .{ v.pos[0], v.pos[1], v.pos[2] });
    }
    for (surf.verts) |v| {
        try put(buf, &off, "vn {d:.4} {d:.4} {d:.4}\n", .{ v.normal[0], v.normal[1], v.normal[2] });
    }
    var t: usize = 0;
    while (t < surf.indices.len) : (t += 3) {
        const a = surf.indices[t] + 1;
        const b = surf.indices[t + 1] + 1;
        const c = surf.indices[t + 2] + 1;
        try put(buf, &off, "f {d}//{d} {d}//{d} {d}//{d}\n", .{ a, a, b, b, c, c });
    }
    const f = fopen("dc_chunk.obj", "wb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    _ = fwrite(buf.ptr, 1, off, f);
}
