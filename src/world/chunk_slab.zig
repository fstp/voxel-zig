const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const BlockId = @import("../voxel/block.zig").BlockId;
const ChunkPos = @import("../voxel/coords.zig").ChunkPos;

/// Fixed-size allocator for chunk buffers (ADR 0003).
///
/// A 32 KB chunk rounded up by a general allocator costs 36.8 KB - one extra
/// 4 KB page per chunk, measured at +12.4 % over 676 chunks. Allocating chunks
/// in blocks and slicing them up gets that back, and because every slot has a
/// fixed address a chunk pointer stays valid for as long as the chunk is
/// loaded, which is what the world map stores.
pub const ChunkSlab = struct {
    allocator: std.mem.Allocator,
    head: ?*Block = null,
    /// Chunks handed out and not yet returned.
    live: usize = 0,
    /// Blocks allocated (each is SLOTS_PER_BLOCK chunk slots).
    block_count: usize = 0,

    pub const SLOTS_PER_BLOCK = 32;

    const Block = struct {
        next: ?*Block = null,
        /// Bit i set means slot i is in use.
        used: u32 = 0,
        chunks: [SLOTS_PER_BLOCK]Chunk = undefined,
    };

    pub fn init(allocator: std.mem.Allocator) ChunkSlab {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ChunkSlab) void {
        var block = self.head;
        while (block) |b| {
            const next = b.next;
            self.allocator.destroy(b);
            block = next;
        }
        self.* = undefined;
    }

    /// Returns a chunk at a fresh position with its blocks zeroed to air.
    pub fn create(self: *ChunkSlab, pos: ChunkPos) !*Chunk {
        var block = self.head;
        while (block) |b| : (block = b.next) {
            const free_mask = ~b.used;
            if (free_mask == 0) continue;
            const index: u5 = @intCast(@ctz(free_mask));
            b.used |= @as(u32, 1) << index;
            self.live += 1;
            const chunk = &b.chunks[index];
            chunk.* = Chunk.init(pos);
            return chunk;
        }

        // Every block is full: allocate another one.
        const b = try self.allocator.create(Block);
        b.* = .{};
        b.next = self.head;
        self.head = b;
        self.block_count += 1;
        b.used = 1;
        self.live += 1;
        const chunk = &b.chunks[0];
        chunk.* = Chunk.init(pos);
        return chunk;
    }

    /// Returns a chunk to the slab. Its contents are not cleared; `create`
    /// overwrites them.
    pub fn destroy(self: *ChunkSlab, chunk: *Chunk) void {
        var block = self.head;
        while (block) |b| : (block = b.next) {
            const base = @intFromPtr(&b.chunks[0]);
            const addr = @intFromPtr(chunk);
            if (addr >= base and addr < base + @sizeOf(@TypeOf(b.chunks))) {
                const index = (addr - base) / @sizeOf(Chunk);
                std.debug.assert(index < SLOTS_PER_BLOCK);
                const mask = @as(u32, 1) << @intCast(index);
                std.debug.assert(b.used & mask != 0);
                b.used &= ~mask;
                std.debug.assert(self.live > 0);
                self.live -= 1;
                return;
            }
        }
        unreachable; // not a pointer this slab handed out
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "chunks come from successive slots and stay distinct" {
    var slab = ChunkSlab.init(testing.allocator);
    defer slab.deinit();

    var pointers: [40]*Chunk = undefined;
    for (&pointers, 0..) |*slot, i| {
        const pos = ChunkPos.init(@intCast(i), 0, 0);
        slot.* = try slab.create(pos);
        try testing.expect(ChunkPos.eql(pos, slot.*.pos));
    }
    try testing.expectEqual(@as(usize, 40), slab.live);
    try testing.expectEqual(@as(usize, 2), slab.block_count);

    // Distinct slots, no aliasing.
    for (pointers, 0..) |a, i| {
        for (pointers[i + 1 ..]) |b| {
            try testing.expect(a != b);
        }
    }
    // Addresses inside a block are exactly one chunk apart.
    try testing.expectEqual(@intFromPtr(pointers[0]) + @sizeOf(Chunk), @intFromPtr(pointers[1]));
}

test "returned slots are reused before a new block is allocated" {
    var slab = ChunkSlab.init(testing.allocator);
    defer slab.deinit();

    const a = try slab.create(ChunkPos.init(0, 0, 0));
    _ = try slab.create(ChunkPos.init(1, 0, 0));
    try testing.expectEqual(@as(usize, 1), slab.block_count);

    slab.destroy(a);
    try testing.expectEqual(@as(usize, 1), slab.live);

    const c = try slab.create(ChunkPos.init(9, 0, 0));
    try testing.expectEqual(@intFromPtr(a), @intFromPtr(c));
    try testing.expectEqual(@as(usize, 1), slab.block_count);
    try testing.expectEqual(@as(usize, 2), slab.live);

    // The reused slot was reset to a fresh chunk, not left holding old state.
    try testing.expectEqual(ChunkPos.init(9, 0, 0), c.pos);
    try testing.expect(c.hasOnly(.air));
    try testing.expectEqual(@as(u32, 0), c.revision);
}

test "neighbouring pointers stay valid while other slots churn" {
    var slab = ChunkSlab.init(testing.allocator);
    defer slab.deinit();

    var chunks: [64]*Chunk = undefined;
    for (&chunks, 0..) |*slot, i| slot.* = try slab.create(ChunkPos.init(@intCast(i), 0, 0));
    chunks[7].setBlock(1, 2, 3, .stone);
    const addresses: [64]usize = blk: {
        var out: [64]usize = undefined;
        for (&out, chunks) |*o, c| o.* = @intFromPtr(c);
        break :blk out;
    };

    // Free every third chunk and re-create them elsewhere in the world.
    var i: usize = 0;
    while (i < chunks.len) : (i += 3) slab.destroy(chunks[i]);
    i = 0;
    while (i < chunks.len) : (i += 3) chunks[i] = try slab.create(ChunkPos.init(-@as(i32, @intCast(i)), 0, 0));

    for (addresses, 0..) |addr, j| {
        if (j % 3 != 0) try testing.expectEqual(addr, @intFromPtr(chunks[j]));
    }
    try testing.expectEqual(BlockId.stone, chunks[7].getBlock(1, 2, 3));
}

test "an emptied slab still frees every block" {
    var slab = ChunkSlab.init(testing.allocator);
    defer slab.deinit();

    var chunks: [70]*Chunk = undefined;
    for (&chunks, 0..) |*slot, i| slot.* = try slab.create(ChunkPos.init(@intCast(i), 0, 0));
    try testing.expectEqual(@as(usize, 3), slab.block_count);
    for (chunks) |c| slab.destroy(c);
    try testing.expectEqual(@as(usize, 0), slab.live);
}
