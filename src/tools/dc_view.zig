//! Dual-contouring viewer (spike, ADR 0018).
//!
//! Meshes a patch of terrain with the DC kernel and draws it with a plain lit shader, so
//! the new surface can be looked at next to the blocky world without touching the block
//! renderer. Scroll-free: one orbit, ESC quits.

const std = @import("std");
const vz = @import("voxel_zig");

const dc = vz.voxel.dc;
const noise = vz.world.noise;
const gfx = vz.gfx;
const sdl = @import("sdl3");
const gl = @import("gl");

const CHUNK: usize = 32;
const SEED: u32 = 1337;
// 10x10 chunks: at PATCH=4 the 16-chunk boundary was visible in frame and accounted for
// 99.6% of the background pixels counted as "holes". A bigger patch pushes the world edge out of
// shot, which is the honest way to separate a mesher defect from the edge of the world.
const PATCH: i32 = 10;
const CELL: f32 = 1.0;

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
    const low = palette(h * 1.7, .{ 0.40, 0.34, 0.20 }, .{ 0.12, 0.11, 0.07 }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 0.05, 0.1 });
    const high = palette(h * 2.3 + 0.4, .{ 0.30, 0.38, 0.22 }, .{ 0.14, 0.12, 0.09 }, .{ 1.0, 1.0, 1.0 }, .{ 0.15, 0.2, 0.25 });
    const stone = palette(h * 3.1 + 1.7, .{ 0.30, 0.29, 0.28 }, .{ 0.08, 0.08, 0.08 }, .{ 1.0, 1.0, 1.0 }, .{ 0.3, 0.35, 0.4 });
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
    \\    vec3 c = albedo * (amb * 0.55 + ndl * 0.65);
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

pub fn main(init: std.process.Init) !void {
    _ = init;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var window = try gfx.Window.init(.{
        .title = "voxel-zig dc spike",
        .width = 1600,
        .height = 900,
        .vsync = true,
    });
    defer window.deinit();

    // The engine loads its GL entry points into a ProcTable; without this every gl call
    // below is a null pointer, which is what segfaulted the first build.
    try vz.gl.init();

    // Chunk-by-chunk, each with a one-cell skirt. Ownership is a half-open cube of sample
    // indices, so each border quad is emitted exactly once - by the chunk that owns it -
    // using a skirt vertex its neighbour computes identically. That is what closes the
    // seams the single-field version was hiding.
    const n = CHUNK;
    const side = n + 3; // owned cells + 2 skirt cells
    var all_verts: std.ArrayList(Coloured) = .empty;
    defer all_verts.deinit(alloc);
    var all_idx: std.ArrayList(u32) = .empty;
    defer all_idx.deinit(alloc);

    var quads: usize = 0;
    var cz: i32 = 0;
    while (cz < PATCH) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < PATCH) : (cx += 1) {
            const vals = try alloc.alloc(f32, side * side * side);
            defer alloc.free(vals);
            const ox: f32 = @floatFromInt(cx * @as(i32, @intCast(CHUNK)));
            const oz: f32 = @floatFromInt(cz * @as(i32, @intCast(CHUNK)));
            var k: usize = 0;
            while (k < side) : (k += 1) {
                var j: usize = 0;
                while (j < side) : (j += 1) {
                    var i: usize = 0;
                    while (i < side) : (i += 1) {
                        // World coordinates are built in INTEGER space and converted once.
                        // Adding the chunk origin as a float gave the same world sample
                        // different low bits in different chunks (ox + (i-1)*cell vs
                        // ox' + (i'-1)*cell), so the shared border vertices differed by ~1e-6
                        // and every chunk border drew a hairline. Integers make the two
                        // evaluations bitwise identical, which is what the skirt assumes.
                        const gx: i32 = @as(i32, @intCast(cx)) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(i)) - 1;
                        const gy: i32 = @as(i32, @intCast(j)) - 1;
                        const gz: i32 = @as(i32, @intCast(cz)) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(k)) - 1;
                        const x = @as(f32, @floatFromInt(gx)) * CELL;
                        const y = 40.0 + @as(f32, @floatFromInt(gy)) * CELL;
                        const z = @as(f32, @floatFromInt(gz)) * CELL;
                        vals[i + side * (j + side * k)] = y - heightAt(x, z);
                    }
                }
            }
            const field = dc.Field{
                .values = vals,
                .n = CHUNK,
                .skirt = 1,
                .origin = .{ ox, 40.0, oz },
                .cell = CELL,
            };
            const surf = try dc.extract(alloc, field);
            defer surf.deinit(alloc);
            quads += surf.quadCount();
            const base: u32 = @intCast(all_verts.items.len);
            for (surf.verts) |v| {
                var mat: u8 = 0;
                const col = materialColour(v.pos, v.normal, &mat);
                try all_verts.append(alloc, .{ .pos = v.pos, .normal = v.normal, .colour = col, .material = @floatFromInt(mat) });
            }
            for (surf.indices) |idx| try all_idx.append(alloc, base + idx);
        }
    }
    const all_verts_s = all_verts.items;
    const all_idx_s = all_idx.items;
    std.debug.print("DC viewer: {d} verts, {d} quads over {d} skirted chunks\n", .{ all_verts_s.len, quads, PATCH * PATCH });

    var shader = try gfx.Shader.init(vertex_src, fragment_src);
    defer shader.deinit();

    var vao: u32 = 0;
    var vbo: u32 = 0;
    var ebo: u32 = 0;
    gl.GenVertexArrays(1, @ptrCast(&vao));
    gl.GenBuffers(1, @ptrCast(&vbo));
    gl.GenBuffers(1, @ptrCast(&ebo));
    gl.BindVertexArray(vao);
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.BufferData(gl.ARRAY_BUFFER, @intCast(all_verts_s.len * @sizeOf(Coloured)), all_verts_s.ptr, gl.STATIC_DRAW);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(all_idx_s.len * @sizeOf(u32)), all_idx_s.ptr, gl.STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32));
    gl.EnableVertexAttribArray(2);
    gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32) * 2);
    gl.EnableVertexAttribArray(3);
    gl.VertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(Coloured), @sizeOf([3]f32) * 3);
    gl.BindVertexArray(0);

    gl.Enable(gl.DEPTH_TEST);
    // Culling is off deliberately: with it on, quads whose winding heuristic had to
    // guess (near-degenerate cells) vanish into the background and read as holes.
    gl.Disable(gl.CULL_FACE);

    const centre: f32 = @floatFromInt(@as(usize, @intCast(PATCH)) * CHUNK / 2);
    const index_count: u32 = @intCast(all_idx_s.len);

    frame: while (true) {
        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl.SDL_EVENT_QUIT) break :frame;
            if (ev.type == sdl.SDL_EVENT_KEY_DOWN and ev.key.key == sdl.SDLK_ESCAPE) break :frame;
        }
        window.syncSize();
        const w: f32 = @floatFromInt(window.width);
        const h: f32 = @floatFromInt(window.height);
        gl.Viewport(0, 0, window.width, window.height);
        gl.ClearColor(0.30, 0.38, 0.50, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const radius: f32 = 78.0;
        const eye = [3]f32{ centre + radius * 0.75, 92.0, centre + radius * 0.95 };
        const view = lookAt(eye, .{ centre, 58.0, centre }, .{ 0, 1, 0 });
        const proj = perspective(0.9, w / @max(h, 1.0), 0.5, 900.0);
        shader.use();
        shader.setMat4("u_view_proj", mul(proj, view));
        gl.BindVertexArray(vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(index_count), gl.UNSIGNED_INT, 0);
        window.swap();
    }
}
