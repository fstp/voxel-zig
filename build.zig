const std = @import("std");

/// Build graph for voxel-zig.
///
/// `zig build`      -> compile the exe into zig-out/bin/voxel-zig
/// `zig build run`  -> build and run it
/// `zig build test` -> run unit tests from the engine module and the exe
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The engine lives in its own module so the voxel/math code can be tested
    // without pulling in main() or (later) a window and a GL context.
    const engine = b.addModule("voxel_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "voxel-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "voxel_zig", .module = engine },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run voxel-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests");

    const module_tests = b.addTest(.{ .root_module = engine });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
