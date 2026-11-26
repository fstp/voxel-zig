const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const ChunkSlab = @import("chunk_slab.zig").ChunkSlab;
const ChunkState = chunk_mod.ChunkState;
const ChunkPos = coords.ChunkPos;
const BlockPos = coords.BlockPos;

/// The loaded world: a chunk hash map keyed by chunk position (ADR 0003).
///
/// `getBlock` is the hot path and allocates nothing at all, including for
/// chunks that have not been generated yet - those read as air.
pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.HashMapUnmanaged(ChunkPos, *Chunk, ChunkPos.Context, 80),
    /// Chunk buffers are carved from fixed 32 KB slots, not malloc'd one by one
    /// (ADR 0003: a single malloc per chunk costs an extra 4 KB page).
    slab: ChunkSlab,
    /// Number of block writes that actually changed something; a cheap metric
    /// for the HUD in 1.15 and for tests.
    edits: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .chunks = .{},
            .slab = ChunkSlab.init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.slab.deinit();
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const World) usize {
        return self.chunks.count();
    }

    pub fn getChunk(self: *const World, pos: ChunkPos) ?*Chunk {
        return self.chunks.get(pos);
    }

    pub fn isLoaded(self: *const World, pos: ChunkPos) bool {
        return self.chunks.contains(pos);
    }

    pub fn getOrCreateChunk(self: *World, pos: ChunkPos) !*Chunk {
        if (self.chunks.get(pos)) |existing| return existing;
        const chunk = try self.slab.create(pos);
        errdefer self.slab.destroy(chunk);
        try self.chunks.put(self.allocator, pos, chunk);
        return chunk;
    }

    pub fn removeChunk(self: *World, pos: ChunkPos) bool {
        if (self.chunks.fetchRemove(pos)) |kv| {
            self.slab.destroy(kv.value);
            return true;
        }
        return false;
    }

    /// Reads the block at world coordinates. Never allocates.
    pub fn getBlock(self: *const World, x: i32, y: i32, z: i32) BlockId {
        if (y < 0 or y >= coords.WORLD_HEIGHT) return .air;
        const pos = BlockPos.init(x, y, z);
        const chunk = self.getChunk(pos.chunk()) orelse return .air;
        const local = pos.local();
        return chunk.getBlock(local.x, local.y, local.z);
    }

    /// Writes a block and dirties every chunk whose geometry depends on it.
    /// Returns false when nothing changed: outside the world height, no chunk
    /// loaded there, or the block already held that value.
    pub fn setBlock(self: *World, x: i32, y: i32, z: i32, block: BlockId) bool {
        if (y < 0 or y >= coords.WORLD_HEIGHT) return false;
        const pos = BlockPos.init(x, y, z);
        const chunk = self.getChunk(pos.chunk()) orelse return false;
        const local = pos.local();
        if (chunk.getBlock(local.x, local.y, local.z) == block) return false;

        chunk.setBlock(local.x, local.y, local.z, block);
        chunk.edited = true;
        self.edits += 1;

        // A block on a chunk boundary contributes faces to the neighbour's
        // mesh as well, so up to one neighbour per axis owes a rebuild.
        const owner = pos.chunk();
        if (local.x == 0) self.markDirty(owner.offset(-1, 0, 0));
        if (local.x == coords.CHUNK_SIZE - 1) self.markDirty(owner.offset(1, 0, 0));
        if (local.y == 0) self.markDirty(owner.offset(0, -1, 0));
        if (local.y == coords.CHUNK_SIZE - 1) self.markDirty(owner.offset(0, 1, 0));
        if (local.z == 0) self.markDirty(owner.offset(0, 0, -1));
        if (local.z == coords.CHUNK_SIZE - 1) self.markDirty(owner.offset(0, 0, 1));
        return true;
    }

    /// Marks a loaded chunk's geometry stale. Unloaded neighbours are skipped:
    /// when they do load they are meshed from scratch anyway.
    fn markDirty(self: *World, pos: ChunkPos) void {
        if (self.getChunk(pos)) |chunk| {
            chunk.state = .dirty;
            chunk.revision +%= 1;
        }
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectChunkPos(expected: ChunkPos, actual: ChunkPos) !void {
    try testing.expect(ChunkPos.eql(expected, actual));
}

test "reads from unloaded chunks are air and allocate nothing" {
    // One slab block is 32 chunk slots (~1.05 MiB), so leave room for it.
    var buffer: [4 << 20]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    _ = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    world.getChunk(ChunkPos.init(0, 0, 0)).?.setBlock(3, 4, 5, .stone);

    const used_after_setup = fba.end_index;

    try testing.expectEqual(BlockId.stone, world.getBlock(3, 4, 5));

    var sum: u64 = 0;
    var i: i32 = -4096;
    while (i < 4096) : (i += 7) {
        // Loaded chunk, neighbouring chunk, and far away: none may allocate.
        if (world.getBlock(i, 64, 0) != .air) sum += 1;
        if (world.getBlock(3, 64, 5) != .air) sum += 1;
        if (world.getBlock(-1, 0, 0) != .air) sum += 1;
    }
    try testing.expectEqual(used_after_setup, fba.end_index);
    try testing.expectEqual(@as(u64, 0), sum);
}

test "negative world coordinates address the right chunk" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    // x = -1 lives in chunk -1 at local 31; x = -32 is chunk -1 local 0.
    _ = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    _ = try world.getOrCreateChunk(ChunkPos.init(-2, 0, 0));

    try testing.expect(world.setBlock(-1, 10, 0, .stone));
    try testing.expect(world.setBlock(-32, 10, 0, .dirt));
    try testing.expect(world.setBlock(-33, 10, 0, .sand));

    try testing.expectEqual(BlockId.stone, world.getBlock(-1, 10, 0));
    try testing.expectEqual(BlockId.dirt, world.getBlock(-32, 10, 0));
    try testing.expectEqual(BlockId.sand, world.getBlock(-33, 10, 0));
    // And nothing leaked into the wrong side of the origin.
    try testing.expectEqual(BlockId.air, world.getBlock(0, 10, 0));
    try testing.expectEqual(BlockId.air, world.getBlock(-31, 10, 0));

    const minus_one = world.getChunk(ChunkPos.init(-1, 0, 0)).?;
    try testing.expectEqual(BlockId.stone, minus_one.getBlock(31, 10, 0));
    try testing.expectEqual(BlockId.dirt, minus_one.getBlock(0, 10, 0));
    const minus_two = world.getChunk(ChunkPos.init(-2, 0, 0)).?;
    try testing.expectEqual(BlockId.sand, minus_two.getBlock(31, 10, 0));
}

