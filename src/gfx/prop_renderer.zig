//! Instanced trees and rocks (ADR 0024, 10.5/10.7). Trees are three procedural cone/trunk LODs
//! drawn with one instanced call per LOD; rocks are a single low-poly mesh. Both use the same
//! vertex-colour program with vertex-rigidity wind for foliage and none for rocks.

const std = @import("std");
const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const Prop = @import("../world/scatter.zig").Prop;

pub const Vertex = extern struct {
    pos: [3]f32,
    nrm: [3]f32,
    col: [3]f32,
    rigid: f32,
};

const MeshData = struct {
    verts: std.ArrayList(Vertex) = .empty,
    idx: std.ArrayList(u32) = .empty,
    fn deinit(self: *MeshData, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
        self.idx.deinit(alloc);
    }
};

const Mesh = struct {
    vao: u32 = 0,
    vbo: u32 = 0,
    ebo: u32 = 0,
    index_count: usize = 0,
};

fn addVertex(md: *MeshData, alloc: std.mem.Allocator, p: [3]f32, n: [3]f32, c: [3]f32, rigid: f32) !u32 {
    const i: u32 = @intCast(md.verts.items.len);
    try md.verts.append(alloc, .{ .pos = p, .nrm = n, .col = c, .rigid = rigid });
    return i;
}

fn addTri(md: *MeshData, alloc: std.mem.Allocator, a: u32, b: u32, c: u32) !void {
    try md.idx.append(alloc, a);
    try md.idx.append(alloc, b);
    try md.idx.append(alloc, c);
}

/// A stylised conifer: a trunk cylinder plus overlapping foliage cones. `cones` and `sides`
/// control the LOD. World height is about 6.5 m at scale 1.
fn buildTree(alloc: std.mem.Allocator, sides: usize, cones: usize) !MeshData {
    var md = MeshData{};
    errdefer md.deinit(alloc);
    const two_pi = std.math.tau;

    // Trunk: two rings, open ends.
    const trunk_h: f32 = 2.2;
    const r0: f32 = 0.19;
    const r1: f32 = 0.13;
    var ring0: [24]u32 = undefined;
    var ring1: [24]u32 = undefined;
    for (0..sides) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides)) * two_pi;
        const cx = @cos(a);
        const sz = @sin(a);
        ring0[i] = try addVertex(&md, alloc, .{ cx * r0, 0, sz * r0 }, .{ cx, 0, sz }, .{ 0.20, 0.14, 0.09 }, 0.0);
        ring1[i] = try addVertex(&md, alloc, .{ cx * r1, trunk_h, sz * r1 }, .{ cx, 0, sz }, .{ 0.22, 0.16, 0.11 }, 0.02);
    }
    for (0..sides) |i| {
        const j = (i + 1) % sides;
        try addTri(&md, alloc, ring0[i], ring1[i], ring0[j]);
        try addTri(&md, alloc, ring0[j], ring1[i], ring1[j]);
    }

    // Foliage cones.
    for (0..cones) |ci| {
        const f = @as(f32, @floatFromInt(ci));
        const base_y: f32 = 1.35 + f * 0.85;
        const radius: f32 = 1.95 - f * 0.26;
        const height: f32 = 2.30 - f * 0.12;
        const shade = 0.82 + 0.18 * (f / @as(f32, @floatFromInt(@max(cones, 1))));
        const col = [3]f32{ 0.075 * shade, 0.20 * shade, 0.065 * shade };
        const rigid = 0.30 + 0.16 * f;
        var ring: [24]u32 = undefined;
        for (0..sides) |i| {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides)) * two_pi;
            const cx = @cos(a);
            const sz = @sin(a);
            const n = Vec3.init(cx * height, radius, sz * height).normalized();
            ring[i] = try addVertex(&md, alloc, .{ cx * radius, base_y, sz * radius }, .{ n.x, n.y, n.z }, col, rigid);
        }
        const tip = try addVertex(&md, alloc, .{ 0, base_y + height, 0 }, .{ 0, 1, 0 }, col, rigid + 0.2);
        for (0..sides) |i| {
            const j = (i + 1) % sides;
            try addTri(&md, alloc, ring[i], tip, ring[j]);
        }
    }
    return md;
}

