//! The three stb_image entry points the engine uses. The implementation is
//! compiled from src/vendor/stb_impl.c; this file only declares them, so no
//! translate-c step and no @cImport (removed in Zig 0.17).
const std = @import("std");

pub extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

pub extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

pub extern fn stbi_set_flip_vertically_on_load(flag: c_int) void;

pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
