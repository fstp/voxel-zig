const std = @import("std");

/// Block types. The numeric value is what goes into the chunk buffer, so the
/// order is part of the on-disk format once 1.14 exists: append, never reorder.
pub const BlockId = enum(u8) {
    air = 0,
    stone,
    dirt,
    grass,
    sand,
    wood,
    leaves,
    water,

    /// Collides with the player and culls neighbour faces.
    pub fn isSolid(self: BlockId) bool {
        return switch (self) {
            .air, .water => false,
            else => true,
        };
    }

    /// Hides the face of a neighbouring block. Leaves are solid but you can
    /// see through the gaps, so they do not cull their neighbours.
    pub fn isOpaque(self: BlockId) bool {
        return switch (self) {
            .air, .water, .leaves => false,
            else => true,
        };
    }
};

test "air and water do not block the player" {
    try std.testing.expect(!BlockId.air.isSolid());
    try std.testing.expect(!BlockId.water.isSolid());
    try std.testing.expect(BlockId.stone.isSolid());
}

test "leaves are solid but not opaque" {
    try std.testing.expect(BlockId.leaves.isSolid());
    try std.testing.expect(!BlockId.leaves.isOpaque());
}

test "ids fit in a byte" {
    try std.testing.expectEqual(@as(usize, 8), std.enums.values(BlockId).len);
    try std.testing.expect(@sizeOf(BlockId) == 1);
}
