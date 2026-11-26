const std = @import("std");
const sdl = @import("sdl3");
const Window = @import("gfx/window.zig").Window;
const gl = @import("gfx/gl.zig");
const DebugDraw = @import("gfx/debug_draw.zig").DebugDraw;
const Input = @import("input.zig").Input;
const Camera = @import("camera.zig").Camera;
const TextureArray = @import("gfx/texture.zig").TextureArray;
const ChunkRenderer = @import("gfx/chunk_renderer.zig").ChunkRenderer;
const Frustum = @import("math/frustum.zig").Frustum;
const Aabb = @import("math/aabb.zig").Aabb;
const Vec3 = @import("math/vec.zig").Vec3;
const World = @import("world/world.zig").World;
const chunk_mesher = @import("world/chunk_mesher.zig");
const mesher = @import("voxel/mesher.zig");
const terrain = @import("world/terrain.zig");
const block = @import("voxel/block.zig");

pub const Config = struct {
    title: [:0]const u8 = "voxel-zig",
    width: i32 = 1280,
    height: i32 = 720,
    vsync: bool = true,
    /// Worldgen seed. Fixed so the acceptance screenshot is reproducible.
    seed: u32 = 0x5EED_1234,
};

/// 1.8 generates a fixed 9x9 chunk area (ADR 0005); streaming replaces the
/// bounds in 1.11.
pub const FIELD_CHUNKS: i32 = 9;

/// Fixed-timestep bookkeeping, split out so it can be tested without a window.
pub const Step = struct {
    accumulator: f64,
    steps: u32,
    /// True when the frame budget was exhausted and time had to be dropped.
    clamped: bool,
};

pub const FIXED_DT: f64 = 1.0 / 60.0;
pub const MAX_STEPS_PER_FRAME: u32 = 5;

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

pub const CHUNK_TOTAL: usize = @intCast(FIELD_CHUNKS * FIELD_CHUNKS * @import("voxel/coords.zig").CHUNK_COUNT_Y);

/// The fixed area 1.8 generates and draws.
pub fn chunkPositions() [CHUNK_TOTAL]@import("voxel/coords.zig").ChunkPos {
    const coords = @import("voxel/coords.zig");
    var positions: [CHUNK_TOTAL]coords.ChunkPos = undefined;
    var i: usize = 0;
    for (0..coords.CHUNK_COUNT_Y) |cy| {
        for (0..FIELD_CHUNKS) |cz| {
            for (0..FIELD_CHUNKS) |cx| {
                positions[i] = coords.ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz));
                i += 1;
            }
        }
    }
    return positions;
}

/// Creates and generates every chunk in the area. Pure per chunk, so this could
/// be split across worker threads without changing the result (1.13).
pub fn buildWorld(world: *World, seed: u32) !void {
    for (chunkPositions()) |pos| {
        const chunk = try world.getOrCreateChunk(pos);
        terrain.generateChunk(chunk, seed);
    }
}

/// First guess for a chunk's geometry buffers; a chunk that needs more is
/// meshed again into a bigger buffer (the checkerboard worst case is 98k quads
/// and not worth reserving up front).
const INITIAL_QUAD_CAPACITY: usize = 4096;

