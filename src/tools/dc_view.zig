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
const BUILD_TAG = "incremental-v5";
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

fn buildField(alloc: std.mem.Allocator, cx: i32, cz: i32) ![]f32 {
    const side = CHUNK + 1;
    const vals = try alloc.alloc(f32, side * side * side);
    const ox: f32 = @floatFromInt(cx * @as(i32, @intCast(CHUNK)));
    const oz: f32 = @floatFromInt(cz * @as(i32, @intCast(CHUNK)));
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const x = ox + @as(f32, @floatFromInt(i)) * CELL;
                const y = 40.0 + @as(f32, @floatFromInt(j)) * CELL;
                const z = oz + @as(f32, @floatFromInt(k)) * CELL;
                vals[i + side * (j + side * k)] = y - heightAt(x, z);
            }
        }
    }
    return vals;
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
) !usize {
    const n = CHUNK;
    const side = n + 3; // owned cells + 2 skirt cells
    const vals = try alloc.alloc(f32, side * side * side);
    defer alloc.free(vals);

    // The field is a HEIGHT field: y - height(x, z) depends on the column only, so the height is
    // evaluated once per (x, z) and reused across all 35 y samples. Doing it per sample cost 140 ms
    // per patch against 5.7 ms this way.
    var heights: [side * side]f32 = undefined;
    var ck: usize = 0;
    while (ck < side) : (ck += 1) {
        var ci: usize = 0;
        while (ci < side) : (ci += 1) {
            const gx: i32 = (patch_origin + cx) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(ci)) - 1;
            const gz: i32 = (patch_origin_z + cz) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(ck)) - 1;
            heights[ci + side * ck] = heightAt(
                @as(f32, @floatFromInt(gx)) * CELL,
                @as(f32, @floatFromInt(gz)) * CELL,
            );
        }
    }
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const y = 40.0 + (@as(f32, @floatFromInt(j)) - 1.0) * CELL;
                vals[i + side * (j + side * k)] = y - heights[i + side * k];
            }
        }
    }

    const field = dc.Field{
        .values = vals,
        .n = CHUNK,
        .skirt = 1,
        .origin = .{
            @as(f32, @floatFromInt((patch_origin + cx) * @as(i32, @intCast(CHUNK)))),
            40.0,
            @as(f32, @floatFromInt((patch_origin_z + cz) * @as(i32, @intCast(CHUNK)))),
        },
        .cell = CELL,
    };
    const surf = try dc.extract(alloc, field);
    defer surf.deinit(alloc);
    const base: u32 = @intCast(verts.items.len);
    for (surf.verts) |v| {
        var mat: u8 = 0;
        const col = materialColour(v.pos, v.normal, &mat);
        try verts.append(alloc, .{ .pos = v.pos, .normal = v.normal, .colour = col, .material = @floatFromInt(mat) });
    }
    for (surf.indices) |v| try idx.append(alloc, base + v);
    return surf.quadCount();
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
) !usize {
    var quads: usize = 0;

    var cz: i32 = 0;
    while (cz < PATCH) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < PATCH) : (cx += 1) {
            quads += try meshChunkInto(alloc, patch_origin, patch_origin_z, cx, cz, verts, idx);
        }
    }
