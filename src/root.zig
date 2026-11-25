//! Root of the `voxel_zig` module: the engine's public surface.
//!
//! Modules by responsibility (the rest arrive with their tasks):
//!   math/   vectors and matrices            (1.2, 1.3)
//!   voxel/  block ids, coordinates, mesher  (1.4 - 1.6)
//!   world/  chunk storage, terrain, save    (1.5, 1.8, 1.14)
//!   gfx/    window, GL, shaders             (1.1, 1.4)
//!   player/ controller and collision        (1.9, 1.10)

pub const version = "0.0.1";

pub const math = struct {
    pub const Vec3 = @import("math/vec.zig").Vec3;
};

pub const voxel = struct {
    pub const BlockId = @import("voxel/block.zig").BlockId;
    pub const coords = @import("voxel/coords.zig");
};

test {
    // Pull the submodule tests into the module test binary.
    _ = @import("math/vec.zig");
    _ = @import("voxel/block.zig");
    _ = @import("voxel/coords.zig");
}
