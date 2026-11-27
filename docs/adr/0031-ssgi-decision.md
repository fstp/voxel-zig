# 0031 SSGI decision gate: rejected

- Status: rejected, no renderer change merged (11.5, 2026-11-27)
- Task: Vikunja #166 (#88)
- Research: ADR 0027

## Context

ADR 0027 put a screen-space GI spike after sun correctness, shadows and terrain AO, with an
explicit ship/reject decision. The engine has no TAA, no MSAA and no persistent scene colour/depth
target; the stage-1 stack is already the dominant visual change.

## Gate implementation

A throwaway branch rendered the scene into an offscreen `SRGB8_ALPHA8` colour texture plus a
`DEPTH_COMPONENT24` depth texture, then ran one full-screen pass. The pass sampled eight screen
neighbours at 18 pixels, weighted them by depth similarity, and mixed 16 % of the neighbour colour
back into the scene. `VOXEL_SSGI=1` enabled it; the scene target and post pass were removed after
the decision.

This is a bounded screen-space bounce probe, not a full SSGI ray marcher: it has no normals, no
ray marching, no temporal accumulation and no off-screen geometry. That is deliberate for a
decision gate, and its result is the reason not to build the larger version.

## Evidence

Peak pose, noon, shadows + AO on, same camera:

| Run | Mean abs difference | >4 levels | >8 levels | >24 levels |
|---|---:|---:|---:|---:|
| SSGI off -> on | **0.343** | 0.82 % | **0.23 %** | 0.00 % |

Screenshots: `docs/adr/img/0031-ssgi-off.png`, `0031-ssgi-on.png`. The colour bleed is invisible
at normal viewing distance; the image does not gain a readable contact-bounce cue.

Frame time at 4K, ReleaseFast, uncapped 120 Hz: SSGI on **8.42-8.52 ms**, off **8.43-8.50 ms** -
inside noise. The cost is not the problem; the benefit is not there. The offscreen target also
doubles scene colour bandwidth and would need a HDR/depth resolve in the real pipeline.

## Decision

**Reject.** The stage-1 stack (sun-correct lighting + SH9, PCSS shadows, heightfield AO) is the
shipping visual result. A full SSGI would require a scene prepass, normals, ray marching and a
spatial denoiser without TAA; the gate says it would add cost and risk without a visible
outdoor bounce. Revisit only if the world gains strong local emitters or interior spaces where
colour bleeding is a first-order cue.

No renderer code from this gate remains; the ADR and the two screenshots are the evidence.

## Files (not retained)

- throwaway `SceneTarget` and `PostRenderer` (removed after the gate)
- screenshots under `docs/adr/img/0031-*.png`
