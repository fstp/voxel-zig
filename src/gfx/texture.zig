const std = @import("std");
const gl = @import("gl");
const stb = @import("stb.zig");

/// One GL_TEXTURE_2D_ARRAY holding every block texture (ADR 0002): one 16x16
/// RGBA8 layer per PNG, NEAREST magnification, mipmapped minification.
pub const TextureArray = struct {
    texture: gl.uint,
    size: u32,
    layers: u32,

    /// PNG rows are top-down (first row is the top of the tile); GL samples
    /// v = 0 at the bottom. stb is asked to flip on load so the two agree.
    pub fn init(paths: []const [:0]const u8, size: u32) !TextureArray {
        std.debug.assert(paths.len > 0);
        const alloc = std.heap.page_allocator;
        const pixels = try alloc.alloc(u8, @as(usize, size) * size * 4 * paths.len);
        defer alloc.free(pixels);

        stb.stbi_set_flip_vertically_on_load(1);

        for (paths, 0..) |path, index| {
            var width: c_int = 0;
            var height: c_int = 0;
            var channels: c_int = 0;
            const data = stb.stbi_load(path, &width, &height, &channels, 4) orelse {
                std.debug.print("failed to load texture {s}\n", .{path});
                return error.ImageLoad;
            };
            defer stb.stbi_image_free(data);

            if (width != size or height != size) {
                std.debug.print("{s} is {d}x{d}, expected {d}x{d}\n", .{ path, width, height, size, size });
                return error.ImageSize;
            }
            const offset = @as(usize, size) * size * 4 * index;
            @memcpy(pixels[offset .. offset + @as(usize, size) * size * 4], data[0 .. @as(usize, size) * size * 4]);
        }

        var texture: gl.uint = 0;
        gl.GenTextures(1, @ptrCast(&texture));
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, texture);
        gl.TexImage3D(
            gl.TEXTURE_2D_ARRAY,
            0,
            gl.RGBA8,
            @intCast(size),
            @intCast(size),
            @intCast(paths.len),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            pixels.ptr,
        );
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, @intCast(gl.NEAREST_MIPMAP_LINEAR));
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, @intCast(gl.NEAREST));
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));
        gl.GenerateMipmap(gl.TEXTURE_2D_ARRAY);

        return .{ .texture = texture, .size = size, .layers = @intCast(paths.len) };
    }

    pub fn deinit(self: *TextureArray) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
    }

    pub fn bind(self: TextureArray, unit: u32) void {
        gl.ActiveTexture(@intCast(@as(gl.@"enum", gl.TEXTURE0) + @as(gl.@"enum", unit)));
        gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.texture);
    }
};
