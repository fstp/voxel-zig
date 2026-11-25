const std = @import("std");
const engine = @import("voxel_zig");

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Placeholder for the real thing: until 1.1 there is no window, so the
    // executable's job is to prove the engine module links and runs.
    std.debug.print("voxel-zig {s} (zig {s})\n", .{ engine.version, @import("builtin").zig_version_string });

    var solid: usize = 0;
    for (std.enums.values(engine.voxel.BlockId)) |block| {
        if (block.isSolid()) solid += 1;
    }
    std.debug.print("block registry: {d} types, {d} solid\n", .{ std.enums.values(engine.voxel.BlockId).len, solid });

    const forward = engine.math.Vec3.init(0, 0, -1);
    const up = engine.math.Vec3.init(0, 1, 0);
    std.debug.print("math sane: dot={d:.1} cross.y={d:.1}\n", .{ forward.dot(up), forward.cross(up).y });

    std.debug.print("run `zig build test` for the suite\n", .{});
}

test "enum values are exhaustive" {
    try std.testing.expectEqual(@as(usize, 8), std.enums.values(engine.voxel.BlockId).len);
}
