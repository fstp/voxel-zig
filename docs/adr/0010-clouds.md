# 0010 - Clouds: one raymarched slab in the sky pass

- Status: accepted
- Date: 2026-11-26
- Decides for: 3.11 (volumetric clouds)
- Depends on: 0008 (linear pipeline), 0009 (sky pass and sun path)

## Decision

| Question | Answer |
|---|---|
| Technique | **raymarched slab** inside the existing sky pass, 20 steps per pixel |
| Slab | 380 to 700 blocks, faded over the top and bottom 60 so it has no visible ceiling |
| Density | two octaves of hash-based value noise (no 3D texture), scaled at 0.0042 per block, offset by a wind vector |
| Lighting | two light taps toward the sun per step (45 and 110 blocks), Beer-Lambert extinction, Henyey-Greenstein phase with g = 0.55 |
| Coverage | 0.47, a single knob: below the threshold is clear sky, above is cloud |
| Drift | a wind offset advanced on the fixed simulation step, so drift does not depend on frame rate |
| Anti-banding | per-pixel jitter on the march start, hashed from `gl_FragCoord` |
| Budget | 2.0 ms at 1280x720 (scope contract) |

## Measured

The cloud march runs inside the sky pass, so the `GL_TIME_ELAPSED` query that
already measured the sky now measures sky plus clouds:

| Scene | Sky pass |
|---|---|
| sky only (3.6) | 0.009-0.011 ms |
| sky + clouds, 20 steps (3.11) | **0.76-0.88 ms** |

That is 40 to 80 times the bare sky and still a quarter of the budget. 120 fps is
unchanged: the pass is not the frame's bottleneck.

## Rejected alternatives

- **Layered 2D sheets with parallax.** One texture fetch and a scroll offset,
  around 0.01 ms. It has no volume, no self-shadowing and no forward scatter: the
  sun cannot burn through a thin edge because there is no thickness to burn
  through. With 2 ms available and the march at 0.9 ms, spending the budget on
  actual volume is the better trade.
- **A 3D noise texture instead of hash noise.** Better quality per step at fewer
  ALU operations, but it adds an asset to author, ship and keep tileable, and the
  hash version keeps the build self-contained. Swap-in if quality ever matters
  more than build simplicity.

## What it does not do

- No precipitation, no lightning, no cloud shadows on the ground.
- One slab, so no cumulus towers or cirrus above it.
- The cloud layer does not feed the sun shadow map (3.8): ground shadows stay
  crisp under an overcast sky, which is the visible lie in this version.
- Clouds are not lit by the terrain or by each other beyond the two-tap march.

## Consequences

- `sky_renderer.draw()` takes the cloud switch and the wind offset; the app owns
  both so the drift is deterministic.
- `u_cloud_light` is the sun ramp plus a warm bias, so clouds redden at sunrise
  and sunset for free, which is the cheapest possible tie between weather and
  time of day.
- The march is per-pixel at full resolution. Half resolution with an upsample is
  the obvious next optimisation if the budget tightens.

## Amendment: less dense, and no wall on the horizon

The first cut of the layer was a uniform deck and, seen edge-on, a flat band sitting
on the horizon. Four changes, all inside `cloudDensity()` and the march:

- **Third octave** (0.55 / 0.29 / 0.16). Two octaves gave smooth blobs; the third
  breaks the edge into ragged detail.
- **Coverage is a field, not a constant.** A low-frequency sample (0.19 per block)
  adds +-0.17 to the coverage threshold, so clear spells and heavy patches sit next
  to each other. This is most of what makes the sky look unplanned rather than
  tiled, and it is one noise sample.
- **The base moves with that same field**, +-35 blocks, so the underside of the deck
  is uneven instead of a table top. It reuses the sample above, so it is free.
- **The march is bounded.** Seen edge-on the slab is thousands of blocks deep, and a
  fixed 20 steps over that distance averages the density into a wall. The ray now
  stops at 3000 blocks and fades toward the sky from 2200, which is aerial
  perspective doing the job a distance cut would otherwise fake.
- Density gained `pow(d, 1.35) * 1.7`: the curve gives puffs a defined edge instead
  of a fog ramp, the scale compensates for what the curve compresses.

| | before | after |
|---|---|---|
| coverage | 0.47 flat | 0.43 +- 0.17 weather field |
| octaves | 2 | 3 |
| march | 20 steps, unbounded | 22 steps, 3000 blocks, aerial fade 2200-3000 |
| sky pass at 1280x720 | 0.76-0.88 ms | **0.91-0.92 ms** |

Tuning note, because it cost two build cycles: raising coverage to 0.56 while adding
the weather field emptied the sky, and pushing the aerial fade in to 650 blocks
erased clouds directly overhead, since an overhead cloud at a shallow pitch is
already 1000 blocks away. Coverage down and the fade out is the direction that works.
