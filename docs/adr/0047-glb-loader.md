# 0047 — GLB loader: imported props work, but proportions and LODs are not automatic

- Status: **loader done** (2026-11-28)
- Task: Vikunja #105, 13.1 (prerequisite for 13.0's asset survey)
- Source data: Kenney Nature Kit 2.1, CC0 (docs/asset-sources.md)

## What was built

`src/gfx/glb.zig` — a deliberately narrow glTF 2.0 binary reader:

- 12-byte header, JSON chunk + BIN chunk, no external `.bin` or image URIs;
- `meshes[].primitives[]` with POSITION, NORMAL and indices (u8/u16/u32);
- per-primitive colour from `pbrMetallicRoughness.baseColorFactor`, gamma-decoded (`lin`) and
  optionally re-weighted per channel (`col_scale`);
- accessor `byteOffset` and `byteStride` honoured; no skinning, morph targets or Draco.

`PropRenderer.replaceTreeMeshFromGlb` scales the asset so its bounding box is `target_height`
(the number the LOD chooser assumes), re-bases it to y = 0, maps it into the existing `Vertex`
layout and re-uploads through the same shared VBO/EBO, so instancing and the one-draw-per-LOD
batching are unchanged. Selected with `VOXEL_TREE_GLB=<path>`; the procedural mesh is the default and
stays one env-var away.

A unit test parses an embedded CC0 Kenney tree (`src/gfx/test_glb/tree_fat.glb`, 5.5 KB) and asserts
**50 triangles**, a 1.15 m tall / 0.75 m wide bounding box standing on y = 0, and that both material
colours survive. Note it only runs because `root.zig` now imports `gfx/glb.zig` — the test block lists
imports by hand.

## Measurements

| | Procedural | `tree_fat.glb` | `tree_pineSmallC.glb` |
|---|---|---|---|
| Triangles (LOD0) | 84 | **50** | **54** |
| Shared geometry | 347 verts / 1,065 idx / 19.5 KB | 96 verts / 150 idx (+ the rest) | 434 verts / 975 idx / 23.0 KB |
| Frame, same pose | 60.6 fps, worst 16.85 ms | 60.4-60.5 fps, worst 16.80 ms | 60.6 fps |
| Draw calls | unchanged | unchanged | unchanged |

Both imported meshes are **inside the 84-tri LOD0 budget** with no decimation, as the survey predicted.

## Two things the import does not solve by itself

1. **Colour.** Kenney's palette leans cyan (`leafsGreen` baseColorFactor 0.161/0.788/0.671), which
   renders as teal next to this engine's yellow-green foliage. A per-channel multiplier
   `.{1.7, 1.0, 0.30}` after the gamma decode brings it into range; the bark then reads orange
   (`.{1.0, 0.35, 0.06}`), so bark wants its own weight. A palette map would be better than channel
   weights.
2. **Proportions.** Scaling by height alone makes `tree_fat` a 4.2 m-wide canopy at 6.5 m tall — it
   reads as a wall of blocks (`0047-tree-fat.png`). `tree_pineSmallC` keeps a conifer silhouette and
   looks like the scene's forest (`0047-tree-pine.png`). **Import first: `tree_pineSmallC`, not
   `tree_fat`.**

## Still procedural, and therefore still popping

Only LOD0 is replaced. LOD1/LOD2 and the far-field aggregate mesh are still built by `buildTree`, so
an imported tree swaps back to a procedural cone at the 44 m LOD boundary and again at the 55 m
aggregate cutoff. The imported mesh also has `rigid = 0`, so it does not take the per-part wind the
procedural trees do. Decimating the imported mesh into a matching LOD chain (and a wind pivot) is the
next step, already recorded in `docs/asset-sources.md`.

## Files

- `src/gfx/glb.zig` — parser + test
- `src/gfx/test_glb/tree_fat.glb` — CC0 test asset (5.5 KB)
- `src/gfx/prop_renderer.zig` — `replaceTreeMeshFromGlb`
- `src/dc_main.zig` — `VOXEL_TREE_GLB`
- `src/root.zig` — test import
- `docs/adr/img/0047-tree-fat.png`, `0047-tree-pine.png`, `0047-procedural.png`
