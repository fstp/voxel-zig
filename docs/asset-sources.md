# Free mesh sources for rocks, bushes and foliage

- Status: surveyed 2026-11-28 (task 13.0). Every URL below was opened on that date; licence text was
  read on the page (or in the shipped `License.txt`), not taken from a marketplace badge.
- Budgets this is measured against (ADR 0034 / 0024): **tree LOD0/LOD1/LOD2 = 84 / 40 / 20 triangles,
  rock = 48 triangles**, one shared VBO/EBO per part, one instanced draw per LOD. Anything accepted
  has to fit that or be decimated deliberately.

## Sources

| Source | Licence (read where) | Attribution | Redistribution | What it has |
|---|---|---|---|---|
| **Poly Haven** | CC0, stated on <https://polyhaven.com/license> | not required | allowed | Photogrammetry-grade rocks, trees, shrubs, ferns, grass; glTF/FBX/blend/USD + PBR maps |
| **Kenney** | CC0, `cc0 1.0` in the pack's own `License.txt` and on <https://kenney.nl/support> | optional ("not mandatory") | allowed | Low-poly game kits; Nature Kit 2.1 ships 329 models as GLB/glTF/OBJ/FBX/DAE/STL |
| **Quaternius** | **QAL v1.0** on <https://quaternius.com/license> (updated 2026-08-28) | not required | **NOT allowed** — may not redistribute the assets as assets | Stylized Nature MegaKit, Simple Nature Pack (trees, bushes, rocks, plants) |
| **ambientCG** | CC0, <https://ambientcg.com/> FAQ + license page | not required | allowed | Mostly PBR materials/HDRIs; few models — useful for ground textures, not props |

**Flag on Quaternius:** the pack pages (e.g. `stylizednaturemegakit.html`) still carry a
`creativecommons.org/publicdomain/zero/1.0/` link while the site's licence page has moved to QAL v1.0,
which forbids redistributing the assets themselves. Downloads also go through itch.io rather than a
direct link. Treat those packs as **QAL, not CC0**: fine to ship inside a game build, but do not commit
the source meshes into a public repository. Verify with Quaternius before relying on the CC0 badge.

## Candidates, measured

Kenney triangles were **counted from the downloaded `nature-kit.zip` GLB files** (index accessor
count / 3); Poly Haven triangles are the `polycount` field from its model API
(<https://api.polyhaven.com/assets?t=models>), read 2026-11-28.

### Rocks and boulders (budget 48 tris)

| Candidate | Source | Licence | Format | Tris | Verdict |
|---|---|---|---|---|---|
| `rock_smallA.glb` | Kenney Nature Kit 2.1 <https://kenney.nl/assets/nature-kit> | CC0 | GLB/OBJ/FBX | **16** | import first — three silhouettes (A/B/C) at 16-24 tris |
| `rock_smallB.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **24** | import first |
| `rock_smallFlatA.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **20** | import first — flatter, reads as scree |
| `cliff_rock.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **32** | import first — larger boulder |
| Moon Rock 02 <https://polyhaven.com/a/moon_rock_02> | Poly Haven | CC0 | glTF/FBX/blend/USD | **6,194** | reference only — 129x the budget; fine as a hero prop if the rock budget is raised |

### Bushes and shrubs

| Candidate | Source | Licence | Format | Tris | Verdict |
|---|---|---|---|---|---|
| `plant_bushSmall.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **16** | import first — ground-level shrub |
| `plant_bush.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **32** | import first — the mid shrub |
| `plant_bushLarge.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **60** | import — above the 48-tri rock budget but well under tree LOD0 |
| `plant_bushDetailed.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **104** | only as a near-field hero; needs a decimated LOD |
| Shrub 03 <https://polyhaven.com/a/shrub_03> | Poly Haven | CC0 | glTF/FBX/blend + Alpha/mask | **16,955** | geometry no; its **Alpha + mask maps** are useful source material for the 12.5 opacity masks |

### Trees

| Candidate | Source | Licence | Format | Tris | Verdict |
|---|---|---|---|---|---|
| `tree_fat.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **50** | import first — inside the 84-tri LOD0 budget with no decimation |
| `tree_pineSmallC.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **54** | import first — a second conifer silhouette |
| `tree_simple.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **62** | import first |
| `tree_default.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **114** | needs decimation to 84/40/20 |
| Fir Tree 01 <https://polyhaven.com/a/fir_tree_01> | Poly Haven | CC0 | glTF/FBX/blend + PBR | **7,853,731** | reference only — 4-5 orders above the budget; its `twig_alpha`/`twig_mask` maps are the interesting part |

### Ground cover (grass cards, ferns, weeds)

| Candidate | Source | Licence | Format | Tris | Verdict |
|---|---|---|---|---|---|
| `ground_grass.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **2** | import first — a two-triangle card, exactly the shape the blade/mask work wants |
| `grass_leafs.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **36** | import — small clump |
| `flower_purpleA.glb` | Kenney Nature Kit 2.1 | CC0 | GLB/OBJ/FBX | **76** | import as a scattered flower (cheaper than a blade cluster) |
| Fern 02 <https://polyhaven.com/a/fern_02> | Poly Haven | CC0 | glTF/FBX/blend + Alpha | **6,232** | geometry no; **Alpha map** is good reference for a fern mask card |
| Grass Medium 01 <https://polyhaven.com/a/grass_medium_01> | Poly Haven | CC0 | glTF/FBX/blend | **1,606,633** | texture/mask reference only |

## Import-first recommendation

1. **Kenney Nature Kit 2.1** (CC0) is the only surveyed source that lands inside the current budgets
   without decimation: rocks 16-32 tris (budget 48), trees 50-62 tris (budget 84), bushes 16-60 tris,
   ground cards 2 tris. Import `tree_fat`, `tree_pineSmallC`, `tree_simple` as the three tree
   silhouettes, `rock_small{A,B,C}` + `rock_smallFlatA` + `cliff_rock` as the rock set,
   `plant_bush{Small,,Large}` for shrubs and `ground_grass` + `grass_leafs` for ground cover.
2. **Tree LOD1/LOD2 still need work**: the source LOD0 meshes are single-resolution, so LOD1 (40 tris)
   and LOD2 (20 tris) have to be decimated or hand-built from them. Nothing in either CC0 source ships
   a matching LOD chain.
3. **Poly Haven is not an import source for this renderer** — a single fir tree is 7.85 M triangles
   against an 84-tri budget. Its value here is (a) hero/reference geometry and (b) the **alpha and
   mask maps** on `fir_tree_01`, `shrub_03` and `fern_02`, which are exactly the input the software
   opacity-mask work (12.5) needs.
4. **Quaternius' Stylized Nature MegaKit** looks the closest stylistically, but the CC0 badge on the
   pack page contradicts the current QAL licence, and QAL forbids redistributing the assets. Worth a
   licence question before use; do not commit its meshes to the repo either way.

## Blocker for actually using any of this

The renderer has **no mesh file loader** — props are built procedurally in `prop_renderer.zig`, and
nothing in `src/` parses glTF or OBJ. Importing a Kenney GLB therefore needs a small loader (GLB
chunk parse, accessor → interleaved `Vertex`, index remap) before any of the above can be drawn. That
is a separate task; this document only establishes what is worth loading.
