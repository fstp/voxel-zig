//! Dual-contouring isosurface extraction (spike, ADR 0018).
//!
//! One vertex per crossed cell, placed by solving a QEF fitted to the SDF gradient and
//! clamped inside the cell; one quad per crossed grid edge. Vertices are functions of
//! the sampled field only, so two chunks that sample the same deterministic field
//! compute identical vertices at their shared border - that is the property the ADR
//! leans on, and the seam test below holds it to account.

const std = @import("std");

/// Diagnostics: reset by `extract`. `skipped_missing_cell` counts quads not emitted because one
/// of the four surrounding cells produced no vertex; `skipped_bounds` counts those rejected for
/// sitting outside the sample grid. Between them they say whether a hole is a sampling miss or
/// something in the ordering.
pub var skipped_missing_cell: usize = 0;
pub var skipped_bounds: usize = 0;
pub var emitted_quads: usize = 0;

pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

pub const Surface = struct {
    verts: []Vertex,
    indices: []u32,

    pub fn deinit(self: Surface, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.indices);
    }

    pub fn quadCount(self: Surface) usize {
        return self.indices.len / 6;
    }
};

/// A scalar field sampled on a (n+1)^3 corner grid, `cell` metres apart.
pub const Field = struct {
    /// Corner samples, x fastest. Length must be (n+1)^3.
    values: []const f32,
    /// Cells per axis.
    n: usize,
    /// Extra cells meshed beyond the owned range on every side. A chunk meshes these so
    /// the cells straddling its border exist locally; because the field is deterministic,
    /// the neighbour computes the same vertices for them and the border quad welds exactly.
    skirt: usize = 0,
    /// World position of sample (0,0,0).
    origin: [3]f32,
    cell: f32,

    pub fn side(self: Field) usize {
        return self.n + 1 + 2 * self.skirt;
    }

    pub fn at(self: Field, i: usize, j: usize, k: usize) f32 {
        const s = self.side();
        return self.values[i + s * (j + s * k)];
    }

    pub fn samplePos(self: Field, i: usize, j: usize, k: usize) [3]f32 {
        const sk: f32 = @floatFromInt(self.skirt);
        return .{
            self.origin[0] + (@as(f32, @floatFromInt(i)) - sk) * self.cell,
            self.origin[1] + (@as(f32, @floatFromInt(j)) - sk) * self.cell,
            self.origin[2] + (@as(f32, @floatFromInt(k)) - sk) * self.cell,
        };
    }

    /// Gradient by central differences on the sampled grid, falling back to a one-sided
    /// difference at the border. Normalised; zero if the field is locally flat.
    pub fn gradient(self: Field, i: usize, j: usize, k: usize) [3]f32 {
        const n = self.side() - 1;
        var g: [3]f32 = undefined;
        inline for (0..3) |axis| {
            const idx: [3]usize = .{ i, j, k };
            const a = if (idx[axis] == 0) 0 else idx[axis] - 1;
            const b = if (idx[axis] >= n) n else idx[axis] + 1;
            var pa: [3]usize = .{ i, j, k };
            var pb: [3]usize = .{ i, j, k };
            pa[axis] = a;
            pb[axis] = b;
            const va = self.at(pa[0], pa[1], pa[2]);
            const vb = self.at(pb[0], pb[1], pb[2]);
            const span: f32 = @as(f32, @floatFromInt(b - a)) * self.cell;
            g[axis] = if (span > 0) (vb - va) / span else 0;
        }
        return normalize(g) orelse .{ 0, 0, 0 };
    }
};

