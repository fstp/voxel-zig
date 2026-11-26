const std = @import("std");

/// Block types. The numeric value is what goes into the chunk buffer, so the
/// order is part of the on-disk format once 1.14 exists: append, never reorder.
pub const BlockId = enum(u8) {
    air = 0,
    stone,
    dirt,
    grass,
    sand,
    wood,
    leaves,
    water,

    /// Collides with the player and culls neighbour faces.
    pub fn isSolid(self: BlockId) bool {
        return switch (self) {
            .air, .water => false,
            else => true,
        };
    }

    /// Hides the face of a neighbouring block. Leaves are solid but you can
    /// see through the gaps, so they do not cull their neighbours.
    pub fn isOpaque(self: BlockId) bool {
        return switch (self) {
            .air, .water, .leaves => false,
            else => true,
        };
    }

    pub fn faceTextures(self: BlockId) FaceTextures {
        return switch (self) {
            .air => .{ .top = LAYER_STONE, .side = LAYER_STONE, .bottom = LAYER_STONE },
            .stone => .{ .top = LAYER_STONE, .side = LAYER_STONE, .bottom = LAYER_STONE },
            .dirt => .{ .top = LAYER_DIRT, .side = LAYER_DIRT, .bottom = LAYER_DIRT },
            .grass => .{ .top = LAYER_GRASS_TOP, .side = LAYER_GRASS_SIDE, .bottom = LAYER_DIRT },
            .sand => .{ .top = LAYER_SAND, .side = LAYER_SAND, .bottom = LAYER_SAND },
            .wood => .{ .top = LAYER_WOOD, .side = LAYER_WOOD, .bottom = LAYER_WOOD },
            .leaves => .{ .top = LAYER_LEAVES, .side = LAYER_LEAVES, .bottom = LAYER_LEAVES },
            .water => .{ .top = LAYER_WATER, .side = LAYER_WATER, .bottom = LAYER_WATER },
        };
    }

    pub fn layerFor(self: BlockId, face: Face) u8 {
        const textures = self.faceTextures();
        return switch (face) {
            .py => textures.top,
            .ny => textures.bottom,
            else => textures.side,
        };
    }
};

pub const Face = enum(u3) { px, nx, py, ny, pz, nz };

/// Outward normal of a face, in the vertex ordering the mesher emits:
/// px, nx, py, ny, pz, nz.
///
/// This is the single source of truth for the mapping. The chunk shader carries
/// the same six-entry table (`normalFromFace`), because 3.3's whole point is to
/// light geometry without growing the 24-byte vertex - the face id already rides
/// in `_pad[0]`. Keep the two in step; the mesher test asserts this table and
/// the mesher's own per-face normals agree.
pub fn faceNormal(face: Face) [3]f32 {
    return switch (face) {
        .px => .{ 1, 0, 0 },
        .nx => .{ -1, 0, 0 },
        .py => .{ 0, 1, 0 },
        .ny => .{ 0, -1, 0 },
        .pz => .{ 0, 0, 1 },
        .nz => .{ 0, 0, -1 },
    };
}

pub const FaceTextures = struct { top: u8, side: u8, bottom: u8 };

// Layer indices must match the order of `texture_paths`.
pub const LAYER_STONE: u8 = 0;
pub const LAYER_DIRT: u8 = 1;
pub const LAYER_GRASS_TOP: u8 = 2;
pub const LAYER_GRASS_SIDE: u8 = 3;
pub const LAYER_SAND: u8 = 4;
pub const LAYER_WOOD: u8 = 5;
pub const LAYER_LEAVES: u8 = 6;
pub const LAYER_WATER: u8 = 7;

/// Edge length of every block texture, in pixels. 16 was the procedural set; the
/// CC0 photo set is 256, which is what stops the blocks looking like coloured
/// noise at arm's length. One number, because the array layers are square.
pub const TEXTURE_SIZE: u32 = 256;

/// One PNG per texture layer, loaded into a single GL_TEXTURE_2D_ARRAY
/// (ADR 0002). The order defines the layer indices above.
/// One entry per texture layer, same order as `texture_paths`. Roughness is the
/// GGX perceptual roughness (0 mirror, 1 fully diffuse); metallic 0 means a
/// dielectric with a 4 percent F0, 1 means the albedo is the reflectance.
///
/// These are the numbers PBR materials are described with, and the reason the
/// blocks read as different substances under a moving sun rather than as one
/// surface wearing different textures: wood takes a highlight, stone scatters it,
/// water keeps a mirror.
pub const Material = struct {
    roughness: f32,
    metallic: f32,
    /// How much of the albedo reaches the diffuse lobe. Water absorbs light that
    /// enters it, so its diffuse is nearly zero and the sky reflection is what
    /// you actually see; everything solid stays at 1.0.
    diffuse: f32 = 1.0,
};

