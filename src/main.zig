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

    var config: engine.Config = .{
        .title = "voxel-zig",
        .width = 2560,
        .height = 1440,
        .vsync = true,
    };
    // 2.4 spike: VOXEL_NET_PORT binds a UDP socket, VOXEL_PEER points at the
    // other instance ("127.0.0.1:4567"). No flags, no config file.
    if (init.environ_map.get("VOXEL_NET_PORT")) |port| {
        config.net_port = std.fmt.parseInt(u16, port, 10) catch 0;
    }
    if (init.environ_map.get("VOXEL_PEER")) |peer| config.net_peer = peer;
    // 3.10: VOXEL_SUN="142,18" pins the sun for screenshots and tests.
    if (init.environ_map.get("VOXEL_SUN")) |spec| config.sun_spec = spec;
    // 6.3: VOXEL_DEBUG_WATER=1 paints water flat magenta for the seam diagnostic.
    if (init.environ_map.get("VOXEL_DEBUG_WATER")) |raw| {
        config.debug_water = raw.len > 0 and raw[0] != '0';
    }
    // 4.1: VOXEL_EXPOSURE=0.55 pins the scene exposure.
    if (init.environ_map.get("VOXEL_EXPOSURE")) |raw| {
        if (std.fmt.parseFloat(f32, raw)) |value| {
            config.exposure = value;
        } else |_| {}
    }

    var app = try engine.App.init(gpa, init.io, config);
    defer app.deinit();

    try app.run();

    std.debug.print("voxel-zig {s} exited cleanly\n", .{engine.version});
}
