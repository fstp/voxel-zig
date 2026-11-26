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
    seed: u32 = 0x5EED_1234,
};

/// 1.11 streaming: a cylinder of LOAD_RADIUS chunks around the player, unloaded
/// one ring beyond that so the seam does not thrash (ADR 0003/0006).
pub const LOAD_RADIUS: i32 = 6;
pub const UNLOAD_RADIUS: i32 = 7;
/// Per-frame budget (the ADR's starting point: 2 generations, 4 uploads).
pub const GEN_PER_FRAME: usize = 2;
pub const MESH_PER_FRAME: usize = 4;
/// Chunks generated and meshed before the first frame so the player spawns on
/// solid ground rather than falling through level 0.
pub const PRELOAD_RADIUS: i32 = 2;
pub const PRELOAD_MESH_RADIUS: i32 = 1;

pub const REACH: f32 = 6.0;
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

/// Cylinder test: same horizontal radius for every chunk layer.
pub fn chunkInRange(centre: ChunkPos, pos: ChunkPos, radius: i32) bool {
    if (pos.y < 0 or pos.y >= coords.CHUNK_COUNT_Y) return false;
    const dx = pos.x - centre.x;
    const dz = pos.z - centre.z;
    return dx * dx + dz * dz <= radius * radius;
}

