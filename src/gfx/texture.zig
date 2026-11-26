const std = @import("std");
const gl = @import("gl");
const stb = @import("stb.zig");

/// One GL_TEXTURE_2D_ARRAY holding every block texture (ADR 0002): one RGBA8
/// layer per PNG at `block.TEXTURE_SIZE`, linear magnification, mipmapped
/// minification.
pub const TextureArray = struct {
    texture: gl.uint,
    size: u32,
    layers: u32,

    /// PNG rows are top-down (first row is the top of the tile); GL samples
    /// v = 0 at the bottom. stb is asked to flip on load so the two agree.
    /// `srgb` must be true for colour and false for data maps: an albedo uploaded
    /// as plain RGBA8 is shaded as if its bytes were linear, which is the washed
    /// out look ADR 0008 set out to remove.
    pub fn init(paths: []const [:0]const u8, size: u32, srgb: bool) !TextureArray {
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
            if (srgb) gl.SRGB8_ALPHA8 else gl.RGBA8,
            @intCast(size),
            @intCast(size),
            @intCast(paths.len),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            pixels.ptr,
        );
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR_MIPMAP_LINEAR));
        // LINEAR magnification: at 256 px the photo detail is the point, and NEAREST
    // turned every texel into a visible square. Mipmapping stays on so distance
    // still averages instead of shimmering.
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
        // REPEAT, not CLAMP: the greedy mesher (2.1) emits one quad per run of
        // blocks with UVs up to (width, height), and the tile has to repeat.
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, @intCast(gl.REPEAT));
        gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, @intCast(gl.REPEAT));
        // Trilinear minification is only half the answer for a ground plane seen
        // at a glancing angle: without anisotropy the driver picks a mip that
        // suits the compressed axis and the surface smears into a blur.
        var max_aniso: f32 = 1.0;
        gl.GetFloatv(gl.MAX_TEXTURE_MAX_ANISOTROPY, @ptrCast(&max_aniso));
        const wanted = @min(max_aniso, 8.0);
        if (wanted > 1.0) {
            gl.TexParameterf(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAX_ANISOTROPY, wanted);
        }
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
