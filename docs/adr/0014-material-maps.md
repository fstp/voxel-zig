# 0014 - Material maps, and three filtering bugs behind "the textures look bad"

- Status: accepted
- Date: 2026-11-26
- Decides for: 4.7 (normal and roughness maps, filtering)
- Depends on: 0002 (texture array), 0008 (linear pipeline), 0011 (PBR), 0013 (textures)

## What was actually wrong

Three separate things, and only one of them was the texture resolution:

1. **Albedo was uploaded as `RGBA8`.** ADR 0008 says colour textures upload as
   `SRGB8_ALPHA8` so the hardware decodes them to linear; the loader was doing
   plain `RGBA8`, so every texture byte was shaded as if it were already linear.
   That is a mid tone 2.3x too bright, with the shadows lifted and the whole set
   looking chalky. `TextureArray.init` now takes an `srgb` flag: true for albedo,
   false for the data maps.
2. **No anisotropy.** Minification was already `LINEAR_MIPMAP_LINEAR` - trilinear
   was on - but a ground plane seen at a glancing angle has very different
   footprint per axis, and isotropic trilinear picks a mip that suits the
   compressed axis and smears the surface. Requested 8x, clamped to whatever the
   driver reports.
3. **No surface relief.** Photo albedo on a perfectly flat face still reads flat.

## Decision

| Question | Answer |
|---|---|
| Maps | tangent-space normal + per-texel roughness, from Poly Haven's `nor_gl` and `Rough` 1k sets, resampled to 256 and renormalised |
| Storage | two more `GL_TEXTURE_2D_ARRAY`s, same layer order as the albedo; `RGBA8` because they are data |
| Tangent basis | derived in the shader from the face normal - every voxel face is axis aligned, so no tangent attribute and no vertex change |
| Normal strength | `xy * 0.55`, with `z` floored at 0.15. Full strength photo normals at one block per metre read as wet tarmac |
| Roughness | `mix(layer_scalar, map.r, 0.8)`: the map carries the variation, the table still sets the material's character |
| Generated | leaves (flat normal, mid roughness), water (sine ripples, very smooth) |
| VRAM | 3 arrays x 8 layers x 256 x 256 x 4 B = 6.0 MB, about 8 MB with mipmaps |

The shadow lookup keeps using the **geometric** normal: offsetting along a
perturbed normal walks the sample into the surface and brings the acne back.

## Consequences

- Exposure had to be re-based, 0.62 -> 1.45, because the old value was tuned
  against the wrongly-decoded textures. This is the clearest evidence that bug 1
  was real: fixing the decode dropped the frame's mean luminance from 85 to 30 at
  the same camera and sun.
- Stone got a softer normal and less contrast, sand was desaturated, and water's
  albedo brightened, all after looking at the first in-game frame - recorded here
  because "photo textures dropped in" is not the end of the job, it is the start
  of the grading.
- Per-block UV variation is still absent, so large stone areas repeat. Normal maps
  help a little because the relief breaks the grid, but a hash-based UV offset per
  block is the real fix.
