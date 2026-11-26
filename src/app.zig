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
const coords = @import("voxel/coords.zig");
const raycast = @import("voxel/raycast.zig");
const Player = @import("player/player.zig").Player;
const ChunkPos = coords.ChunkPos;
const BlockPos = coords.BlockPos;

pub const Config = struct {
    title: [:0]const u8 = "voxel-zig",
    width: i32 = 1280,
    height: i32 = 720,
    vsync: bool = true,
    /// Worldgen seed. Fixed so the acceptance screenshot is reproducible.
    seed: u32 = 0x5EED_1234,
};

/// 1.8 generates a fixed 9x9 chunk area; 1.11 replaces the bounds with streaming.
pub const FIELD_CHUNKS: i32 = 9;
pub const CHUNK_TOTAL: usize = @intCast(FIELD_CHUNKS * FIELD_CHUNKS * coords.CHUNK_COUNT_Y);

/// How far the player can reach with break/place.
pub const REACH: f32 = 6.0;

/// Hotbar, cycled with the mouse wheel while holding no pick.
pub const HOTBAR = [_]block.BlockId{ .stone, .dirt, .grass, .sand, .wood, .leaves };

pub const Step = struct {
    accumulator: f64,
    steps: u32,
    clamped: bool,
};

pub const FIXED_DT: f64 = 1.0 / 60.0;
pub const MAX_STEPS_PER_FRAME: u32 = 5;

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

pub fn chunkPositions() [CHUNK_TOTAL]ChunkPos {
    var positions: [CHUNK_TOTAL]ChunkPos = undefined;
    var i: usize = 0;
    for (0..coords.CHUNK_COUNT_Y) |cy| {
        for (0..FIELD_CHUNKS) |cz| {
            for (0..FIELD_CHUNKS) |cx| {
                positions[i] = ChunkPos.init(@intCast(cx), @intCast(cy), @intCast(cz));
                i += 1;
            }
        }
    }
    return positions;
}

pub fn chunkIndex(pos: ChunkPos) ?usize {
    if (pos.x < 0 or pos.x >= FIELD_CHUNKS) return null;
    if (pos.z < 0 or pos.z >= FIELD_CHUNKS) return null;
    if (pos.y < 0 or pos.y >= coords.CHUNK_COUNT_Y) return null;
    const index = (@as(usize, @intCast(pos.y)) * FIELD_CHUNKS + @as(usize, @intCast(pos.z))) * FIELD_CHUNKS + @as(usize, @intCast(pos.x));
    if (index >= CHUNK_TOTAL) return null;
    return index;
}

pub fn buildWorld(world: *World, seed: u32) !void {
    for (chunkPositions()) |pos| {
        const chunk = try world.getOrCreateChunk(pos);
        terrain.generateChunk(chunk, seed);
    }
}

const INITIAL_QUAD_CAPACITY: usize = 4096;

