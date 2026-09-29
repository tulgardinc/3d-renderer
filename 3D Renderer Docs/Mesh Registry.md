# Mesh Registry

*(Rewritten 2026-09-13 for app-declared layouts and unloadable geometry. The
2026-09-11 version chose vertex pulling; that was reversed — see the last
section. This is the design to build against, not a description of code: a
throwaway reference implementation lives on branch
`claude/declared-layouts-pools`.)*

The walkthrough for [[Renderer Machinery]] pieces 1 and 8: how a mesh becomes
drawable, where its bytes live, and how shaders read them.

## The stores

- **Vertex layout store** (`ArrayList` indexed by VertexLayoutID): **declared by
  the app at startup** via `renderer.declareLayout(.{ .attributes = &.{ .{
  .name, .format }, … } })`, deduplicated by content. The renderer ships one
  built-in (`renderer.builtin_layouts.static`) so an app that doesn't care
  declares nothing. Each record owns that layout's **geometry pool** (below).
  Because every layout exists before the first frame, the set of pipelines is
  closed and can be precompiled ([[Renderer Machinery]] piece 3).
- **Mesh records** (`ArrayList` indexed by MeshID): pure bookkeeping —
  VertexLayoutID, a vertex `Placement {page, base}` + count, and an
  **optional** index `{placement, count}` (the pool's own return type, stored
  as-is; `null` = non-indexed, so the flush branches on the optional rather
  than a zero sentinel). **No GPU handles** — a record addresses bytes owned
  by a page, so it can never dangle. One record = one draw call; a glTF model
  is `[]MeshID`. Buffer-less meshes stay expressible (`indices = null`,
  `vertex_count = 3`).