fn normalize(v: [3]f32) ?[3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-8) return null;
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn scale(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// A 3x3 symmetric QEF: A = sum(n n^T), b = sum(n (n . p)), plus the mass point that is
/// the fallback whenever the solve is ill-conditioned (a flat-ish cell has no unique
/// minimum, and Cramer would happily return noise).
const Qef = struct {
    a: [6]f32 = .{ 0, 0, 0, 0, 0, 0 }, // xx xy xz yy yz zz
    b: [3]f32 = .{ 0, 0, 0 },
    mass: [3]f32 = .{ 0, 0, 0 },
    nsum: [3]f32 = .{ 0, 0, 0 },
    count: u32 = 0,

    fn addPlane(self: *Qef, p: [3]f32, n: [3]f32) void {
        self.a[0] += n[0] * n[0];
        self.a[1] += n[0] * n[1];
        self.a[2] += n[0] * n[2];
        self.a[3] += n[1] * n[1];
        self.a[4] += n[1] * n[2];
        self.a[5] += n[2] * n[2];
        const d = dot(n, p);
        self.b[0] += n[0] * d;
        self.b[1] += n[1] * d;
        self.b[2] += n[2] * d;
        self.mass = add(self.mass, p);
        self.nsum = add(self.nsum, n);
        self.count += 1;
    }

    /// Solve A x = b with Tikhonov regularisation, then clamp into [lo, hi]. Regularising
    /// rather than detecting rank deficiency keeps the solution continuous across cells,
    /// which matters more for a terrain mesh than exact feature recovery.
    fn solve(self: Qef, lo: [3]f32, hi: [3]f32) [3]f32 {
        if (self.count == 0) return scale(add(lo, hi), 0.5);
        const mass = scale(self.mass, 1.0 / @as(f32, @floatFromInt(self.count)));
        const trace = self.a[0] + self.a[3] + self.a[5];
        const eps = @max(trace * 1e-3, 1e-6);
        const a00 = self.a[0] + eps;
        const a01 = self.a[1];
        const a02 = self.a[2];
        const a11 = self.a[3] + eps;
        const a12 = self.a[4];
        const a22 = self.a[5] + eps;

        // Symmetric 3x3 inverse: for symmetric A the cofactor matrix is symmetric too,
        // so A^-1 = C/det with C_ij = cofactor(i,j) in place. Getting this wrong is
        // silent - it yields plausible vertices that miss the surface, which is exactly
        // what the sphere test caught.
        const c00 = a11 * a22 - a12 * a12;
        const c01 = a02 * a12 - a01 * a22;
        const c02 = a01 * a12 - a02 * a11;
        const c11 = a00 * a22 - a02 * a02;
        const c12 = a01 * a02 - a00 * a12;
        const c22 = a00 * a11 - a01 * a01;
        const det = a00 * c00 + a01 * c01 + a02 * c02;
        if (!(@abs(det) > 1e-9)) return mass;

        const inv = 1.0 / det;
        const x = (c00 * self.b[0] + c01 * self.b[1] + c02 * self.b[2]) * inv;
        const y = (c01 * self.b[0] + c11 * self.b[1] + c12 * self.b[2]) * inv;
        const z = (c02 * self.b[0] + c12 * self.b[1] + c22 * self.b[2]) * inv;

        const solved: [3]f32 = .{ x, y, z };
        if (!(std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(z))) return mass;
        // Regularisation already pulls the solution toward the mass point, so the extra
        // mass blend tried here changed the render by 1,060 pixels out of 1.44M and did not
        // remove the specks. Reverted rather than kept on faith.
        return .{
            std.math.clamp(solved[0], lo[0], hi[0]),
            std.math.clamp(solved[1], lo[1], hi[1]),
            std.math.clamp(solved[2], lo[2], hi[2]),
        };
    }
};

const Corner = struct { di: usize, dj: usize, dk: usize };
const corners: [8]Corner = .{
    .{ .di = 0, .dj = 0, .dk = 0 },
    .{ .di = 1, .dj = 0, .dk = 0 },
    .{ .di = 0, .dj = 1, .dk = 0 },
    .{ .di = 1, .dj = 1, .dk = 0 },
    .{ .di = 0, .dj = 0, .dk = 1 },
    .{ .di = 1, .dj = 0, .dk = 1 },
    .{ .di = 0, .dj = 1, .dk = 1 },
    .{ .di = 1, .dj = 1, .dk = 1 },
};

/// The twelve cell edges, as pairs of corner indices.
const edges: [12][2]u8 = .{
    .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, // along x
    .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, // along y
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // along z
};

/// Extract the isosurface at value 0 (negative is inside).
pub fn extract(alloc: std.mem.Allocator, field: Field) !Surface {
    skipped_missing_cell = 0;
    skipped_bounds = 0;
    emitted_quads = 0;
    // Cells cover the whole sample grid, skirts included, so the cells straddling a chunk
    // border exist locally.
    const cpa = field.side() - 1;
    const cells = cpa * cpa * cpa;
    const sk = field.skirt;
    // Owned edges: the along-axis cell index must sit in [sk, sk + n - 1], which makes the
    // ownership ranges of adjacent chunks disjoint - so each border quad is emitted once,
    // by the chunk that owns it, using a skirt vertex its neighbour computes identically.
    const own_lo = sk;
    const own_hi = sk + field.n - 1;

    var verts: std.ArrayList(Vertex) = .empty;
    errdefer verts.deinit(alloc);
    var tris: std.ArrayList(u32) = .empty;

    const cell_vert = try alloc.alloc(i32, cells);
    defer alloc.free(cell_vert);
    @memset(cell_vert, -1);

    const cellIndex = struct {
        fn f(x: usize, y: usize, z: usize, nn: usize) usize {
            return x + nn * (y + nn * z);
        }
    }.f;

    // Pass 1: one vertex per crossed cell.
    var qef = Qef{};
    var ci: usize = 0;
    while (ci < cpa) : (ci += 1) {
        var cj: usize = 0;
        while (cj < cpa) : (cj += 1) {
            var ck: usize = 0;
            while (ck < cpa) : (ck += 1) {
                var v: [8]f32 = undefined;
                var mask: u8 = 0;
                for (corners, 0..) |c, idx| {
                    const val = field.at(ci + c.di, cj + c.dj, ck + c.dk);
                    v[idx] = val;
                    if (val < 0) mask |= @as(u8, 1) << @intCast(idx);
                }
                if (mask == 0 or mask == 0xff) continue;

                qef = .{};
                const lo = field.samplePos(ci, cj, ck);
                const hi = field.samplePos(ci + 1, cj + 1, ck + 1);

                for (edges) |e| {
                    const va = v[e[0]];
                    const vb = v[e[1]];
                    const inside_a = va < 0;
                    const inside_b = vb < 0;
                    if (inside_a == inside_b) continue;
                    const ca = corners[e[0]];
                    const cb = corners[e[1]];
                    const t = va / (va - vb);
                    const pa = field.samplePos(ci + ca.di, cj + ca.dj, ck + ca.dk);
                    const pb = field.samplePos(ci + cb.di, cj + cb.dj, ck + cb.dk);
                    const p = add(pa, scale(sub(pb, pa), t));
                    const g = field.gradient(ci + ca.di, cj + ca.dj, ck + ca.dk);
                    const gn = normalize(g) orelse .{ 0.0, 1.0, 0.0 };
                    // The gradient points uphill, i.e. toward positive (outside); the
                    // surface normal for the QEF is the same direction.
                    qef.addPlane(p, gn);
                }

                // Keep the vertex strictly inside its cell so neighbouring cells cannot
                // produce crossing quads (the failure mode that makes vanilla DC
                // non-intersection-free).
                const inset = field.cell * 0.02;
                const pos = qef.solve(
                    .{ lo[0] + inset, lo[1] + inset, lo[2] + inset },
                    .{ hi[0] - inset, hi[1] - inset, hi[2] - inset },
                );
                // When a cell's crossing normals cancel out, qef.nsum is zero and a
                // hard-coded up vector gives the quad the wrong side - which renders as a
                // dark speck, not as an obvious bug. Fall back to the field gradient.
                const nrm = normalize(qef.nsum) orelse (normalize(field.gradient(ci, cj, ck)) orelse .{ 0.0, 1.0, 0.0 });
                cell_vert[cellIndex(ci, cj, ck, cpa)] = @intCast(verts.items.len);
                try verts.append(alloc, .{ .pos = pos, .normal = nrm });
            }
        }
    }

    // Pass 2: one quad per crossed grid edge, wound so its geometric normal agrees with
    // the vertex normals it joins.
    // Ownership is a half-open cube of *sample* indices, so every grid edge belongs to
    // exactly one chunk: the one whose owned cube contains that edge. The chunk then pulls
    // the cells on both sides of the border from its skirt, and because the field is
    // deterministic its neighbour computes the same vertices for them.
    var i: usize = own_lo;
    while (i <= own_hi) : (i += 1) {
        var j: usize = own_lo;
        while (j <= own_hi) : (j += 1) {
            var k: usize = own_lo;
            while (k <= own_hi) : (k += 1) {
                try emitEdge(field, cell_vert, verts.items, &tris, alloc, cpa, .x, i, j, k);
                try emitEdge(field, cell_vert, verts.items, &tris, alloc, cpa, .y, i, j, k);
                try emitEdge(field, cell_vert, verts.items, &tris, alloc, cpa, .z, i, j, k);
            }
        }
    }

    const v = try verts.toOwnedSlice(alloc);
    errdefer alloc.free(v);
    const t = try tris.toOwnedSlice(alloc);
    return .{ .verts = v, .indices = t };
}

const Axis = enum { x, y, z };

fn emitEdge(
    field: Field,
    cell_vert: []const i32,
    verts: []const Vertex,
    tris: *std.ArrayList(u32),
    alloc: std.mem.Allocator,
    cpa: usize,
    axis: Axis,
    i: usize,
    j: usize,
    k: usize,
) !void {
    const n = cpa;
    // A grid edge crosses the surface when its two corner samples disagree in sign.
    const a = switch (axis) {
        .x => field.at(i, j, k),
        .y => field.at(i, j, k),
        .z => field.at(i, j, k),
    };
    const b = switch (axis) {
        .x => field.at(i + 1, j, k),
        .y => field.at(i, j + 1, k),
        .z => field.at(i, j, k + 1),
    };
    if ((a < 0) == (b < 0)) return;

    // The four cells that share this edge, in the plane perpendicular to it.
    var c: [4][3]usize = undefined;
    switch (axis) {
        .x => {
            if (i >= n or j == 0 or k == 0) {
                skipped_bounds += 1;
                return;
            }
            c = .{ .{ i, j - 1, k - 1 }, .{ i, j, k - 1 }, .{ i, j, k }, .{ i, j - 1, k } };
        },
        .y => {
            if (j >= n or i == 0 or k == 0) {
                skipped_bounds += 1;
                return;
            }
            c = .{ .{ i - 1, j, k - 1 }, .{ i, j, k - 1 }, .{ i, j, k }, .{ i - 1, j, k } };
        },
        .z => {
            if (k >= n or i == 0 or j == 0) {
                skipped_bounds += 1;
                return;
            }
            c = .{ .{ i - 1, j - 1, k }, .{ i, j - 1, k }, .{ i, j, k }, .{ i - 1, j, k } };
        },
    }

    var idx: [4]u32 = undefined;
    for (c, 0..) |cc, m| {
        const vi = cell_vert[cc[0] + n * (cc[1] + n * cc[2])];
        if (vi < 0) {
            // A cell on this edge produced no vertex, so the surface is open here. Counting
            // these is what distinguishes a sampling miss from a quad-ordering problem.
            skipped_missing_cell += 1;
            return;
        }
        idx[m] = @intCast(vi);
    }

    emitted_quads += 1;
    // Wind the quad so its geometric normal agrees with the surface normals it joins,
    // rather than reasoning about axis directions and sign conventions per case.
    const pa = verts[idx[0]].pos;
    const pb = verts[idx[1]].pos;
    const pc = verts[idx[2]].pos;
    const quad_n = cross(sub(pb, pa), sub(pc, pa));
    var avg: [3]f32 = .{ 0, 0, 0 };
    for (idx) |vi| avg = add(avg, verts[vi].normal);
    // Split along a fixed diagonal for now. The shorter-diagonal variant was tried to fix the
    // scattered blue specks (which the counters proved are NOT missing quads: skipped_missing_cell
    // is 0), but the flipped branch reverses the quad's cycle and breaks the winding invariant that
    // the closed-mesh tests rely on - 12 tests failed. Reverted; the correct version has to rotate
    // the cycle rather than swap endpoints, and that needs its own pass.
    if (dot(quad_n, avg) < 0) {
        try tris.append(alloc, idx[0]);
        try tris.append(alloc, idx[2]);
        try tris.append(alloc, idx[1]);
        try tris.append(alloc, idx[0]);
        try tris.append(alloc, idx[3]);
        try tris.append(alloc, idx[2]);
    } else {
        try tris.append(alloc, idx[0]);
        try tris.append(alloc, idx[1]);
        try tris.append(alloc, idx[2]);
        try tris.append(alloc, idx[0]);
        try tris.append(alloc, idx[2]);
        try tris.append(alloc, idx[3]);
    }
}

fn sphereField(alloc: std.mem.Allocator, n: usize, cell: f32, radius: f32) ![]f32 {
    const side = n + 1;
    const vals = try alloc.alloc(f32, side * side * side);
    var k: usize = 0;
    while (k < side) : (k += 1) {
        var j: usize = 0;
        while (j < side) : (j += 1) {
            var i: usize = 0;
            while (i < side) : (i += 1) {
                const x = @as(f32, @floatFromInt(i)) * cell - @as(f32, @floatFromInt(n)) * cell * 0.5;
                const y = @as(f32, @floatFromInt(j)) * cell - @as(f32, @floatFromInt(n)) * cell * 0.5;
                const z = @as(f32, @floatFromInt(k)) * cell - @as(f32, @floatFromInt(n)) * cell * 0.5;
                vals[i + side * (j + side * k)] = @sqrt(x * x + y * y + z * z) - radius;
            }
        }
    }
    return vals;
}

test "dual contouring: a sphere comes out closed and round" {
    const alloc = std.testing.allocator;
    const n = 16;
    const cell: f32 = 1.0;
    const radius: f32 = 6.0;
    const vals = try sphereField(alloc, n, cell, radius);
    defer alloc.free(vals);

    const field = Field{
        .values = vals,
        .n = n,
        .origin = .{ -@as(f32, @floatFromInt(n)) * cell * 0.5, -@as(f32, @floatFromInt(n)) * cell * 0.5, -@as(f32, @floatFromInt(n)) * cell * 0.5 },
        .cell = cell,
    };
    const surf = try extract(alloc, field);
    defer surf.deinit(alloc);

    try std.testing.expect(surf.verts.len > 0);
    try std.testing.expect(surf.indices.len % 6 == 0);

    // Every vertex must sit on the sphere to within a cell: the QEF fits the sampled
    // gradient, so a curved surface is approximated, not reproduced exactly.
    for (surf.verts) |v| {
        const r = @sqrt(v.pos[0] * v.pos[0] + v.pos[1] * v.pos[1] + v.pos[2] * v.pos[2]);
        try std.testing.expect(@abs(r - radius) < cell);
    }

    // Closed: every mesh edge must be shared by exactly two triangles. This is the check
    // that would catch a winding or connectivity mistake, which a screenshot would not.
    var counts = std.AutoHashMap([2]u32, u32).init(alloc);
    defer counts.deinit();
    var t: usize = 0;
    while (t < surf.indices.len) : (t += 3) {
        const tri = surf.indices[t .. t + 3];
        for (0..3) |e| {
            var a = tri[e];
            var b = tri[(e + 1) % 3];
            if (a > b) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            if (a == b) continue;
            const gop = try counts.getOrPut(.{ a, b });
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    var it = counts.iterator();
    var open: usize = 0;
    while (it.next()) |entry| {
        if (entry.value_ptr.* != 2) open += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), open);
}

test "dual contouring: an overlapping chunk reproduces the border vertices exactly" {
    const alloc = std.testing.allocator;
    const n = 8;
    const cell: f32 = 1.0;

    // A tilted plane, evaluated identically by both chunks - which is the property the
    // padded-border scheme relies on. Chunk B starts one cell later and re-meshes the
    // cells A already covered, standing in for the neighbour that samples our border cell
    // as part of its own skirt. Those shared cells must produce bit-identical vertices, or
    // the joining quad would be twisted.
    const plane = struct {
        fn f(x: f32, y: f32, z: f32) f32 {
            return 0.3 * x - 0.5 * y + 0.2 * z + 0.4;
        }
    }.f;

    const build = struct {
        fn g(alloc2: std.mem.Allocator, nn: usize, c: f32, ox: f32) ![]f32 {
            const side = nn + 1;
            const vals = try alloc2.alloc(f32, side * side * side);
            const oxi: i32 = @intFromFloat(ox);
            var k: usize = 0;
            while (k < side) : (k += 1) {
                var j: usize = 0;
                while (j < side) : (j += 1) {
                    var i: usize = 0;
                    while (i < side) : (i += 1) {
                        // Integer first: exact arithmetic keeps the two chunks' shared samples
                        // bitwise identical, which is the property this test is about.
                        const x = @as(f32, @floatFromInt(oxi + @as(i32, @intCast(i)))) * c;
                        const y = @as(f32, @floatFromInt(j)) * c;
                        const z = @as(f32, @floatFromInt(k)) * c;
                        vals[i + side * (j + side * k)] = plane(x, y, z);
                    }
                }
            }
            return vals;
        }
    }.g;

    const a_vals = try build(alloc, n, cell, 0.0);
    defer alloc.free(a_vals);
    const b_vals = try build(alloc, n, cell, cell);
    defer alloc.free(b_vals);

    const fa = Field{ .values = a_vals, .n = n, .origin = .{ 0, 0, 0 }, .cell = cell };
    const fb = Field{ .values = b_vals, .n = n, .origin = .{ cell, 0, 0 }, .cell = cell };
    const sa = try extract(alloc, fa);
    defer sa.deinit(alloc);
    const sb = try extract(alloc, fb);
    defer sb.deinit(alloc);

    try std.testing.expect(sa.verts.len > 0);
    try std.testing.expect(sb.verts.len > 0);

    // Every vertex of A that lies inside B's cell range must appear in B, exactly.
    var matched: usize = 0;
    var considered: usize = 0;
    for (sa.verts) |va| {
        if (va.pos[0] < cell * 1.0 or va.pos[0] > cell * @as(f32, @floatFromInt(n - 1))) continue;
        considered += 1;
        for (sb.verts) |vb| {
            if (va.pos[0] == vb.pos[0] and va.pos[1] == vb.pos[1] and va.pos[2] == vb.pos[2]) {
                matched += 1;
                break;
            }
        }
    }
    try std.testing.expect(considered > 0);
    try std.testing.expectEqual(considered, matched);
}

test "dual contouring: a uniform field yields nothing" {
    const alloc = std.testing.allocator;
    const n = 4;
    const vals = try alloc.alloc(f32, (n + 1) * (n + 1) * (n + 1));
    defer alloc.free(vals);
    @memset(vals, -1.0);
    const field = Field{ .values = vals, .n = n, .origin = .{ 0, 0, 0 }, .cell = 1 };
    const surf = try extract(alloc, field);
    defer surf.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), surf.verts.len);
    try std.testing.expectEqual(@as(usize, 0), surf.indices.len);
}