test "an edit on a chunk boundary dirties both chunks" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const owner = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    const west = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    owner.state = .meshed;
    west.state = .meshed;
    const owner_revision = owner.revision;
    const west_revision = west.revision;

    // local x == 0, so the -X neighbour sees a new face.
    try testing.expect(world.setBlock(0, 10, 5, .stone));

    try testing.expectEqual(ChunkState.dirty, owner.state);
    try testing.expectEqual(ChunkState.dirty, west.state);
    try testing.expectEqual(owner_revision + 1, owner.revision);
    try testing.expectEqual(west_revision + 1, west.revision);
    try testing.expectEqual(@as(u64, 1), world.edits);
}

test "an edit inside a chunk leaves the neighbours alone" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const owner = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    const west = try world.getOrCreateChunk(ChunkPos.init(-1, 0, 0));
    const east = try world.getOrCreateChunk(ChunkPos.init(1, 0, 0));
    owner.state = .meshed;
    west.state = .meshed;
    east.state = .meshed;

    try testing.expect(world.setBlock(15, 10, 15, .stone));

    try testing.expectEqual(ChunkState.dirty, owner.state);
    try testing.expectEqual(ChunkState.meshed, west.state);
    try testing.expectEqual(ChunkState.meshed, east.state);
    try testing.expectEqual(@as(u32, 0), west.revision);
    try testing.expectEqual(@as(u32, 0), east.revision);
}

test "a corner edit dirties one chunk per axis, not all eight" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const positions = [_]ChunkPos{
        ChunkPos.init(0, 0, 0),  ChunkPos.init(-1, 0, -1), ChunkPos.init(0, 0, -1), ChunkPos.init(-1, 0, 0),
        ChunkPos.init(0, -1, 0), ChunkPos.init(-1, -1, -1), ChunkPos.init(0, -1, -1), ChunkPos.init(-1, -1, 0),
    };
    for (positions) |pos| {
        const chunk = try world.getOrCreateChunk(pos);
        chunk.state = .meshed;
    }

    // local (0, 0, 0) touches the -X, -Y and -Z neighbours.
    try testing.expect(world.setBlock(0, 0, 0, .stone));

    for (positions) |pos| {
        const expect_dirty = pos.eql(ChunkPos.init(0, 0, 0)) or
            pos.eql(ChunkPos.init(-1, 0, 0)) or
            pos.eql(ChunkPos.init(0, -1, 0)) or
            pos.eql(ChunkPos.init(0, 0, -1));
        const chunk = world.getChunk(pos).?;
        try testing.expectEqual(if (expect_dirty) ChunkState.dirty else ChunkState.meshed, chunk.state);
    }
}