- **Index pool**: one pool for every layout, `u32` indices only (u16 would mean
  a second pool and a second `setIndexBuffer` per pass for a bandwidth win the
  target profile doesn't need).

## Declared layouts and the packing policy

The app declares **names and formats only**; the renderer owns the packing:

- `position` goes into **stream 0 by itself** (12 bytes for `f32x3`).
  Depth-only passes and tile-based GPUs (iOS is a target) read just that
  stream, so shadow-only or culled triangles never drag normals/uvs through
  the cache. This is the Arm/AMD/Unreal two-stream split as a fixed policy
  rather than a tuning question.
- Everything else goes into **stream 1**, interleaved in declaration order,
  each offset aligned to `min(4, size)`, stride rounded up to 4.
- A position-only layout has a single stream.

The built-in static layout is `position f32x3 | normal snorm16x4, uv f32x2,
color unorm8x4` — 32 bytes, every format hardware-converted, so a shader
declares `normal: vec3<f32>` and reads exact-enough normals with no decode
convention. (Chosen over octahedral `snorm16x2`, which is smaller but makes
every shader call a decode function, and over `f16x2` uvs, which lose
precision above ~8.) A skinned variant (`joints u8x4`, `weights unorm8x4`)
is the expected second built-in when skinning lands.

**Why declared rather than interned on demand** (the 2026-09-10 design):
interning means a chunk streaming in can introduce a new (layout × shader)
pipeline that compiles mid-frame — the one *dynamic* hazard for a streamed
open world. **Why declared rather than a single fixed format**: the app keeps
an escape hatch for attributes with a real reason to exist. The price of that
flexibility is paid per declared layout — a pipeline permutation per shader ×
state × pass targets, a batch boundary, a pool — so `precompilePipelines`
logs the layout count; K is meant to stay small. When one shader needs extra
per-vertex data, prefer a **side-channel**: an app-owned storage buffer in
group 3+ indexed by `@builtin(vertex_index)` (which `drawIndexed` pre-offsets
by `base_vertex`). Zero new pipelines.

## Registration: `renderer.mesh(data)`

`MeshData = { layout: VertexLayoutID, streams: []{ layout: gpu.VertexLayout,
data }, indices: ?[]const u32, vertex_count }` — any named attributes in any
formats. Registration:

1. Validates: non-empty, streams long enough, indices in range (WebGPU only
   checks an index against the *page*, so a bad one would silently read a
   neighbouring mesh).
2. Allocates `vertex_count` vertices from the layout's pool. Allocation is in
   vertex units, so all streams share one `base_vertex`.
3. **Packs** each canonical stream on the CPU: for each layout attribute, find
   the app's attribute by name; same format → memcpy; different → decode to
   `[4]f32` (missing components read `0,0,0,1`, like the input assembler) and
   encode. Attributes the app didn't supply read `(0,0,0,1)`; attributes the
   layout lacks are dropped. One `writeBuffer` per stream.
4. Appends the indices to the index pool, mesh-relative; `base_vertex` is
   applied at draw.
5. Returns `MeshID = { index: u24, generation: u8 }`.

Eager, synchronous, upload-once. Conversion wants a generic
`gpu.VertexFormat.decode/encode` over every format, so the packer never
special-cases a format.

## Geometry pools: unloadable, never stranded

A layout's pool is a list of **pages**. A page is one `WGPUBuffer` per stream
holding `page_capacity` vertices (default 262 144; a mesh larger than that
gets a dedicated page of its own size) plus a **free list**: offset-sorted
free spans, first-fit allocation, coalescing on free. The index pool is the
same structure in index units (default 1 M).

- **Pages are never resized, recreated or released** while the renderer
  lives; growth is "add a page". That is what makes a page buffer safe to
  capture in a future render bundle or bind group — nothing that references
  geometry ever goes stale, so piece 4's generation counter does not cover
  geometry at all.
- **`renderer.unloadMesh(id)`** returns the vertex and index spans to their
  pages and recycles the record slot with a bumped generation. A handle kept
  past unload asserts on use instead of drawing whatever reused the slot.
- Reusing a span in the same frame is safe against in-flight GPU work:
  `queue.writeBuffer` is ordered after previously submitted commands.
- Fragmentation is the free list's problem; compaction is unbuilt but legal
  (nothing outside the registry names an offset) — [[Open Questions]].

This replaces the 2026-09-10 "grow by recreation, never free" arena, which
cannot serve a streamed world: growth copies the whole arena and residency
only goes up. The paged pool is Bevy's `MeshAllocator` shape with one slab
type per stream instead of one per interned layout.

## The draw path

Classic fixed-function vertex fetch. The pipeline for (layout, shader, state,
pass targets) carries one `VertexBufferLayout` per stream — **slot = stream
index** — with shader locations matched to layout attributes **by name**: the
mesh owns stride and offset, the shader owns which attributes it consumes, and
a shader input the layout doesn't supply is `error.MissingVertexInput`. Per
batch, flush binds the mesh's page on page change (`setVertexBuffer` per
stream, whole page, offset 0 — stream 1 is bound even when the shader reads
only `position`), `setIndexBuffer` on index-page change, then
`drawIndexed(index_count, n, first_index, base_vertex, first_instance)`.
Consecutive draws from one page rebind nothing.

## Precompilation

`renderer.precompilePipelines(pass_states)` walks materials × declared
layouts × pass states through the pipeline cache before the first frame,
skipping pairs where the layout can't feed the shader. After it, streaming a
mesh in costs an upload and nothing else. An app-managed offline target with a
format not in `pass_states` is the one way a pipeline can still compile
lazily.

## Why not per-mesh buffers (2026-09-10, still standing)

Exact-size per-mesh buffers were rejected: buffer objects O(meshes), a rebind
per batch, and no path to [[Scaling and Baking|bake]]'s indirect draws —
indirect args can offset into a shared buffer but cannot switch buffers.
Pages keep all of that: O(pages) objects, rebinds only on page change,
`baseVertex` in the indirect args.

## Why not vertex pulling (decided 2026-09-11, reversed 2026-09-13)

The pulling design fetched attributes from a storage-buffer arena through a
tool-generated `vertex(vi)` with `override` stride/offsets. Reversed because
every claimed benefit was either already delivered by the shared-buffer design
(no multi-stream cursor problem, one pipeline key, indirect draws) or was a
regression: a WGSL-writing shader-tool pass, a per-layout group-2 bind-group
cache invalidated on growth, f32-only attributes (compressed formats would
have needed unpack codegen where classic fetch converts them in hardware), and
one robustness clamp per scalar load. Its one genuine capability — shaders
reading arbitrary vertices — is available opt-in through the side-channel
above without being the core path. Pulling becomes necessary only for
meshlet/cluster rendering with computed indexing, which is out of scope.
