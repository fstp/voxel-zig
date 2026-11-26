# 0018 - Leaving blocky voxels: isosurface extraction (marching cubes or dual)

- Status: proposed (research)
- Date: 2026-11-26
- Decides for: 7.2 (surfaces from an isosurface instead of blocks)
- Supersedes in spirit: 0004 (face-culled block mesher) stays, but only as the fallback path

## Question

Should the world stop being blocks and become a surface extracted from a scalar field -
marching cubes, or one of the modern variants - and is there a dependency worth taking?

## The two families, and what actually separates them

Every method places geometry at the same place: where a grid edge runs from outside the
surface to inside. The families differ in what they do with those crossings.

- **Primal (marching cubes, marching tetrahedra)** put a *vertex* at each crossing and cut
  triangles inside the cell from a table.
- **Dual (surface nets, dual contouring, dual marching cubes)** put a *face* at each
  crossing and one *vertex* inside each crossed cell.

The measured differences, from the isoext and isomesh documentation rather than from
folklore:

| | Marching cubes | Surface nets | Dual contouring |
|---|---|---|---|
| Vertices | on grid edges | one per cell, at the crossing centroid | one per cell, fitted to the SDF gradient (QEF) |
| Triangle shape | slivers when a crossing sits near a corner (edges differ by an order of magnitude) | evenly tessellated | evenly tessellated |
| Sharp features | no - nothing sharper than a voxel | no (0.58 cells from a box corner) | **yes** (0.01 cells, 101x closer on a sharp field) |
| Manifold | yes | pinches and tunnel edges | pinches, tunnel edges, and self-intersection if the vertex leaves the cell |
| Chunk seams | tiles exactly on a shared plane | gapped by construction | gapped by construction |

The last row is the one that decides our case, and it needs care to state correctly.
`isomesh` puts it as: "are you chunking? Then the seam is structural, not a bug someone
will fix later: MarchingCubes and SubgridMarchingTetrahedra tile with zero boundary edges on
a shared plane; the dual methods place one vertex per cell and are gapped by construction."

That is true **when each chunk is meshed in isolation**. It is not true for us, because our
mesher already evaluates a padded grid - `PADDED_SIZE 34` for a 32-block chunk - so the
border cells are sampled from the same deterministic field from both sides. Two chunks
therefore compute *identical* border vertices, and a dual method joins seamlessly at equal
LOD. The gap the library warns about is the one you get without a border.

Where the seam problem genuinely remains is **between different LODs**, and that is what
Transvoxel (Lengyel) exists for: it meshes a block mostly normally but with extra detail on
one face, so a coarse block welds to a fine neighbour. There is no equivalent for dual
methods that is as mature; a skirt or a stitched band is the usual workaround.

## What this means for us

We want organic terrain - hills, overhangs, caves - with a view distance, and we carry no
art requirement for crisp CAD edges. That points at:

**Dual Contouring with the QEF solution clamped inside the cell** as the primary path:
- one vertex per cell, so our existing 34^3 padded grid gives exact seams at equal LOD,
- evenly shaped triangles, and far fewer of them than MC for the same detail,
- sharp features for free once we have real SDF gradients (cliffs, carved tunnels),
- clamping the solution inside the cell avoids DC's self-intersection failure mode, at the
  cost of rounding the sharpest corners - which is the right trade for terrain.

Keep the blocky path (the current face-culled mesher) behind a flag. It is finished,
tested and 120 fps, and it is the reference to compare against when the new path is slow or
wrong.

**Do not take a dependency for the extraction itself.** The core is small: find the
crossed edges per cell, accumulate a QEF per cell, solve a 3x3 symmetric system, emit one
quad per crossed edge. That is a few hundred lines in this codebase, and it needs to share
our chunk, threading and material structures - a foreign library would be a marshalling
layer around 300 lines of maths.

Named alternatives, for the record:
- **isomesh** (Rust, MIT): the most complete modern implementation - MC, surface nets, DC,
  manifold DC, subgrid marching tetrahedra, greedy quads - and its docs report measured
  comparisons. Excellent, but a cross-language boundary for a small kernel.
- **CGAL Isosurfacing_3** (C++, GPL): MC, topologically correct MC, DC, with real
  guarantees. Too heavy, wrong licence for a game.
- **Transvoxel reference code** (Lengyel, free to use): the LOD seam solution, worth
  porting when the LOD work starts, not before.

## Consequences that are not about meshing

This is not a mesher swap, and the ADR should be honest about the blast radius:

- **Blocks stop being the unit of the world.** The block registry, the texture array of
  256^2 albedo/normal/roughness, and the per-layer material uniforms all assume a cube with
  a face id. A DC surface has one vertex per cell and no face id; material has to come from
  the field (a material channel per sample, blended at the vertex) instead.
- **Lighting keeps working.** SSAO, PCSS and the sky probe are screen-space or world-space
  and do not care about the geometry's origin. AO from the block-vertex scheme does not
  survive - it has to be recomputed from the SDF or dropped.
- **Water needs rethinking.** Everything in 6.3 was block-shaped water. A DC sea is a plane
  or a height field, not a set of quads per block.
- **Save format changes.** RLE of 32^3 blocks becomes a field; either store the SDF
  quantised per sample, or store the generator parameters and edits.

## Recommendation

1. Spike **dual contouring with clamped QEF** on the current chunk layout, reusing the
   34^3 padded grid and the worker pool. Measure: quads per chunk against the blocky path,
   mesh time per chunk, and whether the seam is exact at equal LOD.
2. Run **marching cubes with the 33-case table** as the comparison point in the same spike,
   not as a straw man - it is the fallback if DC's vertex placement misbehaves on terrain.
3. Defer LOD. When it arrives, port Transvoxel for the MC path or stitch skirts for DC.
4. Keep the blocky mesher behind a flag until the new path is faster and better looking on
   the same scene, at the same 120 fps.

## Open questions for the spike

- How many quads does DC emit per 32^3 chunk on the existing terrain, against the blocky
  943k in view? Dual methods should win on smooth ground and lose on flat planes.
- Do we sample the SDF per chunk from noise at mesh time (cheap, deterministic, seam-exact)
  or keep a cached field (faster, more memory)? The seam argument above depends on the
  field being deterministic at the border.
- What does the AO path become without block-vertex AO?
