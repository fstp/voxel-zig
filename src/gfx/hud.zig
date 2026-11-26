const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const font = @import("hud_font.zig");
const stb = @import("stb.zig");

const VERT_SRC: [:0]const u8 =
    \\#version 460 core
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in vec4 a_rgba;
    \\uniform vec2 u_screen;
    \\out vec2 v_uv;
    \\out vec4 v_colour;
    \\void main() {
    \\    v_uv = a_uv;
    \\    v_colour = a_rgba;
    \\    vec2 ndc = vec2(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 460 core
    \\uniform sampler2D u_font;
    \\in vec2 v_uv;
    \\in vec4 v_colour;
    \\out vec4 f_colour;
    \\void main() {
    \\    // A real anti-aliased atlas, so keep the soft edge: a hard 0.5 cutoff
    \\    // throws away exactly the pixels that make small text readable.
    \\    float a = texture(u_font, v_uv).a;
    \\    if (a < 0.02) discard;
    \\    f_colour = vec4(v_colour.rgb, v_colour.a * a);
    \\}
;

const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    rgba: [4]f32,
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
    scale: f32 = font.default_scale,
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
        gl.VertexAttribPointer(2, 4, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @offsetOf(Vertex, "rgba"));
        gl.EnableVertexAttribArray(2);

        return hud;
    }

    pub fn deinit(self: *Hud) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
        gl.DeleteBuffers(1, @ptrCast(&self.vbo));
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        self.shader.deinit();
    }

    /// Loads the baked DejaVu atlas (assets/font/hud.png). A real font replaced the
    /// 6x8 bitmap on request: at 1920x1080 the bitmap was legible only because it
    /// was drawn at 2x, and even then it read as noise in the corners.
    fn buildAtlas(self: *Hud) void {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        stb.stbi_set_flip_vertically_on_load(1);
        const data = stb.stbi_load(font.atlas_path, &width, &height, &channels, 4) orelse {
            std.debug.print("failed to load font atlas {s}\n", .{font.atlas_path});
            return;
        };
        defer stb.stbi_image_free(data);

        gl.GenTextures(1, @ptrCast(&self.texture));
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR));
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
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

    /// Draws `text` at pixel (x, y) with the top-left corner there.
    pub fn text(self: *Hud, x: f32, y: f32, string: []const u8) void {
        var cursor = x;
        const w = @as(f32, @floatFromInt(font.cell_width)) * self.scale;
        const h = @as(f32, @floatFromInt(font.cell_height)) * self.scale;
        const cell_u = 1.0 / @as(f32, @floatFromInt(font.columns));
        const cell_v = 1.0 / @as(f32, @floatFromInt(font.rows));
        for (string) |raw| {
            const ch: u8 = if (raw < font.first_char or raw > 126) '?' else raw;
            const glyph = ch - font.first_char;
            const gx: f32 = @floatFromInt(glyph % font.columns);
            const gy: f32 = @floatFromInt(glyph / font.columns);
            const u_left = gx * cell_u;
            // Rows are flipped on upload (stb), so cell row `gy` occupies
            // v in [1 - (gy+1)*cell_v, 1 - gy*cell_v] with the top at the larger v.
            const v_top = 1.0 - gy * cell_v;
            const v_bottom = 1.0 - (gy + 1) * cell_v;
            self.quad(cursor, y, w, h, .{ u_left, v_top }, .{ u_left + cell_u, v_bottom }, self.colour);
            // Monospace: the advance is a constant, so kerning never enters.
            cursor += font.advance * self.scale;
        }
    }

    /// A translucent panel behind text. Sampled from a reserved solid cell in the
    /// atlas so it needs no second texture and no extra draw call.
    pub fn panel(self: *Hud, x: f32, y: f32, w: f32, h: f32, alpha: f32) void {
        const cell_u = 1.0 / @as(f32, @floatFromInt(font.columns));
        const cell_v = 1.0 / @as(f32, @floatFromInt(font.rows));
        const last = font.columns * font.rows - 1;
        const u = @as(f32, @floatFromInt(last % font.columns)) * cell_u + cell_u * 0.5;
        const row = last / font.columns;
        const v = 1.0 - (@as(f32, @floatFromInt(row)) + 0.5) * cell_v;
        self.quad(x, y, w, h, .{ u, v }, .{ u, v }, .{ 0.02, 0.03, 0.05, alpha });
    }

    /// Screen pixels between baselines.
    pub fn lineHeight(self: Hud) f32 {
        return font.line_height * self.scale;
    }

    fn quad(self: *Hud, x: f32, y: f32, w: f32, h: f32, uv0: [2]f32, uv1: [2]f32, rgba: [4]f32) void {
        if (self.count + 6 > MAX_VERTICES) return;
        const corners = [4][2]f32{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } };
        const uvs = [4][2]f32{ .{ uv0[0], uv0[1] }, .{ uv1[0], uv0[1] }, .{ uv1[0], uv1[1] }, .{ uv0[0], uv1[1] } };
        const order = [6]usize{ 0, 1, 2, 0, 2, 3 };
        for (order) |index| {
            self.vertices[self.count] = .{ .pos = corners[index], .uv = uvs[index], .rgba = rgba };
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
