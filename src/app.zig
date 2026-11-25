const std = @import("std");
const sdl = @import("sdl3");
const Window = @import("gfx/window.zig").Window;
const gl = @import("gfx/gl.zig");
const DebugDraw = @import("gfx/debug_draw.zig").DebugDraw;
const Input = @import("input.zig").Input;
const TextureArray = @import("gfx/texture.zig").TextureArray;
const BlockRenderer = @import("gfx/block_renderer.zig").BlockRenderer;
const block = @import("voxel/block.zig");
const Camera = @import("camera.zig").Camera;
const Frustum = @import("math/frustum.zig").Frustum;
const Aabb = @import("math/aabb.zig").Aabb;
const Vec3 = @import("math/vec.zig").Vec3;
const Mat4 = @import("math/mat4.zig").Mat4;

pub const Config = struct {
    title: [:0]const u8 = "voxel-zig",
    width: i32 = 1280,
    height: i32 = 720,
    vsync: bool = true,
};

/// Fixed-timestep bookkeeping, split out so it can be tested without a window.
pub const Step = struct {
    accumulator: f64,
    steps: u32,
    /// True when the frame budget was exhausted and time had to be dropped.
    clamped: bool,
};

pub const FIXED_DT: f64 = 1.0 / 60.0;
pub const MAX_STEPS_PER_FRAME: u32 = 5;

/// Debug scene: a 5 x 3 x 5 grid of wireframe boxes, 6 units apart.
pub const BOX_GRID_X = 5;
pub const BOX_GRID_Y = 3;
pub const BOX_GRID_Z = 5;
pub const BOX_COUNT = BOX_GRID_X * BOX_GRID_Y * BOX_GRID_Z;
pub const BOX_SIZE = 2.0;
pub const BOX_SPACING = 6.0;

/// Advances a fixed-timestep accumulator by `dt` seconds.
///
/// A hitch larger than MAX_STEPS_PER_FRAME * FIXED_DT is clamped so the loop
/// cannot spiral (simulate more -> longer frame -> simulate even more).
pub fn advance(accumulator: f64, dt: f64, fixed_dt: f64, max_steps: u32) Step {
    var acc = accumulator + dt;
    var steps: u32 = 0;
    var clamped = false;
    while (acc >= fixed_dt) {
        if (steps == max_steps) {
            acc = @mod(acc, fixed_dt);
            clamped = true;
            break;
        }
        acc -= fixed_dt;
        steps += 1;
    }
    return .{ .accumulator = acc, .steps = steps, .clamped = clamped };
}

pub fn buildDebugBoxes() [BOX_COUNT]Aabb {
    var boxes: [BOX_COUNT]Aabb = undefined;
    var index: usize = 0;
    for (0..BOX_GRID_X) |ix| {
        for (0..BOX_GRID_Y) |iy| {
            for (0..BOX_GRID_Z) |iz| {
                const centre = Vec3.init(
                    (@as(f32, @floatFromInt(ix)) - 2.0) * BOX_SPACING,
                    @as(f32, @floatFromInt(iy)) * BOX_SPACING,
                    (@as(f32, @floatFromInt(iz)) - 2.0) * BOX_SPACING,
                );
                boxes[index] = Aabb.fromCenterSize(centre, Vec3.splat(BOX_SIZE));
                index += 1;
            }
        }
    }
    return boxes;
}

