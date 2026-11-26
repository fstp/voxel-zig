const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const World = @import("world.zig").World;
const ChunkPos = coords.ChunkPos;
const Vec3 = @import("../math/vec.zig").Vec3;

/// World save (1.14).
///
/// Only *edited* chunks are written - pure worldgen is reproducible from the
/// seed - and each 32 KB voxel buffer is run-length encoded first. RLE is the
/// right fit here: a terrain chunk is long runs of air and stone, so it lands
/// around 1-2 KB, and it costs a fraction of what a deflate pass would.
/// (Zig 0.17's std.compress only exposes streaming flate/zstd compressors, not
/// one-shot buffer helpers, and RLE already gets the win at this size.)
pub const MAGIC = "VXZ1";
pub const VERSION: u32 = 1;

pub const Mode = enum(u8) { raw = 0, rle = 1 };

pub const SaveStats = struct {
    chunks: usize,
    raw_bytes: usize,
    packed_bytes: usize,

    pub fn ratio(self: SaveStats) f64 {
        if (self.packed_bytes == 0) return 0;
        return @as(f64, @floatFromInt(self.raw_bytes)) / @as(f64, @floatFromInt(self.packed_bytes));
    }
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    seed: u32 = 0,
    player: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    chunks: std.HashMapUnmanaged(ChunkPos, *[coords.CHUNK_VOLUME]BlockId, ChunkPos.Context, 80) = .{},

    pub fn deinit(self: *Loaded) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_blocks| self.allocator.destroy(chunk_blocks.*);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn savedBlocks(self: *const Loaded, pos: ChunkPos) ?*const [coords.CHUNK_VOLUME]BlockId {
        return self.chunks.get(pos);
    }

    /// Remembers an edited chunk that is about to be unloaded, so its edits are
    /// still written by the next save.
    pub fn rememberBlocks(self: *Loaded, pos: ChunkPos, blocks: *const [coords.CHUNK_VOLUME]BlockId) !void {
        const entry = try self.chunks.getOrPut(self.allocator, pos);
        if (!entry.found_existing) {
            const copy = try self.allocator.create([coords.CHUNK_VOLUME]BlockId);
            entry.value_ptr.* = copy;
        }
        entry.value_ptr.*.* = blocks.*;
    }

    pub fn count(self: *const Loaded) usize {
        return self.chunks.count();
    }
};

/// RLE as (count, value) pairs. Runs longer than 255 are split, so the encoder
/// never needs to buffer more than a byte at a time.
pub fn rleEncode(allocator: std.mem.Allocator, input: []const BlockId) ![]u8 {
    const out = try allocator.alloc(u8, input.len * 2);
    var written: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        const value = input[index];
        var run: usize = 1;
        while (index + run < input.len and input[index + run] == value and run < 255) run += 1;
        out[written] = @intCast(run);
        out[written + 1] = @intFromEnum(value);
        written += 2;
        index += run;
    }
    // Shrink to fit: returning a sub-slice would hand the caller a pointer the
    // allocator cannot free (the allocation length is the whole 2x buffer).
    return try allocator.realloc(out, written);
}

pub fn rleDecode(encoded: []const u8, output: []BlockId) !void {
    if (encoded.len % 2 != 0) return error.CorruptRle;
    var in: usize = 0;
    var out: usize = 0;
    while (in < encoded.len) : (in += 2) {
        const run = encoded[in];
        if (run == 0) return error.CorruptRle;
        if (out + run > output.len) return error.CorruptRle;
        const value: BlockId = @enumFromInt(encoded[in + 1]);
        @memset(output[out .. out + run], value);
        out += run;
    }
    if (out != output.len) return error.CorruptRle;
}

