//! Minimal GLB (binary glTF 2.0) reader for prop meshes (task 13.1).
//!
//! Scope is deliberately narrow, because it only has to read game-ready prop assets from the
//! sources in docs/asset-sources.md (Kenney Nature Kit, and anything else that ships a plain GLB):
//!
//! - one JSON chunk + one BIN chunk, no external .bin or image URIs;
//! - `meshes[].primitives[]` with POSITION, NORMAL and indices (u8/u16/u32);
//! - per-primitive material colour from `pbrMetallicRoughness.baseColorFactor`;
//! - accessor `byteOffset` and `byteStride` honoured; no skinning, morph targets or Draco.
//!
//! It returns positions/normals/colours in glTF space (Y up, metres). The caller applies scale and
//! offset, because those are asset-specific (a Kenney tree is ~1.15 m tall where the procedural tree
//! is 6.5 m).
const std = @import("std");

pub const RawVertex = struct {
    pos: [3]f32,
    nrm: [3]f32,
    col: [3]f32,
};

pub const Mesh = struct {
    verts: std.ArrayList(RawVertex) = .empty,
    idx: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Mesh, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
        self.idx.deinit(alloc);
    }

    pub fn triangleCount(self: Mesh) usize {
        return self.idx.items.len / 3;
    }
};

pub const GlbError = error{
    NotGlb,
    UnsupportedVersion,
    MissingChunk,
    MissingBuffer,
    MissingAttribute,
    UnsupportedComponent,
    UnsupportedType,
    IndexOutOfRange,
};

const GLB_MAGIC: u32 = 0x46546C67; // "glTF"
const CHUNK_JSON: u32 = 0x4E4F534A;
const CHUNK_BIN: u32 = 0x004E4942;

const COMP_FLOAT: u32 = 5126;
const COMP_U8: u32 = 5121;
const COMP_U16: u32 = 5123;
const COMP_U32: u32 = 5125;

const Type = enum { scalar, vec2, vec3, vec4 };

fn typeInfo(name: []const u8) ?struct { t: Type, n: usize } {
    if (std.mem.eql(u8, name, "SCALAR")) return .{ .t = .scalar, .n = 1 };
    if (std.mem.eql(u8, name, "VEC2")) return .{ .t = .vec2, .n = 2 };
    if (std.mem.eql(u8, name, "VEC3")) return .{ .t = .vec3, .n = 3 };
    if (std.mem.eql(u8, name, "VEC4")) return .{ .t = .vec4, .n = 4 };
    return null;
}

fn componentSize(comp: u32) ?usize {
    return switch (comp) {
        COMP_FLOAT, COMP_U32 => 4,
        COMP_U16 => 2,
        COMP_U8 => 1,
        else => null,
    };
}

/// Reads one accessor as f32 triples (padding missing components with 0). Used for POSITION and
/// NORMAL. Returns a slice owned by `alloc`.
fn readVec3Accessor(
    alloc: std.mem.Allocator,
    json: std.json.Value,
    bin: []const u8,
    accessor_index: usize,
    out_count: *usize,
) ![] [3]f32 {
    const root = json.object;
    const accessors = root.get("accessors").?.array;
    if (accessor_index >= accessors.items.len) return GlbError.MissingAttribute;
    const acc = accessors.items[accessor_index].object;

    const comp: u32 = @intCast(acc.get("componentType").?.integer);
    const count: usize = @intCast(acc.get("count").?.integer);
    const type_name = acc.get("type").?.string;
    const ti = typeInfo(type_name) orelse return GlbError.UnsupportedType;
    if (ti.t != .vec3) return GlbError.UnsupportedType;
    const csize = componentSize(comp) orelse return GlbError.UnsupportedComponent;

    const base_off: usize = if (acc.get("byteOffset")) |v| @intCast(v.integer) else 0;
    var stride: usize = csize * ti.n;
    if (acc.get("bufferView")) |bv_idx| {
        const views = root.get("bufferViews").?.array;
        const bv = views.items[@intCast(bv_idx.integer)].object;
        if (bv.get("byteStride")) |s| stride = @intCast(s.integer);
        const view_off: usize = if (bv.get("byteOffset")) |v| @intCast(v.integer) else 0;

        var out = try alloc.alloc([3]f32, count);
        errdefer alloc.free(out);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const at = view_off + base_off + i * stride;
            if (at + csize * 3 > bin.len) return GlbError.IndexOutOfRange;
            var v: [3]f32 = .{ 0, 0, 0 };
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const p = at + c * csize;
                v[c] = switch (comp) {
                    COMP_FLOAT => @bitCast(std.mem.readInt(u32, bin[p..][0..4], .little)),
                    COMP_U16 => @floatFromInt(std.mem.readInt(u16, bin[p..][0..2], .little)),
                    COMP_U8 => @floatFromInt(bin[p]),
                    else => return GlbError.UnsupportedComponent,
                };
            }
            out[i] = v;
        }
        out_count.* = count;
        return out;
    }
    return GlbError.MissingAttribute;
}

