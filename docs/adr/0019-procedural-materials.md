# 0019 - Procedural materials from the field (IQ), no texture array

- Status: proposed
- Date: 2026-11-26
- Decides for: 7.3 (materials for the isosurface world)
- Depends on: 0018 (dual contouring), supersedes the texture-array work of 4.7 in spirit

## Why the texture array cannot survive

4.7 built a 256^2 albedo/normal/roughness array indexed by *block face id*. A DC vertex has
no face id: it is one point per cell, shared by whatever quads touch it. So the material has
to come from the field, not from a cube's six faces. That is not a downgrade - it removes
UVs, the array, the per-layer uniform array, and the ATLAS seam problem in one move.

## What IQ's articles actually give us

Checked against the source articles rather than remembered:

1. **Value-noise derivatives, analytically** (`articles/morenoise`): the value and its three
   derivatives come out of *one* evaluation. His own numbers: analytic is about 5x cheaper
   than central differences, and he used exactly this for the terrain in *Elevated*. Code
   shape: expand the trilinear interpolation into the k0..k7 polynomial, differentiate that.
2. **fBm derivatives** (`articles/morenoise`, plus `articles/gradientnoise`): the fractal sum
   accumulates value *and* derivatives per octave, with the rotation matrix carried along so
   the derivatives stay in world space. That means a *fractal* surface can have an exact
   analytic normal - no finite differences anywhere.
3. **Bump without normal maps** (`articles/nvscene2008/rwwtt.pdf`):
   `n = normalize(grad(SDF, p) + bump * grad(fbm, p))`, with bump small and material
   dependent. This is the whole normal story for us: the DC vertex already carries the SDF
   gradient, so the shader adds a scaled noise gradient on top.
4. **Material blending** (`articles/function2009` slide deck, *Elevated*): three ways to lerp
   between material layers, and the one he actually shipped perturbs the blend factor with a
   noise function `h` so the transition is not a clean straight line. That is what stops a
   blend looking like a gradient.
5. **Biplanar mapping** (`articles/biplanar`, 2020): triplanar needs three texture fetches;
   biplanar needs two, using the two dominant axes and reconstructing the third. Only matters
   if we end up sampling textures at all - with pure procedural noise we never do.

## The design that follows

**Per-vertex material id from the field.** The generator already knows what a point *is*
(soil, rock, sand, snow). Sample it alongside the SDF and store one byte per vertex. That is
cheaper and more stable than classifying in the shader, and it survives the LOD question.

**Albedo and roughness procedurally, in world space.** No UVs: evaluate noise at
`world_pos * scale` per material, derive albedo from a palette function and roughness from a
second band of the same noise. Because it is world space, the pattern is continuous across
every chunk border, which is precisely the property blocky textures never had.

**Normals from analytic derivatives.** `n = normalize(sdf_grad + bump * noise_grad)`, with
`bump` per material. This is IQ's line, and it avoids both a normal map *and* the tangents
4.7 had to derive from the face normal.

**Blend with a noise-perturbed factor, not a straight lerp.** His *Elevated* deck's point:
`mix(a, b, f + h)` where `h` is a noise term, so a rock/soil boundary is ragged instead of
linear.

**Palette functions.** Cosine palettes (`a + b*cos(2pi*(c*t + d))`) give a whole material
range from four vectors with no data. Worth using for the base albedo per material.

## What to build, in order

1. Extend the DC vertex with a material byte (from the generator) and a per-vertex colour
   derived on the CPU - it makes the first render show material variety with no shader work.
2. Port `noised()` / `fbm_derivatives()` into GLSL (the k0..k7 form above is the spec) and
   use the analytic gradient for the bump term.
3. Replace the block texture array from 4.7 with the procedural path, keeping the array
   behind a flag until the new path is faster and better on the same scene.

## Risks

- **Procedural noise costs more than a texture fetch** on a large surface. Measure the
  fragment cost per material band, do not assume; the shader has to stay inside the
  8.5 ms frame budget at 1080p.
- **Derivative noise has to be quintic** in the interpolation, not cubic, or the second
  derivative breaks and the analytic normals show facets - IQ calls this out explicitly in
  the value-noise article.
- Per-vertex material ids make LOD transitions show material seams unless the classifier is
  a pure function of world position (it should be).
