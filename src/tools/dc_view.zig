//! Dual-contouring viewer (spike, ADR 0018).
//!
//! Meshes a patch of terrain with the DC kernel and draws it with a plain lit shader, so
//! the new surface can be looked at next to the blocky world without touching the block
//! renderer. Scroll-free: one orbit, ESC quits.

const std = @import("std");
const vz = @import("voxel_zig");

const dc = vz.voxel.dc;
const noise = vz.world.noise;
const sun_mod = vz.world.sun;
const Mat4 = vz.math.Mat4;
const Vec3 = vz.math.Vec3;
const gfx = vz.gfx;
const sdl = @import("sdl3");
const gl = @import("gl");

const CHUNK: usize = 32;

const TimeSpec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;
fn nowNs() i64 {
    var ts: TimeSpec = undefined;
    _ = clock_gettime(1, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}
const SEED: u32 = 1337;

/// Bumped whenever the field or the mesher changes. Printed at startup so a stale binary cannot be
/// mistaken for a change that "made no difference" - which is what the last commit could not rule out.
const BUILD_TAG = "controls-4";
// 8x8 chunks (64 chunks, 256 m^2), re-meshed as the camera crosses a chunk border:: at PATCH=4 the boundary was visible in frame and accounted for
// 99.6% of the background pixels counted as "holes". A bigger patch pushes the world edge out of
// shot, which is the honest way to separate a mesher defect from the edge of the world.
const PATCH: i32 = 8;
const CELL: f32 = 1.0;

/// The field, sampled directly from the project's fBm. It used to be a bilinear blend of four
/// `terrain.heightAt` values - four generator calls per sample, and a rebuild of 64 chunks cost
/// 157 ms because of it. Sampling the noise once is cheaper AND smoother: the block generator's
/// height is an integer, so the blend still carried a 1 m staircase that DC faithfully reproduced.
fn heightAt(x: f32, z: f32) f32 {
    const base: f32 = 62.0;
    const big = noise.fbm2(SEED, x * 0.009, z * 0.009, 4, 2.0, 0.5);
    const detail = noise.fbm2(SEED + 7, x * 0.041, z * 0.041, 3, 2.0, 0.5);
    return base + 22.0 * big + 3.0 * detail;
}

const Coloured = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    colour: [3]f32,
    material: f32, // uploaded as a float attribute; the id itself is discrete
};

/// IQ-style cosine palette: a + b*cos(2*pi*(c*t + d)). Four vectors give a whole material
/// range with no texture and no data.
fn palette(t: f32, a: [3]f32, b: [3]f32, c: [3]f32, d: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    inline for (0..3) |i| {
        out[i] = a[i] + b[i] * @cos(6.2831853 * (c[i] * t + d[i]));
    }
    return out;
}

/// Material from geometry alone: slope picks rock, height picks sand/grass/alpine tints.
/// A pure function of world position and normal, which is what keeps it stable across chunk
/// borders and future LOD levels.
fn materialColour(pos: [3]f32, nrm: [3]f32, out_material: *u8) [3]f32 {
    const slope: f32 = 1.0 - @abs(nrm[1]);
    const h: f32 = (pos[1] - 45.0) / 30.0;
    const rock = @min(@max((slope - 0.35) / 0.25, 0.0), 1.0);
    // 0 = ground, 1 = rock, 2 = scree on the steepest faces. Discrete ids, because that is what a
    // material byte can carry and what a shader can branch on cheaply.
    out_material.* = if (rock > 0.75) 2 else if (rock > 0.35) 1 else 0;
    const low = palette(h * 1.7, .{ 0.20, 0.22, 0.10 }, .{ 0.10, 0.10, 0.05 }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 0.05, 0.1 });
    const high = palette(h * 2.3 + 0.4, .{ 0.14, 0.20, 0.09 }, .{ 0.10, 0.09, 0.05 }, .{ 1.0, 1.0, 1.0 }, .{ 0.15, 0.2, 0.25 });
    const stone = palette(h * 3.1 + 1.7, .{ 0.22, 0.21, 0.20 }, .{ 0.06, 0.06, 0.06 }, .{ 1.0, 1.0, 1.0 }, .{ 0.3, 0.35, 0.4 });
    const ground = [3]f32{
        low[0] + (high[0] - low[0]) * @min(h, 1.0),
        low[1] + (high[1] - low[1]) * @min(h, 1.0),
        low[2] + (high[2] - low[2]) * @min(h, 1.0),
    };
    return .{
        ground[0] + (stone[0] - ground[0]) * rock,
        ground[1] + (stone[1] - ground[1]) * rock,
        ground[2] + (stone[2] - ground[2]) * rock,
    };
}

