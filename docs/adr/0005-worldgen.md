# 0005 - Worldgen: noise choice, height model, seeding

- Status: accepted
- Date: 2026-11-25
- Decides for: 1.8 (terrain generation v1), 2.2 (biomes, caves, water)

## Decision

| Question | Answer |
|---|---|
| Noise | **stateless hashed gradient noise (2D Perlin, 8 gradients, quintic fade)** |
| Permutation table | **none** - every sample is `hash(seed, ix, iz)`, so any chunk generates in any order on any thread |
| Terrain model | **2D heightmap plus layer fill** for the PoC; 3D density only for caves in 2.2 |
| Composition | continental (freq 0.0045, 4 octaves, +-46) + hills (0.021, 3, +-9) + detail (0.09, 2, +-2.5), base 54 |
| fBm | lacunarity 2, gain 0.5, per-octave seed `seed + i * 7919` |
| Height limits | world 0..127 (ADR 0003), terrain clamped **8..120**, sea level **62** |
| Interface | `fn heightAt(seed: u32, wx: i32, wz: i32) i32` - nothing above it knows which noise is inside |

## Why gradient noise, not value noise

Same cost, visibly different terrain. Hillshaded 128-block crops of identical fBm
parameters (`docs/adr/img/0005-heightmaps.png`): value noise produces **straight,
axis-aligned ridge segments and stair-stepping** along the lattice, gradient noise
produces rounded, isotropic contours. At 1-block quantization the value-noise grid is
still readable as unnatural straight lines, which is exactly the sort of thing that
looks "wrong" in a voxel world without being obviously a bug.

## Why not open-simplex yet

Open-simplex (Perlin's 2001 replacement, patent expired January 2022) is on the table
and is what 2.2 will evaluate for 3D cave density, but not for the 2D PoC:

- its wins are fewer multiplies and better isotropy **in higher dimensions**; in 2D the
  visible difference against gradient noise is marginal, and the terrain is quantized to
  whole blocks anyway;
- the reference implementation is 3-4x the code (skew/unskew constants, six corner
  contributions, distinct handling per dimension) for a piece of the engine that is
  already only 5 ns per sample;
- the noise sits behind `heightAt`, so swapping it later is a one-file change with the
  same tests (same seed and coords must produce identical output).

## Measured

Probe at `~/voxel-spikes/noiseprobe`, ReleaseFast on burken:

| what | result |
|---|---|
| Perlin sample | **5 ns** (10,000,000 samples in 0.05 s) |
| one 32^3 chunk (9 noise samples per column + fill) | **86 us** (5,000 chunks in 0.43 s) |
| 676-chunk load set, one core | ~58 ms |
| same set, meshing for comparison | 12.7 ms (ADR 0004) |

Generation is ~5x the cost of meshing, so it is the thing to put on worker threads
first (1.13), and it is still small: 676 chunks is 58 ms single-threaded.

## Seeding

One `u32` seed feeds a three-round integer mix (`h ^= h>>16; h *= 0x7FEB352D; ...`)
over `(ix, iz, seed)`, and the result picks one of 8 gradient directions. There is no
mutable state anywhere, so:

- chunk generation is a pure function of `(seed, chunk_pos)`, which is what makes it
  safe to run on N threads and to regenerate any chunk after unloading;
- a chunk saved to disk (1.14) can be verified against a regeneration;
- tests can hash 1,000 voxels and compare across runs (1.8 acceptance).

## Height model

`h = 54 + continental*46 + hills*9 + detail*2.5`, clamped to `[8, 120]`. Sea level is
62, so roughly half the world sits near sea level and the continental term decides
coastlines. Below the surface: 3 blocks of dirt then stone, grass on top (1.8).
World height 128 means terrain never touches the top chunk layer, leaving room to build.

## Biomes later (2.2)

A second noise pair - temperature at ~1/512 and humidity at ~1/384 - is sampled per
column, mapped to a small biome table (plains, forest, desert, mountains), and the
biome picks the surface block, tree density and grass tint. Because those fields are
lower frequency than the terrain and evaluated once per column, they cost about 2 % of
generation time. Borders can stay hard for the PoC; proper blending interpolates the
surface-block choice over ~16 blocks, which is a cosmetic pass on top of the same data.
Caves are the reason to revisit open-simplex: they need a 3D density field, where
simplex's cost and anisotropy advantages actually show up.

## Consequences

- 1.8 adds `src/world/noise.zig` (hash, perlin, fbm) and `src/world/terrain.zig`
  (`heightAt`, column fill), both pure and unit-tested against fixed vectors.
- The mesher and chunk code never see noise; only the generator does.
- Generation budget for 1.13: ~86 us per chunk, so a per-frame budget of 2 generations
  costs 172 us on the main thread if it ever has to be synchronous.
- If terrain looks repetitive at world scale, the first knob is the continental
  frequency, not the noise algorithm.
