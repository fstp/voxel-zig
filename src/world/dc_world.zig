//! The dual-contouring world: analytic height field, sphere edits, chunk meshing, streaming
//! diagnostics and the save format (ADR 0022). Extracted from the spike's app file so the
//! executable is just the loop.

const std = @import("std");
const dc = @import("../voxel/dc.zig");
const noise = @import("noise.zig");
const Vec3 = @import("../math/vec.zig").Vec3;

pub const CHUNK: usize = 32;
pub const SEED: u32 = 1337;

// An 8x8 chunk patch: 64 chunks over 256 m². A single-chunk patch put the world edge in shot and
// 99.6% of the background pixels counted as "holes"; the bigger patch separates a mesher defect
// from the edge of the world.
pub const PATCH: i32 = 8;
pub const CELL: f32 = 1.0;

/// The field, sampled directly from the project's fBm. It used to be a bilinear blend of four
/// `terrain.heightAt` values - four generator calls per sample, and a rebuild of 64 chunks cost
/// 157 ms because of it. Sampling the noise once is cheaper AND smoother: the block generator's
/// height is an integer, so the blend still carried a 1 m staircase that DC faithfully reproduced.
pub fn heightAt(x: f32, z: f32) f32 {
    const base: f32 = 62.0;
    const big = noise.fbm2(SEED, x * 0.009, z * 0.009, 4, 2.0, 0.5);
    const detail = noise.fbm2(SEED + 7, x * 0.041, z * 0.041, 3, 2.0, 0.5);
    return base + 22.0 * big + 3.0 * detail;
}

pub const Vertex = extern struct {
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

pub const ChunkStats = struct {
    quads: usize = 0,
    skipped_missing: usize = 0,
    skipped_bounds: usize = 0,
    ambiguous: usize = 0,
    degenerate: usize = 0,
    min_area: f32 = 1e9,
};

pub const PatchStats = struct {
    quads: usize = 0,
    skipped_missing: usize = 0,
    skipped_bounds: usize = 0,
    ambiguous: usize = 0,
    degenerate: usize = 0,
    min_area: f32 = 1e9,
};

/// A spherical brush edit on top of the base height field (ADR 0022). `add` unions the sphere
/// with the terrain, giving a bump; a carve subtracts it, giving a cave or crater. The mesher
/// evaluates the list per field sample, so the edit is part of the world, not a decal.
pub const Edit = struct { x: f32, y: f32, z: f32, r: f32, add: bool };

pub fn editField(edits: []const Edit, x: f32, y: f32, z: f32, base: f32) f32 {
    var f = base;
    for (edits) |e| {
        const dx = x - e.x;
        const dy = y - e.y;
        const dz = z - e.z;
        const s = @sqrt(dx * dx + dy * dy + dz * dz) - e.r;
        f = if (e.add) @min(f, s) else @max(f, -s);
    }
    return f;
}

pub fn fieldAt(edits: []const Edit, p: Vec3) f32 {
    return editField(edits, p.x, p.y, p.z, p.y - heightAt(p.x, p.z));
}

/// Sphere-trace the field from the eye. The SDF is 1-Lipschitz for the base height field and the
/// sphere edits, so a march step of the current value cannot skip the surface.
pub fn raycastField(edits: []const Edit, origin: Vec3, dir: Vec3, max_dist: f32) ?Vec3 {
    var t: f32 = 0;
    while (t < max_dist) {
        const p = origin.add(dir.scale(t));
        const f = fieldAt(edits, p);
        if (f < 0.03) return p;
        t += @max(f, 0.05);
    }
    return null;
}

const SAVE_HEADER = "voxel-zig dc 1";

/// Serialised player state. Kept independent of the player module so the world's save code does
/// not depend on the app.
pub const PlayerSave = struct { x: f32, y: f32, z: f32, yaw: f32, pitch: f32, flying: bool };

pub fn saveWorld(io: std.Io, path: []const u8, sun_time: f32, player: PlayerSave, edits: []const Edit) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.print("{s}\n", .{SAVE_HEADER});
    try w.print("sun {d:.4}\n", .{sun_time});
    try w.print("player {d:.3} {d:.3} {d:.3} {d:.4} {d:.4} {d}\n", .{
        player.x, player.y, player.z, player.yaw, player.pitch, @intFromBool(player.flying),
    });
    for (edits) |e| {
        try w.print("edit {d:.3} {d:.3} {d:.3} {d:.3} {d}\n", .{ e.x, e.y, e.z, e.r, @intFromBool(e.add) });
    }
    try w.flush();
}

