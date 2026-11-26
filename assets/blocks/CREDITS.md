# Block textures

The photo textures are from [Poly Haven](https://polyhaven.com), which releases
its textures under CC0: no attribution required, but it costs nothing to name them.

| file | source |
|---|---|
| stone.png | polyhaven.com/textures/cobblestone_01 (desaturated, blurred, darkened) |
| dirt.png | polyhaven.com/textures/dirt |
| grass_top.png | polyhaven.com/textures/leafy_grass (green boosted) |
| grass_side.png | generated: dirt with a leafy_grass fringe, per-column depth |
| sand.png | polyhaven.com/textures/coast_sand_01 |
| wood.png | polyhaven.com/textures/bark_brown_01 |
| leaves.png | generated: procedural overlapping leaf blobs with alpha gaps |
| water.png | generated: near-uniform deep water, because the albedo barely shows through a 0.12 diffuse |

All are centre-cropped to square and resampled to 256x256 with Lanczos.
The two generated files exist because Poly Haven has no tree-canopy or water
diffuse texture: their leaf assets are forest floor, and a photo of a lake tiles
badly at one metre per block.