/// Writes the seed, the player position and every chunk flagged edited - both
/// the ones still loaded and the ones that were unloaded after being edited
/// (`extra` holds their buffers; without it, flying away from an edit before
/// quitting would lose it).
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    world: *const World,
    seed: u32,
    player: Vec3,
    extra: ?*const std.HashMapUnmanaged(ChunkPos, *[coords.CHUNK_VOLUME]BlockId, ChunkPos.Context, 80),
) !SaveStats {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;

    try w.writeAll(MAGIC);
    try w.writeInt(u32, VERSION, .little);
    try w.writeInt(u32, seed, .little);
    try w.writeInt(u32, @bitCast(player.x), .little);
    try w.writeInt(u32, @bitCast(player.y), .little);
    try w.writeInt(u32, @bitCast(player.z), .little);

    var edited: usize = 0;
    var it = world.chunks.valueIterator();
    while (it.next()) |chunk_ptr| {
        if (!chunk_ptr.*.edited) continue;
        edited += 1;
    }
    if (extra) |map| {
        var extra_it = map.keyIterator();
        while (extra_it.next()) |key| {
            if (!world.isLoaded(key.*)) edited += 1;
        }
    }
    try w.writeInt(u32, @intCast(edited), .little);

    var raw_bytes: usize = 0;
    var packed_bytes: usize = 0;
    it = world.chunks.valueIterator();
    while (it.next()) |chunk_ptr| {
        const chunk = chunk_ptr.*;
        if (!chunk.edited) continue;

        const encoded = try rleEncode(allocator, &chunk.blocks);
        defer allocator.free(encoded);

        const use_rle = encoded.len < chunk.blocks.len;
        if (use_rle) {
            try w.writeInt(i32, chunk.pos.x, .little);
            try w.writeInt(i32, chunk.pos.y, .little);
            try w.writeInt(i32, chunk.pos.z, .little);
            try w.writeInt(u8, @intFromEnum(Mode.rle), .little);
            try w.writeInt(u32, @intCast(encoded.len), .little);
            try w.writeAll(encoded);
            packed_bytes += encoded.len;
        } else {
            try w.writeInt(i32, chunk.pos.x, .little);
            try w.writeInt(i32, chunk.pos.y, .little);
            try w.writeInt(i32, chunk.pos.z, .little);
            try w.writeInt(u8, @intFromEnum(Mode.raw), .little);
            try w.writeInt(u32, @intCast(chunk.blocks.len), .little);
            try w.writeAll(std.mem.sliceAsBytes(&chunk.blocks));
            packed_bytes += chunk.blocks.len;
        }
        raw_bytes += chunk.blocks.len;
    }

    if (extra) |map| {
        var extra_it = map.iterator();
        while (extra_it.next()) |entry| {
            const pos = entry.key_ptr.*;
            if (world.isLoaded(pos)) continue; // written above, fresher
            const blocks = entry.value_ptr.*;
            const encoded = try rleEncode(allocator, blocks);
            defer allocator.free(encoded);
            try w.writeInt(i32, pos.x, .little);
            try w.writeInt(i32, pos.y, .little);
            try w.writeInt(i32, pos.z, .little);
            if (encoded.len < blocks.len) {
                try w.writeInt(u8, @intFromEnum(Mode.rle), .little);
                try w.writeInt(u32, @intCast(encoded.len), .little);
                try w.writeAll(encoded);
                packed_bytes += encoded.len;
            } else {
                try w.writeInt(u8, @intFromEnum(Mode.raw), .little);
                try w.writeInt(u32, @intCast(blocks.len), .little);
                try w.writeAll(std.mem.sliceAsBytes(blocks));
                packed_bytes += blocks.len;
            }
            raw_bytes += blocks.len;
        }
    }
    try w.flush();
    return .{ .chunks = edited, .raw_bytes = raw_bytes, .packed_bytes = packed_bytes };
}