/// Walking and flying player for the DC patch.
///
/// The engine's `Player` collides its AABB against the voxel grid; a DC world has no blocks. The
/// same motion model runs against the height field the surface is extracted from, with the engine's
/// constants: axis-separated moves sub-stepped at 0.25 m, gravity 32, jump 9, walk 4.5, sprint 7,
/// fly 24, and a 1.05 m step-up. `groundAt` is the tallest of the four AABB footprint corners -
/// the terrain is single-valued in y, so that is the whole collision query. A rise greater than the
/// step height blocks the move, which is what a slope becomes.
const DcPlayer = struct {
    position: Vec3,
    velocity: Vec3 = Vec3.zero,
    yaw: f32,
    pitch: f32,
    flying: bool = false,
    on_ground: bool = false,
    /// Fly-mode speed in m/s, changed by the scroll wheel like `vz.Camera.adjustSpeed`.
    fly_speed: f32 = FLY_SPEED,

    const EYE: f32 = 1.62;
    const GRAVITY: f32 = 32.0;
    const TERMINAL_VELOCITY: f32 = 60.0;
    const JUMP_IMPULSE: f32 = 9.0;
    const WALK_SPEED: f32 = 4.5;
    const SPRINT_SPEED: f32 = 7.0;
    const FLY_SPEED: f32 = 24.0;
    const STEP_HEIGHT: f32 = 1.05;
    const RADIUS: f32 = 0.3;
    const MAX_SUBSTEP: f32 = 0.25;

    fn eyePosition(self: DcPlayer) Vec3 {
        return Vec3.init(self.position.x, self.position.y + EYE, self.position.z);
    }

    fn forward(self: DcPlayer) Vec3 {
        const cp = @cos(self.pitch);
        return Vec3.init(@sin(self.yaw) * cp, @sin(self.pitch), -@cos(self.yaw) * cp);
    }

    fn groundAt(x: f32, z: f32) f32 {
        var h = heightAt(x - RADIUS, z - RADIUS);
        h = @max(h, heightAt(x + RADIUS, z - RADIUS));
        h = @max(h, heightAt(x - RADIUS, z + RADIUS));
        h = @max(h, heightAt(x + RADIUS, z + RADIUS));
        return h;
    }

    fn blockedAt(self: DcPlayer, x: f32, z: f32) bool {
        return groundAt(x, z) > self.position.y + STEP_HEIGHT;
    }

    const Axis = enum { x, z };

    fn moveAxis(self: *DcPlayer, axis: Axis, delta: f32) void {
        var remaining = delta;
        while (@abs(remaining) > 0.00001) {
            const step = std.math.clamp(remaining, -MAX_SUBSTEP, MAX_SUBSTEP);
            const nx = if (axis == .x) self.position.x + step else self.position.x;
            const nz = if (axis == .z) self.position.z + step else self.position.z;
            if (self.blockedAt(nx, nz)) {
                self.velocity.x = 0;
                self.velocity.z = 0;
                return;
            }
            self.position.x = nx;
            self.position.z = nz;
            // Walk up a gentle rise without a jump. The engine does this by lifting and testing the
            // block ledge; here the surface is continuous, so the rise itself is the test.
            const ground = groundAt(nx, nz);
            if (ground > self.position.y and ground <= self.position.y + STEP_HEIGHT and self.velocity.y <= 0) {
                self.position.y = ground;
                self.on_ground = true;
            }
            remaining -= step;
        }
    }

    /// One fixed 60 Hz tick. `wish` is the yaw-relative horizontal direction (length 0 or 1),
    /// `up` is +1 for Space and -1 for Ctrl in fly mode.
    fn update(self: *DcPlayer, dt: f32, wish: Vec3, up: f32, sprint: bool) void {
        if (self.flying) {
            const speed = self.fly_speed * (if (sprint) @as(f32, 3.0) else 1.0);
            self.velocity = Vec3.init(wish.x * speed, up * speed, wish.z * speed);
            self.position = self.position.add(self.velocity.scale(dt));
            self.on_ground = false;
            return;
        }

        const speed = if (sprint) SPRINT_SPEED else WALK_SPEED;
        self.velocity.x = wish.x * speed;
        self.velocity.z = wish.z * speed;

        if (up > 0 and self.on_ground) self.velocity.y = JUMP_IMPULSE;
        self.velocity.y = @max(self.velocity.y - GRAVITY * dt, -TERMINAL_VELOCITY);

        self.on_ground = false;
        self.moveAxis(.x, self.velocity.x * dt);
        self.moveAxis(.z, self.velocity.z * dt);
        self.position.y += self.velocity.y * dt;

        const ground = groundAt(self.position.x, self.position.z);
        if (self.position.y <= ground) {
            self.position.y = ground;
            self.velocity.y = 0;
            self.on_ground = true;
        }
    }
};

const HudStats = struct {
    fps: f64,
    frame_ms: f64,
    worst_ms: f64,
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
    on_ground: bool,
    fly_speed: f32,
};