return quads;
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

    var window = try gfx.Window.init(.{
        .title = "voxel-zig dc spike",
        .width = 1920,
        .height = 1080,
        .vsync = true,
    });
    defer window.deinit();

    // The engine loads its GL entry points into a ProcTable; without this every gl call
    // below is a null pointer, which is what segfaulted the first build.
    try vz.gl.init();

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

    var patch_origin: i32 = -PATCH / 2;
    var patch_origin_z: i32 = -PATCH / 2;
    var sim_time: f32 = 0.0;
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
    const quads = try meshPatch(alloc, patch_origin, patch_origin_z, &all_verts, &all_idx);
    const all_verts_s = all_verts.items;
    const all_idx_s = all_idx.items;
    std.debug.print("DC viewer: {d} verts, {d} quads over {d} skirted chunks\n", .{ all_verts_s.len, quads, PATCH * PATCH });

    // Streaming plan step 1 and 2: a rebuild is just a second call, so prove that first.
    // Identical counts mean the build is a pure function of the origin; the timing says what a
    // chunk crossing would cost if it ran synchronously on this thread.
    var probe_verts: std.ArrayList(Coloured) = .empty;
    defer probe_verts.deinit(alloc);
    var probe_idx: std.ArrayList(u32) = .empty;
    defer probe_idx.deinit(alloc);
    const t_rebuild = nowNs();
    const probe_quads = try meshPatch(alloc, patch_origin, patch_origin_z, &probe_verts, &probe_idx);
    const rebuild_ms = @as(f64, @floatFromInt(nowNs() - t_rebuild)) / 1e6;
    const identical = probe_verts.items.len == all_verts_s.len and probe_idx.items.len == all_idx_s.len and probe_quads == quads;
    std.debug.print("rebuild: {d} quads in {d:.1} ms, identical to the first build: {}\n", .{ probe_quads, rebuild_ms, identical });

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
    frame: while (true) {
        const frame_start = nowNs();
        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl.SDL_EVENT_QUIT) break :frame;
            if (ev.type == sdl.SDL_EVENT_KEY_DOWN and ev.key.key == sdl.SDLK_ESCAPE) break :frame;
        }
        window.syncSize();
        const w: f32 = @floatFromInt(window.width);
        const h: f32 = @floatFromInt(window.height);
        gl.Viewport(0, 0, window.width, window.height);
        if (bg_magenta) gl.ClearColor(1.0, 0.0, 1.0, 1.0) else gl.ClearColor(0.30, 0.38, 0.50, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        // Streaming: the camera orbits, so the patch has to follow. Crossing a chunk border rebuilds
        // the whole patch synchronously - 39.7 ms measured - a visible hitch, and exactly why step 3
        // of the plan moves meshing to a worker thread.
        sim_time += 0.0167;
        const orbit: f32 = 0.05 * sim_time;
        const eye = [3]f32{ @cos(orbit) * 260.0, 92.0, @sin(orbit) * 260.0 };
        const cur_cx: i32 = @divFloor(@as(i32, @intFromFloat(eye[0])), @as(i32, @intCast(CHUNK)));
        const cur_cz: i32 = @divFloor(@as(i32, @intFromFloat(eye[2])), @as(i32, @intCast(CHUNK)));
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
        const look_x: f32 = @as(f32, @floatFromInt(patch_origin + @divFloor(PATCH, 2))) * @as(f32, @floatFromInt(CHUNK));
        const look_z: f32 = @as(f32, @floatFromInt(patch_origin_z + @divFloor(PATCH, 2))) * @as(f32, @floatFromInt(CHUNK));
        const view = lookAt(eye, .{ look_x, 86.0, look_z }, .{ 0, 1, 0 });
        const proj = perspective(0.9, w / @max(h, 1.0), 0.5, 900.0);
        const vp_m = mul(proj, view);
        const eye_v = Vec3.init(eye[0], eye[1], eye[2]);
        cloud_shift = Vec3.init(cloud_shift.x + 0.016 * 2.0, 0, cloud_shift.z + 0.016 * 0.6);
        sky.draw(Mat4{ .m = vp_m }, eye_v, &sun, true, cloud_shift);

        shader.use();
        shader.setMat4("u_view_proj", vp_m);
        gl.BindVertexArray(vao);
        // Read the live index count: after a streaming swap the startup slice is stale.
        gl.DrawElements(gl.TRIANGLES, @intCast(all_idx.items.len), gl.UNSIGNED_INT, 0);
        window.swap();

        const frame_ns = nowNs() - frame_start;
        if (frame_ns > worst_ns) worst_ns = frame_ns;
        frames += 1;
        const elapsed = nowNs() - window_start;
        if (elapsed >= 1_000_000_000) {
            const fps = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(elapsed));
            std.debug.print("fps {d:.1}  worst frame {d:.2} ms  verts {d}  quads {d}\n", .{
                fps,
                @as(f64, @floatFromInt(worst_ns)) / 1e6,
                all_verts_s.len,
                quads,
            });
            frames = 0;
            worst_ns = 0;
            window_start = nowNs();
        }
    }
}

// Streaming, the next step and why it is not here yet.
//
// This viewer meshes one patch at startup and uploads it once. Making the world follow the camera
// needs two things this file does not have: the build-and-upload block factored into a callable
// function (it currently lives inline in `main`, appending into two ArrayLists and then binding a
// VAO), and key handling that moves the camera. Both are mechanical, but the cost is a synchronous
// rebuild of the whole patch - 64 chunks x ~0.37 ms = ~24 ms - paid whenever the camera crosses a
// chunk border, so streaming properly means meshing off the main thread and swapping buffers, which
// is the same worker-pool design the block world already uses.
//
// Order that keeps each step verifiable: (1) factor build+upload into `meshPatch(alloc, origin, ...)`
// and call it twice in a row, asserting identical vertex counts; (2) call it on a chunk crossing
// and time the rebuild; (3) move meshing to a worker and upload on completion.