pub fn distanceSq(a: ChunkPos, b: ChunkPos) f32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt((a.y - b.y) * 2); // weight height less
    const dz: f32 = @floatFromInt(a.z - b.z);
    return dx * dx + dy * dy + dz * dz;
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
    meshes: std.HashMapUnmanaged(ChunkPos, ChunkRenderer.Mesh, ChunkPos.Context, 80),
    scratch_vertices: []mesher.Vertex,
    scratch_indices: []u32,
    padded: mesher.PaddedBlocks,
    total_quads: usize = 0,
    meshed_chunks: usize = 0,
    generated_this_frame: usize = 0,
    meshed_this_frame: usize = 0,
    generated_total: usize = 0,
    meshed_total: usize = 0,
    seed: u32,
    show_wire: bool = false,
    shading: bool = true,
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

        var chunk_renderer = try ChunkRenderer.init();
        errdefer chunk_renderer.deinit();

        gl.gl.Enable(gl.gl.DEPTH_TEST);
        gl.gl.Enable(gl.gl.CULL_FACE);
        gl.gl.CullFace(gl.gl.BACK);
        gl.gl.FrontFace(gl.gl.CCW);

        var input = Input.init();
        input.setRelativeMouse(&window, true);

        const spawn_x: i32 = 144;
        const spawn_z: i32 = 144;
        const surface = terrain.heightAt(config.seed, spawn_x, spawn_z);

        var app = App{
            .io = io,
            .window = window,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .camera = .{ .fov_y_deg = 70, .near = 0.1, .far = 1000 },
            .player = .{
                .position = Vec3.init(@floatFromInt(spawn_x), @floatFromInt(surface + 3), @floatFromInt(spawn_z)),
                .yaw = 0,
                .pitch = -0.2,
            },
            .input = input,
            .debug = debug,
            .textures = textures,
            .seed = config.seed,
            .world = world,
            .chunk_renderer = chunk_renderer,
            .meshes = .{},
            .scratch_vertices = try gpa.alloc(mesher.Vertex, INITIAL_QUAD_CAPACITY * 4),
            .scratch_indices = try gpa.alloc(u32, INITIAL_QUAD_CAPACITY * 6),
            .padded = mesher.PaddedBlocks.init(),
            .allocator = gpa,
        };
        errdefer {
            gpa.free(app.scratch_vertices);
            gpa.free(app.scratch_indices);
        }

        const start = std.Io.Timestamp.now(io, .awake);
        try app.preload();
        const preload_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds)) / 1e6;
        std.debug.print(
            "preload: {d} chunks generated, {d} meshed in {d:.1} ms (seed 0x{X}, spawn y {d})\n",
            .{ app.world.count(), app.meshed_chunks, preload_ms, app.seed, surface + 3 },
        );
        return app;
    }

    pub fn deinit(self: *App) void {
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| self.chunk_renderer.destroyMesh(mesh);
        self.meshes.deinit(self.allocator);
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

    fn playerChunk(self: *App) ChunkPos {
        return ChunkPos.fromBlock(BlockPos.init(
            @intFromFloat(@floor(self.player.position.x)),
            @intFromFloat(@floor(self.player.position.y)),
            @intFromFloat(@floor(self.player.position.z)),
        ));
    }

    fn preload(self: *App) !void {
        const centre = self.playerChunk();
        var dy: i32 = 0;
        while (dy < coords.CHUNK_COUNT_Y) : (dy += 1) {
            var dz: i32 = -PRELOAD_RADIUS;
            while (dz <= PRELOAD_RADIUS) : (dz += 1) {
                var dx: i32 = -PRELOAD_RADIUS;
                while (dx <= PRELOAD_RADIUS) : (dx += 1) {
                    const pos = ChunkPos.init(centre.x + dx, dy, centre.z + dz);
                    if (!chunkInRange(centre, pos, PRELOAD_RADIUS)) continue;
                    try self.generateChunk(pos);
                }
            }
        }

        dy = 0;
        while (dy < coords.CHUNK_COUNT_Y) : (dy += 1) {
            var dz: i32 = -PRELOAD_MESH_RADIUS;
            while (dz <= PRELOAD_MESH_RADIUS) : (dz += 1) {
                var dx: i32 = -PRELOAD_MESH_RADIUS;
                while (dx <= PRELOAD_MESH_RADIUS) : (dx += 1) {
                    const pos = ChunkPos.init(centre.x + dx, dy, centre.z + dz);
                    if (!chunkInRange(centre, pos, PRELOAD_MESH_RADIUS)) continue;
                    try self.ensureMesh(pos);
                }
            }
        }
        self.recount();
    }

    fn generateChunk(self: *App, pos: ChunkPos) !void {
        if (self.world.isLoaded(pos)) return;
        const chunk = try self.world.getOrCreateChunk(pos);
        terrain.generateChunk(chunk, self.seed);
        // The frontier faces of the neighbours open up now that this chunk
        // exists, so they owe a rebuild (ADR 0004's remesh-on-arrival rule).
        self.markNeighboursDirty(pos);
    }

    /// Marks the chunks whose geometry depends on this one. The six face
    /// neighbours matter for culling, and the four horizontal diagonals matter
    /// for 1.12's AO (the corner samples live in them), so both are dirtied:
    /// without the diagonals a chunk keeps the AO it was meshed with before its
    /// diagonal arrived, and that shows up as a hard seam on the ground.
    fn markNeighboursDirty(self: *App, pos: ChunkPos) void {
        const dirs = [_][3]i32{
            .{ -1, 0, 0 },  .{ 1, 0, 0 },   .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 },
            .{ -1, 0, -1 }, .{ 1, 0, -1 }, .{ -1, 0, 1 }, .{ 1, 0, 1 },
        };
        for (dirs) |d| {
            const neighbour = pos.offset(d[0], d[1], d[2]);
            if (self.world.getChunk(neighbour)) |chunk| {
                if (chunk.state == .meshed) chunk.state = .dirty;
            }
        }
    }

    fn removeChunk(self: *App, pos: ChunkPos) void {
        if (self.meshes.fetchRemove(pos)) |kv| {
            var mesh = kv.value;
            self.chunk_renderer.destroyMesh(&mesh);
        }
        _ = self.world.removeChunk(pos);
        self.markNeighboursDirty(pos);
    }

    fn unloadFar(self: *App, centre: ChunkPos) void {
        var to_remove: [1024]ChunkPos = undefined;
        var count: usize = 0;
        var it = self.world.chunks.keyIterator();
        while (it.next()) |key| {
            if (chunkInRange(centre, key.*, UNLOAD_RADIUS)) continue;
            if (count == to_remove.len) break;
            to_remove[count] = key.*;
            count += 1;
        }
        for (to_remove[0..count]) |pos| self.removeChunk(pos);
    }

    const WorkKind = enum { generate, mesh };

    /// Collects the `out.len` nearest chunks that need `kind` of work. Nearest
    /// first is what makes terrain appear under the player rather than behind.
    fn collectNearest(self: *App, centre: ChunkPos, kind: WorkKind, out: []ChunkPos) usize {
        var best: [8]f32 = undefined;
        for (&best) |*slot| slot.* = std.math.inf(f32);
        if (out.len > best.len) return 0;
        var count: usize = 0;

        var dy: i32 = 0;
        while (dy < coords.CHUNK_COUNT_Y) : (dy += 1) {
            var dz: i32 = -LOAD_RADIUS;
            while (dz <= LOAD_RADIUS) : (dz += 1) {
                var dx: i32 = -LOAD_RADIUS;
                while (dx <= LOAD_RADIUS) : (dx += 1) {
                    const pos = ChunkPos.init(centre.x + dx, dy, centre.z + dz);
                    if (!chunkInRange(centre, pos, LOAD_RADIUS)) continue;
                    switch (kind) {
                        .generate => if (self.world.isLoaded(pos)) continue,
                        .mesh => {
                            const chunk = self.world.getChunk(pos) orelse continue;
                            if (!chunk.needsMesh()) continue;
                        },
                    }
                    const distance = distanceSq(pos, centre);

                    // Insertion sort into the fixed best[] window.
                    if (count < out.len) {
                        var slot = count;
                        while (slot > 0 and best[slot - 1] > distance) : (slot -= 1) {
                            best[slot] = best[slot - 1];
                            out[slot] = out[slot - 1];
                        }
                        best[slot] = distance;
                        out[slot] = pos;
                        count += 1;
                    } else if (distance < best[out.len - 1]) {
                        var slot = out.len - 1;
                        while (slot > 0 and best[slot - 1] > distance) : (slot -= 1) {
                            best[slot] = best[slot - 1];
                            out[slot] = out[slot - 1];
                        }
                        best[slot] = distance;
                        out[slot] = pos;
                    }
                }
            }
        }
        return count;
    }

    fn streamChunks(self: *App) void {
        const centre = self.playerChunk();
        self.unloadFar(centre);

        var work: [8]ChunkPos = undefined;
        self.generated_this_frame = 0;
        const gen_count = self.collectNearest(centre, .generate, work[0..GEN_PER_FRAME]);
        for (work[0..gen_count]) |pos| {
            self.generateChunk(pos) catch |err| {
                std.debug.print("generate failed: {s}\n", .{@errorName(err)});
                continue;
            };
            self.generated_this_frame += 1;
        }

        self.meshed_this_frame = 0;
        const mesh_count = self.collectNearest(centre, .mesh, work[0..MESH_PER_FRAME]);
        for (work[0..mesh_count]) |pos| {
            self.ensureMesh(pos) catch |err| {
                std.debug.print("mesh failed: {s}\n", .{@errorName(err)});
                continue;
            };
            self.meshed_this_frame += 1;
            self.meshed_total += 1;
        }
    }

    fn ensureMesh(self: *App, pos: ChunkPos) !void {
        const chunk = self.world.getChunk(pos) orelse return;
        const entry = try self.meshes.getOrPut(self.allocator, pos);
        if (!entry.found_existing) entry.value_ptr.* = .{};

        if (terrain.chunkIsAir(self.seed, pos)) {
            self.chunk_renderer.destroyMesh(entry.value_ptr);
            chunk.state = .meshed;
            return;
        }

        while (true) {
            const stats = chunk_mesher.meshChunk(&self.world, pos, &self.padded, self.scratch_vertices, self.scratch_indices) catch |err| switch (err) {
                error.VertexBufferTooSmall => {
                    try self.growScratch();
                    continue;
                },
            };
            if (stats.quads == 0) {
                self.chunk_renderer.destroyMesh(entry.value_ptr);
            } else {
                const origin = pos.blockOrigin();
                self.chunk_renderer.upload(
                    entry.value_ptr,
                    Vec3.init(@floatFromInt(origin.x), @floatFromInt(origin.y), @floatFromInt(origin.z)),
                    self.scratch_vertices[0..stats.vertices],
                    self.scratch_indices[0..stats.indices],
                );
            }
            chunk.state = .meshed;
            return;
        }
    }

    /// Immediate rebuild for user edits: an edit dirties at most four chunks and
    /// the player expects to see it this frame, so this ignores the budget.
    fn remeshDirty(self: *App) void {
        var it = self.world.chunks.keyIterator();
        var dirty: [64]ChunkPos = undefined;
        var count: usize = 0;
        while (it.next()) |key| {
            const chunk = self.world.getChunk(key.*) orelse continue;
            if (!chunk.needsMesh()) continue;
            if (count == dirty.len) break;
            dirty[count] = key.*;
            count += 1;
        }
        for (dirty[0..count]) |pos| {
            self.ensureMesh(pos) catch |err| std.debug.print("remesh failed: {s}\n", .{@errorName(err)});
        }
        self.recount();
    }

    fn recount(self: *App) void {
        var quads: usize = 0;
        var meshed: usize = 0;
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| {
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
            if (self.input.shading_toggle) self.shading = !self.shading;
            if (self.input.fly_toggle) self.player.flying = !self.player.flying;

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

            self.streamChunks();

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
                self.recount();
                const seconds = @as(f64, @floatFromInt(report_dt_ns)) / 1e9;
                std.debug.print(
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  loaded {d} meshed {d} drawn {d} quads {d}  work gen {d} mesh {d}  pos ({d:.1},{d:.1},{d:.1}) {s}{s}\n",
                    .{
                        @as(f64, @floatFromInt(frames)) / seconds,
                        @as(f64, @floatFromInt(report_dt_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
                        worst_ms,
                        self.world.count(),
                        self.meshed_chunks,
                        drawn,
                        self.total_quads,
                        self.generated_total,
                        self.meshed_total,
                        self.player.position.x,
                        self.player.position.y,
                        self.player.position.z,
                        if (self.player.flying) "fly " else "walk ",
                        if (self.player.on_ground) "ground" else "air",
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

        self.camera.position = self.player.eyePosition();
        self.camera.yaw = self.player.yaw;
        self.camera.pitch = self.player.pitch;

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        self.chunk_renderer.begin(vp, &self.textures, self.shading);
        var drawn: usize = 0;
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| {
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
            var it2 = self.meshes.valueIterator();
            while (it2.next()) |mesh| {
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

test "streaming ranges are a cylinder with a one-ring hysteresis" {
    const centre = ChunkPos.init(10, 2, 10);
    try std.testing.expect(chunkInRange(centre, ChunkPos.init(10, 0, 10), LOAD_RADIUS));
    try std.testing.expect(chunkInRange(centre, ChunkPos.init(16, 3, 10), LOAD_RADIUS));
    try std.testing.expect(!chunkInRange(centre, ChunkPos.init(17, 2, 10), LOAD_RADIUS));
    try std.testing.expect(!chunkInRange(centre, ChunkPos.init(11, 2, 17), LOAD_RADIUS));
    // Unload radius keeps a chunk that just left the load radius.
    try std.testing.expect(chunkInRange(centre, ChunkPos.init(17, 2, 10), UNLOAD_RADIUS));
    try std.testing.expect(!chunkInRange(centre, ChunkPos.init(18, 2, 10), UNLOAD_RADIUS));
    // Outside the world height is never in range.
    try std.testing.expect(!chunkInRange(centre, ChunkPos.init(10, -1, 10), LOAD_RADIUS));
    try std.testing.expect(!chunkInRange(centre, ChunkPos.init(10, 4, 10), LOAD_RADIUS));
}
