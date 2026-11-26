const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const ChunkPos = coords.ChunkPos;

/// Lifecycle of a chunk. `ready` means the blocks exist but no geometry has
/// been built; `meshed` means the geometry matches the blocks; `dirty` means
/// an edit invalidated that geometry. `needsMesh()` covers the last two.
pub const ChunkState = enum(u8) {
    empty,
    generating,
    ready,
    meshed,
    dirty,
};

/// A fixed 32^3 block buffer plus its state. It holds no pointers to its
/// neighbours: the world (and later the mesher) resolves those by position, so
/// a chunk can be generated on a worker thread without any cross-chunk refs.
pub const Chunk = struct {
    pos: ChunkPos,
    blocks: [coords.CHUNK_VOLUME]BlockId,
    state: ChunkState = .empty,
    /// Bumped on every block write. The mesher compares it before uploading so
    /// geometry built from stale blocks is discarded (ADR 0006).
    revision: u32 = 0,

    pub fn init(pos: ChunkPos) Chunk {
        return .{
            .pos = pos,
            .blocks = @splat(.air),
        };
    }

    pub fn getBlock(self: *const Chunk, x: i32, y: i32, z: i32) BlockId {
        return self.blocks[coords.localIndex(x, y, z)];
    }

    /// Writes a block without touching neighbours; the world does that.
    pub fn setBlock(self: *Chunk, x: i32, y: i32, z: i32, block: BlockId) void {
        self.blocks[coords.localIndex(x, y, z)] = block;
        self.revision +%= 1;
        self.state = .dirty;
    }

    pub fn fill(self: *Chunk, block: BlockId) void {
        self.blocks = @splat(block);
        self.revision +%= 1;
        self.state = .dirty;
    }

    /// True while the chunk has geometry work owed to it.
    pub fn needsMesh(self: *const Chunk) bool {
        return self.state == .ready or self.state == .dirty;
    }

    /// True when every block is `block`; lets the mesher skip empty chunks.
    pub fn hasOnly(self: *const Chunk, block: BlockId) bool {
        for (self.blocks) |b| {
            if (b != block) return false;
        }
        return true;
    }

    pub fn countBlocks(self: *const Chunk, block: BlockId) usize {
        var n: usize = 0;
        for (self.blocks) |b| {
            if (b == block) n += 1;
        }
        return n;
    }
};

// ------------------------------------------------------------------ tests

test "a new chunk is empty air at the right position" {
    const chunk = Chunk.init(ChunkPos.init(2, 1, -3));
    try std.testing.expectEqual(ChunkState.empty, chunk.state);
    try std.testing.expectEqual(@as(u32, 0), chunk.revision);
    try std.testing.expectEqual(BlockId.air, chunk.getBlock(0, 0, 0));
    try std.testing.expectEqual(BlockId.air, chunk.getBlock(31, 31, 31));
    try std.testing.expect(chunk.hasOnly(.air));
    try std.testing.expectEqual(@as(usize, 0), chunk.countBlocks(.stone));
    try std.testing.expect(ChunkPos.eql(ChunkPos.init(2, 1, -3), chunk.pos));
}

test "chunk buffer is exactly 32 KiB of block ids" {
    try std.testing.expectEqual(@as(usize, 32768), @sizeOf([coords.CHUNK_VOLUME]BlockId));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(BlockId));
}

test "block writes round-trip and bump the revision" {
    var chunk = Chunk.init(ChunkPos.init(0, 0, 0));
    chunk.setBlock(0, 1, 2, .stone);
    chunk.setBlock(31, 31, 31, .water);
    try std.testing.expectEqual(BlockId.stone, chunk.getBlock(0, 1, 2));
    try std.testing.expectEqual(BlockId.water, chunk.getBlock(31, 31, 31));
    try std.testing.expectEqual(@as(u32, 2), chunk.revision);
    try std.testing.expectEqual(ChunkState.dirty, chunk.state);
    // The same local index must not be shared by two corners.
    try std.testing.expect(coords.localIndex(0, 1, 2) != coords.localIndex(31, 31, 31));
}

test "fill and hasOnly" {
    var chunk = Chunk.init(ChunkPos.init(0, 0, 0));
    chunk.fill(.stone);
    try std.testing.expect(chunk.hasOnly(.stone));
    try std.testing.expect(!chunk.hasOnly(.air));
    try std.testing.expectEqual(coords.CHUNK_VOLUME, chunk.countBlocks(.stone));
    chunk.setBlock(5, 5, 5, .air);
    try std.testing.expect(!chunk.hasOnly(.stone));
    try std.testing.expectEqual(coords.CHUNK_VOLUME - 1, chunk.countBlocks(.stone));
}

test "needsMesh covers ready and dirty only" {
    var chunk = Chunk.init(ChunkPos.init(0, 0, 0));
    chunk.state = .empty;
    try std.testing.expect(!chunk.needsMesh());
    chunk.state = .generating;
    try std.testing.expect(!chunk.needsMesh());
    chunk.state = .ready;
    try std.testing.expect(chunk.needsMesh());
    chunk.state = .meshed;
    try std.testing.expect(!chunk.needsMesh());
    chunk.state = .dirty;
    try std.testing.expect(chunk.needsMesh());
}