/// The engine's HUD (baked atlas, panel behind the text), at a small scale for a 4K window.
fn drawHud(hud: *vz.gfx.Hud, width: i32, height: i32, s: HudStats) void {
    hud.begin(width, height);
    hud.scale = 0.85;
    hud.panel(0, 0, 620, 8 + 5 * hud.lineHeight(), 0.55);

    var buffer: [192]u8 = undefined;
    var y: f32 = 8;

    hud.setColour(1.0, 1.0, 0.6);
    if (std.fmt.bufPrint(&buffer, "FPS {d:.1}  FRAME {d:.2} MS  WORST {d:.2} MS", .{ s.fps, s.frame_ms, s.worst_ms })) |text| {
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

    hud.setColour(0.7, 1.0, 0.7);
    if (std.fmt.bufPrint(&buffer, "{s}  {s}  FLY SPEED {d:.0}", .{
        if (s.flying) "FLY" else "WALK", if (s.on_ground) "GROUND" else "AIR", s.fly_speed,
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

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\layout(location = 2) in vec3 a_col;
    \\layout(location = 3) in float a_mat;
    \\uniform mat4 u_view_proj;
    \\out vec3 v_nrm;
    \\out vec3 v_pos;
    \\out vec3 v_col;
    \\out float v_mat;
    \\void main() {
    \\    v_nrm = a_nrm;
    \\    v_pos = a_pos;
    \\    v_col = a_col;
    \\    v_mat = a_mat;
    \\    gl_Position = u_view_proj * vec4(a_pos, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_nrm;
    \\in vec3 v_pos;
    \\in vec3 v_col;
    \\in float v_mat;

    \\float hash13(vec3 p) {
    \\    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    \\    p *= 17.0;
    \\    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    \\}

    \\// Inigo Quilez's value noise with analytic derivatives (articles/morenoise): the trilinear
    \\// interpolation is expanded into the k0..k7 polynomial and differentiated, so the value and its
    \\// gradient come out of ONE evaluation. Quintic interpolation is mandatory - with the cubic
    \\// the second derivative breaks and the analytic normal shows facets.
    \\vec4 noised(vec3 x) {
    \\    vec3 p = floor(x);
    \\    vec3 w = fract(x);
    \\    vec3 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    \\    vec3 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    \\    float a = hash13(p + vec3(0, 0, 0));
    \\    float b = hash13(p + vec3(1, 0, 0));
    \\    float c = hash13(p + vec3(0, 1, 0));
    \\    float d = hash13(p + vec3(1, 1, 0));
    \\    float e = hash13(p + vec3(0, 0, 1));
    \\    float f = hash13(p + vec3(1, 0, 1));
    \\    float g = hash13(p + vec3(0, 1, 1));
    \\    float h = hash13(p + vec3(1, 1, 1));
    \\    float k0 = a;
    \\    float k1 = b - a;
    \\    float k2 = c - a;
    \\    float k3 = e - a;
    \\    float k4 = a - b - c + d;
    \\    float k5 = a - c - e + g;
    \\    float k6 = a - b - e + f;
    \\    float k7 = -a + b + c - d + e - f - g + h;
    \\    float v = k0 + k1*u.x + k2*u.y + k3*u.z + k4*u.x*u.y + k5*u.y*u.z + k6*u.z*u.x + k7*u.x*u.y*u.z;
    \\    vec3 gr = du * vec3(k1 + k4*u.y + k6*u.z + k7*u.y*u.z,
    \\                        k2 + k5*u.z + k4*u.x + k7*u.z*u.x,
    \\                        k3 + k6*u.x + k5*u.y + k7*u.x*u.y);
    \\    return vec4(v, gr);
    \\}
    \\out vec4 frag;
    \\void main() {
    \\    // Two octaves of value noise in WORLD space: world-space means the pattern is continuous
    \\    // across every chunk border and stable through LOD, which blocky textures never were.
    \\    vec3 wp = v_pos * 0.35;
    \\    vec4 o1 = noised(wp);
    \\    vec4 o2 = noised(wp * 2.7 + 11.0);
    \\    float detail = o1.x * 0.65 + o2.x * 0.35;
    \\    vec3 grad = o1.yzw * 0.65 + o2.yzw * 2.7 * 0.35;
    \\
    \\    // Bump without a normal map: surface normal plus a scaled noise gradient, IQ's form.
    \\    // bump is per material - rock is rougher than ground, scree roughest.
    \\    float bump = v_mat < 0.5 ? 0.10 : (v_mat < 1.5 ? 0.22 : 0.34);
    \\    vec3 n = normalize(v_nrm + grad * bump);
    \\    vec3 l = normalize(vec3(0.45, 0.75, 0.40));
    \\    float ndl = max(dot(n, l), 0.0);
    \\    vec3 sky = vec3(0.36, 0.48, 0.62);
    \\    vec3 ground = vec3(0.16, 0.18, 0.14);
    \\    vec3 amb = mix(ground, sky, n.y * 0.5 + 0.5);
    \\    vec3 albedo = v_col * (0.86 + 0.30 * detail);
    \\    // Lighting is deliberately shy of 1.0: albedo arrives already close to mid grey, and
    \\    // multiplying it by ~1.8 and then gamma-encoding clips the whole surface to white.
    \\    // Exposure + ACES (Narkowicz), the same curve the engine's post pass applies (ADR 0011).
    \\    // Without it, linear radiance above 1.0 clips to white once the sRGB framebuffer encodes,
    \\    // which is what turned the surface into a pale sheet the moment FRAMEBUFFER_SRGB went on.
    \\    vec3 c = albedo * (amb + ndl * 1.15) * 0.16;
    \\    c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    \\    frag = vec4(pow(c, vec3(0.4545)), 1.0);
    \\}
;

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    const f = 1.0 / @tan(fovy * 0.5);
    return .{
        f / aspect, 0,      0,                          0,
        0,          f,      0,                          0,
        0,          0,      (far + near) / (near - far), -1,
        0,          0,      (2 * far * near) / (near - far), 0,
    };
}

fn lookAt(eye: [3]f32, target: [3]f32, up: [3]f32) [16]f32 {
    const fx = target[0] - eye[0];
    const fy = target[1] - eye[1];
    const fz = target[2] - eye[2];
    const fl = @sqrt(fx * fx + fy * fy + fz * fz);
    const f = [3]f32{ fx / fl, fy / fl, fz / fl };
    var sx = f[1] * up[2] - f[2] * up[1];
    var sy = f[2] * up[0] - f[0] * up[2];
    var sz = f[0] * up[1] - f[1] * up[0];
    const sl = @sqrt(sx * sx + sy * sy + sz * sz);
    sx /= sl;
    sy /= sl;
    sz /= sl;
    const ux = sy * f[2] - sz * f[1];
    const uy = sz * f[0] - sx * f[2];
    const uz = sx * f[1] - sy * f[0];
    return .{
        sx,                    ux,                    -f[0],                  0,
        sy,                    uy,                    -f[1],                  0,
        sz,                    uz,                    -f[2],                  0,
        -(sx * eye[0] + sy * eye[1] + sz * eye[2]),
        -(ux * eye[0] + uy * eye[1] + uz * eye[2]),
        (f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2]),
        1,
    };
}

fn mul(a: [16]f32, b: [16]f32) [16]f32 {
    var out: [16]f32 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = sum;
        }
    }
    return out;
}



const ChunkStats = struct {
    quads: usize = 0,
    skipped_missing: usize = 0,
    skipped_bounds: usize = 0,
    ambiguous: usize = 0,
    degenerate: usize = 0,
    min_area: f32 = 1e9,
};

const PatchStats = struct {
    quads: usize = 0,
    skipped_missing: usize = 0,
    skipped_bounds: usize = 0,
    ambiguous: usize = 0,
    degenerate: usize = 0,
    min_area: f32 = 1e9,
};

/// Meshes ONE chunk of the patch into the given buffers. Split out so a rebuild can be spread across
/// frames: 64 chunks x ~0.6 ms is a 40 ms hitch if done at once, and a fraction of a millisecond per
/// frame if done a few at a time - which removes the need for a worker thread entirely.
fn meshChunkInto(
    alloc: std.mem.Allocator,
    patch_origin: i32,
    patch_origin_z: i32,
    cx: i32,
    cz: i32,
    verts: *std.ArrayList(Coloured),
    idx: *std.ArrayList(u32),
) !ChunkStats {
    const n = CHUNK;
    // ONE global y slab for the whole world: every chunk samples the same y planes (so a shared
    // border cell is evaluated from the same values) and the slab is tall enough for the peaks near
    // 87. It is not what fixes the border holes - the gradient stencil in the skirt does that; see
    // the skirt comment below.
    const ny_cells: usize = 71; // y 20..92: covers the terrain's peak near 87 with room below
    const y_base: f32 = 20.0;
    // TWO skirt cells each side, and that number is a correctness requirement, not a tuning knob.
    // A duplicated border cell is meshed by both chunks; its copies agree only if the QEF sees the
    // same input from both. The field values and sample positions are already bit-identical, but
    // `Field.gradient()` falls back to a one-sided difference at the padded grid's edge - so with a
    // one-cell skirt the chunk that holds the cell in its skirt computes a different stencil than
    // the chunk that owns it. Measured with the per-cell copy metric: 510 border cells disagreed by
    // more than 1e-3 (299 by more than half a block, worst 1.36). A second skirt cell puts the
    // duplicated cells two samples away from the grid edge, so both sides use central differences.
    // The earlier "two-cell skirt made it worse" measurement counted unreferenced skirt vertices,
    // which this metric does not.
    const skirt: usize = 2;
    const side = n + 1 + 2 * skirt;
    const side_y = ny_cells + 1 + 2 * skirt;
    const vals = try alloc.alloc(f32, side * side_y * side);
    defer alloc.free(vals);

    // The field is a HEIGHT field: y - height(x, z) depends on the column only, so the height is
    // evaluated once per (x, z) and reused across all 35 y samples. Doing it per sample cost 140 ms
    // per patch against 5.7 ms this way.
    var heights: [side * side]f32 = undefined;
    var ck: usize = 0;
    while (ck < side) : (ck += 1) {
        var ci: usize = 0;
        while (ci < side) : (ci += 1) {
            const gx: i32 = (patch_origin + cx) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(ci)) - @as(i32, @intCast(skirt));
            const gz: i32 = (patch_origin_z + cz) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(ck)) - @as(i32, @intCast(skirt));
            heights[ci + side * ck] = heightAt(
                @as(f32, @floatFromInt(gx)) * CELL,
                @as(f32, @floatFromInt(gz)) * CELL,
            );
        }
    }
    // Global slab: tall enough for the peaks (which is what the earlier per-chunk anchoring was for)
    // AND identical in every chunk (which is what the hairlines needed).
    const y0 = y_base;
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side_y) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const y = y0 + (@as(f32, @floatFromInt(j)) - @as(f32, @floatFromInt(skirt))) * CELL;
                vals[i + side * (j + side_y * k)] = y - heights[i + side * k];
            }
        }
    }

    const field = dc.Field{
        .values = vals,
        .n = CHUNK,
        .ny = ny_cells,
        .skirt = skirt,
        .origin = .{
            @as(f32, @floatFromInt((patch_origin + cx) * @as(i32, @intCast(CHUNK)))),
            y0,
            @as(f32, @floatFromInt((patch_origin_z + cz) * @as(i32, @intCast(CHUNK)))),
        },
        .cell = CELL,
    };
    const surf = try dc.extract(alloc, field);
    defer surf.deinit(alloc);
    const stats = ChunkStats{
        .quads = surf.quadCount(),
        .skipped_missing = dc.skipped_missing_cell,
        .skipped_bounds = dc.skipped_bounds,
        .ambiguous = dc.ambiguous_cells,
        .degenerate = dc.degenerate_quads,
        .min_area = dc.min_quad_area_observed,
    };
    const base: u32 = @intCast(verts.items.len);
    for (surf.verts) |v| {
        var mat: u8 = 0;
        const col = materialColour(v.pos, v.normal, &mat);
        try verts.append(alloc, .{ .pos = v.pos, .normal = v.normal, .colour = col, .material = @floatFromInt(mat) });
    }
    for (surf.indices) |v| try idx.append(alloc, base + v);
    return stats;
}

