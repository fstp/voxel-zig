const std = @import("std");

/// Build graph for voxel-zig.
///
/// `zig build`      -> compile the exe into zig-out/bin/voxel-zig
/// `zig build run`  -> build and run it
/// `zig build test` -> run unit tests from the engine module and the exe
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 handles window, input and the GL context (ADR 0001).
    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    // OpenGL 4.6 core bindings, loaded through SDL_GL_GetProcAddress (ADR 0002).
    const gl = @import("zigglgen").generateModule(b, .{
        .api = .gl,
        .version = .@"4.6",
        .profile = .core,
    });

    // The engine lives in its own module so voxel/math/world code can be tested
    // without opening a window.
    const engine = b.addModule("voxel_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl.module("sdl3") },
            .{ .name = "gl", .module = gl },
        },
    });
    engine.linkSystemLibrary("GL", .{});
    // stb_image: one C translation unit, declared by hand in src/gfx/stb.zig.
    engine.addIncludePath(b.path("src/vendor"));
    engine.addCSourceFile(.{ .file = b.path("src/vendor/stb_impl.c"), .flags = &.{} });

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