/// Reads a save file. A missing file is not an error: that is a fresh world.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    var loaded = Loaded{ .allocator = allocator };
    errdefer loaded.deinit();

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return loaded,
        else => return err,
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const r = &reader.interface;

    var magic: [4]u8 = undefined;
    try r.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC)) return error.BadMagic;
    const version = try r.takeInt(u32, .little);
    if (version != VERSION) return error.BadVersion;
    loaded.seed = try r.takeInt(u32, .little);
    loaded.player = .{
        .x = @bitCast(try r.takeInt(u32, .little)),
        .y = @bitCast(try r.takeInt(u32, .little)),
        .z = @bitCast(try r.takeInt(u32, .little)),
    };
    const chunk_count = try r.takeInt(u32, .little);

    var i: u32 = 0;
    while (i < chunk_count) : (i += 1) {
        const pos = ChunkPos.init(
            try r.takeInt(i32, .little),
            try r.takeInt(i32, .little),
            try r.takeInt(i32, .little),
        );
        const mode: Mode = @enumFromInt(try r.takeInt(u8, .little));
        const length = try r.takeInt(u32, .little);
        if (length > coords.CHUNK_VOLUME * 2) return error.CorruptLength;

        const payload = try allocator.alloc(u8, length);
        defer allocator.free(payload);
        try r.readSliceAll(payload);

        const blocks = try allocator.create([coords.CHUNK_VOLUME]BlockId);
        errdefer allocator.destroy(blocks);
        switch (mode) {
            .rle => try rleDecode(payload, blocks),
            .raw => {
                if (payload.len != coords.CHUNK_VOLUME * @sizeOf(BlockId)) return error.CorruptLength;
                @memcpy(std.mem.sliceAsBytes(blocks[0..]), payload);
            },
        }
        const entry = try loaded.chunks.getOrPut(allocator, pos);
        if (entry.found_existing) allocator.destroy(entry.value_ptr.*);
        entry.value_ptr.* = blocks;
    }
    return loaded;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "rle round-trips run-heavy data" {
    var input: [coords.CHUNK_VOLUME]BlockId = undefined;
    @memset(&input, .air);
    for (0..1024) |i| input[i] = .stone;
    for (1024..2048) |i| input[i] = .grass;

    const encoded = try rleEncode(testing.allocator, &input);
    defer testing.allocator.free(encoded);
    try testing.expect(encoded.len < input.len / 2);

    var output: [coords.CHUNK_VOLUME]BlockId = undefined;
    try rleDecode(encoded, &output);
    try testing.expectEqualSlices(BlockId, &input, &output);
}

test "rle handles runs longer than 255 and random data" {
    var input: [1024]BlockId = undefined;
    @memset(&input, .stone);
    const encoded = try rleEncode(testing.allocator, &input);
    defer testing.allocator.free(encoded);
    // 1024 identical blocks = four 255-runs plus one remainder.
    try testing.expectEqual(@as(usize, 10), encoded.len);
    var output: [1024]BlockId = undefined;
    try rleDecode(encoded, &output);
    try testing.expectEqualSlices(BlockId, &input, &output);

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (&input) |*slot| slot.* = @enumFromInt(random.int(u8) % 8);
    const noisy = try rleEncode(testing.allocator, &input);
    defer testing.allocator.free(noisy);
    try rleDecode(noisy, &output);
    try testing.expectEqualSlices(BlockId, &input, &output);
}

test "rle rejects corrupt input instead of overrunning" {
    var output: [16]BlockId = undefined;
    // Odd length.
    try testing.expectError(error.CorruptRle, rleDecode(&[_]u8{ 4, 1, 5 }, &output));
    // Run longer than the output.
    try testing.expectError(error.CorruptRle, rleDecode(&[_]u8{ 20, 1 }, &output));
    // Zero-length run would never terminate.
    try testing.expectError(error.CorruptRle, rleDecode(&[_]u8{ 0, 1 }, &output));
    // Short output is not fully written.
    try testing.expectError(error.CorruptRle, rleDecode(&[_]u8{ 4, 1 }, &output));
}
