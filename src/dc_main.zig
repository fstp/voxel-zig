//! Dual-contouring world app: window, input, HUD, sky, streaming and save triggers. The field,
//! mesher, save format, renderer and player live in the engine modules (ADR 0022 / 8.4).

const std = @import("std");
const vz = @import("voxel_zig");
const sun_mod = vz.world.sun;
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

const CHUNK: usize = dcw.CHUNK;
const PATCH: i32 = dcw.PATCH;
const BUILD_TAG = "dc-modules-1";

const TimeSpec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;
fn nowNs() i64 {
    var ts: TimeSpec = undefined;
    _ = clock_gettime(1, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}

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
    trees: usize,
    rocks: usize,
    impostors: usize,
    fly_speed: f32,
    edits: usize,
};

/// The engine's HUD (baked atlas, panel behind the text), at a small scale for a 4K window.
fn drawHud(hud: *vz.gfx.Hud, width: i32, height: i32, s: HudStats) void {
    hud.begin(width, height);
    hud.scale = 0.85;
    hud.panel(0, 0, 620, 8 + 5 * hud.lineHeight(), 0.55);

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
    if (std.fmt.bufPrint(&buffer, "GRASS {d}  TREES {d}  ROCKS {d}  IMPOSTORS {d}", .{ s.grass, s.trees, s.rocks, s.impostors })) |text| {
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
    if (std.fmt.bufPrint(&buffer, "F1 HUD  F FLY  TAB MOUSE  WHEEL FLY SPEED", .{})) |text| {
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
    sun.setTime(sun_time);
    std.debug.print("sun time {d:.3} elevation {d:.1} deg\n", .{ sun_time, sun.elevation() });
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
    const t_rebuild = nowNs();
    const probe = try dcw.meshPatch(alloc, edits.items, patch_origin, patch_origin_z, &probe_verts, &probe_idx);
    const rebuild_ms = @as(f64, @floatFromInt(nowNs() - t_rebuild)) / 1e6;
    const identical = probe_verts.items.len == all_verts_s.len and probe_idx.items.len == all_idx_s.len and probe.quads == first.quads;
    std.debug.print("rebuild: {d} quads in {d:.1} ms, identical to the first build: {}\n", .{ probe.quads, rebuild_ms, identical });

    var renderer = try vz.gfx.DcRenderer.init();
    defer renderer.deinit();
    renderer.upload(all_verts_s, all_idx_s);

    const scatter_t0 = nowNs();
    var scatter = try scatter_mod.build(
        alloc,
        edits.items,
        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
    );
    std.debug.print("scatter: {d} blades, {d} trees, {d} rocks in {d:.1} ms\n", .{
        scatter.blades.items.len,
        scatter.trees.items.len,
        scatter.rocks.items.len,
        @as(f64, @floatFromInt(nowNs() - scatter_t0)) / 1e6,
    });
    defer scatter.deinit(alloc);
    var grass = try GrassRenderer.init();
    defer grass.deinit();
    grass.upload(scatter.blades.items);
    var props = try PropRenderer.init(alloc);
    defer props.deinit(alloc);
    props.uploadRocks(scatter.rocks.items);

    var water = try WaterRenderer.init();
    defer water.deinit();
    {
        const t0 = nowNs();
        water.ensurePatch(
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
        );
        std.debug.print("water: patch grid built in {d:.1} ms\n", .{@as(f64, @floatFromInt(nowNs() - t0)) / 1e6});
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
    var window_start = nowNs();
    var worst_ns: i64 = 0;
    var last_frame_ns = nowNs();
    var accumulator: f64 = 0;
    var was_swimming = false;
    const fixed_dt: f64 = 1.0 / 60.0;
    var frame_ms: f64 = 0;
    var fps_now: f64 = 0;
    frame: while (true) {
        const frame_start = nowNs();
        var frame_dt = @as(f64, @floatFromInt(frame_start - last_frame_ns)) / 1e9;
        last_frame_ns = frame_start;
        frame_dt = @min(frame_dt, 0.1);

        input.pump(&window);
        if (input.quit) {
            dcw.saveWorld(init.io, save_path, sun_time, playerSave(player), edits.items) catch |err| {
                std.debug.print("save on quit failed: {s}\n", .{@errorName(err)});
            };
            break :frame;
        }
        if (input.save_toggle) {
            dcw.saveWorld(init.io, save_path, sun_time, playerSave(player), edits.items) catch |err| {
                std.debug.print("save failed: {s}\n", .{@errorName(err)});
            };
            std.debug.print("saved {s} ({d} edits)\n", .{ save_path, edits.items.len });
        }
        if (input.hud_toggle) show_hud = !show_hud;
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
            player.update(@floatCast(fixed_dt), wish, up, sprint);
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
            next_verts.clearRetainingCapacity();
            next_idx.clearRetainingCapacity();
        }
        if (pending) {
            // Four chunks per frame is ~2.4 ms of meshing: enough to finish a 64-chunk patch in 16
            // frames (a quarter second) while the old patch stays on screen.
            const t_slice = nowNs();
            var done: i32 = 0;
            while (done < 4 and pending_cursor < PATCH * PATCH) : (done += 1) {
                const cx = @divTrunc(pending_cursor, PATCH);
                const cz = @mod(pending_cursor, PATCH);
                _ = try dcw.meshChunkInto(alloc, edits.items, pending_x, pending_z, cx, cz, &next_verts, &next_idx);
                pending_cursor += 1;
            }
            if (pending_cursor >= PATCH * PATCH) {
                // Complete: swap the buffers and upload both at once. Uploading is the only part that
                // must not be interrupted, and it is ~2 MB of vertex data.
                std.mem.swap(std.ArrayList(dcw.Vertex), &all_verts, &next_verts);
                std.mem.swap(std.ArrayList(u32), &all_idx, &next_idx);
                renderer.upload(all_verts.items, all_idx.items);
                patch_origin = pending_x;
                patch_origin_z = pending_z;
                {
                    const wt = nowNs();
                    water.ensurePatch(
                        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                    );
                    std.debug.print("water: patch grid rebuilt in {d:.1} ms\n", .{@as(f64, @floatFromInt(nowNs() - wt)) / 1e6});
                }
                {
                    const st = nowNs();
                    scatter.deinit(alloc);
                    scatter = try scatter_mod.build(
                        alloc,
                        edits.items,
                        @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
                        @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
                    );
                    grass.upload(scatter.blades.items);
                    props.uploadRocks(scatter.rocks.items);
                    std.debug.print("scatter: {d} blades, {d} trees, {d} rocks in {d:.1} ms\n", .{
                        scatter.blades.items.len,
                        scatter.trees.items.len,
                        scatter.rocks.items.len,
                        @as(f64, @floatFromInt(nowNs() - st)) / 1e6,
                    });
                }
                pending = false;
                rebuilds += 1;
                std.debug.print("stream: patch ({d},{d}) ready, {d} verts, {d} rebuilds, {d:.2} ms this slice\n", .{
                    patch_origin, patch_origin_z, all_verts.items.len, rebuilds,
                    @as(f64, @floatFromInt(nowNs() - t_slice)) / 1e6,
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
        water_clock += dt_f;
        cloud_shift = Vec3.init(cloud_shift.x + dt_f * 0.06, 0, cloud_shift.z + dt_f * 0.015);
        const ramp = sun.ramp();
        const lighting = sun.lighting();
        // The sky pass fills the whole screen, so with it running the magenta clear colour is never
        // visible and a hole shows sky instead. In the diagnostic mode the background is left empty
        // so every hole is the one colour the render cannot produce.
        if (!bg_magenta) sky.draw(vp, camera.position, &sun, true, cloud_shift);

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
        renderer.draw(
            vp,
            camera.position,
            lighting.sun_dir,
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
            all_idx.items.len,
        );
        grass.draw(vp, camera.position, lighting.sun_dir, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock);
        props.drawTrees(vp, camera.position, camera.right(), camera.up(), lighting.sun_dir, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock, scatter.trees.items);
        props.drawRocks(vp, camera.position, lighting.sun_dir, fog_col, fog_sun, fog_density, fog_height, fog_base, water_clock);

        water.draw(
            vp,
            camera.position,
            lighting.sun_dir,
            fog_col,
            fog_sun,
            fog_density,
            fog_height,
            fog_base,
            water_clock,
            @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))),
            @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))),
            @floatFromInt(PATCH * @as(i32, @intCast(CHUNK))),
        );

        if (show_hud) {
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
                .grass = scatter.blades.items.len,
                .trees = scatter.trees.items.len,
                .rocks = scatter.rocks.items.len,
                .impostors = props.last_impostor_count,
                .fly_speed = player.fly_speed,
                .edits = edits.items.len,
            });
        }
        window.swap();

        const frame_ns = nowNs() - frame_start;
        frame_ms = @as(f64, @floatFromInt(frame_ns)) / 1e6;
        if (frame_ns > worst_ns) worst_ns = frame_ns;
        frames += 1;
        const elapsed = nowNs() - window_start;
        if (elapsed >= 1_000_000_000) {
            fps_now = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(elapsed));
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
            window_start = nowNs();
        }
    }
}
