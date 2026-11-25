//! Root of the `voxel_zig` module: the engine's public surface.
//!
//! Modules by responsibility:
//!   math/   vectors, matrices, frustum, AABB   (1.2, 1.3)
//!   voxel/  block ids, coordinates, mesher     (1.4 - 1.6)
//!   world/  chunk storage, terrain, save       (1.5, 1.8, 1.14)
//!   gfx/    window, GL, debug draw             (1.1, 1.3, 1.4)
//!   player/ controller and collision           (1.9, 1.10)

pub const version = "0.1.0";

pub const App = @import("app.zig").App;
pub const Camera = @import("camera.zig").Camera;
pub const Input = @import("input.zig").Input;

pub const math = struct {
    pub const Vec2 = @import("math/vec.zig").Vec2;
    pub const Vec3 = @import("math/vec.zig").Vec3;
    pub const Vec4 = @import("math/vec.zig").Vec4;
    pub const Mat4 = @import("math/mat4.zig").Mat4;
    pub const Aabb = @import("math/aabb.zig").Aabb;
    pub const Frustum = @import("math/frustum.zig").Frustum;
};

pub const voxel = struct {
    pub const BlockId = @import("voxel/block.zig").BlockId;
    pub const coords = @import("voxel/coords.zig");
};

pub const gfx = struct {
    pub const Window = @import("gfx/window.zig").Window;
    pub const DebugDraw = @import("gfx/debug_draw.zig").DebugDraw;
};

test {
    // Pull the submodule tests into the module test binary.
    _ = @import("math/vec.zig");
    _ = @import("math/mat4.zig");
    _ = @import("math/aabb.zig");
    _ = @import("math/frustum.zig");
    _ = @import("camera.zig");
    _ = @import("voxel/block.zig");
    _ = @import("voxel/coords.zig");
    _ = @import("app.zig");
}
