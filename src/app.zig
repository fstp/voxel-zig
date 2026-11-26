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
const SkyRenderer = @import("gfx/sky_renderer.zig").SkyRenderer;
const ShadowRenderer = @import("gfx/shadow_renderer.zig").ShadowRenderer;
const Post = @import("gfx/post.zig").Post;
const EnvProbe = @import("gfx/env_probe.zig").EnvProbe;
const Ssao = @import("gfx/ssao.zig").Ssao;
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
    /// "azimuth,elevation" from VOXEL_SUN (3.10). Invalid specs are rejected with
    /// a warning on screen and in the log, never silently corrected.
    sun_spec: ?[]const u8 = null,
    /// Starting scene exposure from VOXEL_EXPOSURE (4.1); null keeps the default.
    exposure: ?f32 = null,
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
    /// 4.7: material maps, same layers as `textures`.
    normal_textures: TextureArray,
    rough_textures: TextureArray,
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
    legacy_lighting: bool = false,
    show_normals: bool = false,
    fog_enabled: bool = true,
    /// Seconds left to show a rejected --sun spec, and the message itself.
    sun_warning_seconds: f32 = 0,
    sun_warning: ?[]const u8 = null,
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
    sky_renderer: SkyRenderer,
    shadow_renderer: ShadowRenderer,
    /// 4.1: HDR target plus the tone-map resolve.
    post: Post,
    /// 4.4: sky cube map the materials reflect.
    env_probe: EnvProbe,
    /// 4.9: screen-space ambient occlusion.
    ssao: Ssao,
    shadows_enabled: bool = true,
    soft_shadows: bool = true,
    clouds_enabled: bool = true,
    /// Wind offset in cloud space, advanced on the fixed step (3.11).
    cloud_shift: Vec3 = Vec3.init(0, 0, 0),
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

        // Albedo is colour (sRGB); the material maps are data and must not be
        // gamma-decoded on the way in.
        var textures = try TextureArray.init(&block.texture_paths, block.TEXTURE_SIZE, true);
        errdefer textures.deinit();
        var normal_textures = try TextureArray.init(&block.normal_paths, block.TEXTURE_SIZE, false);
        errdefer normal_textures.deinit();
        var rough_textures = try TextureArray.init(&block.rough_paths, block.TEXTURE_SIZE, false);
        errdefer rough_textures.deinit();
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

        // 3.6: the procedural sky, drawn before everything else.
        var sky_renderer = try SkyRenderer.init();
        errdefer sky_renderer.deinit();

        // 3.8: the sun's depth map.
        var shadow_renderer = try ShadowRenderer.init();
        errdefer shadow_renderer.deinit();

        // 4.1: linear light into a half-float target, tone mapped on the way out.
        var post = try Post.init(window.width, window.height);
        errdefer post.deinit();

        // 4.4: the sky, as a cube map for reflections.
        var env_probe = try EnvProbe.init();
        errdefer env_probe.deinit();

        var ssao = try Ssao.init(window.width, window.height);
        errdefer ssao.deinit();
        // 4.1: VOXEL_EXPOSURE pins the starting exposure for screenshots.
        if (config.exposure) |value| {
            post.exposure_base = std.math.clamp(value, 0.05, 8.0);
            post.exposure = post.exposure_base;
            std.debug.print("exposure: {d:.3} from VOXEL_EXPOSURE\n", .{post.exposure_base});
        }

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

        var app_sun = sun_mod.Sun.init();
        var warning: ?[]const u8 = null;
        var warning_seconds: f32 = 0;
        if (config.sun_spec) |spec| {
            if (sun_mod.parseSunSpec(spec)) |parsed| {
                app_sun.pin(parsed.azimuth, parsed.elevation);
                std.debug.print("sun: pinned at az {d:.1} el {d:.1} from VOXEL_SUN\n", .{ parsed.azimuth, parsed.elevation });
            } else |err| {
                warning = switch (err) {
                    error.ElevationOutOfRange => "SUN SPEC REJECTED: elevation must be -90..90",
                    error.NotFinite => "SUN SPEC REJECTED: not a finite number",
                    error.Malformed => "SUN SPEC REJECTED: expected \"azimuth,elevation\"",
                };
                warning_seconds = 8;
                std.debug.print("sun: {s} (got {s})\n", .{ warning.?, spec });
            }
        }

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
            .normal_textures = normal_textures,
            .rough_textures = rough_textures,
            .seed = config.seed,
            .greedy = config.greedy,
            .saved = saved,
            .world = world,
            .chunk_renderer = chunk_renderer,
            .hud = hud,
            .meshes = .{},
            .undo = undo_mod.Undo.init(gpa),
            .block_renderer = block_renderer,
            .sky_renderer = sky_renderer,
            .shadow_renderer = shadow_renderer,
            .post = post,
            .env_probe = env_probe,
            .ssao = ssao,
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
        // The sun field has a default, so the literal above does not mention it;
        // this is what carries VOXEL_SUN's pinned angle into the running app.
        app.sun = app_sun;

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
        self.sky_renderer.deinit();
        self.shadow_renderer.deinit();
        self.post.deinit();
        self.env_probe.deinit();
        self.ssao.deinit();
        self.allocator.free(self.body_items);
        self.hud.deinit();
        self.chunk_renderer.deinit();
        self.saved.deinit();
        self.world.deinit();
        self.textures.deinit();
        self.normal_textures.deinit();
        self.rough_textures.deinit();
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
        // 4.3: eye adaptation. The exposure control and the ACES toe together
        // left night at p95 = 4/255 - technically visible, practically black.
        // Night gets up to 6x the exposure; daylight is untouched (daylight()
        // reaches 1.0 by -6 degrees, so dawn and dusk keep their look).
        const adaptation = 1.0 + 5.0 * (1.0 - self.sun.daylight());
        self.post.exposure = self.post.exposure_base * adaptation;
        // Clouds drift east at about 6 blocks a second: slow enough to read as
        // weather, fast enough to notice over a minute.
        self.cloud_shift = self.cloud_shift.add(Vec3.init(6.0 * @as(f32, @floatCast(dt)) * 0.01, 0, 0));
        if (self.sun_warning_seconds > 0) self.sun_warning_seconds -= @floatCast(dt);
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
            if (self.input.shading_toggle) self.legacy_lighting = !self.legacy_lighting;
            if (self.input.normals_toggle) self.show_normals = !self.show_normals;
            if (self.input.fog_toggle) self.fog_enabled = !self.fog_enabled;
            if (self.input.shadows_toggle) self.shadows_enabled = !self.shadows_enabled;
            if (self.input.soft_shadows_toggle) self.soft_shadows = !self.soft_shadows;
            if (self.input.clouds_toggle) self.clouds_enabled = !self.clouds_enabled;
            if (self.input.tonemap_toggle) self.post.tonemap = !self.post.tonemap;
            if (self.input.ssao_toggle) self.ssao.enabled = !self.ssao.enabled;
            if (self.input.fxaa_toggle) self.post.fxaa = !self.post.fxaa;
            // 4.1: exposure in 1/8-stop-ish steps, clamped so a held key cannot
            // drive the image to black or to white.
            if (self.input.exposure_down) self.post.exposure_base = @max(0.10, self.post.exposure_base * 0.92);
            if (self.input.exposure_up) self.post.exposure_base = @min(4.00, self.post.exposure_base * 1.08);
            if (self.input.sun_pin_toggle) {
                if (self.sun.mode == .pinned) {
                    self.sun.unpin();
                } else {
                    // Seed from the current cycle angle so pinning does not jump.
                    self.sun.pin(self.sun.azimuth(), self.sun.elevation());
                }
            }
            if (self.input.sun_azimuth_delta != 0 or self.input.sun_elevation_delta != 0) {
                self.sun.nudge(self.input.sun_azimuth_delta, self.input.sun_elevation_delta);
            }
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
                    "fps {d:6.1} frame {d:5.2}ms worst {d:5.2}ms  loaded {d} meshed {d} drawn {d} quads {d}  jobs {d} boxes {d}  sky {d:.3} shdw {d:.3} ssao {d:.3} post {d:.3}  sun t{d:.3} el {d:5.1} az {d:6.1} day {d:.2}{s}  yaw {d:5.2} pitch {d:5.2}  pos ({d:.1},{d:.1},{d:.1}) {s}{s}\n",
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
                        self.sky_renderer.last_ms,
                        self.shadow_renderer.last_ms,
                        self.ssao.last_ms,
                        self.post.last_ms,
                        self.sun.time,
                        self.sun.elevation(),
                        self.sun.azimuth(),
                        self.sun.daylight(),
                        if (self.sun.paused) " PAUSED" else "",
                        self.player.yaw,
                        self.player.pitch,
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
        // ADR 0008: the framebuffer is sRGB, so every fragment the shaders write is
        // linear and the hardware encodes it. Clears are converted too, which is
        // why the colour below is linear.
        gl.gl.Enable(gl.gl.FRAMEBUFFER_SRGB);
        const linear_horizon = self.sun.ramp().horizon;
        _ = linear_horizon;

        self.camera.position = self.player.eyePosition();
        self.camera.yaw = self.player.yaw;
        self.camera.pitch = self.player.pitch;

        const aspect = @as(f32, @floatFromInt(self.window.width)) / @as(f32, @floatFromInt(self.window.height));
        const vp = self.camera.viewProjection(aspect);
        const frustum = Frustum.fromViewProjection(vp);

        const lighting = self.sun.lighting();
        // Shadow map first: it needs the chunk meshes but none of the colour state.
        if (self.shadows_enabled) {
            self.shadow_renderer.begin(self.camera.position, lighting.sun_dir);
            var shadow_it = self.meshes.valueIterator();
            while (shadow_it.next()) |mesh| {
                self.shadow_renderer.drawMesh(mesh.vao, mesh.index_count, mesh.origin);
            }
            self.shadow_renderer.end(self.window.width, self.window.height);
        }

        // Sky first, over the cleared colour buffer, then terrain on top of it.
        // 4.4: re-render the sky cube only when the sun has moved. Before this
        // point nothing samples it, so the ordering is safe.
        self.env_probe.updateIfNeeded(&self.sun);

        // 4.1: the world goes into the half-float target, so shaders can emit
        // light above 1.0 and the exposure has something to work with. Bound
        // after the shadow pass, which ends by restoring the window.
        self.post.begin(self.sun.ramp().horizon);
        self.sky_renderer.draw(vp, self.camera.position, &self.sun, self.clouds_enabled, self.cloud_shift);

        const sky_ramp = self.sun.ramp();
        // Fog ends just inside the load radius so chunks fade in behind it rather
        // than popping through a hard frontier: radius 6 chunks = 192 blocks.
        const radius_blocks: f32 = @floatFromInt(LOAD_RADIUS * @as(i32, coords.CHUNK_SIZE));
        self.chunk_renderer.begin(&self.textures, .{
            .view_projection = vp,
            .eye = self.camera.position,
            .lighting = lighting,
            .sky_horizon = sky_ramp.horizon,
            .sky_zenith = sky_ramp.zenith,
            .fog_start = radius_blocks * 0.60,
            .fog_end = radius_blocks * 0.97,
            .fog_enabled = self.fog_enabled,
            .legacy = self.legacy_lighting,
            .normals = self.show_normals,
            .shadow_enabled = self.shadows_enabled,
            .light_vp = self.shadow_renderer.light_vp,
            .shadow_texture = if (self.shadows_enabled) self.shadow_renderer.texture else 0,
            .shadow_texel = 1.0 / @as(f32, @floatFromInt(self.shadow_renderer.size)),
            // Depth bias in normalised depth; 0.0012 of a 840-block range is about
            // half a block, with the normal offset doing the real work.
            .shadow_bias = 0.0012,
            .shadow_normal_offset = self.shadow_renderer.texelSize() * 1.2,
            .env_texture = self.env_probe.texture,
            .normal_texture = self.normal_textures.texture,
            .rough_texture = self.rough_textures.texture,
            .env_max_mip = self.env_probe.max_mip,
            // 2 texels of spread: softer shadow edges (3.12). 1.0 restores the
            // hard 3x3 for an A/B.
            // 4 texels is about 0.9 blocks at this map resolution: enough to read
            // as a soft edge at arm's length. 1 texel is the old hard 3x3.
            .shadow_pcf_radius = 1.0,
            .shadow_kernel = 1,
            .shadow_uv_per_block = 1.0 / (2.0 * self.shadow_renderer.half_extent),
            .shadow_depth_range = self.shadow_renderer.distance * 2.0 - 1.0,
            // 5.1: softness constant, in blocks of penumbra per block of gap.
            // 0 = hard edge, 0.35 gives roughly 1.5 texels of penumbra where a
            // block touches the ground and 8 where it floats a few blocks up.
            .shadow_light_size = 1.2,
            .shadow_quality = if (self.soft_shadows) 1 else 0,
        });
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
            self.block_renderer.begin(vp, &self.textures, lighting, self.legacy_lighting);
            self.block_renderer.draw(.sand, Vec3.init(remote.x, remote.y + 0.9, remote.z), 1.6, Mat4.identity);
        }

        if (self.bodies.count > 0) {
            self.block_renderer.begin(vp, &self.textures, lighting, self.legacy_lighting);
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

        // 4.9: occlusion from the depth buffer just written, then hand the blur to
        // the resolve. Half resolution: AO is low frequency by nature.
        if (self.ssao.enabled) {
            const projection = self.camera.projection(aspect);
            const inv_projection = projection.inverse() orelse Mat4.identity;
            self.ssao.render(self.post.depth, projection, inv_projection, self.camera.near, self.camera.far, self.window.width, self.window.height);
            self.post.ao_texture = self.ssao.blur_texture;
        } else {
            self.post.ao_texture = 0;
        }

        // Resolve the HDR target to the window before the 2D passes, which draw
        // straight into the default framebuffer.
        self.post.end(self.window.width, self.window.height);

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
        if (std.fmt.bufPrint(&buffer, "FRAME {d:.2} MS  WORST {d:.2} MS  SKY {d:.3}  SHDW {d:.3}  SSAO {d:.3}  POST {d:.3} MS  EV {d:.2}{s}", .{ self.frame_ms, self.worst_frame_ms, self.sky_renderer.last_ms, self.shadow_renderer.last_ms, self.ssao.last_ms, self.post.last_ms, self.post.exposure, if (self.post.tonemap) " ACES" else " CLIP" })) |text| {
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
            const text = std.fmt.bufPrint(&sun_line, "SUN {d:0>2}:{d:0>2}  el {d:5.1}  az {d:5.1}  day {d:.2}  cycle {d}s{s}{s}", .{
                whole,
                minutes,
                self.sun.elevation(),
                self.sun.azimuth(),
                self.sun.daylight(),
                @as(u32, @intFromFloat(self.sun.cycle_seconds)),
                if (self.sun.paused) "  PAUSED" else "",
                if (self.sun.mode == .pinned) "  PINNED (O/arrows)" else "",
            }) catch "";
            self.hud.setColour(0.95, 0.9, 0.6);
            self.hud.text(10, @as(f32, @floatFromInt(self.window.height)) - 66, text);
        }

        const keys = "F1 HUD  F FLY  F3 BOXES  F4 LIGHT A/B  F6 NORMALS  F7 FOG  F8 SHADOWS  F10 CLOUDS  F11 TONEMAP  F12 SSAO  F13 FXAA  -/= EXPOSURE  P PAUSE SUN  1-4 TIMES";
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
