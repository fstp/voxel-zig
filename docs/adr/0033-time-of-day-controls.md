# 0033 Time-of-day controls in the DC app

- Status: implemented (2026-11-27)
- Related: ADR 0009 (sun model), ADR 0029 (shadows), `src/input.zig`

## Problem

The DC app read the saved sun time or `VOXEL_DC_SUN` once and never changed it. The engine's
`Sun` already had `paused`, `setTime` and `clockHours`, and `Input` already emitted `pause_time`,
`time_scrub` and `time_jump`, but `src/dc_main.zig` ignored them. There was no way to inspect the
scene at a different time of day without relaunching with a different environment variable.

## Controls

- **P** pauses or resumes the 300 s daylight cycle. The app starts paused so the initial frame is
  repeatable.
- **,** and **.** move the clock back/forward by `0.02` of the cycle (6 s at the 300 s cycle).
- **1** dawn (`t=0.02`, 06:24), **2** noon (`0.30`, 12:00), **3** dusk (`0.58`, 17:36),
  **4** midnight (`0.80`, 00:00).
- **F5** and quitting save the current `sun.time`, so a chosen time survives the next launch.
- The HUD now has a line `TIME HH:MM  SUN <elevation>  PAUSED|RUNNING` and the control line lists
  `P PAUSE  ,/. TIME  1-4 DAWN/NOON/DUSK/MIDNIGHT`.

The HUD is a text atlas, not an immediate-mode GUI, so the controls are keyboard actions with a
text readout rather than clickable widgets.

## Implementation

- `src/dc_main.zig` consumes `input.pause_time`, `input.time_scrub` and `input.time_jump` before
  rendering, calls `sun.setTime`/`togglePaused`, and advances the clock with
  `sun.update(fixed_dt)` inside the existing fixed 60 Hz step.
- The save calls now pass `sun.time` instead of the startup-only `sun_time`.
- `HudStats` gained `sun_hours`, `sun_elevation` and `sun_paused`; the HUD panel grew by one line.
- The app starts with `sun.paused = true`. The `VOXEL_DC_SUN` override still pins the starting time
  for deterministic screenshots, but the keys can move it afterwards.

## Verification

Driven on burken at the tree pose with the HUD visible:

```
sun jump time 0.580 (17.60 h)     # key 3
sun running at time 0.580         # P
sun paused at time 0.593          # P after ~3 s
sun time 0.613 (18.40 h)          # period
sun time 0.593 (17.87 h)          # comma
sun jump time 0.020 (6.40 h)      # 1
sun jump time 0.800 (0.00 h)      # 4
```

The HUD showed `TIME 17:36 SUN 6 PAUSED`, then `RUNNING` while the clock advanced, and the sky
changed to dusk. Screenshot: `docs/adr/img/0033-time-controls.png`. `zig build test` green and
ReleaseFast green; the tree-pose run stayed at 60 fps.

## Limitations

- Time is a stylised cycle, not an astronomical clock: 300 s per full cycle, 60 % day / 40 % night
  (ADR 0009).
- The HUD reads out the time but is not mouse-interactive; a clickable control needs a GUI widget
  layer that the HUD deliberately does not have.
- `VOXEL_DC_SUN` is still the startup override; the new keys change the loaded/pinned time after
  startup.

## Files

- `src/dc_main.zig`
- `docs/adr/img/0033-time-controls.png`
