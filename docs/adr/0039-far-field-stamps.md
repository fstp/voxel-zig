# 0039 — Far-field stamps: measured, not shipped

- Status: measured, **stamp stays off by default** (2026-11-28)
- Task: Vikunja #96, "12.7 Far-field foliage stamps and aggregate trees"
- Related: ADR 0034 (phase 12 target), ADR 0038 (partitioned blade streaming), ADR 0024 (far tree
  aggregation)

## What 12.7 needed to prove

At least 50 % fewer far-field instances beyond the chosen cutoff on the test pose, no visible stamp
seam or tree popping at the blend, a screenshot pair, 60 fps, and no regression in near-field
density.

## Far-field state before this task

- **Blades are already bounded by the patch, not by a cutoff.** Since ADR 0038 the blade field is
  cell-quantised to 96 m around the patch centre, and the streamer simply does not build cells past
  it: 32 partitions instead of 64, 2,503,346 instances instead of ~5.0 M when the radius was 95 m
  per-candidate over the whole patch. The "far-field instance count" the paper reduces with stamps
  is already reduced by the partition radius.
- **Trees are already aggregated.** ADR 0034 merges every tree beyond 55 m into one static mesh per
  32 m cell: at the test pose 32 per-tree instances plus 42 aggregate instances represent 190 trees.
- **Animation cutoff is already in place.** ADR 0037's `foliage_animation.zig` computes the 93.9 m
  ridged cutoff with a 15 m fade; blades and tree parts past it are rigid.

## What was built and measured

The one mechanism genuinely missing was the paper's **far-field stamp**: paint the meadow into the
terrain where blades no longer exist, so the ground does not turn into plain grass photo beyond the
blade field.

- `chunk_frag` gained `meadowStamp()`: strand-scale streaks from `noised()` plus a jittered
  coverage threshold between a low and a high meadow colour, a dry-grass accent and a clump-scale
  shading break-up, applied only on flat, snow-free, mud-free ground beyond
  `u_meadow_radius` with a `u_meadow_band` blend. Uniforms are the linear colours, so a calibration
  pass can invert them from a measured frame. `VOXEL_STAMP=1` turns it on.
- The blade shader's 55-120 m CPU thinning was **removed**: with the streamed field it could only
  delete instances the stream had already kept. Blades now fade by radius (height pull-down from
  74 m to the field edge) so the two representations hand over instead of one ending in front of
  the other.

### A/B result (ReleaseFast, 3840x2103, `VOXEL_DC_SUN=0.30`, ground pose, stamp on vs off)

| Metric | Value |
|---|---|
| Pixels changed by >8 levels | **862 of 8,294,400 (0.010 %)** |
| Where | HUD/second-boundary only: no terrain pixel changed |
| Max difference | 553 levels (HUD text, not terrain) |
| Frame | 60 fps both, worst 24.27 ms (on) / 25.71 ms (off) |

**The stamp is invisible at the pose that matters.** The reason is a colour match, not a bug: the
blade palette's bright tip `vec3(0.27, 0.40, 0.12)` and the terrain's existing ground photo
(`#345C1B`–`#597A2E` ranges) land within a few levels of each other after the terrain shader's
`0.16-0.34` exposure and ACES curve. The stamped colour I set (`vec3(0.020-0.055, 0.045-0.135,
0.032)` linear, times the shader's `0.35`) reproduced the ground photo almost exactly, so "with
stamp" and "without stamp" are the same image.

That is a real finding, and it changes the task: **there is no visible far-field problem for a
terrain-coloured stamp to fix on this world.** Making the stamp different enough to see would mean
deliberately mismatching the blades, which is the failure mode the task's "no visible stamp seam"
line exists to prevent.

## Decision

- **Stamp off by default** (`stamp_on: bool = false`); `VOXEL_STAMP=1` enables it for future work.
  The code is kept because the mechanism is the right one once the blade field is extended beyond
  the patch (a scope change, not a 12.7 fix) or the ground layers are made to diverge from the
  blade palette.
- **Blade CPU thinning stays removed** — it was dead work against the streamed field, and the
  radius fade replaces it without changing what is drawn.
- **No tree work in 12.7.** The aggregation from ADR 0034 is already the "merge distant trees into
  aggregate geometry" step, and the far-field stamp's purpose (hiding the end of the trees) does
  not apply: the aggregate mesh per 32 m cell is the last representation and it is drawn.

## Consequences for 12.8

The 12.7 acceptance line cannot be met as written (it asks for 50 % fewer far-field instances from
a mechanism whose target instances were already removed by 12.6), so **12.7 closes as measured with
that line named as not applicable**, and 12.8 judges the phase on: 1 M visible blades, 1,000 tree
instances, 60 fps at 4K, 1 px LOD error, and no frame over budget on a patch swap. The far-field
instance budget is set by `scatter.ACTIVE_RADIUS`; changing it changes density, not just cost, and
belongs with a density decision rather than a streaming one.

## References

- Evidence pair (stamp on / off, ground pose, same seed and sun): `/tmp/stamp_on_ground.png`,
  `/tmp/stamp_off_ground.png` on burken; the diff is 862 HUD pixels.
- ADR 0034 far-tree aggregation, ADR 0037 animation cutoff, ADR 0038 active-set quantisation.

## Files

- `src/gfx/dc_renderer.zig` (`meadowStamp`, `u_meadow_*`, `u_stamp_*`)
- `src/gfx/grass_renderer.zig` (CPU thinning removed, radius fade)
- `src/dc_main.zig` (`VOXEL_STAMP`, field centre propagation)