pub const App = struct {
    io: std.Io,
    window: Window,
    frame_arena: std.heap.ArenaAllocator,
    accumulator: f64 = 0,
    sim_ticks: u64 = 0,
    camera: Camera,
    player: Player,
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
    highlight: ?raycast.Hit = null,
    selected: block.BlockId = .stone,
    edits: usize = 0,
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

        try gl.init();
        std.debug.print("renderer: {s}\n", .{gl.rendererString()});

        var debug = try DebugDraw.init();
        errdefer debug.deinit();

        var textures = try TextureArray.init(&block.texture_paths, block.TEXTURE_SIZE);
        errdefer textures.deinit();
        std.debug.print("textures: {d} layers of {d}x{d}\n", .{ textures.layers, textures.size, textures.size });

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
            .camera = .{ .fov_y_deg = 70, .near = 0.1, .far = 1000 },
            .player = .{
                .position = Vec3.init(144, 90, 144),
                .yaw = 0,
                .pitch = -0.25,
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

    fn meshWorld(self: *App) !void {
        for (chunkPositions(), 0..) |pos, index| {
            try self.rebuildChunk(pos, index);
        }
        self.recount();
    }

    /// Meshes one chunk and uploads it (or drops its mesh when it is empty).
    fn rebuildChunk(self: *App, pos: ChunkPos, index: usize) !void {
        const chunk = self.world.getChunk(pos) orelse return;
        if (terrain.chunkIsAir(self.seed, pos)) {
            self.chunk_renderer.destroyMesh(&self.meshes[index]);
            chunk.state = .meshed;
            return;
        }

        var padded = mesher.PaddedBlocks.init();
        while (true) {
            const stats = chunk_mesher.meshChunk(&self.world, pos, &padded, self.scratch_vertices, self.scratch_indices) catch |err| switch (err) {
                error.VertexBufferTooSmall => {
                    try self.growScratch();
                    continue;
                },
            };
            if (stats.quads == 0) {
                self.chunk_renderer.destroyMesh(&self.meshes[index]);
            } else {
                const origin = pos.blockOrigin();
                self.chunk_renderer.upload(
                    &self.meshes[index],
                    Vec3.init(@floatFromInt(origin.x), @floatFromInt(origin.y), @floatFromInt(origin.z)),
                    self.scratch_vertices[0..stats.vertices],
                    self.scratch_indices[0..stats.indices],
                );
            }
            chunk.state = .meshed;
            return;
        }
    }

    /// Re-meshes every chunk the world marked dirty (an edit, or a neighbour
    /// arriving). A single edit touches at most four chunks.
    fn remeshDirty(self: *App) void {
        for (chunkPositions(), 0..) |pos, index| {
            const chunk = self.world.getChunk(pos) orelse continue;
            if (!chunk.needsMesh()) continue;
            self.rebuildChunk(pos, index) catch |err| {
                std.debug.print("remesh failed for {d},{d},{d}: {s}\n", .{ pos.x, pos.y, pos.z, @errorName(err) });
            };
        }
        self.recount();
    }

    fn recount(self: *App) void {
        var quads: usize = 0;
        var meshed: usize = 0;
        for (chunkPositions(), 0..) |pos, index| {
            _ = pos;
            _ = index;
        }
        // Geometry totals come from the renderer's index counts (4 verts, 6
        // indices per quad), so no separate bookkeeping can drift.
        for (self.meshes) |mesh| {
            if (mesh.index_count == 0) continue;
            meshed += 1;
            quads += mesh.index_count / 6;
        }
        self.total_quads = quads;
        self.meshed_chunks = meshed;
    }

    fn growScratch(self: *App) !void {
        const quads = self.scratch_vertices.len / 4;
        const bigger = quads * 2;
        self.allocator.free(self.scratch_vertices);
        self.allocator.free(self.scratch_indices);
        self.scratch_vertices = try self.allocator.alloc(mesher.Vertex, bigger * 4);
        self.scratch_indices = try self.allocator.alloc(u32, bigger * 6);
    }

    /// Movement wish in world space from the held keys and the player yaw.
    fn wishVector(self: *App) Vec3 {
        const forward_amount: f32 = @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_W)));
        const back_amount: f32 = @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_S)));
        const right_amount: f32 = @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_D)));
        const left_amount: f32 = @floatFromInt(@intFromBool(self.input.down(sdl.SDL_SCANCODE_A)));

        const forward = Vec3.init(@sin(self.player.yaw), 0, -@cos(self.player.yaw));
        const right = Vec3.init(@cos(self.player.yaw), 0, @sin(self.player.yaw));
        const wish = forward.scale(forward_amount - back_amount).add(right.scale(right_amount - left_amount));
        const length = @sqrt(wish.x * wish.x + wish.z * wish.z);
        if (length < 1e-5) return Vec3.init(0, 0, 0);
        return Vec3.init(wish.x / length, 0, wish.z / length);
    }

    fn simulate(self: *App, dt: f64) void {
        const up: f32 = @floatFromInt(
            @intFromBool(self.input.down(sdl.SDL_SCANCODE_SPACE)) -
                @intFromBool(self.input.down(sdl.SDL_SCANCODE_LCTRL)),
        );
        const sprint = self.input.down(sdl.SDL_SCANCODE_LSHIFT);
        self.player.update(&self.world, @floatCast(dt), self.wishVector(), up, sprint);
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

            if (self.input.debug_toggle) self.show_wire = !self.show_wire;
            if (self.input.fly_toggle) self.player.flying = !self.player.flying;

            // Mouse look drives the player; the camera follows the eyes.
            self.player.yaw += self.input.mouse_dx * Camera.SENSITIVITY;
            self.player.pitch = std.math.clamp(
                self.player.pitch - self.input.mouse_dy * Camera.SENSITIVITY,
                -Camera.MAX_PITCH,
                Camera.MAX_PITCH,
            );

            if (self.input.wheel != 0) {
                const delta: i32 = if (self.input.wheel > 0) 1 else -1;
                const count: i32 = @intCast(HOTBAR.len);
                const index = @mod(@as(i32, @intCast(self.hotbarIndex())) + delta, count);
                self.selected = HOTBAR[@intCast(index)];
            }

            const step = advance(self.accumulator, dt, FIXED_DT, MAX_STEPS_PER_FRAME);
            self.accumulator = step.accumulator;
            var i: u32 = 0;
            while (i < step.steps) : (i += 1) {
                self.simulate(FIXED_DT);
                self.sim_ticks += 1;
            }

            self.updateHighlight();
            if (self.input.primary_click) self.breakBlock();
            if (self.input.secondary_click) self.placeBlock();
            if (self.input.middle_click) self.pickBlock();
            self.input.endFrame();

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
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  chunks {d}/{d} quads {d}  pos ({d:.1},{d:.1},{d:.1}) {s} {s} sel {s}  edits {d}\n",
                    .{
                        @as(f64, @floatFromInt(frames)) / seconds,
                        @as(f64, @floatFromInt(report_dt_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
                        worst_ms,
                        drawn,
                        self.meshed_chunks,
                        self.total_quads,
                        self.player.position.x,
                        self.player.position.y,
                        self.player.position.z,
                        if (self.player.on_ground) "ground" else "air",
                        if (self.player.flying) "fly" else "walk",
                        @tagName(self.selected),
                        self.edits,
                    },
                );
                frames = 0;
                worst_ms = 0;
                report_at = now;
            }
        }
    }

    fn hotbarIndex(self: *App) usize {
        for (HOTBAR, 0..) |b, i| {
            if (b == self.selected) return i;
        }
        return 0;
    }

    fn updateHighlight(self: *App) void {
        self.highlight = raycast.raycast(&self.world, self.player.eyePosition(), self.player.forward(), REACH);
    }

    fn breakBlock(self: *App) void {
        const hit = self.highlight orelse return;
        if (self.world.setBlock(hit.block.x, hit.block.y, hit.block.z, .air)) {
            self.edits += 1;
            self.remeshDirty();
        }
    }

    fn placeBlock(self: *App) void {
        const hit = self.highlight orelse return;
        const target = BlockPos.init(
            hit.block.x + hit.normal[0],
            hit.block.y + hit.normal[1],
            hit.block.z + hit.normal[2],
        );
        // Never place a block inside the player: that is how you get stuck.
        if (self.blockIntersectsPlayer(target)) return;
        if (self.world.setBlock(target.x, target.y, target.z, self.selected)) {
            self.edits += 1;
            self.remeshDirty();
        }
    }

    fn pickBlock(self: *App) void {
        const hit = self.highlight orelse return;
        const picked = self.world.getBlock(hit.block.x, hit.block.y, hit.block.z);
        if (picked != .air) self.selected = picked;
    }

    fn blockIntersectsPlayer(self: *App, target: BlockPos) bool {
        const player_box = Player.aabbAt(self.player.position);
        const block_box = Aabb.fromCenterSize(
            Vec3.init(@as(f32, @floatFromInt(target.x)) + 0.5, @as(f32, @floatFromInt(target.y)) + 0.5, @as(f32, @floatFromInt(target.z)) + 0.5),
            Vec3.init(1, 1, 1),
        );
        return overlaps(player_box, block_box);
    }

    fn render(self: *App) usize {
        gl.gl.Viewport(0, 0, self.window.width, self.window.height);
        gl.gl.ClearColor(0.53, 0.72, 0.92, 1.0);
        gl.gl.Clear(gl.gl.COLOR_BUFFER_BIT | gl.gl.DEPTH_BUFFER_BIT);

        // The camera is a pure view of the player: eyes, yaw, pitch.
        self.camera.position = self.player.eyePosition();
        self.camera.yaw = self.player.yaw;
        self.camera.pitch = self.player.pitch;

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        self.chunk_renderer.begin(vp, &self.textures);
        var drawn: usize = 0;
        for (self.meshes) |*mesh| {
            if (mesh.index_count == 0) continue;
            if (!frustum.containsAabb(mesh.bounds)) continue;
            drawn += 1;
            self.chunk_renderer.draw(mesh);
        }

        if (self.highlight) |hit| {
            self.debug.begin(vp);
            const centre = Vec3.init(
                @as(f32, @floatFromInt(hit.block.x)) + 0.5,
                @as(f32, @floatFromInt(hit.block.y)) + 0.5,
                @as(f32, @floatFromInt(hit.block.z)) + 0.5,
            );
            self.debug.box(Aabb.fromCenterSize(centre, Vec3.init(1.004, 1.004, 1.004)), .{ 0.05, 0.05, 0.05 });
        }

        if (self.show_wire) {
            self.debug.begin(vp);
            for (self.meshes) |*mesh| {
                if (mesh.index_count == 0) continue;
                if (!frustum.containsAabb(mesh.bounds)) continue;
                self.debug.box(mesh.bounds, .{ 0.9, 0.85, 0.4 });
            }
        }
        return drawn;
    }
};

fn overlaps(a: Aabb, b: Aabb) bool {
    return a.min.x < b.max.x and a.max.x > b.min.x and
        a.min.y < b.max.y and a.max.y > b.min.y and
        a.min.z < b.max.z and a.max.z > b.min.z;
}

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
    while (i < 90) : (i += 1) {
        const step = advance(acc, 1.0 / 90.0, FIXED_DT, MAX_STEPS_PER_FRAME);
        acc = step.accumulator;
        steps += step.steps;
    }
    try std.testing.expectEqual(@as(u32, 60), steps);
}

test "the generated area is 9x9x4 chunks and indices round-trip" {
    const positions = chunkPositions();
    try std.testing.expectEqual(@as(usize, 324), positions.len);
    for (positions, 0..) |pos, index| {
        try std.testing.expectEqual(index, chunkIndex(pos).?);
    }
    try std.testing.expectEqual(@as(?usize, null), chunkIndex(ChunkPos.init(-1, 0, 0)));
    try std.testing.expectEqual(@as(?usize, null), chunkIndex(ChunkPos.init(0, 4, 0)));
}