test "writes that change nothing are not edits" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const chunk = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));
    chunk.state = .meshed;

    try testing.expect(world.setBlock(4, 10, 4, .stone));
    const revision = chunk.revision;
    chunk.state = .meshed;

    // Same block again: no revision bump, no state change.
    try testing.expect(!world.setBlock(4, 10, 4, .stone));
    try testing.expectEqual(revision, chunk.revision);
    try testing.expectEqual(ChunkState.meshed, chunk.state);
    try testing.expectEqual(@as(u64, 1), world.edits);

    // Air onto air is also a no-op.
    try testing.expect(!world.setBlock(5, 10, 5, .air));
    try testing.expectEqual(revision, chunk.revision);
}

test "edits outside the loaded world are refused, not created" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.getOrCreateChunk(ChunkPos.init(0, 0, 0));

    try testing.expect(!world.setBlock(8, 200, 8, .stone)); // above the world
    try testing.expect(!world.setBlock(8, -1, 8, .stone)); // below the world
    try testing.expect(!world.setBlock(9999, 64, 9999, .stone)); // unloaded chunk
    try testing.expectEqual(@as(usize, 1), world.count());
    try testing.expectEqual(@as(u64, 0), world.edits);
    try testing.expectEqual(BlockId.air, world.getBlock(8, 200, 8));
}

test "the 676-chunk load set costs 22 slab blocks, not 676 mallocs" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    // ADR 0003's load set: radius 6 -> 13 x 13 x 4 = 676 chunks.
    var slots: usize = 0;
    for (0..4) |cy| {
        for (0..13) |cz| {
            for (0..13) |cx| {
                _ = try world.getOrCreateChunk(ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz)));
                slots += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 676), slots);
    try testing.expectEqual(@as(usize, 676), world.count());
    try testing.expectEqual(@as(usize, 676), world.slab.live);
    // 676 / 32 slots per block, rounded up.
    try testing.expectEqual(@as(usize, 22), world.slab.block_count);
    // A malloc per chunk would have been 676 allocations of 36.8 KB (+12.4 %).
    // A slot is the chunk itself, so the whole payload is 676 x @sizeOf(Chunk).
    try testing.expect(@sizeOf(chunk_mod.Chunk) >= 32768);
    try testing.expect(@sizeOf(chunk_mod.Chunk) <= 32800);
    const payload_mib = @as(f64, @floatFromInt(676 * @sizeOf(chunk_mod.Chunk))) / (1024.0 * 1024.0);
    try testing.expect(payload_mib < 21.5);

    for (0..4) |cy| {
        for (0..13) |cz| {
            for (0..13) |cx| {
                _ = world.removeChunk(ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz)));
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), world.slab.live);
    try testing.expectEqual(@as(usize, 0), world.count());
}

test "chunk bookkeeping: create, reuse, remove" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const first = try world.getOrCreateChunk(ChunkPos.init(4, 2, -6));
    const again = try world.getOrCreateChunk(ChunkPos.init(4, 2, -6));
    try testing.expectEqual(first, again);
    try testing.expect(world.isLoaded(ChunkPos.init(4, 2, -6)));
    try testing.expectEqual(@as(usize, 1), world.count());

    try testing.expect(world.removeChunk(ChunkPos.init(4, 2, -6)));
    try testing.expect(!world.isLoaded(ChunkPos.init(4, 2, -6)));
    try testing.expectEqual(@as(usize, 0), world.count());
    try testing.expect(!world.removeChunk(ChunkPos.init(4, 2, -6)));
}

test "chunks across the world height all read back" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    for (0..coords.CHUNK_COUNT_Y) |cy| {
        _ = try world.getOrCreateChunk(ChunkPos.init(0, @intCast(cy), 0));
    }
    try testing.expect(world.setBlock(3, 0, 3, .stone));
    try testing.expect(world.setBlock(3, coords.WORLD_HEIGHT - 1, 3, .water));
    try testing.expectEqual(BlockId.stone, world.getBlock(3, 0, 3));
    try testing.expectEqual(BlockId.water, world.getBlock(3, coords.WORLD_HEIGHT - 1, 3));
    try testing.expectEqual(@as(usize, 4), world.count());
}