/// Meshes a PATCH x PATCH block of chunks with the one-cell skirt. Factored out of `main` so a
/// rebuild is possible at all: without this the world could only ever be meshed once, and streaming
/// is exactly "call this again with a different origin".
fn meshPatch(
    alloc: std.mem.Allocator,
    patch_origin: i32,
    patch_origin_z: i32,
    verts: *std.ArrayList(Coloured),
    idx: *std.ArrayList(u32),
) !PatchStats {
    var out = PatchStats{};

    var cz: i32 = 0;
    while (cz < PATCH) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < PATCH) : (cx += 1) {
            const st = try meshChunkInto(alloc, patch_origin, patch_origin_z, cx, cz, verts, idx);
            out.quads += st.quads;
            out.skipped_missing += st.skipped_missing;
            out.skipped_bounds += st.skipped_bounds;
            out.ambiguous += st.ambiguous;
            out.degenerate += st.degenerate;
            if (st.min_area < out.min_area) out.min_area = st.min_area;
        }
    }
    return out;
}


/// Uploads a mesh into the existing VAO/VBO/EBO. Factored out with `meshPatch` so a rebuild can
/// replace the buffers in place: streaming is "mesh again, upload again", nothing else.
fn uploadMesh(vao: *u32, vbo: *u32, ebo: *u32, verts: []const Coloured, idx: []const u32) void {
    if (vao.* == 0) {
        gl.GenVertexArrays(1, @ptrCast(vao));
        gl.GenBuffers(1, @ptrCast(vbo));
        gl.GenBuffers(1, @ptrCast(ebo));
    }
    gl.BindVertexArray(vao.*);
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo.*);
    gl.BufferData(gl.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(Coloured)), verts.ptr, gl.STATIC_DRAW);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo.*);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(idx.len * @sizeOf(u32)), idx.ptr, gl.STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32));
    gl.EnableVertexAttribArray(2);
    gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32) * 2);
    gl.EnableVertexAttribArray(3);
    gl.VertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32) * 3);
    gl.BindVertexArray(0);
}


