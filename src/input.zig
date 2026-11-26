const std = @import("std");
const sdl = @import("sdl3");
const Window = @import("gfx/window.zig").Window;

/// Frame input: held keys come straight from SDL's keyboard state, relative
/// mouse movement and wheel are accumulated from events and cleared at the end
/// of each frame.
pub const Input = struct {
    keys: [*c]const bool,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    wheel: f32 = 0,
    quit: bool = false,
    relative_mouse: bool = false,
    /// Set on the frame F3 goes down; the app clears it when consumed.
    debug_toggle: bool = false,
    /// Set on the frame F goes down (fly mode toggle).
    fly_toggle: bool = false,
    /// Set on the frame F4 goes down (AO/face-shading toggle, for A/B shots).
    shading_toggle: bool = false,
    /// Set on the frame F5 goes down (write the world save now).
    save_toggle: bool = false,
    /// Set on the frame F1 goes down (debug HUD).
    hud_toggle: bool = false,
    /// Sun controls (3.4): P pauses the cycle, comma and period scrub it,
    /// 1-4 jump to dawn, noon, dusk and midnight.
    pause_time: bool = false,
    time_scrub: i8 = 0,
    time_jump: ?f32 = null,
    /// F6 shows the normal debug view (3.3), F7 toggles distance fog (3.7).
    fog_toggle: bool = false,
    /// F8 toggles the sun shadow map (3.8).
    shadows_toggle: bool = false,
    /// F9 toggles soft (2-texel PCF) versus hard (1-texel) shadow edges.
    soft_shadows_toggle: bool = false,
    /// F10 toggles the volumetric cloud layer (3.11).
    clouds_toggle: bool = false,
    /// F11 toggles the filmic tone curve (A/B against a plain clip).
    tonemap_toggle: bool = false,
    /// - and = scale the scene exposure.
    exposure_down: bool = false,
    exposure_up: bool = false,
    /// 3.10: O pins the sun at an explicit angle or hands it back to the clock;
    /// the arrow keys move a pinned sun.
    sun_pin_toggle: bool = false,
    sun_azimuth_delta: f32 = 0,
    sun_elevation_delta: f32 = 0,
    normals_toggle: bool = false,
    /// Scripting: B cycles the brush, brackets resize it, ctrl+z/y undo/redo.
    brush_cycle: bool = false,
    throw_pressed: bool = false,
    radius_delta: i8 = 0,
    undo_pressed: bool = false,
    redo_pressed: bool = false,
    /// One-frame mouse button edges: left = break, right = place, middle = pick.
    primary_click: bool = false,
    secondary_click: bool = false,
    middle_click: bool = false,

    pub fn init() Input {
        return .{ .keys = sdl.SDL_GetKeyboardState(null) };
    }

    pub fn pump(self: *Input, window: *Window) void {
        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                sdl.SDL_EVENT_QUIT => self.quit = true,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (ev.key.key == sdl.SDLK_ESCAPE) self.quit = true;
                    // Tab releases the mouse so the desktop is usable again.
                    if (ev.key.key == sdl.SDLK_TAB) self.setRelativeMouse(window, !self.relative_mouse);
                    if (ev.key.key == sdl.SDLK_F3) self.debug_toggle = true;
                    if (ev.key.key == sdl.SDLK_F) self.fly_toggle = true;
                    if (ev.key.key == sdl.SDLK_F4) self.shading_toggle = true;
                    if (ev.key.key == sdl.SDLK_F6) self.normals_toggle = true;
                    if (ev.key.key == sdl.SDLK_F7) self.fog_toggle = true;
                    if (ev.key.key == sdl.SDLK_F8) self.shadows_toggle = true;
                    if (ev.key.key == sdl.SDLK_F9) self.soft_shadows_toggle = true;
                    if (ev.key.key == sdl.SDLK_F10) self.clouds_toggle = true;
                    if (ev.key.key == sdl.SDLK_F11) self.tonemap_toggle = true;
                    if (ev.key.key == sdl.SDLK_MINUS) self.exposure_down = true;
                    if (ev.key.key == sdl.SDLK_EQUALS) self.exposure_up = true;
                    if (ev.key.key == sdl.SDLK_O) self.sun_pin_toggle = true;
                    if (ev.key.key == sdl.SDLK_LEFT) self.sun_azimuth_delta -= 2.0;
                    if (ev.key.key == sdl.SDLK_RIGHT) self.sun_azimuth_delta += 2.0;
                    if (ev.key.key == sdl.SDLK_UP) self.sun_elevation_delta += 1.0;
                    if (ev.key.key == sdl.SDLK_DOWN) self.sun_elevation_delta -= 1.0;
                    if (ev.key.key == sdl.SDLK_P) self.pause_time = true;
                    if (ev.key.key == sdl.SDLK_COMMA) self.time_scrub = -1;
                    if (ev.key.key == sdl.SDLK_PERIOD) self.time_scrub = 1;
                    if (ev.key.key == sdl.SDLK_1) self.time_jump = 0.02;
                    if (ev.key.key == sdl.SDLK_2) self.time_jump = 0.25;
                    if (ev.key.key == sdl.SDLK_3) self.time_jump = 0.48;
                    if (ev.key.key == sdl.SDLK_4) self.time_jump = 0.75;
                    if (ev.key.key == sdl.SDLK_F5) self.save_toggle = true;
                    if (ev.key.key == sdl.SDLK_F1) self.hud_toggle = true;
                    if (ev.key.key == sdl.SDLK_B) self.brush_cycle = true;
                    if (ev.key.key == sdl.SDLK_G) self.throw_pressed = true;
                    if (ev.key.key == sdl.SDLK_LEFTBRACKET) self.radius_delta = -1;
                    if (ev.key.key == sdl.SDLK_RIGHTBRACKET) self.radius_delta = 1;
                    const ctrl_held = ev.key.mod & sdl.SDL_KMOD_CTRL != 0;
                    if (ctrl_held and ev.key.key == sdl.SDLK_Z) self.undo_pressed = true;
                    if (ctrl_held and ev.key.key == sdl.SDLK_Y) self.redo_pressed = true;
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    self.mouse_dx += ev.motion.xrel;
                    self.mouse_dy += ev.motion.yrel;
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    self.wheel += ev.wheel.y;
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    switch (ev.button.button) {
                        1 => self.primary_click = true,
                        2 => self.middle_click = true,
                        3 => self.secondary_click = true,
                        else => {},
                    }
                },
                sdl.SDL_EVENT_WINDOW_RESIZED, sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => window.syncSize(),
                else => {},
            }
        }
    }

    /// Clears the per-frame accumulators. Call after the frame has consumed them.
    pub fn endFrame(self: *Input) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.wheel = 0;
        self.primary_click = false;
        self.secondary_click = false;
        self.middle_click = false;
        self.fly_toggle = false;
        self.debug_toggle = false;
        self.shading_toggle = false;
        self.normals_toggle = false;
        self.fog_toggle = false;
        self.shadows_toggle = false;
        self.soft_shadows_toggle = false;
        self.clouds_toggle = false;
        self.tonemap_toggle = false;
        self.exposure_down = false;
        self.exposure_up = false;
        self.sun_pin_toggle = false;
        self.sun_azimuth_delta = 0;
        self.sun_elevation_delta = 0;
        self.pause_time = false;
        self.time_scrub = 0;
        self.time_jump = null;
        self.save_toggle = false;
        self.hud_toggle = false;
        self.brush_cycle = false;
        self.throw_pressed = false;
        self.radius_delta = 0;
        self.undo_pressed = false;
        self.redo_pressed = false;
    }

    pub fn setRelativeMouse(self: *Input, window: *Window, enabled: bool) void {
        _ = sdl.SDL_SetWindowRelativeMouseMode(window.handle, enabled);
        self.relative_mouse = enabled;
    }

    pub fn down(self: Input, scancode: c_int) bool {
        return self.keys[@intCast(scancode)];
    }
};
