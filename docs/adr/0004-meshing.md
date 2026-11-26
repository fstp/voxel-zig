# 0004 - Meshing: naive face culling now, greedy later

- Status: accepted
- Date: 2026-11-25
- Decides for: 1.6 (mesher), 1.7 (draw a chunk grid), 2.1 (greedy meshing)

## Decision

Ship a **naive face-culled mesher** for the PoC: one quad per visible voxel face, no
merging. Greedy meshing is deferred to 2.1, where the same probe says it buys 3.1x
triangles for 19x the CPU time.

Vertex format for the PoC (24 bytes, proved in the 0.3 probe):

```zig
pub const Vertex = extern struct {
    pos: [3]f32,   // 12 B  chunk-local 0..32
    uv: [2]f32,    //  8 B  0..1 per face
    layer: u8,     //  1 B  texture array layer
    ao: u8,        //  1 B  0..3 (0.4 task 1.12 fills it)
    _pad: [2]u8,
};                 // 24 B, align 4
```

Indices are `u32` and per chunk, so a quad costs `4 x 24 + 6 x 4 = 120 B`. A packed
8-byte vertex (pos 5+5+5, face 3, ao 2, layer 8, then u/v spans) is the planned
optimisation in 1.16/2.1; it cuts the vertex side by 3x.

## Boundary rule

A face is emitted unless the neighbouring voxel **is opaque**:

| neighbour | emit face? |
|---|---|
| air | yes |
| water | yes (water is not opaque; separate pass later) |
| leaves | yes (cutout, you can see through the gaps) |
| stone, dirt, grass, wood | no |
| neighbour chunk not loaded | **no** - treat as opaque, and remesh this chunk when that neighbour arrives |

Treating an unloaded neighbour as opaque keeps the frontier from emitting a wall of
faces into nothing (and from re-emitting them when the chunk loads). The remesh-on-load
rule is what opens the seam; 1.11 queues it.

### Note from 1.7 (fixed field, no streaming)

The rule above is written for streaming. 1.7 draws one fixed 5 x 5 field with nothing beyond it, so
treating those borders as opaque would delete the island's outer walls and you would see straight
through the terrain into the sky. `world/chunk_mesher.zig` therefore samples the border from the
world and lets an unloaded chunk read as air, which emits the shell. The flip back to "opaque at the
frontier" belongs with 1.11, when loading actually fills those neighbours and the remesh-on-arrival
rule exists to open the seam again.

## Measured

Probe at `~/voxel-spikes/meshprobe`: same 32^3 terrain chunk(s), ReleaseFast, 32-wide
noise heightmap with stone/dirt/grass, counts verified by construction (a fully solid
chunk with no neighbours is exactly 6 x 32^2 = 6,144 faces; the probe reports 6,136
because the top layer breaks through).

Single surface chunk:

| | quads | verts | bytes @24 B | bytes @8 B |
|---|---|---|---|---|
| naive, with neighbours | 1,445 | 5,780 | 173,400 | 63,580 |
| greedy, with neighbours | 468 | 1,872 | 56,160 | 20,592 |
| naive, chunk alone (no neighbours) | 6,136 | 24,544 | 736,320 | 269,984 |
| greedy, chunk alone | 562 | 2,248 | 67,440 | 24,728 |

25 chunks in a 5x5 area at the surface layer, neighbours loaded:

- naive: min 1,194 / **avg 1,414** / max 1,550 quads per chunk, 169.7 KB each
- greedy: avg 414 quads per chunk, 49.7 KB each
- ratio 3.4x

CPU time per chunk (ReleaseFast, 40,000 meshes per run, both contexts):

| mesher | per chunk | 676-chunk load set |
|---|---|---|
| naive | **18.8 us** | 12.7 ms single-threaded |
| greedy | 353 us | 239 ms |

Debug builds are ~100x slower (2.1 ms and 5.7 ms), which is why the numbers above are
ReleaseFast only.

## Why naive wins for the PoC

- 18.8 us per chunk means a whole 676-chunk load set meshes in 13 ms on one thread, and
  an edit remeshes in 19 us. There is no CPU pressure to relieve yet.
- The greedy gain is 3.4x, not the 10-20x the articles quote. That ratio needs runs of
  identical blocks; a terrain surface is broken up by grass/dirt/stone boundaries. The
  10.9x seen on the isolated chunk is the uniform-shell case, which real meshing with
  neighbours never has.
- Greedy makes AO and per-face UVs much harder (a merged quad needs equal AO on all its
  corners to look right, which further cuts merging). Doing naive first keeps 1.12
  honest; greedy arrives when the AO question can be revisited with data.
- Naive quads per chunk (1,414) at 676 chunks is ~1M quads / 2M triangles. The 9070 XT
  does not notice; the cost that matters is memory (41 MB at 24 B/vertex vs 12 MB
  greedy), and packing the vertex to 8 B removes most of that without an algorithm.

So: naive now, greedy when either render distance grows or vertex memory shows up in
the profiler.

## Consequences

- 1.6 meshes one chunk in a padded buffer (34^3 with a 1-voxel border, as the probe
  does) so boundary culling is the same code path as interior culling.
- 1.7 uploads ~170 KB of vertex data per surface chunk; 676 chunks of it is 41 MB, which
  is why chunk meshes must be freed on unload and why 1.16 packing matters.
- 1.11's remesh queue has two triggers: a block edit, and a neighbour chunk arriving.
- 2.1's greedy mesher has a benchmark to beat: 3.1-3.4x quad reduction must not cost
  more than ~5x the naive CPU time to be worth it.
- AO (1.12) is computed per vertex corner in the naive mesher; the vertex format already
  carries the two bits.