/// A flattened low-poly boulder.
fn buildRock(alloc: std.mem.Allocator) !MeshData {
    var md = MeshData{};
    errdefer md.deinit(alloc);
    const segs: usize = 8;
    const rings: usize = 3;
    var grid: [3][12]u32 = undefined;
    for (0..rings) |ri| {
        const v = @as(f32, @floatFromInt(ri)) / @as(f32, @floatFromInt(rings - 1));
        const y = (v - 0.5) * 0.9;
        const rad = @sqrt(@max(0.0, 0.25 - (v - 0.5) * (v - 0.5) * 0.8));
        for (0..segs) |si| {
            const a = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs)) * std.math.tau;
            const cx = @cos(a);
            const sz = @sin(a);
            const n = Vec3.init(cx, y * 1.2, sz).normalized();
            const shade = 0.85 + 0.15 * @sin(@as(f32, @floatFromInt(si)) * 1.7 + @as(f32, @floatFromInt(ri)));
            grid[ri][si] = try addVertex(&md, alloc, .{ cx * rad, y, sz * rad }, .{ n.x, n.y, n.z }, .{ 0.30 * shade, 0.29 * shade, 0.27 * shade }, 0.0);
        }
    }
    for (0..rings - 1) |ri| {
        for (0..segs) |si| {
            const sj = (si + 1) % segs;
            try addTri(&md, alloc, grid[ri][si], grid[ri + 1][si], grid[ri][sj]);
            try addTri(&md, alloc, grid[ri][sj], grid[ri + 1][si], grid[ri + 1][sj]);
        }
    }
    return md;
}

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\layout(location = 2) in vec3 a_col;
    \\layout(location = 3) in float a_rigid;
    \\layout(location = 4) in vec3 a_ipos;
    \\layout(location = 5) in vec3 a_imisc; // yaw, scale, tint
    \\uniform mat4 u_view_proj;
    \\uniform float u_time;
    \\out vec3 v_col;
    \\out vec3 v_nrm;
    \\out vec3 v_world;
    \\void main() {
    \\    float yaw = a_imisc.x;
    \\    float scale = a_imisc.y;
    \\    float tint = a_imisc.z;
    \\    float c = cos(yaw);
    \\    float s = sin(yaw);
    \\    vec3 lp = a_pos * scale;
    \\    vec3 rp = vec3(lp.x * c - lp.z * s, lp.y, lp.x * s + lp.z * c);
    \\    float height = max(a_pos.y, 0.0) * scale;
    \\    float sway = sin(u_time * 0.9 + a_ipos.x * 0.13 + a_ipos.z * 0.11 + tint * 6.2831);
    \\    float bend = a_rigid * sway * 0.10 * (height / 6.5) * (height / 6.5) * 6.5;
    \\    vec3 world = a_ipos + rp + vec3(bend, 0.0, bend * 0.4);
    \\    v_world = world;
    \\    v_nrm = vec3(a_nrm.x * c - a_nrm.z * s, a_nrm.y, a_nrm.x * s + a_nrm.z * c);
    \\    v_col = a_col * (0.80 + 0.45 * tint);
    \\    gl_Position = u_view_proj * vec4(world, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_col;
    \\in vec3 v_nrm;
    \\in vec3 v_world;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\out vec4 frag;
    \\void main() {
    \\    vec3 n = normalize(v_nrm);
    \\    if (!gl_FrontFacing) n = -n;
    \\    float ndl = max(dot(n, u_sun_dir), 0.0);
    \\    vec3 c = v_col * (0.50 + ndl * 0.85) * 0.20;
    \\    c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    \\    vec3 outc = pow(max(c, 0.0), vec3(0.4545));
    \\    vec3 ray = v_world - u_eye;
    \\    float dist = length(ray);
    \\    float H = max(u_fog_height, 1.0);
    \\    float k = ray.y / H;
    \\    float d0 = u_fog_density * exp(-(u_eye.y - u_fog_base) / H);
    \\    float tau = abs(k) > 1e-4 ? d0 * dist * (1.0 - exp(-k)) / k : d0 * dist;
    \\    float fog = 1.0 - exp(-max(tau, 0.0));
    \\    float sun_amt = pow(max(dot(normalize(ray), u_sun_dir), 0.0), 6.0);
    \\    vec3 fogc = mix(u_fog_colour, u_fog_sun, 0.15 + 0.55 * sun_amt);
    \\    outc = mix(outc, fogc, fog);
    \\    frag = vec4(outc, 1.0);
    \\}
;

const bake_vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\layout(location = 2) in vec3 a_col;
    \\layout(location = 3) in float a_rigid;
    \\uniform mat4 u_mvp;
    \\out vec3 v_col;
    \\out vec3 v_nrm;
    \\void main() {
    \\    v_col = a_col;
    \\    v_nrm = a_nrm;
    \\    gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
;

const bake_fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_col;
    \\in vec3 v_nrm;
    \\uniform vec3 u_sun_dir;
    \\out vec4 frag;
    \\void main() {
    \\    float ndl = max(dot(normalize(v_nrm), u_sun_dir), 0.0);
    \\    frag = vec4(v_col * (0.9 + 0.5 * ndl), 1.0);
    \\}
;

const impostor_vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_misc; // yaw, scale, tint
    \\uniform mat4 u_view_proj;
    \\uniform vec3 u_right;
    \\uniform vec3 u_up;
    \\uniform vec3 u_eye;
    \\out vec2 v_atlas;
    \\out vec3 v_world;
    \\out float v_tint;
    \\out vec3 v_dir;
    \\void main() {
    \\    float yaw = a_misc.x;
    \\    float scale = a_misc.y;
    \\    float h = 6.5 * scale;
    \\    float w = 3.4 * scale;
    \\    float cx = (gl_VertexID == 1 || gl_VertexID == 3) ? 0.5 : -0.5;
    \\    float cy = (gl_VertexID >= 2) ? 1.0 : 0.0;
    \\    vec3 world = a_pos + u_right * (cx * w) + u_up * (cy * h);
    \\    vec3 center = a_pos + vec3(0.0, h * 0.5, 0.0);
    \\    vec3 dir = normalize(u_eye - center);
    \\    float c = cos(-yaw);
    \\    float s = sin(-yaw);
    \\    v_dir = vec3(dir.x * c - dir.z * s, dir.y, dir.x * s + dir.z * c);
    \\    v_world = world;
    \\    v_tint = a_misc.z;
    \\    gl_Position = u_view_proj * vec4(world, 1.0);
    \\}
;

const impostor_fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec2 v_atlas;
    \\in vec3 v_world;
    \\in float v_tint;
    \\in vec3 v_dir;
    \\uniform sampler2D u_atlas;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_fog_colour;
    \\uniform vec3 u_fog_sun;
    \\uniform float u_fog_density;
    \\uniform float u_fog_height;
    \\uniform float u_fog_base;
    \\out vec4 frag;
    \\vec2 hemi_oct(vec3 d) {
    \\    d = normalize(d);
    \\    vec2 p = d.xz / (abs(d.x) + abs(d.y) + abs(d.z) + 1e-5);
    \\    return p * 0.5 + 0.5;
    \\}
    \\void main() {
    \\    vec2 uv = hemi_oct(v_dir);
    \\    vec2 g = uv * 8.0 - 0.5;
    \\    vec2 fl = floor(g);
    \\    vec2 fr = fract(g);
    \\    vec2 c0, c1, c2;
    \\    float w0, w1, w2;
    \\    if (fr.x + fr.y <= 1.0) {
    \\        c0 = fl;              w0 = 1.0 - fr.x - fr.y;
    \\        c1 = fl + vec2(1,0);  w1 = fr.x;
    \\        c2 = fl + vec2(0,1);  w2 = fr.y;
    \\    } else {
    \\        c0 = fl + vec2(1,1);  w0 = fr.x + fr.y - 1.0;
    \\        c1 = fl + vec2(1,0);  w1 = 1.0 - fr.y;
    \\        c2 = fl + vec2(0,1);  w2 = 1.0 - fr.x;
    \\    }
    \\    vec2 uv0 = (clamp(c0, vec2(0.0), vec2(7.0)) + 0.5) / 8.0;
    \\    vec2 uv1 = (clamp(c1, vec2(0.0), vec2(7.0)) + 0.5) / 8.0;
    \\    vec2 uv2 = (clamp(c2, vec2(0.0), vec2(7.0)) + 0.5) / 8.0;
    \\    vec4 s = texture(u_atlas, uv0) * w0 + texture(u_atlas, uv1) * w1 + texture(u_atlas, uv2) * w2;
    \\    if (s.a < 0.5) discard;
    \\    vec3 c = s.rgb * (0.8 + 0.4 * v_tint) * 0.30;
    \\    c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    \\    vec3 outc = pow(max(c, 0.0), vec3(0.4545));
    \\    vec3 ray = v_world - u_eye;
    \\    float dist = length(ray);
    \\    float H = max(u_fog_height, 1.0);
    \\    float k = ray.y / H;
    \\    float d0 = u_fog_density * exp(-(u_eye.y - u_fog_base) / H);
    \\    float tau = abs(k) > 1e-4 ? d0 * dist * (1.0 - exp(-k)) / k : d0 * dist;
    \\    float fog = 1.0 - exp(-max(tau, 0.0));
    \\    vec3 fogc = mix(u_fog_colour, u_fog_sun, 0.15);
    \\    outc = mix(outc, fogc, fog);
    \\    frag = vec4(outc, 1.0);
    \\}
;

const ATLAS_SIZE: usize = 1024;
const ATLAS_GRID: usize = 8;
const ATLAS_CELL: usize = ATLAS_SIZE / ATLAS_GRID;

const MAX_PER_LOD: usize = 256;

pub const PropRenderer = struct {
    shader: Shader,
    tree_meshes: [3]Mesh = .{ .{}, .{}, .{} },
    tree_instances: [3]u32 = .{ 0, 0, 0 },
    rock_mesh: Mesh = .{},
    rock_instances: u32 = 0,
    rock_count: usize = 0,
    impostor_shader: ?Shader = null,
    impostor_vao: u32 = 0,
    impostor_vbo: u32 = 0,
    impostor_tex: u32 = 0,
    last_impostor_count: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !PropRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        var self = PropRenderer{ .shader = shader };
        errdefer self.deinit(alloc);

        const lods = [_]struct { sides: usize, cones: usize }{
            .{ .sides = 12, .cones = 5 },
            .{ .sides = 8, .cones = 3 },
            .{ .sides = 5, .cones = 2 },
        };
        for (0..3) |i| {
            var md = try buildTree(alloc, lods[i].sides, lods[i].cones);
            defer md.deinit(alloc);
            gl.GenBuffers(1, @ptrCast(&self.tree_instances[i]));
            self.tree_meshes[i] = try uploadMesh(alloc, &md, self.tree_instances[i]);
        }

        var rock = try buildRock(alloc);
        defer rock.deinit(alloc);
        gl.GenBuffers(1, @ptrCast(&self.rock_instances));
        self.rock_mesh = try uploadMesh(alloc, &rock, self.rock_instances);

        self.impostor_shader = try Shader.init(impostor_vertex_src, impostor_fragment_src);
        gl.GenBuffers(1, @ptrCast(&self.impostor_vbo));
        gl.GenVertexArrays(1, @ptrCast(&self.impostor_vao));
        gl.BindVertexArray(self.impostor_vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.impostor_vbo);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Prop), 0);
        gl.VertexAttribDivisor(0, 1);
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Prop), @sizeOf([3]f32));
        gl.VertexAttribDivisor(1, 1);
        gl.BindVertexArray(0);
        try bakeAtlas(&self);
        return self;
    }

    pub fn deinit(self: *PropRenderer, alloc: std.mem.Allocator) void {
        _ = alloc;
        for (0..3) |i| {
            destroyMesh(&self.tree_meshes[i]);
            if (self.tree_instances[i] != 0) gl.DeleteBuffers(1, @ptrCast(&self.tree_instances[i]));
        }
        destroyMesh(&self.rock_mesh);
        if (self.rock_instances != 0) gl.DeleteBuffers(1, @ptrCast(&self.rock_instances));
        if (self.impostor_shader) |*sh| sh.deinit();
        if (self.impostor_vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.impostor_vao));
        if (self.impostor_vbo != 0) gl.DeleteBuffers(1, @ptrCast(&self.impostor_vbo));
        if (self.impostor_tex != 0) gl.DeleteTextures(1, @ptrCast(&self.impostor_tex));
        self.shader.deinit();
    }

    /// Uploads the rock list once per scatter build.
    pub fn uploadRocks(self: *PropRenderer, rocks: []const Prop) void {
        self.rock_count = rocks.len;
        if (rocks.len == 0) return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.rock_instances);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(rocks.len * @sizeOf(Prop)), rocks.ptr, gl.STATIC_DRAW);
    }

    /// Partitions trees by distance and draws each LOD with one instanced call.
    pub fn drawTrees(
        self: *PropRenderer,
        view_projection: Mat4,
        eye: Vec3,
        right: Vec3,
        up: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
        trees: []const Prop,
    ) void {
        if (trees.len == 0) return;
        var l0: [MAX_PER_LOD]Prop = undefined;
        var l1: [MAX_PER_LOD]Prop = undefined;
        var l2: [MAX_PER_LOD]Prop = undefined;
        var l3: [MAX_PER_LOD]Prop = undefined;
        var n0: usize = 0;
        var n1: usize = 0;
        var n2: usize = 0;
        var n3: usize = 0;
        for (trees) |t| {
            const dx = t.pos[0] - eye.x;
            const dz = t.pos[2] - eye.z;
            const d2 = dx * dx + dz * dz;
            if (d2 < 45.0 * 45.0 and n0 < MAX_PER_LOD) {
                l0[n0] = t;
                n0 += 1;
            } else if (d2 < 90.0 * 90.0 and n1 < MAX_PER_LOD) {
                l1[n1] = t;
                n1 += 1;
            } else if (d2 < 130.0 * 130.0 and n2 < MAX_PER_LOD) {
                l2[n2] = t;
                n2 += 1;
            } else if (n3 < MAX_PER_LOD) {
                l3[n3] = t;
                n3 += 1;
            }
        }

        self.begin(view_projection, eye, sun_dir, fog_colour, fog_sun, fog_density, fog_height, fog_base, time);
        self.drawLod(0, l0[0..n0], time);
        self.drawLod(1, l1[0..n1], time);
        self.drawLod(2, l2[0..n2], time);
        self.last_impostor_count = n3;
        drawImpostors(self, l3[0..n3], view_projection, eye, right, up, sun_dir, fog_colour, fog_sun, fog_density, fog_height, fog_base);
    }

    pub fn drawRocks(
        self: *PropRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
    ) void {
        if (self.rock_count == 0) return;
        self.begin(view_projection, eye, sun_dir, fog_colour, fog_sun, fog_density, fog_height, fog_base, time);
        gl.BindVertexArray(self.rock_mesh.vao);
        gl.DrawElementsInstanced(gl.TRIANGLES, @intCast(self.rock_mesh.index_count), gl.UNSIGNED_INT, 0, @intCast(self.rock_count));
    }

    fn begin(
        self: *PropRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        time: f32,
    ) void {
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_time", time);
    }

    fn drawLod(self: *PropRenderer, lod: usize, props: []const Prop, time: f32) void {
        _ = time;
        if (props.len == 0) return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.tree_instances[lod]);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(props.len * @sizeOf(Prop)), props.ptr, gl.STATIC_DRAW);
        gl.BindVertexArray(self.tree_meshes[lod].vao);
        gl.DrawElementsInstanced(gl.TRIANGLES, @intCast(self.tree_meshes[lod].index_count), gl.UNSIGNED_INT, 0, @intCast(props.len));
    }
};

    fn bakeAtlas(self: *PropRenderer) !void {
        const sun_dir = Vec3.init(0.45, 0.75, 0.40).normalized();
        var bake_shader = try Shader.init(bake_vertex_src, bake_fragment_src);
        defer bake_shader.deinit();

        gl.GenTextures(1, @ptrCast(&self.impostor_tex));
        gl.BindTexture(gl.TEXTURE_2D, self.impostor_tex);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, ATLAS_SIZE, ATLAS_SIZE, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        var fbo: u32 = 0;
        var rbo: u32 = 0;
        gl.GenFramebuffers(1, @ptrCast(&fbo));
        gl.GenRenderbuffers(1, @ptrCast(&rbo));
        gl.BindFramebuffer(gl.FRAMEBUFFER, fbo);
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.impostor_tex, 0);
        gl.BindRenderbuffer(gl.RENDERBUFFER, rbo);
        gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, ATLAS_SIZE, ATLAS_SIZE);
        gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rbo);
        defer {
            gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
            gl.DeleteFramebuffers(1, @ptrCast(&fbo));
            gl.DeleteRenderbuffers(1, @ptrCast(&rbo));
            gl.BindTexture(gl.TEXTURE_2D, 0);
        }
        if (gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) return error.ImpostorFramebuffer;

        gl.Viewport(0, 0, ATLAS_SIZE, ATLAS_SIZE);
        gl.ClearColor(0, 0, 0, 0);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        bake_shader.use();
        bake_shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });

        const target = Vec3.init(0, 3.2, 0);
        const proj = Mat4.ortho(-4.4, 4.4, -4.4, 4.4, 0.1, 60);
        for (0..ATLAS_GRID) |j| {
            for (0..ATLAS_GRID) |i| {
                const u = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(ATLAS_GRID));
                const v = (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(ATLAS_GRID));
                const dir = hemiDecode(u, v);
                const eye = target.add(dir.scale(24.0));
                const up_vec = if (@abs(dir.y) > 0.95) Vec3.init(0, 0, 1) else Vec3.init(0, 1, 0);
                const view = Mat4.lookAt(eye, target, up_vec);
                const mvp = proj.mul(view);
                gl.Viewport(@intCast(i * ATLAS_CELL), @intCast(j * ATLAS_CELL), @intCast(ATLAS_CELL), @intCast(ATLAS_CELL));
                bake_shader.setMat4("u_mvp", mvp.m);
                gl.BindVertexArray(self.tree_meshes[0].vao);
                gl.DrawElements(gl.TRIANGLES, @intCast(self.tree_meshes[0].index_count), gl.UNSIGNED_INT, 0);
            }
        }
        gl.BindVertexArray(0);
        gl.Viewport(0, 0, 3840, 2103);
    }

    fn drawImpostors(
        self: *PropRenderer,
        props: []const Prop,
        view_projection: Mat4,
        eye: Vec3,
        right: Vec3,
        up: Vec3,
        sun_dir: Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
    ) void {
        if (props.len == 0) return;
        const sh = if (self.impostor_shader) |*sh| sh else return;
        gl.BindBuffer(gl.ARRAY_BUFFER, self.impostor_vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(props.len * @sizeOf(Prop)), props.ptr, gl.STATIC_DRAW);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        sh.use();
        sh.setMat4("u_view_proj", view_projection.m);
        sh.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        sh.setVec3("u_right", .{ right.x, right.y, right.z });
        sh.setVec3("u_up", .{ up.x, up.y, up.z });
        sh.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        sh.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        sh.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        sh.setFloat("u_fog_density", fog_density);
        sh.setFloat("u_fog_height", fog_height);
        sh.setFloat("u_fog_base", fog_base);
        sh.setInt("u_atlas", 0);
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.impostor_tex);
        gl.BindVertexArray(self.impostor_vao);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(props.len));
    }

    fn hemiDecode(u: f32, v: f32) Vec3 {
        const a = u * 2.0 - 1.0;
        const b = v * 2.0 - 1.0;
        const tx = (a - b) * 0.5;
        const tz = (a + b) * 0.5;
        const ty = 1.0 - @abs(tx) - @abs(tz);
        const y = @max(ty, 0.0);
        const len = @sqrt(tx * tx + y * y + tz * tz);
        return Vec3.init(tx / len, y / len, tz / len);
    }