pub const LoadedWorld = struct {
    sun_time: ?f32 = null,
    player: ?PlayerSave = null,
    edits: std.ArrayList(Edit) = .empty,

    pub fn deinit(self: *LoadedWorld, alloc: std.mem.Allocator) void {
        self.edits.deinit(alloc);
    }
};

pub fn loadWorld(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedWorld {
    var out = LoadedWorld{};
    errdefer out.deinit(alloc);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => return err,
    };
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return error.BadSave;
    if (!std.mem.eql(u8, std.mem.trim(u8, header, " \r"), SAVE_HEADER)) return error.BadSave;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = it.next() orelse continue;
        if (std.mem.eql(u8, tag, "sun")) {
            out.sun_time = std.fmt.parseFloat(f32, it.next() orelse continue) catch null;
        } else if (std.mem.eql(u8, tag, "player")) {
            var p = PlayerSave{ .x = 0, .y = 0, .z = 0, .yaw = 0, .pitch = 0, .flying = false };
            p.x = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.y = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.z = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.yaw = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.pitch = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.flying = (std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0) != 0;
            out.player = p;
        } else if (std.mem.eql(u8, tag, "edit")) {
            var e = Edit{ .x = 0, .y = 0, .z = 0, .r = 3.0, .add = true };
            e.x = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            e.y = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            e.z = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            e.r = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            e.add = (std.fmt.parseInt(u8, it.next() orelse "1", 10) catch 1) != 0;
            try out.edits.append(alloc, e);
        }
    }
    return out;
}

/// Meshes ONE chunk of the patch into the given buffers. Split out so a rebuild can be spread across
/// frames: 64 chunks x ~0.6 ms is a 40 ms hitch if done at once, and a fraction of a millisecond per

pub fn meshChunkInto(
    alloc: std.mem.Allocator,
    edits: []const Edit,
    patch_origin: i32,
    patch_origin_z: i32,
    cx: i32,
    cz: i32,
    verts: *std.ArrayList(Vertex),
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
    var xs: [side]f32 = undefined;
    var zs: [side]f32 = undefined;
    for (0..side) |i| {
        xs[i] = @floatFromInt((patch_origin + cx) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(i)) - @as(i32, @intCast(skirt)));
        zs[i] = @floatFromInt((patch_origin_z + cz) * @as(i32, @intCast(CHUNK)) + @as(i32, @intCast(i)) - @as(i32, @intCast(skirt)));
    }
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
                vals[i + side * (j + side_y * k)] = editField(edits, xs[i], y, zs[k], y - heights[i + side * k]);
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
pub fn meshPatch(
    alloc: std.mem.Allocator,
    edits: []const Edit,
    patch_origin: i32,
    patch_origin_z: i32,
    verts: *std.ArrayList(Vertex),
    idx: *std.ArrayList(u32),
) !PatchStats {
    var out = PatchStats{};

    var cz: i32 = 0;
    while (cz < PATCH) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < PATCH) : (cx += 1) {
            const st = try meshChunkInto(alloc, edits, patch_origin, patch_origin_z, cx, cz, verts, idx);
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

pub fn countNearDuplicates(alloc: std.mem.Allocator, verts: []const Vertex) !struct { exact: usize, near: usize } {
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

fn countCellCopies(alloc: std.mem.Allocator, verts: []const Vertex, idx: []const u32) !CopyStats {
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
    verts: []const Vertex,
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

pub fn diagnoseMesh(
    alloc: std.mem.Allocator,
    verts: []const Vertex,
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