/// Counts near-duplicate vertices. If the skirt ownership rule has an off-by-one, adjacent chunks
/// put a vertex at *almost* the same point instead of exactly the same one, and the quad that should
/// bridge them leaves a hairline. Welding by position in the tiling test hides precisely this, so it
/// has to be measured on the raw mesh.
fn countNearDuplicates(alloc: std.mem.Allocator, verts: []const Coloured) !struct { exact: usize, near: usize } {
    const Cell = struct {
        fn key(x: f32, y: f32, z: f32, inv: f32) [3]i32 {
            return .{
                @intFromFloat(@floor(x * inv)),
                @intFromFloat(@floor(y * inv)),
                @intFromFloat(@floor(z * inv)),
            };
        }
    };
    const inv: f32 = 4.0; // buckets of 0.25 blocks, so a pair within half a block shares buckets
    var map = std.AutoHashMap([3]i32, std.ArrayListUnmanaged(u32)).init(alloc);
    defer {
        var it = map.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        map.deinit();
    }
    for (verts, 0..) |v, i| {
        const k = Cell.key(v.pos[0], v.pos[1], v.pos[2], inv);
        const gop = try map.getOrPut(k);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, @intCast(i));
    }
    var exact: usize = 0;
    var near: usize = 0;
    for (verts, 0..) |v, i| {
        const base = Cell.key(v.pos[0], v.pos[1], v.pos[2], inv);
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    const k = [3]i32{ base[0] + dx, base[1] + dy, base[2] + dz };
                    const list = map.get(k) orelse continue;
                    for (list.items) |j| {
                        if (j <= i) continue;
                        const o = verts[j].pos;
                        const ddx = o[0] - v.pos[0];
                        const ddy = o[1] - v.pos[1];
                        const ddz = o[2] - v.pos[2];
                        const d2 = ddx * ddx + ddy * ddy + ddz * ddz;
                        if (d2 <= 1e-10) {
                            exact += 1;
                        } else if (d2 < 0.25) {
                            near += 1;
                        }
                    }
                }
            }
        }
    }
    return .{ .exact = exact, .near = near };
}