fn uploadMesh(alloc: std.mem.Allocator, md: *MeshData, instance_vbo: u32) !Mesh {
    var m = Mesh{};
    m.index_count = md.idx.items.len;
    gl.GenVertexArrays(1, @ptrCast(&m.vao));
    gl.GenBuffers(1, @ptrCast(&m.vbo));
    gl.GenBuffers(1, @ptrCast(&m.ebo));
    gl.BindVertexArray(m.vao);
    gl.BindBuffer(gl.ARRAY_BUFFER, m.vbo);
    gl.BufferData(gl.ARRAY_BUFFER, @intCast(md.verts.items.len * @sizeOf(Vertex)), md.verts.items.ptr, gl.STATIC_DRAW);
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, m.ebo);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(md.idx.items.len * @sizeOf(u32)), md.idx.items.ptr, gl.STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32));
    gl.EnableVertexAttribArray(2);
    gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 2);
    gl.EnableVertexAttribArray(3);
    gl.VertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 3);

    gl.BindBuffer(gl.ARRAY_BUFFER, instance_vbo);
    gl.EnableVertexAttribArray(4);
    gl.VertexAttribPointer(4, 3, gl.FLOAT, gl.FALSE, @sizeOf(Prop), 0);
    gl.VertexAttribDivisor(4, 1);
    gl.EnableVertexAttribArray(5);
    gl.VertexAttribPointer(5, 3, gl.FLOAT, gl.FALSE, @sizeOf(Prop), @sizeOf([3]f32));
    gl.VertexAttribDivisor(5, 1);
    gl.BindVertexArray(0);
    _ = alloc;
    return m;
}

fn destroyMesh(m: *Mesh) void {
    if (m.vao != 0) {
        gl.DeleteVertexArrays(1, @ptrCast(&m.vao));
        gl.DeleteBuffers(1, @ptrCast(&m.vbo));
        gl.DeleteBuffers(1, @ptrCast(&m.ebo));
    }
}
