//! Save/load benchmark: `zig build bench-save -Doptimize=ReleaseFast`.
//!
//! Acceptance for 1.14 is save plus load of 100 chunks under 50 ms, and the RLE
//! ratio on real terrain chunks (not synthetic runs).
const std = @import("std");
const engine = @import("voxel_zig");
const World = engine.world.World;
const ChunkPos = engine.voxel.ChunkPos;
const terrain = engine.world.terrain;
const save = engine.world.save;

const CHUNKS = 100;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const seed: u32 = 0x5EED_1234;

    var world = World.init(allocator);
    defer world.deinit();

    // 100 terrain chunks, each with a few blocks dug out so every one of them
    // is flagged edited (that is what a save actually stores).
    var created: usize = 0;
    var cx: i32 = 0;
    while (created < CHUNKS) : (cx += 1) {
        const pos = ChunkPos.init(cx, 2, 0);
        const chunk = try world.getOrCreateChunk(pos);
        terrain.generateChunk(chunk, seed);
        // Place a marker block in the air near the top of each chunk: that is
        // always a real edit, so every chunk gets saved.
        _ = world.setBlock(pos.blockOrigin().x + 8, pos.blockOrigin().y + 31, pos.blockOrigin().z + 8, .stone);
        // And carve a hole at the surface when it falls inside this layer.
        const surface = terrain.heightAt(seed, pos.blockOrigin().x + 8, pos.blockOrigin().z + 8) - pos.blockOrigin().y;
        if (surface > 1 and surface < 31) {
            _ = world.setBlock(pos.blockOrigin().x + 8, pos.blockOrigin().y + surface, pos.blockOrigin().z + 8, .air);
        }
        created += 1;
    }

    const save_start = std.Io.Timestamp.now(init.io, .awake);
    const stats = try save.save(allocator, init.io, "bench-save.vxz", &world, seed, .{ .x = 0, .y = 70, .z = 0 });
    const save_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(init.io, .awake).nanoseconds - save_start.nanoseconds)) / 1e6;

    const load_start = std.Io.Timestamp.now(init.io, .awake);
    var loaded = try save.load(allocator, init.io, "bench-save.vxz");
    const load_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(init.io, .awake).nanoseconds - load_start.nanoseconds)) / 1e6;
    defer loaded.deinit();

    std.debug.print("save bench ({s})\n", .{@tagName(@import("builtin").mode)});
    std.debug.print("  chunks        {d}\n", .{stats.chunks});
    std.debug.print("  raw           {d} KB\n", .{stats.raw_bytes / 1024});
    std.debug.print("  packed        {d} KB ({d:.1}x, {d} B/chunk)\n", .{ stats.packed_bytes / 1024, stats.ratio(), stats.packed_bytes / stats.chunks });
    std.debug.print("  save          {d:.2} ms\n", .{save_ms});
    std.debug.print("  load          {d:.2} ms\n", .{load_ms});
    std.debug.print("  save + load   {d:.2} ms (budget 50 ms)\n", .{save_ms + load_ms});
    std.debug.print("  loaded chunks {d}\n", .{loaded.count()});
}
