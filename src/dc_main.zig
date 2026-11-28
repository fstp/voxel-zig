//! Dual-contouring world app: window, input, HUD, sky, streaming and save triggers. The field,
//! mesher, save format, renderer and player live in the engine modules (ADR 0022 / 8.4).

const std = @import("std");
const vz = @import("voxel_zig");
const sun_mod = vz.world.sun;
const foliage_anim = vz.world.foliage_animation;
const Vec3 = vz.math.Vec3;
const gfx = vz.gfx;
const sdl = @import("sdl3");
const gl = @import("gl");
const dcw = vz.world.dc_world;
const DcPlayer = vz.player.DcPlayer;
const WaterRenderer = vz.gfx.WaterRenderer;
const GrassRenderer = vz.gfx.GrassRenderer;
const PropRenderer = vz.gfx.PropRenderer;
const scatter_mod = vz.world.scatter;
const blade_stream = vz.world.blade_stream;

const CHUNK: usize = dcw.CHUNK;
const PATCH: i32 = dcw.PATCH;
const BUILD_TAG = "dc-modules-1";

/// Monotonic nanoseconds for the app's own instrumentation. An extern `clock_gettime` against
/// this libc can land on a vDSO page that is resolved differently once a library is injected
/// (RenderDoc), which makes main-thread stamps non-monotonic in a way that looks like a 10 ms
/// stall in whichever block sits between two of them. `std.Io.Timestamp.now` goes through the
/// runtime's own clock and was monotonic under the same conditions.
fn nowNsIo(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(ts.nanoseconds);
}

/// GL_TIME_ELAPSED around one swap-frame section. The read is deferred one frame so the query is
/// already finished and costs no stall (ADR 0041/14.2).
const GpuQuery = struct {
    id: gl.uint = 0,
    active: bool = false,
    armed: bool = false,
    last_ms: f64 = 0,

    fn begin(self: *GpuQuery) void {
        if (self.id == 0) gl.GenQueries(1, @ptrCast(&self.id));
        gl.BeginQuery(gl.TIME_ELAPSED, self.id);
        self.active = true;
    }

    fn end(self: *GpuQuery) void {
        if (!self.active) return;
        gl.EndQuery(gl.TIME_ELAPSED);
        self.active = false;
        self.armed = true;
    }

    /// Blocks only until the frame that armed it has finished, which is at least one frame back.
    fn read(self: *GpuQuery) f64 {
        if (!self.armed) return self.last_ms;
        var ns: gl.uint = 0;
        gl.GetQueryObjectuiv(self.id, gl.QUERY_RESULT, @ptrCast(&ns));
        self.last_ms = @as(f64, @floatFromInt(ns)) / 1e6;
        self.armed = false;
        return self.last_ms;
    }
};

fn playerSave(p: DcPlayer) dcw.PlayerSave {
    return .{ .x = p.position.x, .y = p.position.y, .z = p.position.z, .yaw = p.yaw, .pitch = p.pitch, .flying = p.flying };
}

const HudStats = struct {
    fps: f64,
    frame_ms: f64,
    worst_ms: f64,
    sky_ms: f32,
    verts: usize,
    quads: usize,
    patch_x: i32,
    patch_z: i32,
    rebuilds: usize,
    player_x: f32,
    player_y: f32,
    player_z: f32,
    yaw: f32,
    pitch: f32,
    flying: bool,
    swimming: bool,
    on_ground: bool,
    grass: usize,
    parts: usize,
    dirty: usize,
    update_ms: f32,
    trees: usize,
    rocks: usize,
    snow: usize,
    shore: usize,
    fly_speed: f32,
    edits: usize,
    sun_hours: f32,
    sun_elevation: f32,
    sun_paused: bool,
};