fn readIndices(
    alloc: std.mem.Allocator,
    json: std.json.Value,
    bin: []const u8,
    accessor_index: usize,
) ![]u32 {
    const root = json.object;
    const accessors = root.get("accessors").?.array;
    const acc = accessors.items[accessor_index].object;
    const comp: u32 = @intCast(acc.get("componentType").?.integer);
    const count: usize = @intCast(acc.get("count").?.integer);
    const csize = componentSize(comp) orelse return GlbError.UnsupportedComponent;
    const base_off: usize = if (acc.get("byteOffset")) |v| @intCast(v.integer) else 0;

    const views = root.get("bufferViews").?.array;
    const bv = views.items[@intCast(acc.get("bufferView").?.integer)].object;
    const view_off: usize = if (bv.get("byteOffset")) |v| @intCast(v.integer) else 0;

    var out = try alloc.alloc(u32, count);
    errdefer alloc.free(out);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const at = view_off + base_off + i * csize;
        if (at + csize > bin.len) return GlbError.IndexOutOfRange;
        out[i] = switch (comp) {
            COMP_U32 => std.mem.readInt(u32, bin[at..][0..4], .little),
            COMP_U16 => @intCast(std.mem.readInt(u16, bin[at..][0..2], .little)),
            COMP_U8 => bin[at],
            else => return GlbError.UnsupportedComponent,
        };
    }
    return out;
}

