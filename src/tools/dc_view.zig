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
const PATCH: i32 = 4; // chunks per axis
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

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\uniform mat4 u_view_proj;
    \\out vec3 v_nrm;
    \\out vec3 v_pos;
    \\void main() {
    \\    v_nrm = a_nrm;
    \\    v_pos = a_pos;
    \\    gl_Position = u_view_proj * vec4(a_pos, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_nrm;
    \\in vec3 v_pos;
    \\out vec4 frag;
    \\void main() {
    \\    vec3 n = normalize(v_nrm);
    \\    vec3 l = normalize(vec3(0.45, 0.75, 0.40));
    \\    float ndl = max(dot(n, l), 0.0);
    \\    vec3 sky = vec3(0.36, 0.48, 0.62);
    \\    vec3 ground = vec3(0.16, 0.18, 0.14);
    \\    vec3 amb = mix(ground, sky, n.y * 0.5 + 0.5);
    \\    vec3 albedo = vec3(0.42, 0.52, 0.34);
    \\    vec3 c = albedo * (amb + ndl * 1.15);
    \\    // Simple height tint so slopes read against the low ground.
    \\    c = mix(c, vec3(0.52, 0.46, 0.38), clamp((v_pos.y - 50.0) / 24.0, 0.0, 1.0) * 0.45);
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

    // The whole patch as ONE field. Meshing chunk-by-chunk leaves each chunk's outer quad
    // ring missing - that ring is what a neighbour completes - and the cracks are plainly
    // visible in the screenshot of the first build. One field has no interior borders.
    const n = CHUNK * @as(usize, @intCast(PATCH));
    const side = n + 1;
    const vals = try alloc.alloc(f32, side * side * side);
    defer alloc.free(vals);
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const x = @as(f32, @floatFromInt(i)) * CELL;
                const y = 40.0 + @as(f32, @floatFromInt(j)) * CELL;
                const z = @as(f32, @floatFromInt(k)) * CELL;
                vals[i + side * (j + side * k)] = y - heightAt(x, z);
            }
        }
    }
    const field = dc.Field{ .values = vals, .n = n, .origin = .{ 0, 40.0, 0 }, .cell = CELL };
    const surf = try dc.extract(alloc, field);
    defer surf.deinit(alloc);
    std.debug.print("DC viewer: {d} verts, {d} quads over one {d}^3 field\n", .{ surf.verts.len, surf.quadCount(), n });

    const all_verts = surf.verts;
    const all_idx = surf.indices;

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
    gl.BufferData(gl.ARRAY_BUFFER, @intCast(all_verts.len * @sizeOf(dc.Vertex)), all_verts.ptr, gl.STATIC_DRAW);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(all_idx.len * @sizeOf(u32)), all_idx.ptr, gl.STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(dc.Vertex), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(dc.Vertex), @sizeOf([3]f32));
    gl.BindVertexArray(0);

    gl.Enable(gl.DEPTH_TEST);
    // Culling is off deliberately: with it on, quads whose winding heuristic had to
    // guess (near-degenerate cells) vanish into the background and read as holes.
    gl.Disable(gl.CULL_FACE);

    const centre: f32 = @floatFromInt(@as(usize, @intCast(PATCH)) * CHUNK / 2);
    const index_count: u32 = @intCast(all_idx.len);

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
