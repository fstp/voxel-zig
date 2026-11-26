const std = @import("std");
const sdl = @import("sdl3");
const Window = @import("gfx/window.zig").Window;
const gl = @import("gfx/gl.zig");
const DebugDraw = @import("gfx/debug_draw.zig").DebugDraw;
const Input = @import("input.zig").Input;
const Camera = @import("camera.zig").Camera;
const TextureArray = @import("gfx/texture.zig").TextureArray;
const ChunkRenderer = @import("gfx/chunk_renderer.zig").ChunkRenderer;
const Hud = @import("gfx/hud.zig").Hud;
const Frustum = @import("math/frustum.zig").Frustum;
const Aabb = @import("math/aabb.zig").Aabb;
const Vec3 = @import("math/vec.zig").Vec3;
const Mat4 = @import("math/mat4.zig").Mat4;
const World = @import("world/world.zig").World;
const chunk_mesher = @import("world/chunk_mesher.zig");
const mesher = @import("voxel/mesher.zig");
const terrain = @import("world/terrain.zig");
const save = @import("world/save.zig");
const brush = @import("world/brush.zig");
const undo_mod = @import("world/undo.zig");
const sun_mod = @import("world/sun.zig");
const physics = @import("physics/bodies.zig");
const BlockRenderer = @import("gfx/block_renderer.zig").BlockRenderer;
const net = @import("net/udp.zig");
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
    /// 2.1: greedy meshing on by default; the naive mesher stays for comparison.
    greedy: bool = true,
    /// 2.4 spike: 0 disables networking. Otherwise this is the UDP port to bind.
    net_port: u16 = 0,
    /// "ip:port" of the other side; the peer is learned from the first packet if
    /// this is null.
    net_peer: ?[]const u8 = null,
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
pub const SAVE_PATH = "world.vxz";
/// 2.3: how many thrown boxes the toy allocates room for.
pub const MAX_BODIES: usize = 96;
/// Boxes spawned per press of G.
pub const THROW_BATCH: usize = 50;
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

/// 1.13: generation runs on the io pool. A job owns its own 32 KB block buffer,
/// so the worker never touches the world map (ADR 0006's ownership rule); the
/// main thread inserts the finished buffer. Meshing stays on the main thread -
/// it reads nine chunks at once, and copying those for a worker costs more than
/// the 52 us the mesh itself takes.
pub const JOBS_PER_FRAME: usize = 4;

pub const GenerateJob = struct {
    pos: ChunkPos,
    seed: u32,
    /// Player chunk when the job was submitted, used to drop stale results.
    origin_centre: ChunkPos,
    blocks: [coords.CHUNK_VOLUME]block.BlockId = undefined,
    done: bool = false,
};

