const std = @import("std");
const BlockId = @import("../voxel/block.zig").BlockId;
const coords = @import("../voxel/coords.zig");
const World = @import("world.zig").World;
const BlockPos = coords.BlockPos;

/// One block that changed, with both sides of the edit.
pub const Change = struct {
    pos: BlockPos,
    before: BlockId,
    after: BlockId,
};

pub const MAX_RECORDS = 64;

/// Undo/redo stack of block edits (2.5). Each brush stroke is one record, so an
/// undo removes the whole stroke rather than one block of it. The stack is
/// capped by bytes: when the cap is hit the oldest record is freed, which is
/// what keeps a long sculpting session from growing without bound.
pub const Undo = struct {
    allocator: std.mem.Allocator,
    records: [MAX_RECORDS][]Change = undefined,
    /// Number of records in history. `cursor` records of them are applied.
    len: usize = 0,
    cursor: usize = 0,
    bytes: usize = 0,
    max_bytes: usize = 8 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator) Undo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Undo) void {
        for (self.records[0..self.len]) |record| self.allocator.free(record);
        self.* = undefined;
    }

    /// Takes ownership of `changes` as a new record, dropping any redo branch.
    pub fn push(self: *Undo, changes: []Change) !void {
        if (changes.len == 0) {
            self.allocator.free(changes);
            return;
        }
        // A new edit after an undo throws the redo branch away.
        while (self.len > self.cursor) {
            self.len -= 1;
            self.bytes -= self.records[self.len].len * @sizeOf(Change);
            self.allocator.free(self.records[self.len]);
        }

        // Make room, evicting the oldest stroke when either cap is hit.
        while (self.len == MAX_RECORDS or self.bytes + changes.len * @sizeOf(Change) > self.max_bytes) {
            if (self.len == 0) break;
            self.bytes -= self.records[0].len * @sizeOf(Change);
            self.allocator.free(self.records[0]);
            std.mem.copyForwards([]Change, self.records[0 .. self.len - 1], self.records[1..self.len]);
            self.len -= 1;
            self.cursor = if (self.cursor > 0) self.cursor - 1 else 0;
        }

        self.records[self.len] = changes;
        self.len += 1;
        self.cursor = self.len;
        self.bytes += changes.len * @sizeOf(Change);
    }

    /// Reverts the newest applied record. Returns how many blocks changed.
    pub fn undo(self: *Undo, world: *World) usize {
        if (self.cursor == 0) return 0;
        const record = self.records[self.cursor - 1];
        var applied: usize = 0;
        var i = record.len;
        while (i > 0) {
            i -= 1;
            const change = record[i];
            if (world.setBlock(change.pos.x, change.pos.y, change.pos.z, change.before)) applied += 1;
        }
        self.cursor -= 1;
        return applied;
    }

    /// Re-applies the record the last undo reverted.
    pub fn redo(self: *Undo, world: *World) usize {
        if (self.cursor >= self.len) return 0;
        const record = self.records[self.cursor];
        var applied: usize = 0;
        for (record) |change| {
            if (world.setBlock(change.pos.x, change.pos.y, change.pos.z, change.after)) applied += 1;
        }
        self.cursor += 1;
        return applied;
    }

    pub fn canUndo(self: *const Undo) bool {
        return self.cursor > 0;
    }

    pub fn canRedo(self: *const Undo) bool {
        return self.cursor < self.len;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testWorld(allocator: std.mem.Allocator) !World {
    var world = World.init(allocator);
    errdefer world.deinit();
    for (0..2) |cy| {
        for (0..2) |cz| {
            for (0..2) |cx| {
                _ = try world.getOrCreateChunk(coords.ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz)));
            }
        }
    }
    return world;
}

fn recordFor(allocator: std.mem.Allocator, world: *World, positions: []const BlockPos, after: BlockId) ![]Change {
    const changes = try allocator.alloc(Change, positions.len);
    for (positions, 0..) |pos, i| {
        changes[i] = .{ .pos = pos, .before = world.getBlock(pos.x, pos.y, pos.z), .after = after };
    }
    return changes;
}

test "undo restores the previous blocks and redo re-applies them" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var undo = Undo.init(testing.allocator);
    defer undo.deinit();

    const positions = [_]BlockPos{ BlockPos.init(2, 4, 2), BlockPos.init(3, 4, 2), BlockPos.init(2, 4, 3) };
    _ = world.setBlock(3, 4, 2, .dirt); // a block we must get back, not air

    const changes = try recordFor(testing.allocator, &world, &positions, .stone);
    for (changes) |change| _ = world.setBlock(change.pos.x, change.pos.y, change.pos.z, .stone);
    try undo.push(try testing.allocator.dupe(Change, changes));
    testing.allocator.free(changes);

    try testing.expectEqual(BlockId.stone, world.getBlock(2, 4, 2));
    try testing.expect(undo.canUndo());

    try testing.expectEqual(@as(usize, 3), undo.undo(&world));
    try testing.expectEqual(BlockId.air, world.getBlock(2, 4, 2));
    try testing.expectEqual(BlockId.dirt, world.getBlock(3, 4, 2));
    try testing.expect(undo.canRedo());
    try testing.expect(!undo.canUndo());

    try testing.expectEqual(@as(usize, 3), undo.redo(&world));
    try testing.expectEqual(BlockId.stone, world.getBlock(2, 4, 2));
    try testing.expectEqual(BlockId.stone, world.getBlock(3, 4, 2));
}

test "a new edit after an undo drops the redo branch" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var undo = Undo.init(testing.allocator);
    defer undo.deinit();

    const first = try recordFor(testing.allocator, &world, &[_]BlockPos{BlockPos.init(1, 4, 1)}, .stone);
    try undo.push(first);
    const second_record = try recordFor(testing.allocator, &world, &[_]BlockPos{BlockPos.init(2, 4, 2)}, .stone);
    try undo.push(second_record);

    _ = undo.undo(&world);
    try testing.expect(undo.canRedo());

    const third = try recordFor(testing.allocator, &world, &[_]BlockPos{BlockPos.init(3, 4, 3)}, .stone);
    try undo.push(third);
    try testing.expect(!undo.canRedo());
    try testing.expect(undo.canUndo());
}

test "the stack evicts the oldest stroke when it runs out of room" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var undo = Undo.init(testing.allocator);
    defer undo.deinit();
    undo.max_bytes = @sizeOf(Change) * 2; // room for exactly two 1-change records

    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const changes = try recordFor(testing.allocator, &world, &[_]BlockPos{BlockPos.init(i, 4, 1)}, .stone);
        try undo.push(changes);
    }
    try testing.expectEqual(@as(usize, 2), undo.len);
    try testing.expectEqual(@as(usize, 2), undo.cursor);
}

test "an empty record is not pushed" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var undo = Undo.init(testing.allocator);
    defer undo.deinit();
    try undo.push(try testing.allocator.alloc(Change, 0));
    try testing.expectEqual(@as(usize, 0), undo.len);
    try testing.expectEqual(@as(usize, 0), undo.undo(&world));
}