/// The defect this measures: one vertex per crossed cell means the SAME world cell is meshed by
/// every chunk whose padded grid contains it, and the copies must be bit-identical or the seam
/// crack shows background. Keying by the cell (floor of the position, valid because the QEF is
/// clamped 2 % inside its cell) compares copies of one cell. The older near-duplicate metric
/// counted every pair of unrelated vertices closer than half a block, including skirt vertices that
/// no quad references, so it could not tell a real seam mismatch from two adjacent cells whose
/// surface points happen to sit close together.
const CopyStats = struct {
    pairs: usize = 0,
    exact: usize = 0, // delta <= 1e-6
    tiny: usize = 0, // 1e-6 .. 1e-3
    big: usize = 0, // > 1e-3
    border: usize = 0, // pairs whose cell sits on a chunk border column
    hist: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 }, // 1e-6,1e-4,1e-3,1e-2,1e-1,0.5,inf
    max_delta: f32 = 0,
    worst_pos: [3]f32 = .{ 0, 0, 0 },
};

fn countCellCopies(alloc: std.mem.Allocator, verts: []const Coloured, idx: []const u32) !CopyStats {
    var out = CopyStats{};
    const used = try alloc.alloc(bool, verts.len);
    defer alloc.free(used);
    @memset(used, false);
    for (idx) |i| used[i] = true;

    var first = std.AutoHashMap([3]i32, u32).init(alloc);
    defer first.deinit();
    for (verts, 0..) |v, i| {
        if (!used[i]) continue;
        const key = [3]i32{
            @intFromFloat(@floor(v.pos[0])),
            @intFromFloat(@floor(v.pos[1])),
            @intFromFloat(@floor(v.pos[2])),
        };
        const gop = try first.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
            continue;
        }
        const o = verts[gop.value_ptr.*].pos;
        const dx = v.pos[0] - o[0];
        const dy = v.pos[1] - o[1];
        const dz = v.pos[2] - o[2];
        const d = @sqrt(dx * dx + dy * dy + dz * dz);
        out.pairs += 1;
        const bucket: usize = if (d <= 1e-6) 0 else if (d <= 1e-4) 1 else if (d <= 1e-3) 2 else if (d <= 1e-2) 3 else if (d <= 1e-1) 4 else if (d <= 0.5) 5 else 6;
        out.hist[bucket] += 1;
        if (d <= 1e-6) {
            out.exact += 1;
        } else if (d <= 1e-3) {
            out.tiny += 1;
        } else {
            out.big += 1;
        }
        const bx = @mod(key[0], @as(i32, @intCast(CHUNK)));
        const bz = @mod(key[2], @as(i32, @intCast(CHUNK)));
        const is_border = bx == 0 or bx == CHUNK - 1 or bz == 0 or bz == CHUNK - 1;
        if (d > 1e-3 and is_border) out.border += 1;
        if (d > out.max_delta) {
            out.max_delta = d;
            out.worst_pos = v.pos;
        }
    }
    return out;
}

/// Connectivity of the whole patch: every interior edge must be shared by exactly two triangles. An
/// edge counted once is a crack where background shows through; counted three or more is duplicated
/// or folded geometry. Edges within two blocks of the patch's x/z bounds are the world edge, where
/// the surface legitimately stops, and are reported apart from the interior.
const ClosureStats = struct {
    edges: usize = 0,
    open: usize = 0,
    open_outer: usize = 0,
    open_interior: usize = 0,
    once: usize = 0,
    more: usize = 0,
    nan_verts: usize = 0,
    first_interior: [3]f32 = .{ 0, 0, 0 },
};