/// Parses a GLB from memory. `lin` converts the stored base colour to the linear space the
/// renderer's lighting expects; pass 2.2 for sRGB-authored palettes and 1.0 for already-linear.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, lin: f32) !Mesh {
    if (bytes.len < 12) return GlbError.NotGlb;
    if (std.mem.readInt(u32, bytes[0..4], .little) != GLB_MAGIC) return GlbError.NotGlb;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 2) return GlbError.UnsupportedVersion;

    var json_bytes: ?[]const u8 = null;
    var bin_bytes: ?[]const u8 = null;
    var off: usize = 12;
    while (off + 8 <= bytes.len) {
        const clen = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const ctype = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        const data = bytes[off + 8 ..][0..clen];
        if (ctype == CHUNK_JSON) json_bytes = data;
        if (ctype == CHUNK_BIN) bin_bytes = data;
        off += 8 + clen;
        if (clen % 4 != 0) off += 4 - (clen % 4);
    }
    const jb = json_bytes orelse return GlbError.MissingChunk;
    const bin = bin_bytes orelse return GlbError.MissingBuffer;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, jb, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const meshes = root.get("meshes") orelse return GlbError.MissingAttribute;
    const materials = root.get("materials");

    var out = Mesh{};
    errdefer out.deinit(alloc);

    for (meshes.array.items) |mesh_val| {
        const prims = mesh_val.object.get("primitives").?.array;
        for (prims.items) |prim_val| {
            const prim = prim_val.object;
            const attrs = prim.get("attributes").?.object;
            const pos_val = attrs.get("POSITION") orelse return GlbError.MissingAttribute;
            const pos_idx: usize = @intCast(pos_val.integer);

            // Material colour: baseColorFactor, gamma-corrected. Default grey when a primitive has
            // no material, so a wrong colour is visible rather than silently black.
            var col: [3]f32 = .{ 0.5, 0.5, 0.5 };
            if (materials) |mats| {
                if (prim.get("material")) |mi| {
                    const mat = mats.array.items[@intCast(mi.integer)].object;
                    if (mat.get("pbrMetallicRoughness")) |pbr| {
                        if (pbr.object.get("baseColorFactor")) |bcf| {
                            const a = bcf.array.items;
                            col = .{
                                std.math.pow(f32, @floatCast(a[0].float), lin),
                                std.math.pow(f32, @floatCast(a[1].float), lin),
                                std.math.pow(f32, @floatCast(a[2].float), lin),
                            };
                        }
                    }
                }
            }

            var pos_count: usize = 0;
            const positions = try readVec3Accessor(alloc, parsed.value, bin, pos_idx, &pos_count);
            defer alloc.free(positions);

            var normals: ?[] [3]f32 = null;
            defer if (normals) |n| alloc.free(n);
            if (attrs.get("NORMAL")) |ni| {
                var n_count: usize = 0;
                normals = readVec3Accessor(alloc, parsed.value, bin, @intCast(ni.integer), &n_count) catch null;
            }

            const base: u32 = @intCast(out.verts.items.len);
            try out.verts.ensureUnusedCapacity(alloc, pos_count);
            for (positions, 0..) |p, i| {
                out.verts.appendAssumeCapacity(.{
                    .pos = p,
                    .nrm = if (normals) |n| n[i] else .{ 0, 1, 0 },
                    .col = col,
                });
            }

            if (prim.get("indices")) |ii| {
                const idx = try readIndices(alloc, parsed.value, bin, @intCast(ii.integer));
                defer alloc.free(idx);
                try out.idx.ensureUnusedCapacity(alloc, idx.len);
                for (idx) |v| {
                    if (v >= pos_count) return GlbError.IndexOutOfRange;
                    out.idx.appendAssumeCapacity(base + v);
                }
            } else {
                // Non-indexed: synthesise a triangle list.
                try out.idx.ensureUnusedCapacity(alloc, pos_count);
                var i: u32 = 0;
                while (i < pos_count) : (i += 1) out.idx.appendAssumeCapacity(base + i);
            }
        }
    }
    return out;
}

/// Zig 0.17 reads through the Io interface (`std.Io.Dir.cwd()`), not `std.fs.cwd()`.
pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, lin: f32) !Mesh {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(64 * 1024 * 1024));
    defer alloc.free(bytes);
    return parse(alloc, bytes, lin);
}

// A Kenney Nature Kit tree, embedded so the parser has a test that does not depend on a download.
// CC0 (kenney.nl/assets/nature-kit); see docs/asset-sources.md.
const test_glb = @embedFile("test_glb/tree_fat.glb");

test "GLB parse reads a Kenney tree: 2 primitives, 50 triangles" {
    const alloc = std.testing.allocator;
    var mesh = try parse(alloc, test_glb, 2.2);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 50), mesh.triangleCount());
    try std.testing.expect(mesh.verts.items.len > 0);

    // Bounds of tree_fat: about 1.15 m tall and 0.75 m wide, standing on y = 0.
    var lo = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (mesh.verts.items) |v| {
        for (0..3) |c| {
            lo[c] = @min(lo[c], v.pos[c]);
            hi[c] = @max(hi[c], v.pos[c]);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lo[1], 0.01);
    try std.testing.expect(hi[1] > 1.1 and hi[1] < 1.2);
    try std.testing.expect(hi[0] - lo[0] > 0.7 and hi[0] - lo[0] < 0.8);

    // Both materials must have produced distinct colours (leafs vs bark).
    const c0 = mesh.verts.items[0].col;
    var differs = false;
    for (mesh.verts.items) |v| {
        if (@abs(v.col[0] - c0[0]) > 0.01 or @abs(v.col[1] - c0[1]) > 0.01) differs = true;
    }
    try std.testing.expect(differs);
}
