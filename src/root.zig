//! Root of the `voxel_zig` module: the engine's public surface for the dual-contouring world.
//!
//! Modules by responsibility:
//!   math/   vectors, matrices, frustum, AABB
//!   voxel/  dual-contouring kernel
//!   world/  noise, sun
//!   gfx/    window, GL, shader, sky, HUD
//!   player  (the DC player lives in the executable, see src/dc_main.zig)

pub const version = "0.2.0";

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
    pub const dc = @import("voxel/dc.zig");
};

pub const world = struct {
    pub const dc_world = @import("world/dc_world.zig");
    pub const noise = @import("world/noise.zig");
    pub const sun = @import("world/sun.zig");
};

pub const player = struct {
    pub const DcPlayer = @import("player/dc_player.zig").DcPlayer;
};

/// The GL ProcTable owner: any code outside the engine that draws must call `init()`
/// after the context exists, or every entry point is a null pointer.
pub const gl = @import("gfx/gl.zig");

pub const gfx = struct {
    pub const Window = @import("gfx/window.zig").Window;
    pub const Shader = @import("gfx/shader.zig").Shader;
    pub const SkyRenderer = @import("gfx/sky_renderer.zig").SkyRenderer;
    pub const Hud = @import("gfx/hud.zig").Hud;
    pub const DcRenderer = @import("gfx/dc_renderer.zig").DcRenderer;
};

test {
    // Pull the submodule tests into the module test binary.
    _ = @import("math/vec.zig");
    _ = @import("math/mat4.zig");
    _ = @import("math/aabb.zig");
    _ = @import("math/frustum.zig");
    _ = @import("camera.zig");
    _ = @import("voxel/dc.zig");
    _ = @import("world/dc_world.zig");
    _ = @import("world/noise.zig");
    _ = @import("world/sun.zig");
    _ = @import("player/dc_player.zig");
}