fn runGenerateJob(job: *GenerateJob) void {
    terrain.generateInto(&job.blocks, job.pos, job.seed);
    job.done = true;
}

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
    jobs: [JOBS_PER_FRAME]GenerateJob = @splat(.{ .pos = ChunkPos.init(0, 0, 0), .seed = 0, .origin_centre = ChunkPos.init(0, 0, 0) }),
    jobs_run: usize = 0,
    jobs_dropped: usize = 0,
    seed: u32,
    greedy: bool,
    saved: save.Loaded,
    save_path: []const u8 = SAVE_PATH,
    show_wire: bool = false,
    shading: bool = true,
    show_normals: bool = false,
    sun: sun_mod.Sun = sun_mod.Sun.init(),
    hud: Hud,
    show_hud: bool = true,
    t_stream_ms: f64 = 0,
    t_draw_ms: f64 = 0,
    t_hud_ms: f64 = 0,
    frame_ms: f64 = 0,
    worst_frame_ms: f64 = 0,
    highlight: ?raycast.Hit = null,
    selected: block.BlockId = .stone,
    edits: usize = 0,
    undo: undo_mod.Undo,
    block_renderer: BlockRenderer,
    bodies: physics.Bodies,
    body_items: []physics.Body,
    rng: u32 = 0x1234_5678,
    peer: ?net.Peer = null,
    remote_position: ?Vec3 = null,
    remote_yaw: f32 = 0,
    net_accumulator: f32 = 0,
    edit_seq: u32 = 0,
    remote_seq_seen: u32 = 0,
    edits_sent: usize = 0,
    edits_received: usize = 0,
    brush_mode: ?brush.Mode = null,
    brush_radius: i32 = 3,
    last_stroke_blocks: usize = 0,
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

        var hud = try Hud.init();
        errdefer hud.deinit();

        // 2.3: single-block renderer reused for the physics toys.
        var block_renderer = try BlockRenderer.init();
        errdefer block_renderer.deinit();

        gl.gl.Enable(gl.gl.DEPTH_TEST);
        gl.gl.Enable(gl.gl.CULL_FACE);
        gl.gl.CullFace(gl.gl.BACK);
        gl.gl.FrontFace(gl.gl.CCW);

        var input = Input.init();
        input.setRelativeMouse(&window, true);

        // 1.14: edits survive a restart. A missing file is a fresh world, and a
        // saved chunk is never regenerated over.
        const load_start = std.Io.Timestamp.now(io, .awake);
        var saved = try save.load(gpa, io, SAVE_PATH);
        errdefer saved.deinit();
        const load_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).nanoseconds - load_start.nanoseconds)) / 1e6;
        std.debug.print("save: {d} edited chunks loaded in {d:.2} ms from {s}\n", .{ saved.count(), load_ms, SAVE_PATH });

        const spawn_x: i32 = 144;
        const spawn_z: i32 = 144;
        const surface = terrain.heightAt(config.seed, spawn_x, spawn_z);

        var peer: ?net.Peer = null;
        if (config.net_port != 0) {
            peer = try net.Peer.init(io, config.net_port);
            if (config.net_peer) |text| {
                if (parseAddress(text)) |address| peer.?.setRemote(address);
            }
            std.debug.print("net: listening on udp {d}{s}\n", .{
                peer.?.port,
                if (peer.?.remote != null) " with a known peer" else ", peer learned from traffic",
            });
        }
        errdefer if (peer) |*p| p.deinit(io);

        var app = App{
            .io = io,
            .window = window,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .camera = .{ .fov_y_deg = 70, .near = 0.1, .far = 1000 },
            .player = .{
                .position = if (saved.count() > 0) saved.player else Vec3.init(@floatFromInt(spawn_x), @floatFromInt(surface + 3), @floatFromInt(spawn_z)),
                .yaw = 0,
                .pitch = -0.2,
            },
            .input = input,
            .debug = debug,
            .textures = textures,
            .seed = config.seed,
            .greedy = config.greedy,
            .saved = saved,
            .world = world,
            .chunk_renderer = chunk_renderer,
            .hud = hud,
            .meshes = .{},
            .undo = undo_mod.Undo.init(gpa),
            .block_renderer = block_renderer,
            .bodies = undefined,
            .peer = peer,
            .body_items = try gpa.alloc(physics.Body, MAX_BODIES),
            .scratch_vertices = try gpa.alloc(mesher.Vertex, INITIAL_QUAD_CAPACITY * 4),
            .scratch_indices = try gpa.alloc(u32, INITIAL_QUAD_CAPACITY * 6),
            .padded = mesher.PaddedBlocks.init(),
            .allocator = gpa,
        };
        errdefer {
            gpa.free(app.scratch_vertices);
            gpa.free(app.scratch_indices);
        }
        // The body list needs the allocation above to exist first.
        app.bodies = physics.Bodies.init(app.body_items);

        const start = std.Io.Timestamp.now(io, .awake);
        try app.preload();
        const preload_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds)) / 1e6;
        std.debug.print(
            "preload: {d} chunks generated, {d} meshed in {d:.1} ms (seed 0x{X}, spawn y {d})\n",
            .{ app.world.count(), app.meshed_chunks, preload_ms, app.seed, surface + 3 },
        );
        return app;
    }

    fn saveWorld(self: *App) void {
        const start = std.Io.Timestamp.now(self.io, .awake);
        const stats = save.save(self.allocator, self.io, self.save_path, &self.world, self.seed, self.player.position, &self.saved.chunks) catch |err| {
            std.debug.print("save failed: {s}\n", .{@errorName(err)});
            return;
        };
        const ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds)) / 1e6;
        std.debug.print(
            "save: wrote {d} chunks, {d} KB raw -> {d} KB packed ({d:.1}x) in {d:.2} ms to {s}\n",
            .{ stats.chunks, stats.raw_bytes / 1024, stats.packed_bytes / 1024, stats.ratio(), ms, self.save_path },
        );
    }

    pub fn deinit(self: *App) void {
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| self.chunk_renderer.destroyMesh(mesh);
        self.meshes.deinit(self.allocator);
        self.allocator.free(self.scratch_vertices);
        self.allocator.free(self.scratch_indices);
        if (self.peer) |*p| p.deinit(self.io);
        self.undo.deinit();
        self.block_renderer.deinit();
        self.allocator.free(self.body_items);
        self.hud.deinit();
        self.chunk_renderer.deinit();
        self.saved.deinit();
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
        if (self.saved.savedBlocks(pos)) |blocks| {
            chunk.blocks = blocks.*;
            chunk.state = .ready;
            chunk.revision +%= 1;
            chunk.edited = true;
        } else {
            terrain.generateChunk(chunk, self.seed);
        }
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
        // An edited chunk must outlive its unload or the edit is lost when the
        // player flies away before quitting.
        if (self.world.getChunk(pos)) |chunk| {
            if (chunk.edited) self.saved.rememberBlocks(pos, &chunk.blocks) catch {};
        }
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

        // 1.13: the nearest missing chunks go to the io pool, and the finished
        // block buffers are inserted here on the main thread. Bounded by the
        // pool size, so a frame never waits on more than JOBS_PER_FRAME jobs.
        const gen_count = self.collectNearest(centre, .generate, work[0..JOBS_PER_FRAME]);
        if (gen_count > 0) {
            for (work[0..gen_count], 0..) |pos, index| {
                self.jobs[index] = .{ .pos = pos, .seed = self.seed, .origin_centre = centre };
            }
            var group: std.Io.Group = .init;
            for (self.jobs[0..gen_count]) |*job| group.async(self.io, runGenerateJob, .{job});
            group.await(self.io) catch {};
            self.jobs_run += gen_count;

            for (self.jobs[0..gen_count]) |job| {
                if (!job.done) continue;
                // Stale result: the player has moved out of range since this job
                // was queued, so inserting it would only be unloaded again.
                if (!chunkInRange(self.playerChunk(), job.pos, UNLOAD_RADIUS)) {
                    self.jobs_dropped += 1;
                    continue;
                }
                if (self.world.isLoaded(job.pos)) continue;
                const chunk = self.world.getOrCreateChunk(job.pos) catch continue;
                // A saved chunk wins over the freshly generated one: the world
                // must come back exactly as it was left.
                if (self.saved.savedBlocks(job.pos)) |blocks| {
                    chunk.blocks = blocks.*;
                    chunk.edited = true;
                } else {
                    chunk.blocks = job.blocks;
                }
                chunk.state = .ready;
                chunk.revision +%= 1;
                self.markNeighboursDirty(job.pos);
                self.generated_this_frame += 1;
                self.generated_total += 1;
            }
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
            const stats = chunk_mesher.meshChunk(&self.world, pos, &self.padded, self.scratch_vertices, self.scratch_indices, self.greedy) catch |err| switch (err) {
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

    /// Vertical axis for fly mode: +1 for Space, -1 for Ctrl, 0 for neither.
    ///
    /// Signed on purpose. The obvious `@intFromBool(space) - @intFromBool(ctrl)`
    /// infers u1 for both operands, and `0 - 1` in u1 is an integer overflow: the
    /// game aborted the first time Ctrl was pressed without Space.
    pub fn verticalAxis(space: bool, ctrl: bool) i8 {
        return @as(i8, @intFromBool(space)) - @as(i8, @intFromBool(ctrl));
    }

    fn simulate(self: *App, dt: f64) void {
        const up: f32 = @floatFromInt(verticalAxis(
            self.input.down(sdl.SDL_SCANCODE_SPACE),
            self.input.down(sdl.SDL_SCANCODE_LCTRL),
        ));
        const sprint = self.input.down(sdl.SDL_SCANCODE_LSHIFT);
        self.player.update(&self.world, @floatCast(dt), self.wishVector(), up, sprint);
        self.bodies.step(&self.world, @floatCast(dt));
        self.sun.update(@floatCast(dt));
        self.stepNetwork(@floatCast(dt));
    }

    /// 2.4: positions go out at POSITION_INTERVAL, edits go out as they happen.
    /// Incoming edits are applied with a sequence check so a duplicated datagram
    /// cannot re-apply a stale block.
    fn stepNetwork(self: *App, dt: f32) void {
        const peer = if (self.peer) |*p| p else return;

        self.net_accumulator += dt;
        if (self.net_accumulator >= net.POSITION_INTERVAL) {
            self.net_accumulator = 0;
            peer.send(self.io, .{ .position = .{
                .ids = 1,
                .x = self.player.position.x,
                .y = self.player.position.y,
                .z = self.player.position.z,
                .yaw = self.player.yaw,
            } });
        }

        var message: net.Message = undefined;
        var budget: usize = 8;
        while (budget > 0 and peer.receive(self.io, &message)) : (budget -= 1) {
            switch (message) {
                .position => |position| {
                    self.remote_position = Vec3.init(position.x, position.y, position.z);
                    self.remote_yaw = position.yaw;
                },
                .edit => |edit| {
                    if (edit.seq <= self.remote_seq_seen) continue;
                    self.remote_seq_seen = edit.seq;
                    const block_id: block.BlockId = @enumFromInt(edit.block);
                    if (self.world.setBlock(edit.x, edit.y, edit.z, block_id)) {
                        self.edits_received += 1;
                        std.debug.print("net: applied edit {d} at ({d},{d},{d}) -> {d}\n", .{ edit.seq, edit.x, edit.y, edit.z, edit.block });
                        self.remeshDirty();
                    }
                },
            }
        }
    }

    fn sendEdit(self: *App, pos: BlockPos, block_id: block.BlockId) void {
        const peer = if (self.peer) |*p| p else return;
        self.edit_seq += 1;
        peer.send(self.io, .{ .edit = .{ .seq = self.edit_seq, .x = pos.x, .y = pos.y, .z = pos.z, .block = @intFromEnum(block_id) } });
        self.edits_sent += 1;
        std.debug.print("net: sent edit {d} at ({d},{d},{d}) -> {d}\n", .{ self.edit_seq, pos.x, pos.y, pos.z, @intFromEnum(block_id) });
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
            if (self.input.save_toggle) self.saveWorld();

            const now = std.Io.Timestamp.now(self.io, .awake);
            const dt_ns = now.nanoseconds - last.nanoseconds;
            last = now;
            const dt = @as(f64, @floatFromInt(dt_ns)) / 1e9;

            if (self.input.debug_toggle) self.show_wire = !self.show_wire;
            if (self.input.shading_toggle) self.shading = !self.shading;
            if (self.input.normals_toggle) self.show_normals = !self.show_normals;
            if (self.input.pause_time) self.sun.togglePaused();
            if (self.input.time_scrub != 0) {
                const delta = @as(f32, @floatFromInt(self.input.time_scrub)) * 0.01;
                self.sun.setTime(self.sun.time + delta);
            }
            if (self.input.time_jump) |t| {
                self.sun.setTime(t);
                self.sun.paused = true;
            }
            if (self.input.hud_toggle) self.show_hud = !self.show_hud;
            if (self.input.brush_cycle) self.cycleBrush();
            if (self.input.throw_pressed) self.throwBoxes(THROW_BATCH);
            if (self.input.radius_delta != 0) {
                self.brush_radius = std.math.clamp(self.brush_radius + self.input.radius_delta, 1, 12);
            }
            if (self.input.undo_pressed) {
                const reverted = self.undo.undo(&self.world);
                std.debug.print("undo: {d} blocks reverted (cursor {d}/{d})\n", .{ reverted, self.undo.cursor, self.undo.len });
                if (reverted > 0) self.remeshDirty();
            }
            if (self.input.redo_pressed) {
                const reapplied = self.undo.redo(&self.world);
                std.debug.print("redo: {d} blocks re-applied (cursor {d}/{d})\n", .{ reapplied, self.undo.cursor, self.undo.len });
                if (reapplied > 0) self.remeshDirty();
            }
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

            const stream_start = std.Io.Timestamp.now(self.io, .awake);
            self.streamChunks();
            self.t_stream_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(self.io, .awake).nanoseconds - stream_start.nanoseconds)) / 1e6;

            self.updateHighlight();
            if (self.input.primary_click) {
                if (self.brush_mode) |mode| self.applyBrush(mode) else self.breakBlock();
            }
            if (self.input.secondary_click) self.placeBlock();
            if (self.input.middle_click) self.pickBlock();
            self.input.endFrame();

            _ = self.frame_arena.reset(.retain_capacity);
            const draw_start = std.Io.Timestamp.now(self.io, .awake);
            drawn = self.render();
            self.t_draw_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(self.io, .awake).nanoseconds - draw_start.nanoseconds)) / 1e6;
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
            self.frame_ms = frame_ms;
            self.worst_frame_ms = worst_ms;

            const report_dt_ns = now.nanoseconds - report_at.nanoseconds;
            if (report_dt_ns >= std.time.ns_per_s) {
                self.recount();
                const seconds = @as(f64, @floatFromInt(report_dt_ns)) / 1e9;
                std.debug.print(
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  loaded {d} meshed {d} drawn {d} quads {d}  jobs {d} boxes {d}  sun t{d:.3} el {d:5.1} az {d:6.1} day {d:.2}{s}  pos ({d:.1},{d:.1},{d:.1}) {s}{s}\n",
                    .{
                        @as(f64, @floatFromInt(frames)) / seconds,
                        @as(f64, @floatFromInt(report_dt_ns)) / 1e6 / @as(f64, @floatFromInt(frames)),
                        worst_ms,
                        self.world.count(),
                        self.meshed_chunks,
                        drawn,
                        self.total_quads,
                        self.jobs_run,
                        self.bodies.count,
                        self.sun.time,
                        self.sun.elevation(),
                        self.sun.azimuth(),
                        self.sun.daylight(),
                        if (self.sun.paused) " PAUSED" else "",
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

        // Save on exit so a restart resumes the edited chunks.
        self.saveWorld();
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

    /// B cycles: off -> lower -> raise -> smooth -> box -> off.
    fn cycleBrush(self: *App) void {
        self.brush_mode = if (self.brush_mode) |mode| switch (mode) {
            .lower => .raise,
            .raise => .smooth,
            .smooth => .box_fill,
            .box_fill => null,
        } else .lower;
    }

    fn applyBrush(self: *App, mode: brush.Mode) void {
        const hit = self.highlight orelse return;
        // Build outward from the face for the fill modes, inward for carving.
        const centre = switch (mode) {
            .raise, .box_fill => BlockPos.init(
                hit.block.x + hit.normal[0],
                hit.block.y + hit.normal[1],
                hit.block.z + hit.normal[2],
            ),
            else => hit.block,
        };
        const stroke = brush.apply(self.allocator, &self.world, centre, self.brush_radius, mode, self.selected) catch |err| {
            std.debug.print("brush failed: {s}\n", .{@errorName(err)});
            return;
        };
        self.last_stroke_blocks = stroke.changes.len;
        std.debug.print("brush {s} r{d}: {d} blocks at ({d},{d},{d})\n", .{ @tagName(mode), self.brush_radius, stroke.changes.len, centre.x, centre.y, centre.z });
        if (stroke.changes.len == 0) {
            stroke.deinit(self.allocator);
            return;
        }
        self.undo.push(stroke.changes) catch {
            stroke.deinit(self.allocator);
            return;
        };
        self.edits += 1;
        self.remeshDirty();
    }

    /// G spawns a batch of boxes in front of the player, with a little spread so
    /// they tumble rather than falling as a column.
    fn throwBoxes(self: *App, count: usize) void {
        const eye = self.player.eyePosition();
        const forward = self.player.forward();
        const base = eye.add(forward.scale(3));

        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.rng = self.rng *% 1664525 +% 1013904223;
            const r1: f32 = @floatFromInt(self.rng >> 24);
            self.rng = self.rng *% 1664525 +% 1013904223;
            const r2: f32 = @floatFromInt(self.rng >> 24);
            self.rng = self.rng *% 1664525 +% 1013904223;
            const r3: f32 = @floatFromInt(self.rng >> 24);

            const half: f32 = 0.3 + (r1 / 255.0) * 0.3;
            const position = Vec3.init(
                base.x + (r2 / 255.0 - 0.5) * 6.0,
                base.y + (r3 / 255.0) * 4.0,
                base.z + (r1 / 255.0 - 0.5) * 6.0,
            );
            const velocity = Vec3.init(
                forward.x * 8.0 + (r2 / 255.0 - 0.5) * 4.0,
                2.0 + (r3 / 255.0) * 4.0,
                forward.z * 8.0 + (r3 / 255.0 - 0.5) * 4.0,
            );
            _ = self.bodies.spawn(position, Vec3.init(half, half, half), velocity);
        }
    }

    fn breakBlock(self: *App) void {
        const hit = self.highlight orelse return;
        if (self.world.setBlock(hit.block.x, hit.block.y, hit.block.z, .air)) {
            self.edits += 1;
            self.sendEdit(hit.block, .air);
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
            self.sendEdit(target, self.selected);
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
        // Until the sky pass lands (3.6), the clear colour is the sun's horizon
        // colour. Note this is an sRGB value and the pipeline is not sRGB yet;
        // 3.5 turns on FRAMEBUFFER_SRGB and must revisit this line.
        const horizon = sun_mod.toSrgb(self.sun.ramp().horizon);
        gl.gl.ClearColor(horizon.x, horizon.y, horizon.z, 1.0);
        gl.gl.Clear(gl.gl.COLOR_BUFFER_BIT | gl.gl.DEPTH_BUFFER_BIT);

        self.camera.position = self.player.eyePosition();
        self.camera.yaw = self.player.yaw;
        self.camera.pitch = self.player.pitch;

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        self.chunk_renderer.begin(vp, &self.textures, self.shading, self.show_normals);
        var drawn: usize = 0;
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| {
            if (mesh.index_count == 0) continue;
            if (!frustum.containsAabb(mesh.bounds)) continue;
            drawn += 1;
            self.chunk_renderer.draw(mesh);
        }

        if (self.remote_position) |remote| {
            // The other player is a floating cube for now: enough to see them move.
            self.block_renderer.begin(vp, &self.textures);
            self.block_renderer.draw(.sand, Vec3.init(remote.x, remote.y + 0.9, remote.z), 1.6, Mat4.identity);
        }

        if (self.bodies.count > 0) {
            self.block_renderer.begin(vp, &self.textures);
            for (self.bodies.items[0..self.bodies.count]) |body| {
                const size = body.half.x * 2.0;
                self.block_renderer.draw(.wood, body.position, size, Mat4.identity);
            }
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

        if (self.show_hud) {
            const hud_start = std.Io.Timestamp.now(self.io, .awake);
            self.drawHud(drawn);
            self.t_hud_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(self.io, .awake).nanoseconds - hud_start.nanoseconds)) / 1e6;
        }
        return drawn;
    }

    /// 1.15 overlay: fps, frame time, chunk and geometry counts, the streaming
    /// and draw timings, a rough memory figure and the player's position.
    fn drawHud(self: *App, drawn: usize) void {
        self.hud.begin(self.window.width, self.window.height);
        self.hud.scale = 2.0;

        const world_mb = @as(f64, @floatFromInt(self.world.count())) * @as(f64, @floatFromInt(coords.CHUNK_VOLUME)) / (1024.0 * 1024.0);
        const mesh_mb = @as(f64, @floatFromInt(self.total_quads)) * 120.0 / (1024.0 * 1024.0);

        var buffer: [128]u8 = undefined;
        var line: usize = 0;

        self.hud.setColour(1.0, 1.0, 0.6);
        if (std.fmt.bufPrint(&buffer, "FPS {d:.1}", .{if (self.frame_ms > 0) 1000.0 / self.frame_ms else 0})) |text| {
            self.hud.text(10, 8, text);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "FRAME {d:.2} MS  WORST {d:.2} MS", .{ self.frame_ms, self.worst_frame_ms })) |text| {
            self.hud.text(10, 26, text);
        } else |_| {}
        line = 2;

        const counts = std.fmt.bufPrint(&buffer, "CHUNKS {d} LOADED {d} MESHED {d} DRAWN", .{ self.world.count(), self.meshed_chunks, drawn }) catch "";
        self.hud.setColour(0.85, 0.95, 1.0);
        self.hud.text(10, 8 + @as(f32, @floatFromInt(line)) * 18, counts);
        line += 1;

        const geometry = std.fmt.bufPrint(&buffer, "QUADS {d} TRIS {d}", .{ self.total_quads, self.total_quads * 2 }) catch "";
        self.hud.text(10, 8 + @as(f32, @floatFromInt(line)) * 18, geometry);
        line += 1;

        const mem = std.fmt.bufPrint(&buffer, "MEM WORLD {d:.1}MB MESH {d:.1}MB JOBS {d}", .{ world_mb, mesh_mb, self.jobs_run }) catch "";
        self.hud.text(10, 8 + @as(f32, @floatFromInt(line)) * 18, mem);
        line += 1;

        const timings = std.fmt.bufPrint(&buffer, "STREAM {d:.2} DRAW {d:.2} HUD {d:.2} MS", .{ self.t_stream_ms, self.t_draw_ms, self.t_hud_ms }) catch "";
        self.hud.setColour(0.7, 1.0, 0.7);
        self.hud.text(10, 8 + @as(f32, @floatFromInt(line)) * 18, timings);
        line += 1;

        const where = std.fmt.bufPrint(&buffer, "POS {d:.1} {d:.1} {d:.1} {s}{s}", .{
            self.player.position.x,
            self.player.position.y,
            self.player.position.z,
            if (self.player.flying) "FLY " else "WALK ",
            if (self.player.on_ground) "GROUND" else "AIR",
        }) catch "";
        self.hud.setColour(0.8, 0.8, 0.8);
        self.hud.text(10, 8 + @as(f32, @floatFromInt(line)) * 18, where);
        line += 1;

        if (self.peer != null) {
            var peer_line: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&peer_line, "NET PORT {d} REMOTE {d:.1} {d:.1} {d:.1} SENT {d} RECV {d}", .{
                self.peer.?.port,
                if (self.remote_position) |r| r.x else 0,
                if (self.remote_position) |r| r.y else 0,
                if (self.remote_position) |r| r.z else 0,
                self.edits_sent,
                self.edits_received,
            }) catch "";
            self.hud.setColour(0.6, 1.0, 1.0);
            self.hud.text(10, @as(f32, @floatFromInt(self.window.height)) - 44, text);
        }

        {
            const hours = self.sun.clockHours();
            const whole: u32 = @intFromFloat(hours);
            const minutes: u32 = @intFromFloat((hours - @as(f32, @floatFromInt(whole))) * 60.0);
            var sun_line: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&sun_line, "SUN {d:0>2}:{d:0>2}  el {d:5.1}  az {d:5.1}  day {d:.2}  cycle {d}s{s}", .{
                whole,
                minutes,
                self.sun.elevation(),
                self.sun.azimuth(),
                self.sun.daylight(),
                @as(u32, @intFromFloat(self.sun.cycle_seconds)),
                if (self.sun.paused) "  PAUSED" else "",
            }) catch "";
            self.hud.setColour(0.95, 0.9, 0.6);
            self.hud.text(10, @as(f32, @floatFromInt(self.window.height)) - 66, text);
        }

        const keys = "F1 HUD  F FLY  F3 BOXES  F4 SHADING  F6 NORMALS  P PAUSE SUN  1-4 TIMES";
        self.hud.setColour(0.6, 0.6, 0.6);
        self.hud.text(10, @as(f32, @floatFromInt(self.window.height)) - 22, keys);

        self.hud.end();
    }
};

/// "ip:port" into an IpAddress, or null when it does not parse.
fn parseAddress(text: []const u8) ?std.Io.net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const host = text[0..colon];
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return .{ .ip4 = .{ .bytes = octets, .port = port } };
}

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

test "vertical axis is signed: ctrl alone is -1, not an overflow" {
    try std.testing.expectEqual(@as(i8, 1), App.verticalAxis(true, false));
    try std.testing.expectEqual(@as(i8, -1), App.verticalAxis(false, true));
    try std.testing.expectEqual(@as(i8, 0), App.verticalAxis(true, true));
    try std.testing.expectEqual(@as(i8, 0), App.verticalAxis(false, false));
}