test "dual contouring: two skirted chunks tile without a crack" {
    const alloc = std.testing.allocator;
    const n = 8;
    const cell: f32 = 1.0;

    // Referenced to x = 1000 so the plane still cuts the box at that far origin.
    const plane = struct {
        fn f(x: f32, y: f32, z: f32) f32 {
            return 0.35 * (x - 1000.0) - 0.6 * y + 0.25 * z + 0.5;
        }
    }.f;

    const build = struct {
        fn g(alloc2: std.mem.Allocator, nn: usize, c: f32, ox: f32, sk: usize) ![]f32 {
            const side = nn + 1 + 2 * sk;
            const vals = try alloc2.alloc(f32, side * side * side);
            const oxi: i32 = @intFromFloat(ox);
            var k: usize = 0;
            while (k < side) : (k += 1) {
                var j: usize = 0;
                while (j < side) : (j += 1) {
                    var i: usize = 0;
                    while (i < side) : (i += 1) {
                        // Integer first, converted once: identical inputs for a shared sample.
                        const gx: i32 = oxi + @as(i32, @intCast(i)) - @as(i32, @intCast(sk));
                        const gy: i32 = @as(i32, @intCast(j)) - @as(i32, @intCast(sk));
                        const gz: i32 = @as(i32, @intCast(k)) - @as(i32, @intCast(sk));
                        const x = @as(f32, @floatFromInt(gx)) * c;
                        const y = @as(f32, @floatFromInt(gy)) * c;
                        const z = @as(f32, @floatFromInt(gz)) * c;
                        vals[i + side * (j + side * k)] = plane(x, y, z);
                    }
                }
            }
            return vals;
        }
    }.g;

    // A far origin on purpose: at x = 1000 an f32 has ~6e-5 of spacing, so building the
    // sample coordinate as origin + index*cell gives the shared border sample different low
    // bits in the two chunks and the seam draws a hairline. Sampling in integer space is
    // what keeps the two evaluations bitwise identical.
    const a_vals = try build(alloc, n, cell, 1000.0, 1);
    defer alloc.free(a_vals);
    const b_vals = try build(alloc, n, cell, 1000.0 + @as(f32, @floatFromInt(n)) * cell, 1);
    defer alloc.free(b_vals);

    const fa = Field{ .values = a_vals, .n = n, .skirt = 1, .origin = .{ 1000.0, 0, 0 }, .cell = cell };
    const fb = Field{ .values = b_vals, .n = n, .skirt = 1, .origin = .{ 1008.0, 0, 0 }, .cell = cell };
    const sa = try extract(alloc, fa);
    defer sa.deinit(alloc);
    const sb = try extract(alloc, fb);
    defer sb.deinit(alloc);

    try std.testing.expect(sa.verts.len > 0 and sb.verts.len > 0);

    // Merge and weld by position, then demand that every edge is shared by exactly two
    // triangles. A missing border quad shows up as edges counted once; a duplicated one as
    // edges counted four times - both are what a visible crack or a z-fight looks like.
    var pos = std.AutoHashMap([3]i64, u32).init(alloc);
    defer pos.deinit();
    var merged: std.ArrayList(Vertex) = .empty;
    defer merged.deinit(alloc);
    var idx: std.ArrayList(u32) = .empty;
    defer idx.deinit(alloc);

    const addSurface = struct {
        fn f(
            al: std.mem.Allocator,
            surf: Surface,
            map: *std.AutoHashMap([3]i64, u32),
            verts: *std.ArrayList(Vertex),
            indices: *std.ArrayList(u32),
        ) !void {
            var remap = try al.alloc(u32, surf.verts.len);
            defer al.free(remap);
            for (surf.verts, 0..) |v, vi| {
                const key = [3]i64{
                    @intFromFloat(@round(v.pos[0] * 4096.0)),
                    @intFromFloat(@round(v.pos[1] * 4096.0)),
                    @intFromFloat(@round(v.pos[2] * 4096.0)),
                };
                const gop = try map.getOrPut(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(verts.items.len);
                    try verts.append(al, v);
                }
                remap[vi] = gop.value_ptr.*;
            }
            for (surf.indices) |src_idx| try indices.append(al, remap[src_idx]);
        }
    }.f;

    try addSurface(alloc, sa, &pos, &merged, &idx);
    try addSurface(alloc, sb, &pos, &merged, &idx);

    var counts = std.AutoHashMap([2]u32, u32).init(alloc);
    defer counts.deinit();
    var t: usize = 0;
    while (t < idx.items.len) : (t += 3) {
        const tri = idx.items[t .. t + 3];
        for (0..3) |e| {
            var a = tri[e];
            var b = tri[(e + 1) % 3];
            if (a > b) {
                const tmp = a;
                a = b;
                b = tmp;
            }
            if (a == b) continue;
            const gop = try counts.getOrPut(.{ a, b });
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    // Only the seam band is meaningful here: the surface legitimately runs out of the
    // domain at the union's outer faces, and open edges there are not a crack.
    var it = counts.iterator();
    var bad: usize = 0;
    var checked: usize = 0;
    const seam_lo: f32 = 1000.0 + @as(f32, @floatFromInt(n)) - 2.0;
    const seam_hi: f32 = 1000.0 + @as(f32, @floatFromInt(n)) + 2.0;
    while (it.next()) |entry| {
        const pa = merged.items[entry.key_ptr.*[0]].pos;
        const pb = merged.items[entry.key_ptr.*[1]].pos;
        if (pa[0] < seam_lo or pa[0] > seam_hi or pb[0] < seam_lo or pb[0] > seam_hi) continue;
        // The plane leaves the box at the y and z faces, where there is no neighbour chunk
        // to close the surface - open edges there are the domain, not a crack.
        const inner: f32 = 1.5;
        const outer: f32 = @as(f32, @floatFromInt(n)) - 1.5;
        if (pa[1] < inner or pa[1] > outer or pb[1] < inner or pb[1] > outer) continue;
        if (pa[2] < inner or pa[2] > outer or pb[2] < inner or pb[2] > outer) continue;
        checked += 1;
        if (entry.value_ptr.* != 2) bad += 1;
    }
    try std.testing.expect(checked > 20);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
