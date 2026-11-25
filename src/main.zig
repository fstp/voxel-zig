const std = @import("std");
const engine = @import("voxel_zig");

pub fn main(init: std.process.Init) !void {
    // Long-lived allocations go through the debug allocator so a leak shows up
    // at exit; per-frame temporaries live in the app's arena (ADR 0006 spirit:
    // no allocations in the hot path).
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) std.debug.print("LEAK: allocations still live at exit\n", .{});
    }
    const gpa = debug_allocator.allocator();

    var app = try engine.App.init(gpa, init.io, .{
        .title = "voxel-zig",
        .width = 1280,
        .height = 720,
        .vsync = true,
    });
    defer app.deinit();

    try app.run();

    std.debug.print("voxel-zig {s} exited cleanly\n", .{engine.version});
}