fn checkClosure(
    alloc: std.mem.Allocator,
    verts: []const Coloured,
    idx: []const u32,
    patch_origin: i32,
    patch_origin_z: i32,
) !ClosureStats {
    var out = ClosureStats{};
    for (verts) |v| {
        if (!(std.math.isFinite(v.pos[0]) and std.math.isFinite(v.pos[1]) and std.math.isFinite(v.pos[2]))) out.nan_verts += 1;
    }
    var counts = std.AutoHashMap(u64, u8).init(alloc);
    defer counts.deinit();

    // Chunk meshes are concatenated without a shared vertex index, so an edge on a chunk border is
    // two different index pairs even when the two vertices are the same point. Weld bit-identical
    // copies by quantised position first (the two-cell skirt makes them exact); otherwise every
    // border reads as an open edge and the count says nothing about the surface being closed.
    const canon = try alloc.alloc(u32, verts.len);
    defer alloc.free(canon);
    var posmap = std.AutoHashMap([3]i64, u32).init(alloc);
    defer posmap.deinit();
    const quant = struct {
        fn f(x: f32) i64 {
            return @intFromFloat(@round(x * 1024.0));
        }
    }.f;
    for (verts, 0..) |v, i| {
        const q = [3]i64{ quant(v.pos[0]), quant(v.pos[1]), quant(v.pos[2]) };
        const gop = try posmap.getOrPut(q);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        canon[i] = gop.value_ptr.*;
    }

    var t: usize = 0;
    while (t + 2 < idx.len) : (t += 3) {
        for (0..3) |e| {
            const a = canon[idx[t + e]];
            const b = canon[idx[t + (e + 1) % 3]];
            if (a == b) continue;
            const lo = @min(a, b);
            const hi = @max(a, b);
            const key = (@as(u64, lo) << 32) | @as(u64, hi);
            const gop = try counts.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* +|= 1;
        }
    }
    out.edges = counts.count();
    const x0: f32 = @as(f32, @floatFromInt(patch_origin * @as(i32, @intCast(CHUNK))));
    const x1: f32 = @as(f32, @floatFromInt((patch_origin + PATCH) * @as(i32, @intCast(CHUNK))));
    const z0: f32 = @as(f32, @floatFromInt(patch_origin_z * @as(i32, @intCast(CHUNK))));
    const z1: f32 = @as(f32, @floatFromInt((patch_origin_z + PATCH) * @as(i32, @intCast(CHUNK))));
    const isOuter = struct {
        fn f(p: [3]f32, a: f32, b: f32, c: f32, d: f32) bool {
            return p[0] <= a + 2.0 or p[0] >= b - 2.0 or p[2] <= c + 2.0 or p[2] >= d - 2.0;
        }
    }.f;
    var it = counts.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == 2) continue;
        out.open += 1;
        if (kv.value_ptr.* == 1) out.once += 1 else out.more += 1;
        const key = kv.key_ptr.*;
        const a: u32 = @intCast(key >> 32);
        const b: u32 = @intCast(key & 0xffffffff);
        if (isOuter(verts[a].pos, x0, x1, z0, z1) or isOuter(verts[b].pos, x0, x1, z0, z1)) {
            out.open_outer += 1;
        } else {
            if (out.open_interior == 0) out.first_interior = verts[a].pos;
            out.open_interior += 1;
        }
    }
    return out;
}