/// The engine's HUD (baked atlas, panel behind the text), at a small scale for a 4K window.
fn drawHud(hud: *vz.gfx.Hud, width: i32, height: i32, s: HudStats) void {
    hud.begin(width, height);
    hud.scale = 0.85;
    hud.panel(0, 0, 900, 8 + 7 * hud.lineHeight(), 0.55);

    var buffer: [192]u8 = undefined;
    var y: f32 = 8;

    hud.setColour(1.0, 1.0, 0.6);
    if (std.fmt.bufPrint(&buffer, "FPS {d:.1}  FRAME {d:.2} MS  WORST {d:.2} MS  SKY {d:.2} MS", .{ s.fps, s.frame_ms, s.worst_ms, s.sky_ms })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.85, 0.95, 1.0);
    if (std.fmt.bufPrint(&buffer, "VERTS {d}  QUADS {d}  PATCH {d},{d}  REBUILDS {d}", .{ s.verts, s.quads, s.patch_x, s.patch_z, s.rebuilds })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.8, 0.8, 0.8);
    if (std.fmt.bufPrint(&buffer, "POS {d:.1} {d:.1} {d:.1}  YAW {d:.2}  PITCH {d:.2}", .{ s.player_x, s.player_y, s.player_z, s.yaw, s.pitch })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.6, 0.9, 0.6);
    if (std.fmt.bufPrint(&buffer, "GRASS {d}  TREES {d}  ROCKS {d}  SNOW {d}  SHORE {d}", .{ s.grass, s.trees, s.rocks, s.snow, s.shore })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.65, 0.9, 0.7);
    if (std.fmt.bufPrint(&buffer, "PARTS {d}  DIRTY {d}  BLADE UPD {d:.2} ms", .{ s.parts, s.dirty, s.update_ms })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(1.0, 0.85, 0.45);
    const hours = @mod(s.sun_hours, 24.0);
    const hour: u32 = @intFromFloat(@floor(hours));
    const minute: u32 = @intFromFloat(@floor((hours - @floor(hours)) * 60.0));
    if (std.fmt.bufPrint(&buffer, "TIME {d:0>2}:{d:0>2}  SUN {d:.0}  {s}", .{
        hour, minute, s.sun_elevation, if (s.sun_paused) "PAUSED" else "RUNNING",
    })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.7, 1.0, 0.7);
    const mode: []const u8 = if (s.flying) "FLY" else if (s.swimming) "SWIM" else "WALK";
    const where: []const u8 = if (s.flying) "AIR" else if (s.swimming) "WATER" else if (s.on_ground) "GROUND" else "AIR";
    if (std.fmt.bufPrint(&buffer, "{s}  {s}  FLY SPEED {d:.0}  EDITS {d}", .{
        mode, where, s.fly_speed, s.edits,
    })) |text| {
        hud.text(10, y, text);
    } else |_| {}
    y += hud.lineHeight();

    hud.setColour(0.6, 0.6, 0.6);
    if (std.fmt.bufPrint(&buffer, "F1 HUD  F FLY  TAB MOUSE  P PAUSE  ,/. TIME  1-4 DAWN/NOON/DUSK/MIDNIGHT", .{})) |text| {
        hud.text(10, y, text);
    } else |_| {}

    hud.setColour(0.55, 0.55, 0.55);
    hud.text(10, @as(f32, @floatFromInt(height)) - hud.lineHeight() - 4, "WASD MOVE  SHIFT SPRINT  SPACE JUMP/UP  CTRL DOWN  ESC QUIT");
    hud.end();
}

pub fn main(init: std.process.Init) !void {
    // VOXEL_DC_BG=magenta paints the background a colour that terrain shading cannot produce, so a
    // hole count can never be confused with a pixel that merely happens to land near the sky tone.
    // Sampling the background colour from the frame cannot make that distinction, and did not:
    // two builds with IDENTICAL geometry measured 74 vs 320 "hole" pixels purely from shading.
    const bg_magenta = if (init.environ_map.get("VOXEL_DC_BG")) |raw| raw.len > 0 and raw[0] == 'm' else false;
    const io = init.io;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    std.debug.print("dc spike {s}\n", .{BUILD_TAG});

    // 4K by default: the point of the viewer is surface detail, and the panel is 3840x2160 at
    // 120 Hz. VOXEL_DC_SIZE=WxH overrides it for a quick low-res run.
    var win_w: i32 = 3840;
    var win_h: i32 = 2160;
    if (init.environ_map.get("VOXEL_DC_SIZE")) |raw| {
        if (std.mem.indexOfScalar(u8, raw, 'x')) |sep| {
            win_w = std.fmt.parseInt(i32, raw[0..sep], 10) catch win_w;
            win_h = std.fmt.parseInt(i32, raw[sep + 1 ..], 10) catch win_h;
        }
    }
    var window = try gfx.Window.init(.{
        .title = "voxel-zig dc spike",
        .width = win_w,
        .height = win_h,
        .vsync = true,
    });
    defer window.deinit();
    // A native-4K window plus decorations does not fit a 4K screen; borderless at the top-left
    // uses the whole panel and leaves the window manager nothing to clip.
    _ = sdl.SDL_SetWindowBordered(window.handle, false);
    _ = sdl.SDL_SetWindowPosition(window.handle, 0, 0);
    window.syncSize();
    // A 4K window at 120 Hz keeps this GPU at ~99 % and the fans at 3.2k RPM. The viewer does not
    // need 120 fps, so ask for every second refresh (60) instead. VOXEL_DC_FPS=120 restores it.
    var target_fps: u32 = 60;
    if (init.environ_map.get("VOXEL_DC_FPS")) |raw| {
        target_fps = std.fmt.parseInt(u32, raw, 10) catch target_fps;
    }
    _ = sdl.SDL_GL_SetSwapInterval(if (target_fps >= 120) 1 else 2);
    var swap_interval: c_int = -1;
    _ = sdl.SDL_GL_GetSwapInterval(&swap_interval);
    std.debug.print("fps cap {d} via swap interval {d}\n", .{ target_fps, swap_interval });

    // The engine loads its GL entry points into a ProcTable; without this every gl call
    // below is a null pointer, which is what segfaulted the first build.
    try vz.gl.init();

    // The engine's own input and HUD rather than copies: the controls should feel like the block
    // world (0.0022 rad/px look, clamped pitch, wheel fly speed, Tab releases the mouse).
    var input = vz.Input.init();
    input.setRelativeMouse(&window, true);
    var hud = try vz.gfx.Hud.init();
    defer hud.deinit();
    var show_hud = true;

    // ADR 0022: the save is a small line-based text file holding the player, the sun time and the
    // sphere edits. F5 writes it and quitting writes it; a missing file is a fresh world.
    const save_path = init.environ_map.get("VOXEL_DC_SAVE") orelse "dc_world.sav";
    var loaded = dcw.loadWorld(alloc, init.io, save_path) catch |err| blk: {
        std.debug.print("save load failed ({s}); starting fresh\n", .{@errorName(err)});
        break :blk dcw.LoadedWorld{};
    };
    defer loaded.deinit(alloc);
    var edits = loaded.edits;
    loaded.edits = .empty;
    defer edits.deinit(alloc);

    // The engine's own sky and volumetric clouds (ADR 0010), ported rather than reimplemented:
    // the point of the spike is to judge the DC surface, and it should be lit by the same sky the
    // block world uses so the two are comparable by eye.
    var sky = try vz.gfx.SkyRenderer.init();
    defer sky.deinit();
    // The high cirrus deck is gone (ADR 0021). The replacement is a horizon haze band in the sky
    // plus analytic height fog / aerial perspective on the terrain. VOXEL_ATMOSPHERE=0 turns both
    // off for A/B screenshots.
    var atmosphere = true;
    if (init.environ_map.get("VOXEL_ATMOSPHERE")) |raw| {
        if (raw.len > 0 and raw[0] == '0') atmosphere = false;
    }
    sky.atmosphere = atmosphere;
    var sun = sun_mod.Sun.init();
    // ADR 0009: noon sits at t = 0.30 of the 300 s cycle. VOXEL_DC_SUN pins another time for the
    // dawn/noon/dusk acceptance shots.
    var sun_time: f32 = loaded.sun_time orelse 0.30;
    if (init.environ_map.get("VOXEL_DC_SUN")) |raw| sun_time = std.fmt.parseFloat(f32, raw) catch sun_time;

    // VOXEL_DETAIL=0 is the A/B for 7.3: it skips the procedural noise and bump in the terrain
    // fragment shader, leaving the per-vertex material colours flat.
    var detail: f32 = 1.0;
    if (init.environ_map.get("VOXEL_DETAIL")) |raw| {
        if (raw.len > 0 and raw[0] == '0') detail = 0.0;
    }
    // VOXEL_SURFACES=0 is the A/B for 10.8: snow above the snow line, mud/wetness around the sea.
    var surfaces: f32 = 1.0;
    if (init.environ_map.get("VOXEL_SURFACES")) |raw| {
        if (raw.len > 0 and raw[0] == '0') surfaces = 0.0;
    }
    const snow_line: f32 = 68.0;
    const mud_band: f32 = 1.4;
    var ao_enabled = true;
    if (init.environ_map.get("VOXEL_AO")) |raw| {
        if (raw.len > 0 and raw[0] == '0') ao_enabled = false;
    }
    sun.setTime(sun_time);
    // Start still so a screenshot/test is reproducible; P resumes the 300 s cycle, comma and
    // period scrub it, and 1-4 jump to dawn/noon/dusk/midnight.
    sun.paused = true;
    std.debug.print("sun time {d:.3} elevation {d:.1} deg paused={s}\n", .{ sun_time, sun.elevation(), if (sun.paused) "true" else "false" });
    var cloud_shift = Vec3.init(0, 0, 0);
    var water_clock: f32 = 0;
    // Height-fog coefficients: a thin layer hugging the low ground, scale height 25 m, reaching
    // ~40 % at 200 m from the eye at terrain height. Density is a tuning constant, not a physical
    // atmosphere constant (ADR 0021).
    const fog_density: f32 = 0.0045;
    const fog_height: f32 = 20.0;
    const fog_base: f32 = 30.0;

    var all_verts: std.ArrayList(dcw.Vertex) = .empty;
    defer all_verts.deinit(alloc);
    var all_idx: std.ArrayList(u32) = .empty;
    defer all_idx.deinit(alloc);

    // Spawn standing on the surface at the patch's south-east corner, looking back across it.
    const spawn_x: f32 = 48.0;
    const spawn_z: f32 = 48.0;
    // Spawn flying 40 m above the surface looking across the patch, the way the orbit view saw it.
    // F drops into walk mode and the height-field physics takes over.
    var player = DcPlayer{
        .position = Vec3.init(spawn_x, DcPlayer.groundAt(spawn_x, spawn_z) + 40.0, spawn_z),
        .yaw = -0.785,
        .pitch = -0.18,
        .flying = true,
    };
    if (loaded.player) |ps| {
        player.position = Vec3.init(ps.x, ps.y, ps.z);
        player.yaw = ps.yaw;
        player.pitch = ps.pitch;
        player.flying = ps.flying;
    }
    var camera = vz.Camera{ .fov_y_deg = 70, .near = 0.1, .far = 1000 };
    var patch_origin: i32 = @divFloor(@as(i32, @intFromFloat(player.position.x)), @as(i32, @intCast(CHUNK))) - @divFloor(PATCH, 2);
    var patch_origin_z: i32 = @divFloor(@as(i32, @intFromFloat(player.position.z)), @as(i32, @intCast(CHUNK))) - @divFloor(PATCH, 2);
    std.debug.print("world: {d} edits from {s}\n", .{ edits.items.len, save_path });
    // Double buffering: the new patch is built a few chunks per frame into `next_*` while the old
    // one keeps rendering. Swapping only when it is complete means no frame ever sees a half-built
    // patch, and no frame pays the full 40-50 ms.
    var next_verts: std.ArrayList(dcw.Vertex) = .empty;
    defer next_verts.deinit(alloc);
    var next_idx: std.ArrayList(u32) = .empty;
    defer next_idx.deinit(alloc);
    var pending = false;
    var pending_x: i32 = 0;
    var pending_z: i32 = 0;
    var pending_cursor: i32 = 0;
    var rebuilds: usize = 0;
    const first = try dcw.meshPatch(alloc, edits.items, patch_origin, patch_origin_z, &all_verts, &all_idx);
    const all_verts_s = all_verts.items;
    const all_idx_s = all_idx.items;
    std.debug.print("DC viewer: {d} verts, {d} quads over {d} skirted chunks\n", .{ all_verts_s.len, first.quads, PATCH * PATCH });
    std.debug.print("kernel: emitted {d}, skipped_missing {d}, skipped_bounds {d}, ambiguous cells {d}, degenerate quads {d}, min tri area {d:.6}\n", .{
        first.quads, first.skipped_missing, first.skipped_bounds, first.ambiguous, first.degenerate, first.min_area,
    });
    try dcw.diagnoseMesh(alloc, all_verts_s, all_idx_s, patch_origin, patch_origin_z);
    {
        const dup = try dcw.countNearDuplicates(alloc, all_verts_s);
        std.debug.print("duplicates: exact {d}, near (<0.5 block, >1e-5) {d}\n", .{ dup.exact, dup.near });
    }

    // Streaming plan step 1 and 2: a rebuild is just a second call, so prove that first.
    // Identical counts mean the build is a pure function of the origin; the timing says what a
    // chunk crossing would cost if it ran synchronously on this thread.
    var probe_verts: std.ArrayList(dcw.Vertex) = .empty;
    defer probe_verts.deinit(alloc);
    var probe_idx: std.ArrayList(u32) = .empty;
    defer probe_idx.deinit(alloc);
    const t_rebuild = nowNsIo(io);
    const probe = try dcw.meshPatch(alloc, edits.items, patch_origin, patch_origin_z, &probe_verts, &probe_idx);
    const rebuild_ms = @as(f64, @floatFromInt(nowNsIo(io) - t_rebuild)) / 1e6;
    const identical = probe_verts.items.len == all_verts_s.len and probe_idx.items.len == all_idx_s.len and probe.quads == first.quads;
    std.debug.print("rebuild: {d} quads in {d:.1} ms, identical to the first build: {}\n", .{ probe.quads, rebuild_ms, identical });

    // The AO map lives here (not in the swap) so a refresh is built before the frame that uses it.
    var ao_work: ?[]u8 = null;
    defer if (ao_work) |buf| alloc.free(buf);
    var renderer = try vz.gfx.DcRenderer.init();
    defer renderer.deinit();
    renderer.upload(all_verts_s, all_idx_s);
    renderer.setAoEnabled(ao_enabled);
    if (ao_enabled) {
        const ao_t0 = nowNsIo(io);
        ao_work = try vz.world.heightfield_ao.build(
            alloc,
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
        );
        renderer.uploadAo(
            ao_work.?,
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
        );
        std.debug.print("ao: 64x64 in {d:.2} ms\n", .{@as(f64, @floatFromInt(nowNsIo(io) - ao_t0)) / 1e6});
    }

    const scatter_t0 = nowNsIo(io);
    var scatter = try scatter_mod.buildProps(
        alloc,
        edits.items,
        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
    );
    std.debug.print("scatter props: {d} trees, {d} bushes, {d} rocks, {d} snow, {d} shore in {d:.1} ms\n", .{
        scatter.trees.items.len,
        scatter.bushes.items.len,
        scatter.rocks.items.len,
        scatter.snow.items.len,
        scatter.shore.items.len,
        @as(f64, @floatFromInt(nowNsIo(io) - scatter_t0)) / 1e6,
    });
    defer scatter.deinit(alloc);
    var grass = try GrassRenderer.init();
    defer grass.deinit();
    // Blade partitions: the same stream the patch swap uses, run to completion once at startup.
    const blade_capacity: usize = 4_000_000;
    var stream = try blade_stream.Stream.init(alloc, blade_capacity);
    defer stream.deinit(alloc);
    // The stream is mutated in place by begin/step/commit/takeJob; taking the pointer once here
    // keeps that explicit for the compiler's "never mutated" check.
    const stream_ptr = &stream;
    _ = stream_ptr;
    var uploads: std.ArrayList(blade_stream.Upload) = .empty;
    defer uploads.deinit(alloc);
    {
        const st = nowNsIo(io);
        const patch_min_x = @as(f32, @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))));
        const patch_min_z = @as(f32, @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))));
        // Startup is synchronous: build every partition at once, then hand them to the GPU.
        stream.begin(patch_origin, patch_origin_z, PATCH, patch_min_x + 128.0, patch_min_z + 128.0);
        while (!(try stream.step(alloc, edits.items, 1 << 30, &uploads))) {}
        _ = stream.commit(alloc);
        grass.ensureCapacity(blade_capacity);
        for (uploads.items) |u| grass.uploadRange(u.offset, u.blades);
        std.debug.print("blades: {d} partitions, {d} instances, slots {d}/{d}, built in {d:.1} ms\n", .{
            stream.liveCount(), stream.liveBlades(), stream.used, blade_capacity,
            @as(f64, @floatFromInt(nowNsIo(io) - st)) / 1e6,
        });
        uploads.clearRetainingCapacity();

        // VOXEL_BLADE_CHECK=1: prove the streamed partitions carry exactly the instances of a
        // whole-patch build. Order-independent: count plus a commutative sum of per-blade hashes.
        if (init.environ_map.get("VOXEL_BLADE_CHECK")) |raw| {
            if (raw.len > 0 and raw[0] == '1') {
                const ct = nowNsIo(io);
                var ref = try scatter_mod.build(alloc, edits.items, patch_min_x, patch_min_z, @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))));
                defer ref.deinit(alloc);
                var stream_sum: u64 = 0;
                for (stream.parts.items) |*pp| {
                    if (!pp.live) continue;
                    for (pp.blades.items) |b| {
                        var hh = std.hash.Wyhash.init(0);
                        hh.update(std.mem.asBytes(&b));
                        stream_sum +%= hh.final();
                    }
                }
                var ref_sum: u64 = 0;
                for (ref.blades.items) |b| {
                    var hh = std.hash.Wyhash.init(0);
                    hh.update(std.mem.asBytes(&b));
                    ref_sum +%= hh.final();
                }
                std.debug.print("blade check: stream {d} blades sum {x}, full build {d} blades sum {x}, equal {}\n", .{
                    stream.liveBlades(), stream_sum, ref.blades.items.len, ref_sum,
                    stream.liveBlades() == ref.blades.items.len and stream_sum == ref_sum,
                });
                std.debug.print("blade check took {d:.1} ms\n", .{@as(f64, @floatFromInt(nowNsIo(io) - ct)) / 1e6});
            }
        }
    }
    var props = try PropRenderer.init(alloc);
    defer props.deinit(alloc);
    props.uploadRocks(scatter.rocks.items);
    props.uploadBushes(scatter.bushes.items);
    props.uploadSnow(scatter.snow.items);
    props.uploadShore(scatter.shore.items);
    if (init.environ_map.get("VOXEL_TREE_AGG")) |raw| {
        if (raw.len > 0 and raw[0] == '0') props.aggregate_distance = 1.0e9;
    }
    if (init.environ_map.get("VOXEL_TREE_FORCE_LOD")) |raw| {
        if (raw.len > 0) {
            const v = std.fmt.parseInt(u8, raw, 10) catch 255;
            if (v <= 2) props.force_lod = v;
        }
    }
    props.lod_focal = foliage_anim.focalPixels(@floatFromInt(window.height), camera.fov_y_deg);
    // ADR 0047: verification aid for the LOD transition error. Prints the nearest trees with the
    // projected pixel size the LOD chooser uses, so a pose can be placed exactly at a switch.
    if (init.environ_map.get("VOXEL_TREE_DEBUG")) |raw| {
        if (raw.len > 0 and raw[0] == '1') {
            std.debug.print("tree debug: focal {d:.1} px, {d} trees, aggregate cutoff {d:.0} m\n",
                .{ props.lod_focal, scatter.trees.items.len, props.aggregate_distance });
            // Top-10 nearest, so the print answers "what LOD has the closest tree" (ADR 0046).
            const Item = struct { d: f32, x: f32, z: f32, px: f32, lod: u8 };
            var items: [10]Item = undefined;
            var n: usize = 0;
            for (scatter.trees.items) |t| {
                const dx = t.pos[0] - player.position.x;
                const dz = t.pos[2] - player.position.z;
                const d = @sqrt(dx * dx + dz * dz);
                if (n == items.len and d >= items[n - 1].d) continue;
                const px = 6.5 * t.scale * props.lod_focal / @max(d, 0.1);
                const it = Item{ .d = d, .x = t.pos[0], .z = t.pos[2], .px = px, .lod = foliage_anim.lodForPixels(px, 0) };
                var slot: usize = if (n < items.len) n else items.len - 1;
                while (slot > 0 and items[slot - 1].d > it.d) : (slot -= 1) {
                    items[slot] = items[slot - 1];
                }
                items[slot] = it;
                if (n < items.len) n += 1;
            }
            var max_lod: u8 = 0;
            for (items[0..n]) |it| {
                if (it.lod > max_lod) max_lod = it.lod;
                std.debug.print("  tree {d:.1} {d:.1} | dist {d:.1} m | {d:.0} px | lod {d}\n",
                    .{ it.x, it.z, it.d, it.px, it.lod });
            }
            std.debug.print("  nearest 10: max lod {d} (aggregate cutoff {d:.0} m)\n", .{ max_lod, props.aggregate_distance });
        }
    }
    try props.uploadTrees(
        alloc,
        scatter.trees.items,
        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
    );
    props.logAssetStats();

    // Wind is only worth paying for while its projected displacement can be seen. Use a
    // conservative 0.125 m foliage displacement and a 2 px target at the 4K window; the fade
    // band makes the cutoff invisible rather than a snap.
    var animation_enabled = true;
    if (init.environ_map.get("VOXEL_ANIM")) |raw| {
        if (raw.len > 0 and raw[0] == '0') animation_enabled = false;
    }
    var freeze_player = false;
    if (init.environ_map.get("VOXEL_DC_FREEZE")) |raw| {
        if (raw.len > 0 and raw[0] == '1') freeze_player = true;
    }
    const animation_cutoff: f32 = if (animation_enabled)
        @min(foliage_anim.cutoffDistance(0.125, 2.0, @floatFromInt(window.height), camera.fov_y_deg), 110.0)
    else
        0.0;
    const animation_fade: f32 = 15.0;
    grass.active_radius = scatter_mod.ACTIVE_RADIUS;
    grass.active_fade = scatter_mod.ACTIVE_FADE;
    grass.field_centre = .{
        @as(f32, @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK)))) + 128.0,
        @as(f32, @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK)))) + 128.0,
    };
    renderer.meadow_centre = grass.field_centre;
    grass.animation_cutoff = animation_cutoff;
    grass.animation_fade = animation_fade;
    // Far-field stamp A/B: VOXEL_STAMP=1 paints the meadow into the ground beyond the blades.
    // Off by default until the colour has been calibrated against the blades (ADR 0039).
    if (init.environ_map.get("VOXEL_STAMP")) |raw| {
        if (raw.len > 0 and raw[0] == '1') renderer.stamp_on = true;
    }
    props.animation_cutoff = animation_cutoff;
    props.animation_fade = animation_fade;
    {
        const eye = player.eyePosition();
        const c2 = animation_cutoff * animation_cutoff;
        var animated_trees: usize = 0;
        for (scatter.trees.items) |t| {
            const dx = t.pos[0] - eye.x;
            const dz = t.pos[2] - eye.z;
            if (dx * dx + dz * dz <= c2) animated_trees += 1;
        }
        var animated_blades: usize = 0;
        for (scatter.blades.items) |b| {
            const dx = b.pos[0] - eye.x;
            const dz = b.pos[2] - eye.z;
            if (dx * dx + dz * dz <= c2) animated_blades += 1;
        }
        std.debug.print(
            "animation: cutoff {d:.1} m, {d} trees, {d} blades animated, fade {d:.1} m, enabled={s}\n",
            .{ animation_cutoff, animated_trees, animated_blades, animation_fade, if (animation_enabled) "true" else "false" },
        );
    }

    var water = try WaterRenderer.init();
    defer water.deinit();
    var shadow = try vz.gfx.ShadowRenderer.init();
    defer shadow.deinit();
    var shadows_enabled = true;
    if (init.environ_map.get("VOXEL_SHADOWS")) |raw| {
        if (raw.len > 0 and raw[0] == '0') shadows_enabled = false;
    }
    shadow.enabled = shadows_enabled;
    {
        const t0 = nowNsIo(io);
        water.ensurePatch(
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
        );
        std.debug.print("water: patch grid built in {d:.1} ms\n", .{@as(f64, @floatFromInt(nowNsIo(io) - t0)) / 1e6});
    }

    // ADR 0008: the engine draws into an sRGB framebuffer and every shader writes LINEAR, so the
    // hardware does the encode. The spike omitted this line, which is why its terrain looked washed
    // out while the sky looked right - the sky does its own encode, the terrain does not.
    gl.Enable(gl.FRAMEBUFFER_SRGB);
    gl.Enable(gl.DEPTH_TEST);
    // Culling is off deliberately: with it on, quads whose winding heuristic had to
    // guess (near-degenerate cells) vanish into the background and read as holes.
    gl.Disable(gl.CULL_FACE);


    var frames: u64 = 0;
    var window_start = nowNsIo(io);
    var worst_ns: i64 = 0;
    var last_frame_ns = nowNsIo(io);
    var accumulator: f64 = 0;
    var was_swimming = false;
    var tree_stats_logged = false;
    var stream_update_ms: f32 = 0;
    var stream_dirty: usize = 0;
    var blade_job: blade_stream.Job = .{ .cx = 0, .cz = 0 };
    var props_ready = false;
    var ao_pending_done = false;
    // Terrain double buffering (ADR 0042): the pending mesh is uploaded in slices while it grows.
    var up_v: usize = 0;
    var up_i: usize = 0;
    var q_shadow = [2]GpuQuery{ GpuQuery{}, GpuQuery{} };
    var q_sky = GpuQuery{};
    var q_terrain = GpuQuery{};
    var q_grass = GpuQuery{};
    var q_props = GpuQuery{};
    var q_water = GpuQuery{};
    var q_water_swap = GpuQuery{};
    var q_swprops = GpuQuery{};
    var q_hud = GpuQuery{};
    var q_flip = GpuQuery{};
    var q_ao = GpuQuery{};
    var swap_gpu_pending = false;
    // VOXEL_GPU_SYNC=1: drain the GPU at frame end so the CPU frame time includes the queue.
    const gpu_sync = if (init.environ_map.get("VOXEL_GPU_SYNC")) |raw| raw.len > 0 and raw[0] == '1' else false;
    if (init.environ_map.get("VOXEL_CLOUD_STEPS")) |raw| {
        sky.cloud_steps = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \t"), 10) catch 22;
    }
    const fixed_dt: f64 = 1.0 / 60.0;
    var frame_ms: f64 = 0;
    var fps_now: f64 = 0;
    frame: while (true) {
        const frame_start = nowNsIo(io);
        if (swap_gpu_pending) {
            swap_gpu_pending = false;
            std.debug.print("swap gpu: flip {d:.3} ms | ao {d:.3} | water {d:.3} | props {d:.3} (GPU time)\n", .{
                q_flip.read(), q_ao.read(), q_water_swap.read(), q_swprops.read(),
            });
        }
        var frame_dt = @as(f64, @floatFromInt(frame_start - last_frame_ns)) / 1e9;
        last_frame_ns = frame_start;
        frame_dt = @min(frame_dt, 0.1);

        input.pump(&window);
        if (freeze_player) {
            input.mouse_dx = 0;
            input.mouse_dy = 0;
        }
        if (input.quit) {
            dcw.saveWorld(init.io, save_path, sun.time, playerSave(player), edits.items) catch |err| {
                std.debug.print("save on quit failed: {s}\n", .{@errorName(err)});
            };
            break :frame;
        }
        if (input.save_toggle) {
            dcw.saveWorld(init.io, save_path, sun.time, playerSave(player), edits.items) catch |err| {
                std.debug.print("save failed: {s}\n", .{@errorName(err)});
            };
            std.debug.print("saved {s} ({d} edits)\n", .{ save_path, edits.items.len });
        }
        if (input.hud_toggle) show_hud = !show_hud;
        if (input.pause_time) {
            sun.togglePaused();
            std.debug.print("sun {s} at time {d:.3}\n", .{ if (sun.paused) "paused" else "running", sun.time });
        }
        if (input.time_scrub != 0) {
            sun.setTime(sun.time + @as(f32, @floatFromInt(input.time_scrub)) * 0.02);
            std.debug.print("sun time {d:.3} ({d:.2} h)\n", .{ sun.time, sun.clockHours() });
        }
        if (input.time_jump) |t| {
            sun.setTime(t);
            std.debug.print("sun jump time {d:.3} ({d:.2} h)\n", .{ sun.time, sun.clockHours() });
        }
        if (input.fly_toggle) player.flying = !player.flying;
        if (input.wheel != 0) {
            player.fly_speed *= std.math.pow(f32, 1.25, input.wheel);
            player.fly_speed = std.math.clamp(player.fly_speed, 1, 400);
        }
        // Same look response as the engine's player (Camera.SENSITIVITY, clamped pitch).
        player.yaw += input.mouse_dx * vz.Camera.SENSITIVITY;
        player.pitch = std.math.clamp(
            player.pitch - input.mouse_dy * vz.Camera.SENSITIVITY,
            -vz.Camera.MAX_PITCH,
            vz.Camera.MAX_PITCH,
        );

        // Dig (left) and place (right): sphere-trace the field, append a sphere edit and rebuild
        // the current patch. The rebuild is spread over frames like a streaming swap.
        if (input.primary_click or input.secondary_click) {
            const add = input.secondary_click;
            if (dcw.raycastField(edits.items, player.eyePosition(), player.forward(), 12.0)) |hit| {
                try edits.append(alloc, .{ .x = hit.x, .y = hit.y, .z = hit.z, .r = 3.0, .add = add });
                std.debug.print("edit {s} at ({d:.1},{d:.1},{d:.1}), {d} total\n", .{
                    if (add) "add" else "carve", hit.x, hit.y, hit.z, edits.items.len,
                });
                pending = true;
                pending_x = patch_origin;
                pending_z = patch_origin_z;
                pending_cursor = 0;
                next_verts.clearRetainingCapacity();
                next_idx.clearRetainingCapacity();
            }
        }

        var wish = Vec3.zero;
        {
            const forward_amount: f32 = @floatFromInt(@intFromBool(input.down(sdl.SDL_SCANCODE_W)));
            const back_amount: f32 = @floatFromInt(@intFromBool(input.down(sdl.SDL_SCANCODE_S)));
            const right_amount: f32 = @floatFromInt(@intFromBool(input.down(sdl.SDL_SCANCODE_D)));
            const left_amount: f32 = @floatFromInt(@intFromBool(input.down(sdl.SDL_SCANCODE_A)));
            const forward = Vec3.init(@sin(player.yaw), 0, -@cos(player.yaw));
            const right = Vec3.init(@cos(player.yaw), 0, @sin(player.yaw));
            const v = forward.scale(forward_amount - back_amount).add(right.scale(right_amount - left_amount));
            const len = @sqrt(v.x * v.x + v.z * v.z);
            if (len > 1e-5) wish = Vec3.init(v.x / len, 0, v.z / len);
        }
        // Signed on purpose: subtracting two @intFromBool values infers u1 and overflows on Ctrl.
        const up: f32 = @floatFromInt(@as(i8, @intFromBool(input.down(sdl.SDL_SCANCODE_SPACE))) - @as(i8, @intFromBool(input.down(sdl.SDL_SCANCODE_LCTRL))));
        const sprint = input.down(sdl.SDL_SCANCODE_LSHIFT);

        // Player physics on the engine's fixed step; rendering on the frame delta.
        accumulator += frame_dt;
        var steps: u32 = 0;
        while (accumulator >= fixed_dt and steps < 5) : (steps += 1) {
            if (!freeze_player) player.update(@floatCast(fixed_dt), wish, up, sprint);
            if (!freeze_player) sun.update(@floatCast(fixed_dt));
            accumulator -= fixed_dt;
        }
        if (steps == 5) accumulator = @mod(accumulator, fixed_dt);
        if (player.swimming != was_swimming) {
            std.debug.print("swim: {s} at ({d:.1},{d:.1},{d:.1})\n", .{
                if (player.swimming) "enter" else "exit",
                player.position.x,
                player.position.y,
                player.position.z,
            });
            was_swimming = player.swimming;
        }
        input.endFrame();

        window.syncSize();
        const w: f32 = @floatFromInt(window.width);
        const h: f32 = @floatFromInt(window.height);
        const aspect = w / @max(h, 1.0);
        gl.Viewport(0, 0, window.width, window.height);
        if (bg_magenta) gl.ClearColor(1.0, 0.0, 1.0, 1.0) else gl.ClearColor(0.30, 0.38, 0.50, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        // Streaming: the patch follows the player's chunk now that the camera is free.
        const cur_cx: i32 = @divFloor(@as(i32, @intFromFloat(player.position.x)), @as(i32, @intCast(CHUNK)));
        const cur_cz: i32 = @divFloor(@as(i32, @intFromFloat(player.position.z)), @as(i32, @intCast(CHUNK)));
        const want_x = cur_cx - @divFloor(PATCH, 2);
        const want_z = cur_cz - @divFloor(PATCH, 2);
        if (!pending and (want_x != patch_origin or want_z != patch_origin_z)) {
            pending = true;
            pending_x = want_x;
            pending_z = want_z;
            pending_cursor = 0;
            props_ready = false;
            ao_pending_done = false;
            up_v = 0;
            up_i = 0;
            // Size the back buffers from the current mesh (a patch is within ~10 % of its neighbour)
            // and grow once at the swap if the estimate was short.
            renderer.beginUpload(all_verts.items.len + all_verts.items.len / 8 + 4096, all_idx.items.len + all_idx.items.len / 8 + 4096);
            stream.begin(pending_x, pending_z, PATCH, @as(f32, @floatFromInt(pending_x * @as(i32, @intCast(CHUNK)))) + 128.0, @as(f32, @floatFromInt(pending_z * @as(i32, @intCast(CHUNK)))) + 128.0);
            next_verts.clearRetainingCapacity();
            next_idx.clearRetainingCapacity();
        }
        if (pending) {
            // The swap frame only uploads: meshing slices, blade partitions, the prop scatter and
            // the AO bake all complete before it (ADR 0041).
            const t_slice = nowNsIo(io);
            var done: i32 = 0;
            while (done < 4 and pending_cursor < PATCH * PATCH) : (done += 1) {
                const cx = @divTrunc(pending_cursor, PATCH);
                const cz = @mod(pending_cursor, PATCH);
                _ = try dcw.meshChunkInto(alloc, edits.items, pending_x, pending_z, cx, cz, &next_verts, &next_idx);
                pending_cursor += 1;
            }

            // Keep the terrain upload in step with the mesh: ~12k vertices per frame is ~0.15 ms.
            {
                const cap_v: usize = 12000;
                const v_to = @min(next_verts.items.len, up_v + cap_v);
                const i_to = @min(next_idx.items.len, up_i + cap_v * 3 / 2);
                if (v_to > up_v or i_to > up_i) {
                    renderer.uploadSlice(next_verts.items, next_idx.items, up_v, v_to, up_i, i_to);
                    up_v = v_to;
                    up_i = i_to;
                }
            }

            // Blade partitions: at most one generation job in flight, so the wait below is short;
            // on the frame a job lands it is already finished and costs only the copy.
            // Drain first, then refill: starting before draining would overwrite the in-flight job's
            // start stamp and report a bogus duration.
            const taken = try stream.takeJob(io, &uploads, nowNsIo(io));
            if (taken) {
                std.debug.print("blades: landed +{d} instances, {d:.2} ms from start to upload\n", .{
                    stream.last_landed, @as(f64, @floatFromInt(stream.last_job_ms_ns)) / 1e6,
                });
            }
            const job_t0 = nowNsIo(io);
            const started = if (stream.job == null) try stream.startJobTimed(io, &blade_job, edits.items, job_t0) else false;
            if (started) {
                std.debug.print("blades: job started for cell ({d},{d}), dispatch {d} ns\n", .{
                    blade_job.cx, blade_job.cz, nowNsIo(io) - job_t0,
                });
            }
            if (taken) {
                for (uploads.items) |u| grass.uploadRange(u.offset, u.blades);
                uploads.clearRetainingCapacity();
            }
            stream_update_ms = stream.last_wait_ms;
            stream_dirty = if (stream.job_ptr != null) 1 else 0;

            // Props for the pending patch, built once alongside the mesh slices (6.1 ms here).
            if (!props_ready) {
                const pt = nowNsIo(io);
                scatter.deinit(alloc);
                scatter = try scatter_mod.buildProps(
                    alloc,
                    edits.items,
                    @floatFromInt(pending_x * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(pending_z * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                );
                props_ready = true;
                std.debug.print("scatter props: {d} trees, {d} bushes, {d} rocks, {d} snow, {d} shore in {d:.1} ms (off the swap frame)\n", .{
                    scatter.trees.items.len,
                    scatter.bushes.items.len,
                    scatter.rocks.items.len,
                    scatter.snow.items.len,
                    scatter.shore.items.len,
                    @as(f64, @floatFromInt(nowNsIo(io) - pt)) / 1e6,
                });
            }

            // The AO bake (2.5 ms) is independent of the mesh; it waits for the props so only one
            // patch-sized allocation is in flight at a time.
            if (props_ready and !ao_pending_done) {
                const wt = nowNsIo(io);
                water.buildPatch(
                    @floatFromInt(pending_x * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(pending_z * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                );
                std.debug.print("water: grid built off-frame in {d:.2} ms\n", .{@as(f64, @floatFromInt(nowNsIo(io) - wt)) / 1e6});
                const at = nowNsIo(io);
                if (ao_work) |old| alloc.free(old);
                ao_work = try vz.world.heightfield_ao.build(
                    alloc,
                    @floatFromInt(pending_x * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(pending_z * @as(i32, @intCast(CHUNK))),
                    @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                );
                ao_pending_done = true;
                std.debug.print("ao: 64x64 in {d:.2} ms (off the swap frame)\n", .{@as(f64, @floatFromInt(nowNsIo(io) - at)) / 1e6});
            }

            if (pending_cursor >= PATCH * PATCH and stream.pendingCount() == 0 and stream.job == null and props_ready and ao_pending_done) {
                const swap_t = nowNsIo(io);
                // Complete: swap the buffers and upload both at once. Uploading is the only part that
                // must not be interrupted, and it is ~2 MB of vertex data.
                const t_a = nowNsIo(io);
                const fits = renderer.backFits(next_verts.items.len, next_idx.items.len);
                if (!fits) {
                    renderer.beginUpload(next_verts.items.len, next_idx.items.len);
                    up_v = 0;
                    up_i = 0;
                }
                const t_b = nowNsIo(io);
                if (up_v < next_verts.items.len or up_i < next_idx.items.len) {
                    renderer.uploadSlice(next_verts.items, next_idx.items, up_v, next_verts.items.len, up_i, next_idx.items.len);
                    up_v = next_verts.items.len;
                    up_i = next_idx.items.len;
                }
                const t_c = nowNsIo(io);
                q_flip.begin();
                renderer.setIndexCount(next_idx.items.len);
                renderer.flip();
                q_flip.end();
                const t_flip = nowNsIo(io);
                std.debug.print("  swap breakdown: fits+realloc {d} us, remainder upload {d} us, flip {d} us\n", .{
                    @divTrunc(t_b - t_a, 1000), @divTrunc(t_c - t_b, 1000), @divTrunc(t_flip - t_c, 1000),
                });
                std.mem.swap(std.ArrayList(dcw.Vertex), &all_verts, &next_verts);
                std.mem.swap(std.ArrayList(u32), &all_idx, &next_idx);
                patch_origin = pending_x;
                patch_origin_z = pending_z;
                q_ao.begin();
                if (ao_enabled and ao_work != null) {
                    renderer.uploadAo(
                        ao_work.?,
                        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                    );
                }
                const t_ao = nowNsIo(io);
                q_ao.end();
                q_water_swap.begin();
                water.uploadPatch();
                q_water_swap.end();
                const t_water = nowNsIo(io);
                q_swprops.begin();
                {
                    const dropped = stream.commit(alloc);
                    props.uploadRocks(scatter.rocks.items);
                    props.uploadBushes(scatter.bushes.items);
                    props.uploadSnow(scatter.snow.items);
                    props.uploadShore(scatter.shore.items);
                    try props.uploadTrees(
                        alloc,
                        scatter.trees.items,
                        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                    );
                    const pmx = @as(f32, @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK)))) + 128.0;
                    const pmz = @as(f32, @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK)))) + 128.0;
                    grass.field_centre = .{ pmx, pmz };
                    renderer.meadow_centre = .{ pmx, pmz };
                    std.debug.print("swap: blades {d} partitions ({d} dropped), {d} instances, slots {d}/{d}; swap upload {d:.2} ms\n", .{
                        stream.liveCount(),
                        dropped,
                        stream.liveBlades(),
                        stream.used,
                        blade_capacity,
                        @as(f64, @floatFromInt(nowNsIo(io) - swap_t)) / 1e6,
                    });
                }
                q_swprops.end();
                swap_gpu_pending = true;
                const t_parts = nowNsIo(io);
                std.debug.print("swap parts: remainder {d:.2} ms | flip {d:.2} | ao {d:.2} | water {d:.2} | props+commit {d:.2}\n", .{
                    @as(f64, @floatFromInt(t_flip - swap_t)) / 1e6,
                    @as(f64, @floatFromInt(t_ao - t_flip)) / 1e6,
                    @as(f64, @floatFromInt(t_water - t_ao)) / 1e6,
                    @as(f64, @floatFromInt(t_parts - t_water)) / 1e6,
                    0.0,
                });
                pending = false;
                props_ready = false;
                ao_pending_done = false;
                rebuilds += 1;
                std.debug.print("stream: patch ({d},{d}) ready, {d} verts, {d} rebuilds, {d:.2} ms this slice\n", .{
                    patch_origin, patch_origin_z, all_verts.items.len, rebuilds,
                    @as(f64, @floatFromInt(nowNsIo(io) - t_slice)) / 1e6,
                });
            }
        }

        camera.position = player.eyePosition();
        camera.yaw = player.yaw;
        camera.pitch = player.pitch;
        const vp = camera.viewProjection(aspect);

        // The cumulus deck drifts on the frame delta at the engine's own wind speed (0.06 units/s,
        // `6.0 * dt * 0.01` in app.zig). The old fixed 0.016*2.0 per frame ran at 3.84 units/s on
        // a 120 Hz display, 64x the engine.
        const dt_f: f32 = @floatCast(frame_dt);
        if (!freeze_player) {
            water_clock += dt_f;
            cloud_shift = Vec3.init(cloud_shift.x + dt_f * 0.06, 0, cloud_shift.z + dt_f * 0.015);
        }
        const ramp = sun.ramp();
        const lighting = sun.lighting();
        const sky_sh = sun.skySh();
        if (shadow.enabled) {
            shadow.update(camera.position, player.forward(), lighting.sun_dir);
            for (0..2) |ci| {
                q_shadow[ci].begin();
                shadow.begin(@intCast(ci));
                renderer.drawDepth(shadow.vp[ci], all_idx.items.len);
                props.drawTreesDepth(shadow.vp[ci], water_clock, scatter.trees.items, camera.position);
                props.drawRocksDepth(shadow.vp[ci], water_clock, camera.position);
                props.drawBushesDepth(shadow.vp[ci], water_clock, camera.position);
                props.drawSnowDepth(shadow.vp[ci], water_clock, camera.position);
                props.drawShoreDepth(shadow.vp[ci], water_clock, camera.position);
                shadow.end();
                q_shadow[ci].end();
            }
        }
        // The shadow passes leave the 2048 viewport bound; restore the window before anything draws
        // to it (the per-frame state rules in the skill apply here too).
        gl.Viewport(0, 0, window.width, window.height);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        // The sky pass fills the whole screen, so with it running the magenta clear colour is never
        // visible and a hole shows sky instead. In the diagnostic mode the background is left empty
        // so every hole is the one colour the render cannot produce.
        q_sky.begin();
        if (!bg_magenta) sky.draw(vp, camera.position, &sun, true, cloud_shift);
        q_sky.end();

        // Fog colours are passed display-encoded because the terrain shader applies its own gamma
        // encode on top of the sRGB framebuffer; matching that space keeps the look and makes the
        // haze read like the sky's horizon.
        const encode = struct {
            fn f(x: f32) f32 {
                return std.math.pow(f32, @max(x, 0.0), 0.4545);
            }
        }.f;
        const fog_col = Vec3.init(encode(ramp.horizon.x), encode(ramp.horizon.y), encode(ramp.horizon.z));
        const fog_sun = Vec3.init(encode(ramp.sun.x), encode(ramp.sun.y), encode(ramp.sun.z));
        q_terrain.begin();
        renderer.draw(
            vp,
            camera.position,
            lighting.sun_dir,
            lighting.sun_colour,
            lighting.ambient_ground,
            sky_sh.c,
            fog_col,
            fog_sun,
            fog_density,
            fog_height,
            fog_base,
            atmosphere,
            detail,
            surfaces,
            dcw.SEA_LEVEL,
            snow_line,
            mud_band,
            &shadow,
            all_idx.items.len,
        );
        q_terrain.end();
        q_grass.begin();
        for (stream.parts.items) |*p| {
            if (!p.live or p.blades.items.len == 0) continue;
            grass.drawRange(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow, p.slot.start, p.blades.items.len);
        }
        q_grass.end();
        q_props.begin();
        props.drawTrees(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow, scatter.trees.items);
        if (!tree_stats_logged) {
            props.logTreeStats();
            tree_stats_logged = true;
        }
        props.drawRocks(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow);
        props.drawBushes(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow);
        props.drawSnow(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow);
        props.drawShore(vp, camera.position, lighting.sun_dir, lighting.sun_colour, lighting.ambient_sky, lighting.ambient_ground, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, &shadow);

        q_props.end();
        q_water.begin();
        water.draw(
            vp,
            camera.position,
            lighting.sun_dir,
            lighting.sun_colour,
            fog_col,
            fog_sun,
            fog_density,
            fog_height,
            fog_base,
            water_clock,
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
            &shadow,
        );

        q_water.end();
        if (show_hud) {
            q_hud.begin();
            drawHud(&hud, window.width, window.height, .{
                .fps = if (fps_now > 0) fps_now else 1000.0 / @max(frame_ms, 0.001),
                .frame_ms = frame_ms,
                .worst_ms = @as(f64, @floatFromInt(worst_ns)) / 1e6,
                .sky_ms = sky.last_ms,
                .verts = all_verts.items.len,
                .quads = all_idx.items.len / 6,
                .patch_x = patch_origin,
                .patch_z = patch_origin_z,
                .rebuilds = rebuilds,
                .player_x = player.position.x,
                .player_y = player.position.y,
                .player_z = player.position.z,
                .yaw = player.yaw,
                .pitch = player.pitch,
                .flying = player.flying,
                .swimming = player.swimming,
                .on_ground = player.on_ground,
                .grass = stream.liveBlades(),
                .parts = stream.liveCount(),
                .dirty = stream_dirty,
                .update_ms = stream_update_ms,
                .trees = scatter.trees.items.len,
                .rocks = scatter.rocks.items.len,
                .snow = scatter.snow.items.len,
                .shore = scatter.shore.items.len,
                .fly_speed = player.fly_speed,
                .edits = edits.items.len,
                .sun_hours = sun.clockHours(),
                .sun_elevation = sun.elevation(),
                .sun_paused = sun.paused,
            });
            q_hud.end();
        }
        if (gpu_sync) {
            const sync_t = nowNsIo(io);
            gl.Finish();
            std.debug.print("gpu sync: {d:.2} ms of queue drained at frame end\n", .{@as(f64, @floatFromInt(nowNsIo(io) - sync_t)) / 1e6});
        }
        window.swap();

        const frame_ns = nowNsIo(io) - frame_start;
        frame_ms = @as(f64, @floatFromInt(frame_ns)) / 1e6;
        if (frame_ns > worst_ns) worst_ns = frame_ns;
        frames += 1;
        const elapsed = nowNsIo(io) - window_start;
        if (elapsed >= 1_000_000_000) {
            fps_now = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(elapsed));
            std.debug.print("gpu passes: sky {d:.2} | terrain {d:.2} | grass {d:.2} | props {d:.2} | water {d:.2} | hud {d:.2} | shadow {d:.2}+{d:.2} ms\n", .{
                q_sky.read(), q_terrain.read(), q_grass.read(), q_props.read(), q_water.read(), q_hud.read(),
                q_shadow[0].read(), q_shadow[1].read(),
            });
            std.debug.print("stream: parts {d}  dirty {d}  upd {d:.2} ms  blades {d}  slots {d}/{d}\n", .{
                stream.liveCount(), stream_dirty, stream_update_ms, stream.liveBlades(), stream.used, blade_capacity,
            });
            std.debug.print("fps {d:.1}  worst frame {d:.2} ms  verts {d}  quads {d}  pos {d:.1} {d:.1} {d:.1}  yaw {d:.3} pitch {d:.3}  {s} {s} speed {d:.0}\n", .{
                fps_now,
                @as(f64, @floatFromInt(worst_ns)) / 1e6,
                all_verts.items.len,
                all_idx.items.len / 6,
                player.position.x,
                player.position.y,
                player.position.z,
                player.yaw,
                player.pitch,
                if (player.flying) "FLY" else if (player.swimming) "SWIM" else "WALK",
                if (player.flying) "AIR" else if (player.swimming) "WATER" else if (player.on_ground) "GROUND" else "AIR",
                player.fly_speed,
            });
            frames = 0;
            worst_ns = 0;
            window_start = nowNsIo(io);
        }
    }
}
