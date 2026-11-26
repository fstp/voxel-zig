# 0008 - Sunlight: Lambert plus hemisphere ambient, normals from the face id, sRGB pipeline

- Status: accepted
- Date: 2026-11-26
- Decides for: 3.3 (normals), 3.5 (directional lighting), C14-C16, C20

## Decision

| Question | Answer |
|---|---|
| Lighting model | **Lambert `max(N·L, 0)` from the sun** plus a **hemisphere ambient** (sky colour above, ground bounce below); the baked AO term multiplies the result |
| Light storage | none - no per-block light values, no propagation grid; the sun is a uniform, AO is already per vertex |
| Normal source | **face id in the existing vertex pad byte**, expanded by a 6-entry table in the vertex shader; the vertex stays 24 bytes and the chunk format does not change |
| Texture pipeline | upload block textures as **`GL_SRGB8_ALPHA8`** and enable **`GL_FRAMEBUFFER_SRGB`**; shading math happens in linear space, the hardware decodes on sample and encodes on write |
| Tone response | linear light, no filmic curve yet; a soft knee only if 3.5 shows clipping at dawn/dusk |
| Face table | kept, but only as the F4 A/B reference (C16), not as the lit path |
| Block light / torches | out of scope (phase 3 non-goal); the light grid below is the path if it is ever wanted |

## Why not bake the sun into the vertices

The cheapest-looking option is to compute `N·L` in the mesher and store brightness in the
vertex. It breaks on the first moving sun: every chunk would have to be remeshed when the
time of day changes. From measured numbers: 314 chunks meshed at ~60 us each is **18.8 ms**
of meshing per light change, and at the 4-jobs-per-frame pacing from ADR 0006 that is
**~79 frames (1.3 s) of stutter** every time the sun moves. A day cycle that stutters is
worse than no day cycle, so the sun stays a uniform and the GPU does the multiply.

## Why not a Minecraft-style light grid

A per-block light value with flood-fill propagation is the correct answer when there are
torches, lava glow and caves that need to be dark. It costs a light array per chunk:
32^3 = 32,768 blocks, **32 KB per chunk as u8** (16 KB nibble-packed), so **14-17 MB** for
the 452-520 chunks a radius-6 view keeps loaded, plus propagation work on every edit and a
remesh whenever a light value changes. Phase 3 explicitly excludes block light, and AO
already handles local occlusion. Recorded here so the decision is not re-argued from
memory: revisit when torches exist, not before.

## The gamma measurement

Probe: `~/voxel-spikes/gammaprobe` (SDL3 + GL 4.6, same stack as the engine). A 128-grey
texel put through the same shader three ways, read back with `glReadPixels`:

| Mode | Pipeline | light 1.0 | light 0.5 |
|---|---|---|---|
| 0 | `gl.RGBA8` texture, multiply in sRGB space (what the engine does today) | 128 | **64** |
| 1 | `gl.RGBA8` + decode/multiply/encode in the shader | 128 | **93** |
| 2 | `GL_SRGB8_ALPHA8` + `GL_FRAMEBUFFER_SRGB` | 128 | **92** |

Same question on a 0-255 ramp after a 0.5 multiply, eight samples across:

| Mode | Samples |
|---|---|
| 0 | 0, 16, 32, 48, 64, 80, 96, 112 |
| 1 | 1, 24, 47, 71, 94, 117, 141, 164 |
| 2 | 0, 21, 45, 69, 93, 117, 141, 165 |

Two conclusions, both measured rather than asserted:

1. Multiplying sRGB bytes by 0.5 loses **29 levels** at mid-grey and crushes the ramp into
   the bottom half of the range - that is the dark, flat look a naive voxel shader has.
2. The hardware route (mode 2) matches the manual route (mode 1) within **one level** and
   costs one texture-format change plus one `glEnable`. There is no reason to hand-roll it.

The default framebuffer on burken reports colour encoding **sRGB**, so mode 2 is available
without an FBO.

## Cost of the lighting math

3000 full-screen (960x540) draws with vsync off, timed with `glFinish` and a readback:

| Variant | Total | Per 960x540 frame |
|---|---|---|
| Passthrough (texture fetch only) | 9.3 ms | ~0.003 ms |
| Lambert + hemisphere ambient + AO + gamma | 8.4 ms | ~0.003 ms |

The lit variant did not measure slower - the extra ~30 ALU ops are hidden under fill rate
on a 9070 XT, and the difference is inside run-to-run noise. Lighting is not this phase's
frame-budget risk; the sky pass (3.6) and the optional shadow map (3.8) are.

## Consequences

- The vertex format and the mesher are untouched (the face id is already there since 1.12).
- The chunk shader gains uniforms only: `u_sun_dir`, `u_sun_colour`, `u_ambient`.
- Textures must be uploaded as sRGB. Any future non-colour texture (normal maps, masks)
  must stay linear - write that down when such a texture appears.
- The block renderer (physics boxes) gets the same lighting path, which is C22.
- Water and leaves keep their alpha handling; they are in the same mesh and get lit.
- The F4 A/B keeps the old table as mode 0, so C16 is a keypress, not a rebuild.

## Probe

`~/voxel-spikes/gammaprobe`: prints the three gamma modes, the ramp samples and the fill
cost, then exits. Rerun it after any change to the texture format or framebuffer setup.