fn diagnoseMesh(
    alloc: std.mem.Allocator,
    verts: []const Coloured,
    idx: []const u32,
    patch_origin: i32,
    patch_origin_z: i32,
) !void {
    const copies = try countCellCopies(alloc, verts, idx);
    std.debug.print(
        "diag copies: {d} cell pairs (exact {d}, <=1e-3 {d}, >1e-3 {d}, border>1e-3 {d}), max delta {d:.6} at ({d:.3},{d:.3},{d:.3})\n",
        .{ copies.pairs, copies.exact, copies.tiny, copies.big, copies.border, copies.max_delta, copies.worst_pos[0], copies.worst_pos[1], copies.worst_pos[2] },
    );
    std.debug.print(
        "diag delta hist: <=1e-6 {d}, <=1e-4 {d}, <=1e-3 {d}, <=1e-2 {d}, <=1e-1 {d}, <=0.5 {d}, >0.5 {d}\n",
        .{ copies.hist[0], copies.hist[1], copies.hist[2], copies.hist[3], copies.hist[4], copies.hist[5], copies.hist[6] },
    );
    const cl = try checkClosure(alloc, verts, idx, patch_origin, patch_origin_z);
    std.debug.print(
        "diag closure: {d} edges, open {d} (once {d}, more {d}; outer {d}, interior {d}), nan verts {d}, first interior open ({d:.3},{d:.3},{d:.3})\n",
        .{ cl.edges, cl.open, cl.once, cl.more, cl.open_outer, cl.open_interior, cl.nan_verts, cl.first_interior[0], cl.first_interior[1], cl.first_interior[2] },
    );
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

    // The engine's own sky and volumetric clouds (ADR 0010), ported rather than reimplemented:
    // the point of the spike is to judge the DC surface, and it should be lit by the same sky the
    // block world uses so the two are comparable by eye.
    var sky = try vz.gfx.SkyRenderer.init();
    defer sky.deinit();
    var sun = sun_mod.Sun.init();
    sun.setTime(0.30); // ADR 0009: noon sits at t = 0.30 of the 300 s cycle
    var cloud_shift = Vec3.init(0, 0, 0);

    var all_verts: std.ArrayList(Coloured) = .empty;
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
    var camera = vz.Camera{ .fov_y_deg = 70, .near = 0.1, .far = 1000 };
    var patch_origin: i32 = @divFloor(@as(i32, @intFromFloat(spawn_x)), @as(i32, @intCast(CHUNK))) - @divFloor(PATCH, 2);
    var patch_origin_z: i32 = @divFloor(@as(i32, @intFromFloat(spawn_z)), @as(i32, @intCast(CHUNK))) - @divFloor(PATCH, 2);
    // Double buffering: the new patch is built a few chunks per frame into `next_*` while the old
    // one keeps rendering. Swapping only when it is complete means no frame ever sees a half-built
    // patch, and no frame pays the full 40-50 ms.
    var next_verts: std.ArrayList(Coloured) = .empty;
    defer next_verts.deinit(alloc);
    var next_idx: std.ArrayList(u32) = .empty;
    defer next_idx.deinit(alloc);
    var pending = false;
    var pending_x: i32 = 0;
    var pending_z: i32 = 0;
    var pending_cursor: i32 = 0;
    var rebuilds: usize = 0;
    const first = try meshPatch(alloc, patch_origin, patch_origin_z, &all_verts, &all_idx);
    const all_verts_s = all_verts.items;
    const all_idx_s = all_idx.items;
    std.debug.print("DC viewer: {d} verts, {d} quads over {d} skirted chunks\n", .{ all_verts_s.len, first.quads, PATCH * PATCH });
    std.debug.print("kernel: emitted {d}, skipped_missing {d}, skipped_bounds {d}, ambiguous cells {d}, degenerate quads {d}, min tri area {d:.6}\n", .{
        first.quads, first.skipped_missing, first.skipped_bounds, first.ambiguous, first.degenerate, first.min_area,
    });
    try diagnoseMesh(alloc, all_verts_s, all_idx_s, patch_origin, patch_origin_z);
    {
        const dup = try countNearDuplicates(alloc, all_verts_s);
        std.debug.print("duplicates: exact {d}, near (<0.5 block, >1e-5) {d}\n", .{ dup.exact, dup.near });
    }

    // Streaming plan step 1 and 2: a rebuild is just a second call, so prove that first.
    // Identical counts mean the build is a pure function of the origin; the timing says what a
    // chunk crossing would cost if it ran synchronously on this thread.
    var probe_verts: std.ArrayList(Coloured) = .empty;
    defer probe_verts.deinit(alloc);
    var probe_idx: std.ArrayList(u32) = .empty;
    defer probe_idx.deinit(alloc);
    const t_rebuild = nowNs();
    const probe = try meshPatch(alloc, patch_origin, patch_origin_z, &probe_verts, &probe_idx);
    const rebuild_ms = @as(f64, @floatFromInt(nowNs() - t_rebuild)) / 1e6;
    const identical = probe_verts.items.len == all_verts_s.len and probe_idx.items.len == all_idx_s.len and probe.quads == first.quads;
    std.debug.print("rebuild: {d} quads in {d:.1} ms, identical to the first build: {}\n", .{ probe.quads, rebuild_ms, identical });

    var shader = try gfx.Shader.init(vertex_src, fragment_src);
    defer shader.deinit();

    var vao: u32 = 0;
    var vbo: u32 = 0;
    var ebo: u32 = 0;
    uploadMesh(&vao, &vbo, &ebo, all_verts_s, all_idx_s);

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
    const fixed_dt: f64 = 1.0 / 60.0;
    var frame_ms: f64 = 0;
    var fps_now: f64 = 0;
    frame: while (true) {
        const frame_start = nowNs();
        var frame_dt = @as(f64, @floatFromInt(frame_start - last_frame_ns)) / 1e9;
        last_frame_ns = frame_start;
        frame_dt = @min(frame_dt, 0.1);

        input.pump(&window);
        if (input.quit) break :frame;
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
                _ = try meshChunkInto(alloc, pending_x, pending_z, cx, cz, &next_verts, &next_idx);
                pending_cursor += 1;
            }
            if (pending_cursor >= PATCH * PATCH) {
                // Complete: swap the buffers and upload both at once. Uploading is the only part that
                // must not be interrupted, and it is ~2 MB of vertex data.
                std.mem.swap(std.ArrayList(Coloured), &all_verts, &next_verts);
                std.mem.swap(std.ArrayList(u32), &all_idx, &next_idx);
                uploadMesh(&vao, &vbo, &ebo, all_verts.items, all_idx.items);
                patch_origin = pending_x;
                patch_origin_z = pending_z;
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

        // Clouds drift on the frame delta instead of a fixed 0.016 per frame: the old code moved
        // 0.016*2.0 per frame, i.e. 3.84 m/s on this 120 Hz display (2 m/s only at 60 Hz). The
        // speed here is 75 % of what was on screen and no longer depends on the frame rate.
        const dt_f: f32 = @floatCast(frame_dt);
        cloud_shift = Vec3.init(cloud_shift.x + dt_f * 2.9, 0, cloud_shift.z + dt_f * 0.85);
        // The sky pass fills the whole screen, so with it running the magenta clear colour is never
        // visible and a hole shows sky instead. In the diagnostic mode the background is left empty
        // so every hole is the one colour the render cannot produce.
        if (!bg_magenta) sky.draw(vp, camera.position, &sun, true, cloud_shift);

        // hud.end() leaves depth writing off and blending on; restore the terrain state explicitly
        // every frame rather than trusting that the HUD put it back.
        gl.Enable(gl.DEPTH_TEST);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        shader.use();
        shader.setMat4("u_view_proj", vp.m);
        gl.BindVertexArray(vao);
        // Read the live index count: after a streaming swap the startup slice is stale.
        gl.DrawElements(gl.TRIANGLES, @intCast(all_idx.items.len), gl.UNSIGNED_INT, 0);

        if (show_hud) {
            drawHud(&hud, window.width, window.height, .{
                .fps = if (fps_now > 0) fps_now else 1000.0 / @max(frame_ms, 0.001),
                .frame_ms = frame_ms,
                .worst_ms = @as(f64, @floatFromInt(worst_ns)) / 1e6,
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
                .on_ground = player.on_ground,
                .fly_speed = player.fly_speed,
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
                if (player.flying) "FLY" else "WALK",
                if (player.on_ground) "GROUND" else "AIR",
                player.fly_speed,
            });
            frames = 0;
            worst_ns = 0;
            window_start = nowNs();
        }
    }
}
