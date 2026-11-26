# 0003 - Voxel storage: chunk shape, voxel type, world container

- Status: accepted
- Date: 2026-11-25
- Decides for: 1.5 (chunk + world model), 1.6 (mesher), 1.8 (worldgen), 1.11 (streaming), 1.14 (save format)

## Decision

| Choice | Value |
|---|---|
| Chunk | **32 x 32 x 32 cubes**, 32,768 voxels |
| Voxel | **u8** block id (256 types, 35 used by the plan) |
| Chunk buffer | 32 KB, index `(y * 32 + z) * 32 + x` |
| World height | **128** blocks = 4 chunk layers (y 0..127) |
| Load set | horizontal radius 6 chunks x 4 layers = **676 chunks**, a cylinder not a sphere |
| Container | `std.HashMapUnmanaged(ChunkPos, *Chunk, ctx, 80)`, key = 3 x i32 |
| Ownership | world owns every chunk; unload frees voxels and mesh |
| Scale | 1 voxel = 1 unit = 1 m; player 0.6 x 1.8 x 0.6, eye 1.62 |

## Chunk shape

At equal volume a 16 x 128 x 16 column and a 32 x 32 x 32 cube both cost 32 KB per
chunk, so memory does not decide it. What does:

| | 32^3 cube | 16 x 128 x 16 column | 16^3 cube |
|---|---|---|---|
| buffer | 32 KB | 32 KB | 4 KB |
| per-chunk allocator overhead (measured) | 12 % | 12 % | **100 %** (one page on a 4 KB buffer) |
| remesh after one block edit | 1 chunk | whole 128-high column | 1 chunk, but 8x more chunks |
| streaming | 3D, cheap to skip air above | 2D, always loads the full height | 3D, 8x the bookkeeping |
| neighbour rules for the mesher | 6 faces | 6 faces, 4 of them (x/z) only | 6 faces |

The cube wins: one isotropic buffer means one mesher, one size constant, and an edit
touches one chunk. The column's only advantage (2D streaming) is not worth a
128-block-tall remesh. 16^3 loses on measured allocator overhead: at 4 KB payload a
single extra page per allocation doubles the real cost.

## Voxel type

`u8` (256 ids). Paletted storage would shrink terrain chunks (typically <10 distinct
blocks) but adds a palette per chunk, indirection in every read, and pack/unpack work
in the mesher. Memory is not the constraint (see below), mesh memory is. `u16` buys
nothing we need. If per-voxel light arrives later it goes in a **separate** u8 array
(two nibbles: skylight, blocklight), not in the id.

## World container and lifetime

`ChunkPos = struct { x: i32, y: i32, z: i32 }` (12 bytes, no padding), hashed with
Wyhash over the three fields. Verified working in the probe: 2,197 chunks inserted and
iterated, counts match.

Lifetime rules, to keep 0.7's threading model honest:

- The world map is the single owner. Loading inserts, unloading removes and frees.
- Workers never touch a live chunk. A job owns its own output buffer and hands back a
  finished voxel buffer or mesh.
- Every chunk carries a generation stamp. When a job result arrives for a chunk whose
  stamp changed (unloaded, or reloaded elsewhere) the result is dropped. No refcounts.

## Measured memory

Probe at `~/voxel-spikes/memprobe` (burken, debug build, `page_allocator`, peak RSS from
`/usr/bin/time -v`), baseline 4.4 MiB:

| chunks | payload | peak RSS | RSS - baseline | bytes/chunk | vs 32 KB payload |
|---|---|---|---|---|---|
| 0 | 0 | 4.4 MiB | - | - | - |
| 169 | 5.3 MiB | 9.8 MiB | 5.5 MiB | 33,931 | +3.6 % |
| 676 | 21.1 MiB | 28.1 MiB | 23.8 MiB | 36,840 | +12.4 % |
| 2,197 | 68.7 MiB | 81.6 MiB | 77.2 MiB | 36,870 | +12.5 % |
| 676 + 150 KB mesh/chunk | 120.1 MiB | 128.0 MiB | 123.7 MiB | 191,906 | +5.4 KB/chunk |

The overhead is one 4 KB page per allocation, not hash map cost: 32 KB rounds up to
36 KB in the allocator. **1.5 must carve chunk buffers from a slab or arena**, e.g.
one arena block sliced into 32 KB pieces, to get the 12 % back. With 676 chunks that is
2.6 MiB, tolerable; with a taller world or a bigger radius it compounds.

The 676-chunk load set (21 MiB) is comfortable. Mesh memory is the real number: a
terrain chunk is about 1,280 quads, at 4 vertices and 24 bytes each that is ~150 KB per
meshed chunk. Only surface chunks carry geometry (roughly a third of the set), so
~35 MiB. Packing the vertex to 8 bytes later cuts that to ~9 MiB.

## Scale and coordinates

1 voxel = 1 unit = 1 m. A chunk is 32 m, render distance 6 chunks is 192 m, the player
is 1.8 m tall, so the world reads at Minecraft-like scale.

Chunk and local coordinates come from floor division, never truncating division:

```zig
pub fn chunkOf(world: i32, chunk_size: i32) i32 { return @divFloor(world, chunk_size); }
pub fn localOf(world: i32, chunk_size: i32) i32 { return @mod(world, chunk_size); }
```

`src/voxel/coords.zig` pins the cases that catch every off-by-one:

| world | chunk | local |
|---|---|---|
| -64 | -2 | 0 |
| -33 | -2 | 31 |
| -32 | -1 | 0 |
| -1 | -1 | 31 |
| 0 | 0 | 0 |
| 31 | 0 | 31 |
| 32 | 1 | 0 |

and one test that asserts `@divTrunc(-1, 32) == 0` to document the bug this replaces.
`zig build test` is at 12 tests after this task.

## Implemented (1.5)

`World` owns a `ChunkSlab` (`src/world/chunk_slab.zig`) instead of calling the
allocator per chunk: fixed blocks of 32 chunk slots (~1.05 MiB each, one `create` per
block), a `u32` bitmask of used slots per block, and freed slots reused before a new
block is allocated. The 676-chunk load set therefore costs **22 block allocations
instead of 676 mallocs** (asserted by `the 676-chunk load set costs 22 slab blocks, not
676 mallocs`), and the per-slot payload is the chunk itself, so the +12.4 % page
overhead is gone. Slot addresses never move while a chunk is loaded, which is what lets
the world map hold a raw `*Chunk`.

## Consequences

- 1.5 implements `Chunk` (32 KB buffer, state, generation) and the world map, lifting
  `ChunkPos`/hash from the probe, with the slab allocator for chunk buffers.
- The mesher (1.6) reads six neighbours, including the two vertical ones, so chunk
  boundary handling is 3D from the start.
- Streaming (1.11) enumerates a 13 x 13 x 4 cylinder, not a sphere, and can skip layers
  that are entirely air.
- Worldgen (1.8) writes columns into 32^3 chunks: a column spans four chunks, so the
  generator fills voxels chunk-wise, not column-wise, or it will thrash boundaries.
- Save format (1.14) stores 32 KB chunks; RLE on mostly-uniform chunks should land at
  1-4 KB each.
- Raising the world height or radius is linear in this table, and that is the number to
  check before changing either.