pub const layer_materials = [_]Material{
    .{ .roughness = 0.72, .metallic = 0.0 }, // stone: some sheen on a broken face
    .{ .roughness = 0.95, .metallic = 0.0 }, // dirt: almost fully diffuse
    .{ .roughness = 0.90, .metallic = 0.0 }, // grass top
    .{ .roughness = 0.90, .metallic = 0.0 }, // grass side
    .{ .roughness = 0.88, .metallic = 0.0 }, // sand
    .{ .roughness = 0.48, .metallic = 0.0 }, // wood: planed, the shiniest natural block
    .{ .roughness = 0.82, .metallic = 0.0 }, // leaves
    // Water: smooth, and with almost no diffuse. Leaving it at 1.0 was why the
    // sea read as flat blue - its own albedo swamped the 4 percent reflection.
    .{ .roughness = 0.08, .metallic = 0.0, .diffuse = 0.28 },
};

pub const texture_paths = [_][:0]const u8{
    "assets/blocks/stone.png",
    "assets/blocks/dirt.png",
    "assets/blocks/grass_top.png",
    "assets/blocks/grass_side.png",
    "assets/blocks/sand.png",
    "assets/blocks/wood.png",
    "assets/blocks/leaves.png",
    "assets/blocks/water.png",
};

// ------------------------------------------------------------------ tests

test "air and water do not block the player" {
    try std.testing.expect(!BlockId.air.isSolid());
    try std.testing.expect(!BlockId.water.isSolid());
    try std.testing.expect(BlockId.stone.isSolid());
}

test "leaves are solid but not opaque" {
    try std.testing.expect(BlockId.leaves.isSolid());
    try std.testing.expect(!BlockId.leaves.isOpaque());
}

test "ids fit in a byte" {
    try std.testing.expectEqual(@as(usize, 8), std.enums.values(BlockId).len);
    try std.testing.expect(@sizeOf(BlockId) == 1);
}

test "grass uses grass top, grass side and dirt bottom" {
    const grass = BlockId.grass;
    try std.testing.expectEqual(LAYER_GRASS_TOP, grass.faceTextures().top);
    try std.testing.expectEqual(LAYER_GRASS_SIDE, grass.faceTextures().side);
    try std.testing.expectEqual(LAYER_DIRT, grass.faceTextures().bottom);
}

test "layerFor picks the right layer per face" {
    const grass = BlockId.grass;
    try std.testing.expectEqual(LAYER_GRASS_TOP, grass.layerFor(.py));
    try std.testing.expectEqual(LAYER_DIRT, grass.layerFor(.ny));
    try std.testing.expectEqual(LAYER_GRASS_SIDE, grass.layerFor(.px));
    try std.testing.expectEqual(LAYER_GRASS_SIDE, grass.layerFor(.nz));
    try std.testing.expectEqual(LAYER_STONE, BlockId.stone.layerFor(.ny));
}

test "every block maps inside the texture array" {
    for (std.enums.values(BlockId)) |block| {
        const t = block.faceTextures();
        try std.testing.expect(t.top < texture_paths.len);
        try std.testing.expect(t.side < texture_paths.len);
        try std.testing.expect(t.bottom < texture_paths.len);
    }
}

test "every texture layer has a material" {
    try std.testing.expectEqual(texture_paths.len, layer_materials.len);
    for (layer_materials) |m| {
        try std.testing.expect(m.roughness > 0.0 and m.roughness <= 1.0);
        try std.testing.expect(m.metallic >= 0.0 and m.metallic <= 1.0);
        try std.testing.expect(m.diffuse >= 0.0 and m.diffuse <= 1.0);
    }
}

/// Tangent-space normal maps, same order and length as `texture_paths`. Data, not
/// colour: uploaded as plain RGBA8 (see `TextureArray.init`'s `srgb` flag).
pub const normal_paths = [_][:0]const u8{
    "assets/blocks/stone_n.png",
    "assets/blocks/dirt_n.png",
    "assets/blocks/grass_top_n.png",
    "assets/blocks/grass_side_n.png",
    "assets/blocks/sand_n.png",
    "assets/blocks/wood_n.png",
    "assets/blocks/leaves_n.png",
    "assets/blocks/water_n.png",
};

/// Per-texel roughness, red channel, blended with the layer's scalar value. Water
/// is nearly black here because it is nearly a mirror.
pub const rough_paths = [_][:0]const u8{
    "assets/blocks/stone_r.png",
    "assets/blocks/dirt_r.png",
    "assets/blocks/grass_top_r.png",
    "assets/blocks/grass_side_r.png",
    "assets/blocks/sand_r.png",
    "assets/blocks/wood_r.png",
    "assets/blocks/leaves_r.png",
    "assets/blocks/water_r.png",
};

test "every layer has a normal map and a roughness map" {
    try std.testing.expectEqual(texture_paths.len, normal_paths.len);
    try std.testing.expectEqual(texture_paths.len, rough_paths.len);
}