pub const App = struct {
    io: std.Io,
    window: Window,
    frame_arena: std.heap.ArenaAllocator,
    accumulator: f64 = 0,
    sim_ticks: u64 = 0,
    camera: Camera,
    input: Input,
    debug: DebugDraw,
    textures: TextureArray,
    world: World,
    chunk_renderer: ChunkRenderer,
    meshes: []ChunkRenderer.Mesh,
    scratch_vertices: []mesher.Vertex,
    scratch_indices: []u32,
    total_quads: usize = 0,
    meshed_chunks: usize = 0,
    seed: u32,
    show_wire: bool = false,
    allocator: std.mem.Allocator,

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

        // ADR 0005 worldgen: a pure function of (seed, chunk_pos), so the order
        // these chunks are created in cannot matter.
        var world = World.init(gpa);
        errdefer world.deinit();
        const gen_start = std.Io.Timestamp.now(io, .awake);
        try buildWorld(&world, config.seed);
        const gen_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).nanoseconds - gen_start.nanoseconds)) / 1e6;
        std.debug.print("worldgen: {d} chunks in {d:.1} ms ({d:.1} us/chunk)\n", .{ CHUNK_TOTAL, gen_ms, gen_ms * 1000.0 / @as(f64, @floatFromInt(CHUNK_TOTAL)) });

        var chunk_renderer = try ChunkRenderer.init();
        errdefer chunk_renderer.deinit();

        gl.gl.Enable(gl.gl.DEPTH_TEST);
        gl.gl.Enable(gl.gl.CULL_FACE);
        gl.gl.CullFace(gl.gl.BACK);
        gl.gl.FrontFace(gl.gl.CCW);

        var input = Input.init();
        input.setRelativeMouse(&window, true);

        var app = App{
            .io = io,
            .window = window,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .camera = .{
                .position = Vec3.init(144, 150, 430),
                .yaw = 0,
                .pitch = -0.18,
                .speed = 40,
            },
            .input = input,
            .debug = debug,
            .textures = textures,
            .seed = config.seed,
            .world = world,
            .chunk_renderer = chunk_renderer,
            .meshes = try gpa.alloc(ChunkRenderer.Mesh, CHUNK_TOTAL),
            .scratch_vertices = try gpa.alloc(mesher.Vertex, INITIAL_QUAD_CAPACITY * 4),
            .scratch_indices = try gpa.alloc(u32, INITIAL_QUAD_CAPACITY * 6),
            .allocator = gpa,
        };
        errdefer {
            gpa.free(app.meshes);
            gpa.free(app.scratch_vertices);
            gpa.free(app.scratch_indices);
        }
        @memset(app.meshes, .{});

        const mesh_start = std.Io.Timestamp.now(io, .awake);
        try app.meshWorld();
        const mesh_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).nanoseconds - mesh_start.nanoseconds)) / 1e6;
        std.debug.print("meshing: {d} chunks in {d:.1} ms ({d:.1} us/chunk)\n", .{ app.meshed_chunks, mesh_ms, mesh_ms * 1000.0 / @as(f64, @floatFromInt(app.meshed_chunks)) });
        return app;
    }

    pub fn deinit(self: *App) void {
        for (self.meshes) |*mesh| self.chunk_renderer.destroyMesh(mesh);
        self.allocator.free(self.meshes);
        self.allocator.free(self.scratch_vertices);
        self.allocator.free(self.scratch_indices);
        self.chunk_renderer.deinit();
        self.world.deinit();
        self.textures.deinit();
        self.debug.deinit();
        self.frame_arena.deinit();
        self.window.deinit();
        self.* = undefined;
    }

    /// Meshes every chunk in the world once and uploads it. 1.13 moves this to
    /// worker threads; 1.11 remeshes on demand.
    fn meshWorld(self: *App) !void {
        var padded = mesher.PaddedBlocks.init();
        const positions = chunkPositions();
        var total_quads: usize = 0;
        var meshed: usize = 0;

        for (positions, 0..) |pos, index| {
            // A chunk entirely above the surface has no geometry; skipping it
            // before meshing avoids empty VAOs and the fill pass.
            if (terrain.chunkIsAir(self.seed, pos)) continue;
            while (true) {
                // meshChunk's only error is the capacity one, so the loop can
                // grow and retry rather than reserving the 98k-quad bound.
                const stats = chunk_mesher.meshChunk(&self.world, pos, &padded, self.scratch_vertices, self.scratch_indices) catch |err| switch (err) {
                    error.VertexBufferTooSmall => {
                        try self.growScratch();
                        continue;
                    },
                };
                const origin = pos.blockOrigin();
                self.chunk_renderer.upload(
                    &self.meshes[index],
                    Vec3.init(@floatFromInt(origin.x), @floatFromInt(origin.y), @floatFromInt(origin.z)),
                    self.scratch_vertices[0..stats.vertices],
                    self.scratch_indices[0..stats.indices],
                );
                total_quads += stats.quads;
                if (stats.quads > 0) meshed += 1;
                break;
            }
        }
        self.total_quads = total_quads;
        self.meshed_chunks = meshed;
        std.debug.print(
            "world: {d} chunks generated ({d} with geometry), {d} quads, {d:.1} MB of vertex data, seed 0x{X}\n",
            .{
                positions.len,
                meshed,
                total_quads,
                @as(f64, @floatFromInt(total_quads * 4 * @sizeOf(mesher.Vertex))) / (1024.0 * 1024.0),
                self.seed,
            },
        );
    }

    fn growScratch(self: *App) !void {
        const quads = self.scratch_vertices.len / 4;
        const bigger = quads * 2;
        std.debug.print("chunk needs more than {d} quads, growing to {d}\n", .{ quads, bigger });
        self.allocator.free(self.scratch_vertices);
        self.allocator.free(self.scratch_indices);
        self.scratch_vertices = try self.allocator.alloc(mesher.Vertex, bigger * 4);
        self.scratch_indices = try self.allocator.alloc(u32, bigger * 6);
    }

    pub fn run(self: *App) !void {
        var last = std.Io.Timestamp.now(self.io, .awake);
        var report_at = last;
        var frames: u32 = 0;
        var worst_ms: f64 = 0;
        var first_frame = true;
        var drawn: usize = 0;

        while (true) {
            self.input.pump(&self.window);
            if (self.input.quit) break;

            const now = std.Io.Timestamp.now(self.io, .awake);
            const dt_ns = now.nanoseconds - last.nanoseconds;
            last = now;
            const dt = @as(f64, @floatFromInt(dt_ns)) / 1e9;

            if (self.input.debug_toggle) {
                self.input.debug_toggle = false;
                self.show_wire = !self.show_wire;
            }

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
            drawn = self.render();
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
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  chunks {d}/{d} of {d} quads {d}  pos ({d:.1},{d:.1},{d:.1}) yaw {d:.2}\n",
                    .{
                        @as(f64, @floatFromInt(frames)) / seconds,
                        @as(f64, @floatFromInt(report_dt_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
                        worst_ms,
                        drawn,
                        self.meshed_chunks,
                        self.meshes.len,
                        self.total_quads,
                        self.camera.position.x,
                        self.camera.position.y,
                        self.camera.position.z,
                        self.camera.yaw,
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

    /// Draws every chunk that survives the frustum test. Returns how many were
    /// drawn.
    fn render(self: *App) usize {
        gl.gl.Viewport(0, 0, self.window.width, self.window.height);
        gl.gl.ClearColor(0.53, 0.72, 0.92, 1.0);
        gl.gl.Clear(gl.gl.COLOR_BUFFER_BIT | gl.gl.DEPTH_BUFFER_BIT);

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        self.chunk_renderer.begin(vp, &self.textures);
        var drawn: usize = 0;
        for (self.meshes) |*mesh| {
            // Air-only chunks have no uploaded geometry and must not count as
            // drawn, or the HUD lies about what the frustum let through.
            if (mesh.index_count == 0) continue;
            if (!frustum.containsAabb(mesh.bounds)) continue;
            drawn += 1;
            self.chunk_renderer.draw(mesh);
        }

        if (self.show_wire) {
            self.debug.begin(vp);
            for (self.meshes) |*mesh| {
                if (!frustum.containsAabb(mesh.bounds)) continue;
                self.debug.box(mesh.bounds, .{ 0.9, 0.85, 0.4 });
            }
        }
        return drawn;
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

test "the generated area is 9x9x4 chunks" {
    const positions = chunkPositions();
    try std.testing.expectEqual(@as(usize, 324), positions.len);
    try std.testing.expectEqual(@as(usize, 324), CHUNK_TOTAL);

    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    for (positions) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
    }
    try std.testing.expectEqual(@as(i32, 0), min_x);
    try std.testing.expectEqual(@as(i32, 8), max_x);
}
