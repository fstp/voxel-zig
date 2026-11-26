# 0013 - Block textures: CC0 photo sources at 256 px, linear magnification

- Status: accepted
- Date: 2026-11-26
- Decides for: 4.6 (texture quality)
- Depends on: 0002 (texture array), 0011 (PBR)

## Decision

| Question | Answer |
|---|---|
| Size | 256x256 per layer, up from 16x16 |
| Source | Poly Haven, CC0 - see `assets/blocks/CREDITS.md` for the file-to-source table |
| Magnification | `GL_LINEAR`, not `NEAREST`: at 256 px the photo detail is the point, and NEAREST turned every texel into a square |
| Minification | `LINEAR_MIPMAP_LINEAR`, unchanged in kind, now doing real work because the source has detail |
| Generated | leaves (Poly Haven has no canopy texture, only forest floor), water (a photo of a lake tiles badly at one metre per block) |
| Derived | grass_side: dirt with a leafy_grass fringe, per-column depth so the edge is ragged rather than painted |
| VRAM | 8 layers x 256 x 256 x 4 B = 2.0 MB, about 2.8 MB with mipmaps |

## What was rejected, and why it is worth writing down

- **Cobblestone as the stone block.** It was the first choice and it was wrong: one
  cobble texture per block face turns every stone cliff into brickwork, which read
  as a castle rather than terrain. `rock_boulder_dry` - a natural weathered rock
  surface with no coursing - is what a voxel stone block needs.
- **The raw photo colours.** Poly Haven's leafy_grass is a dry meadow and its rock
  is warm brown; used as-is the set read olive and beige. Each file got a small
  grade (grass greener and darker, stone cooler with a little more contrast) before
  it went in, and the grades are in `CREDITS.md` next to the sources.
- **A leaf canopy from Poly Haven.** They do not have one; the leaf assets are
  forest floor litter. Generated foliage with alpha gaps beats a floor texture used
  as a canopy.

## Consequences

- The 16 px set is gone, so the game no longer has the "blocky pixels" look; this is
  a deliberate move toward a realistic material look that matches the PBR shading.
- Every block face still maps the texture 0..1, so a 256 px texture is one texture
  per block face. Detail per block is much higher; there is no texture atlas
  variation between blocks, so large stone areas repeat visibly. Varying UV offsets
  per block would fix that and costs a vertex attribute or a hash in the shader.
- Normal and roughness maps are still absent: the material table is a scalar per
  layer. Poly Haven ships those maps, so adding them is now only a shader and
  vertex-format problem, not a sourcing one.