pub const App = struct {
    io: std.Io,
    window: Window,
    frame_arena: std.heap.ArenaAllocator,
    accumulator: f64 = 0,
    sim_ticks: u64 = 0,
    camera: Camera = .{},
    input: Input,
    debug: DebugDraw,
    textures: TextureArray,
    block_renderer: BlockRenderer,
    boxes: [BOX_COUNT]Aabb,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, config: Config) !App {
        var window = try Window.init(.{
            .title = config.title,
            .width = config.width,
            .height = config.height,
            .vsync = config.vsync,
        });
        errdefer {
            var w = window;
            w.deinit();
        }

        // The GL context must exist before the entry points can be loaded.
        try gl.init();
        std.debug.print("renderer: {s}\n", .{gl.rendererString()});

        var debug = try DebugDraw.init();
        errdefer debug.deinit();

        // ADR 0002: one 16x16 RGBA8 layer per block texture, array texture.
        var textures = try TextureArray.init(&block.texture_paths, block.TEXTURE_SIZE);
        errdefer textures.deinit();
        std.debug.print("textures: {d} layers of {d}x{d}\n", .{ textures.layers, textures.size, textures.size });

        var block_renderer = try BlockRenderer.init();
        errdefer block_renderer.deinit();

        gl.gl.Enable(gl.gl.DEPTH_TEST);
        gl.gl.Enable(gl.gl.CULL_FACE);
        gl.gl.CullFace(gl.gl.BACK);
        gl.gl.FrontFace(gl.gl.CCW);

        var input = Input.init();
        input.setRelativeMouse(&window, true);

        return .{
            .io = io,
            .window = window,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .input = input,
            .debug = debug,
            .textures = textures,
            .block_renderer = block_renderer,
            .boxes = buildDebugBoxes(),
        };
    }

    pub fn deinit(self: *App) void {
        self.block_renderer.deinit();
        self.textures.deinit();
        self.debug.deinit();
        self.frame_arena.deinit();
        self.window.deinit();
    }

    pub fn run(self: *App) !void {
        var last = std.Io.Timestamp.now(self.io, .awake);
        var report_at = last;
        var frames: u32 = 0;
        var worst_ms: f64 = 0;
        var first_frame = true;
        var visible: usize = 0;

        while (true) {
            self.input.pump(&self.window);
            if (self.input.quit) break;

            const now = std.Io.Timestamp.now(self.io, .awake);
            const dt_ns = now.nanoseconds - last.nanoseconds;
            last = now;
            const dt = @as(f64, @floatFromInt(dt_ns)) / 1e9;

            // Look is frame-rate shaped by the mouse; movement uses the frame
            // delta so the camera is smooth on a 120 Hz display without
            // interpolation. Physics (1.9) will run on the fixed step below.
            self.camera.look(self.input.mouse_dx, self.input.mouse_dy);
            if (self.input.wheel != 0) self.camera.adjustSpeed(self.input.wheel);

            const wish = Vec3.init(
                @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_D)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_A)))),
                @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_SPACE)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_LCTRL)))),
                @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_W)))) -
                    @as(f32, @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_S)))),
            );
            self.camera.fly(wish, @floatCast(dt), self.input.down(sdl.SDL_SCANCODE_LSHIFT));
            self.input.endFrame();

            const step = advance(self.accumulator, dt, FIXED_DT, MAX_STEPS_PER_FRAME);
            self.accumulator = step.accumulator;
            var i: u32 = 0;
            while (i < step.steps) : (i += 1) {
                self.simulate(FIXED_DT);
                self.sim_ticks += 1;
            }

            _ = self.frame_arena.reset(.retain_capacity);
            visible = self.render();
            self.window.swap();

            if (first_frame) {
                first_frame = false;
                last = std.Io.Timestamp.now(self.io, .awake);
                report_at = last;
                continue;
            }

            frames += 1;
            const frame_ms = @as(f64, @floatFromInt(dt_ns)) / 1e6;
            worst_ms = @max(worst_ms, frame_ms);

            const report_dt_ns = now.nanoseconds - report_at.nanoseconds;
            if (report_dt_ns >= std.time.ns_per_s) {
                const seconds = @as(f64, @floatFromInt(report_dt_ns)) / 1e9;
                std.debug.print(
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  vis {d}/{d}  pos ({d:.1},{d:.1},{d:.1}) yaw {d:.2} speed {d:.0}\n",
                    .{
                        @as(f64, @floatFromInt(frames)) / seconds,
                        @as(f64, @floatFromInt(report_dt_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
                        worst_ms,
                        visible,
                        BOX_COUNT,
                        self.camera.position.x,
                        self.camera.position.y,
                        self.camera.position.z,
                        self.camera.yaw,
                        self.camera.speed,
                    },
                );
                frames = 0;
                worst_ms = 0;
                report_at = now;
            }
        }
    }

    /// Simulation tick. Nothing to simulate yet: the player arrives in 1.9.
    fn simulate(self: *App, dt: f64) void {
        _ = self;
        _ = dt;
    }

    /// Draws the debug grid, culling boxes against the frustum. Returns the
    /// number of boxes that survived culling.
    fn render(self: *App) usize {
        gl.gl.Viewport(0, 0, self.window.width, self.window.height);
        gl.gl.ClearColor(0.53, 0.72, 0.92, 1.0);
        gl.gl.Clear(gl.gl.COLOR_BUFFER_BIT | gl.gl.DEPTH_BUFFER_BIT);

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        // Textured blocks: a grass block and a leaves block to exercise the
        // alpha cutout. The chunk mesher replaces this in 1.6.
        self.block_renderer.begin(vp, &self.textures);
        self.block_renderer.draw(.grass, .{ .x = 0, .y = 4, .z = 0 }, 6, Mat4.identity);
        self.block_renderer.draw(.leaves, .{ .x = 8, .y = 4, .z = 0 }, 6, Mat4.identity);

        self.debug.begin(vp);
        var visible: usize = 0;
        for (self.boxes) |box| {
            if (!frustum.containsAabb(box)) continue;
            visible += 1;
            self.debug.box(box, .{ 0.15, 0.95, 0.75 });
        }
        return visible;
    }
};

// ------------------------------------------------------------------ tests

test "60 fps input produces one simulation step per frame" {
    var acc: f64 = 0;
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const step = advance(acc, 1.0 / 60.0, FIXED_DT, MAX_STEPS_PER_FRAME);
        acc = step.accumulator;
        try std.testing.expectEqual(@as(u32, 1), step.steps);
        try std.testing.expect(!step.clamped);
    }
}

test "a long hitch is clamped instead of spiralling" {
    const step = advance(0, 2.0, FIXED_DT, MAX_STEPS_PER_FRAME);
    try std.testing.expectEqual(MAX_STEPS_PER_FRAME, step.steps);
    try std.testing.expect(step.clamped);
    try std.testing.expect(step.accumulator < FIXED_DT);
}

test "fractional frames accumulate rather than dropping time" {
    var acc: f64 = 0;
    var steps: u32 = 0;
    var i: u32 = 0;
    // 90 fps for one second must produce 60 ticks, not 90 and not 0.
    while (i < 90) : (i += 1) {
        const step = advance(acc, 1.0 / 90.0, FIXED_DT, MAX_STEPS_PER_FRAME);
        acc = step.accumulator;
        steps += step.steps;
    }
    try std.testing.expectEqual(@as(u32, 60), steps);
}

test "debug grid is 75 boxes centred on the origin in x and z" {
    const boxes = buildDebugBoxes();
    try std.testing.expectEqual(@as(usize, 75), boxes.len);
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    for (boxes) |b| {
        min_x = @min(min_x, b.min.x);
        max_x = @max(max_x, b.max.x);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), min_x + max_x, 1e-5);
}
