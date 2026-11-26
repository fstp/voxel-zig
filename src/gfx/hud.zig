const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const font = @import("font8x6.zig");

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\uniform vec2 u_screen;
    \\out vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    vec2 ndc = vec2(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2D u_font;
    \\uniform vec4 u_colour;
    \\in vec2 v_uv;
    \\out vec4 f_colour;
    \\void main() {
    \\    float a = texture(u_font, v_uv).a;
    \\    if (a < 0.5) discard;
    \\    f_colour = u_colour;
    \\}
;

const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
};

pub const MAX_VERTICES: usize = 6 * 4 * 1024; // 1024 glyphs per frame

/// Bitmap-text overlay (1.15). One atlas texture built from the baked 6x8 font,
/// one dynamic VBO, one draw call per frame. Ugly and readable, as asked.
pub const Hud = struct {
    shader: Shader,
    vao: gl.uint = 0,
    vbo: gl.uint = 0,
    texture: gl.uint = 0,
    vertices: [MAX_VERTICES]Vertex = undefined,
    count: usize = 0,
    scale: f32 = 2.0,
    screen: [2]f32 = .{ 1280, 720 },
    colour: [4]f32 = .{ 1, 1, 1, 1 },

    pub fn init() !Hud {
        var shader = try Shader.init(VERT_SRC, FRAG_SRC);
        errdefer shader.deinit();

        var hud = Hud{ .shader = shader };
        hud.buildAtlas();

        gl.GenVertexArrays(1, @ptrCast(&hud.vao));
        gl.GenBuffers(1, @ptrCast(&hud.vbo));
        gl.BindVertexArray(hud.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, hud.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(MAX_VERTICES * @sizeOf(Vertex)), null, gl.DYNAMIC_DRAW);
        gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), 0);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @offsetOf(Vertex, "uv"));
        gl.EnableVertexAttribArray(1);

        return hud;
    }

    pub fn deinit(self: *Hud) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
        gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    /// Unpacks the 1-bit glyph table into a 96x64 RGBA atlas: white where the
    /// bit is set, transparent elsewhere. NEAREST sampling keeps it crisp.
    fn buildAtlas(self: *Hud) void {
        const width = @as(u32, font.COLUMNS) * font.CELL_WIDTH;
        const height = @as(u32, font.CELL_HEIGHT) * (128 / font.COLUMNS);
        var pixels: [96 * 64 * 4]u8 = undefined;
        @memset(&pixels, 0);

        var glyph: usize = 0;
        while (glyph < 128) : (glyph += 1) {
            const gx = glyph % font.COLUMNS;
            const gy = glyph / font.COLUMNS;
            var row: usize = 0;
            while (row < font.CELL_HEIGHT) : (row += 1) {
                const bits = font.glyphs[glyph * font.CELL_HEIGHT + row];
                var column: usize = 0;
                while (column < font.CELL_WIDTH) : (column += 1) {
                    const set = (bits & (@as(u8, 1) << @intCast(5 - column))) != 0;
                    const px = gx * font.CELL_WIDTH + column;
                    const py = gy * font.CELL_HEIGHT + row;
                    const offset = (py * width + px) * 4;
                    pixels[offset + 0] = 255;
                    pixels[offset + 1] = 255;
                    pixels[offset + 2] = 255;
                    pixels[offset + 3] = if (set) 255 else 0;
                }
            }
        }

        gl.GenTextures(1, @ptrCast(&self.texture));
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, @intCast(width), @intCast(height), 0, gl.RGBA, gl.UNSIGNED_BYTE, &pixels);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.NEAREST));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.NEAREST));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));
    }

    pub fn begin(self: *Hud, width: i32, height: i32) void {
        self.count = 0;
        self.screen = .{ @floatFromInt(width), @floatFromInt(height) };
        self.colour = .{ 1, 1, 1, 1 };
    }

    pub fn setColour(self: *Hud, r: f32, g: f32, b: f32) void {
        self.colour = .{ r, g, b, 1 };
    }

    /// Draws `text` at pixel (x, y) with the top-left corner there and `scale`
    /// screen pixels per font pixel.
    pub fn text(self: *Hud, x: f32, y: f32, string: []const u8) void {
        var cursor = x;
        for (string) |raw| {
            const ch: u8 = if (raw < font.FIRST_CHAR or raw > 127) '?' else raw;
            const glyph: usize = ch - font.FIRST_CHAR;
            const gx: f32 = @floatFromInt(glyph % font.COLUMNS);
            const gy: f32 = @floatFromInt(glyph / font.COLUMNS);
            const u_left = gx / @as(f32, @floatFromInt(font.COLUMNS));
            const v_top = gy / @as(f32, @floatFromInt(128 / font.COLUMNS));
            const cell_u = 1.0 / @as(f32, @floatFromInt(font.COLUMNS));
            const cell_v = 1.0 / @as(f32, @floatFromInt(128 / font.COLUMNS));

            const w = @as(f32, @floatFromInt(font.CELL_WIDTH)) * self.scale;
            const h = @as(f32, @floatFromInt(font.CELL_HEIGHT)) * self.scale;
            self.quad(cursor, y, w, h, .{ u_left, v_top }, .{ u_left + cell_u, v_top + cell_v });
            cursor += w;
        }
    }

    fn quad(self: *Hud, x: f32, y: f32, w: f32, h: f32, uv0: [2]f32, uv1: [2]f32) void {
        if (self.count + 6 > MAX_VERTICES) return;
        const corners = [4][2]f32{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } };
        const uvs = [4][2]f32{ .{ uv0[0], uv0[1] }, .{ uv1[0], uv0[1] }, .{ uv1[0], uv1[1] }, .{ uv0[0], uv1[1] } };
        const order = [6]usize{ 0, 1, 2, 0, 2, 3 };
        for (order) |index| {
            self.vertices[self.count] = .{ .pos = corners[index], .uv = uvs[index] };
            self.count += 1;
        }
    }

    /// Uploads and draws everything queued since `begin`.
    pub fn end(self: *Hud) void {
        if (self.count == 0) return;
        gl.Disable(gl.DEPTH_TEST);
        gl.Disable(gl.CULL_FACE);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

        self.shader.use();
        self.shader.setFloat2("u_screen", self.screen);
        self.shader.setInt("u_font", 0);
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
        self.shader.setFloat4("u_colour", self.colour);

        gl.BindVertexArray(self.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        // Orphan first: a plain BufferData on a buffer the GPU is still reading
        // stalls the pipeline, which showed up as ~2 ms of "HUD time".
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(MAX_VERTICES * @sizeOf(Vertex)), null, gl.DYNAMIC_DRAW);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(self.count * @sizeOf(Vertex)), &self.vertices);
        gl.DrawArrays(gl.TRIANGLES, 0, @intCast(self.count));

        gl.Disable(gl.BLEND);
        gl.Enable(gl.DEPTH_TEST);
        gl.Enable(gl.CULL_FACE);
    }
};
