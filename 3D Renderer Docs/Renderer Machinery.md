# Renderer Machinery

Settled 2026-09-07 (piece 8 revised 2026-09-13: app-declared layouts and
paged geometry pools). The
ownership story for renderer.zig: what moves per frame, what the renderer
owns, and why everything is addressed by IDs and indexes instead of data.

## What uploads to the GPU per frame — and nothing else

- **The instance stream**: the pass's flat instance array, one `writeBuffer`
  into the renderer's single big storage buffer. Batches address it via
  `firstInstance` → `@builtin(instance_index)`; bound once, never rebound
  ([[Instancing and Flush]]).
- **Pass-uniform slots**: one 256-aligned slot per pass per group-0 uniform,
  in one buffer, selected via dynamic offset. Per-pass data can never reuse one
  overwritten buffer: all `queue.writeBuffer`s execute before the submitted
  commands run, so pass 1 would read pass 2's camera. This covers `world` and
  any `pass.set` uniform alike — `setBindGroup` takes an *array* of dynamic
  offsets, so one group 0 serves several slotted uniforms. Full reasoning:
  [[Uniform Storage]].
- **`material.set` / pass-scoped app data** when the app uses them.

Everything else is upload-once: mesh buffers at `renderer.mesh()`, textures at
creation, bind groups and pipelines only on cache miss or invalidation.

## Addressing: IDs and indexes, never data

- The app holds only **thin phantom-typed handles** (comptime type + `u32`
  index into a renderer-owned record). Handles are copyable values that own
  nothing — Zig value semantics force this: a by-value struct held by the app
  could never be lazily mutated by flush ([[Materials and Draw Params]]).
- `DrawCmd` is pure integers: MaterialID, MeshID (+ PipelineID resolved at
  flush) — the sort key and the record index are the same number.
- The frequency ladder: per-pass = a dynamic **offset** (not even an object);
  per-material = a bind group; per-object = an **index** into the instance
  array; per-vertex = fixed-function fetch from the mesh's page, offset by
  `base_vertex` ([[Mesh Registry]]). Per-object bind groups never exist — the only thing
  that could force one is a per-object texture, which is by definition
  another material (textures are the actual bindless gap in WebGPU; buffers
  never needed bindless).

## Where each bind group lives

- **Group 1 (material identity)**: created **eagerly** in
  `renderer.material()` — that call is the only registration point — and
  stored in the material record. Immutable forever.
- **Group 0 (world + lighting convention)** and **group 2 (the instance
  stream)**: layouts are per-shader (reflection), contents reference
  renderer-owned buffers. Created **lazily on first flush**, cached in the
  material record with a generation stamp. Group 0 is created with
  `hasDynamicOffset` on the `world` binding, so one cached object serves
  every pass — only the offset argument changes.
- Group 2 names only the shared instance buffer. Geometry is never a bind
  group input: vertex pages are bound with `setVertexBuffer`
  ([[Mesh Registry]]).
- Rejected: caching group 0/2 in a comptime per-shader container `var` —
  global state decoupled from the Renderer/device instance. Price of
  per-record caching: a harmless duplicate group per material sharing a
  shader.

## The eight renderer-owned pieces

1. **Mesh registry** — store, `ArrayList` indexed by MeshID.
   `renderer.mesh(data)` registers eagerly and synchronously. The record is
   pure bookkeeping — layout ID, `base_vertex`, counts, bounds — and holds
   **no GPU handles**: the vertex bytes go into piece 8's pages, indices into
   the u32 index pool, and `unloadMesh` returns both. No bind groups → no
   invalidation, ever.
   Primitives are pre-registered by `Renderer.init`
   (`renderer.primitives.cube`). Buffer-less meshes (fullscreen triangle: no
   streams, `vertex_count = 3`) stay expressible. One entry = one draw call,
   so a glTF model is `[]MeshID`. Full walkthrough: [[Mesh Registry]].
   *(Revised 2026-09-10 from "uploads eagerly (exact-size vertex/index
   buffers)" — per-mesh buffers made buffer objects O(meshes), forced a
   `setVertexBuffer` per batch, and foreclosed [[Scaling and Baking|bake]]'s
   indirect draws.)*
2. **Material registry** — store, `ArrayList` indexed by MaterialID. Record
   holds: group 1 (eager), uniform slots (`{chunk, offset, size}` into piece
   7), `RenderState` + entry-point selection, cached group 0/2 + generation
   stamp.
3. **Pipeline cache** — the one genuine keyed cache. Key = ShaderID ×
   RenderState × topology × **VertexLayoutID** (piece 8, never MeshID) × pass
   target formats, resolved **at flush** ([[Instancing and Flush]]). All
   integers, so lookups compare with `==`. Dedup is correctness-adjacent:
   materials sharing shader + state must yield the same PipelineID or the
   pipeline → material → mesh sort can't batch them. VertexLayoutID selects
   the vertex state — one `VertexBufferLayout` per stream, shader locations
   matched by name. Because layouts are declared up front the key space is
   closed: `precompilePipelines` walks it before the first frame
   ([[Mesh Registry]]).
4. **Generation counter** — renderer storage grows **by recreation** (new
   `WGPUBuffer`; the policy [[GPU Layer]] deliberately left to this layer).
   One grow strands every cached bind group referencing the buffer — across
   all materials and any helper bind groups, since the instance buffer is
   shared — so one renderer-level counter beats per-cache bookkeeping:
   bump on grow; lazy fields compare stamps and recreate. Grows are rare
   high-water-mark events. Geometry is **not** covered: pages are never
   recreated ([[Mesh Registry]]).
5. **Pass-uniform slot allocator** — hands out the 256-aligned slots above,
   resets per frame. Pooling here is a *correctness* requirement, not an
   optimization: disjoint ranges per pass are forced by the writeBuffer
   ordering above. Grows by **reallocation** — fan-in is one bind group and
   `beginFrame` is a free rebuild point, the opposite of piece 7 on both
   counts ([[Uniform Storage]]).
6. **Shader registry** (added 2026-09-07) — store, `ArrayList` indexed by
   ShaderID, interned by `@typeName`. **Not app-facing**: there is no
   `renderer.shader()` call; `renderer.material(S, ...)` interns on demand.
   Record is fully erased plain data — module, group layouts, VS metadata,
   entry points — since everything in the generated module except the
   generated *types* is comptime data.

   Not optional: piece 3's dedup requires materials sharing a shader to point
   at the **same** `WGPUShaderModule`. Only its *visibility* was in question.

   Why internal, when meshes got explicit registration: both objections that
   killed invisible mesh caching evaporate here. The key is a comptime type —
   `@typeName` is a binary-interned constant that cannot dangle or be recycled
   (vs. a pointer to CPU data), and shaders are never freed, only *replaced*
   by hot reload. A `ShaderID` would also have no app-side consumer: its only
   use is being handed straight back to `material()`, which unbundles the type
   from the handle that `Material(S)` deliberately binds together
   ([[Materials and Draw Params]]). Precedent: primitives are pre-registered
   by `init` — the renderer already owns things the app never registers.

   The one real counter-argument is cost visibility: WGSL compilation is the
   most expensive operation in the renderer, and hiding it makes the first
   `material()` per shader far costlier than the rest. Answer if hitching is
   ever observed: an optional `renderer.precompile(S)` warm-up — control
   without a mandatory handle. Not before.

   Payoff: stable ShaderIDs make WGSL hot reload ([[Helpers]] #3) a
   scan-and-drop over pipeline-cache keys containing that ID, instead of
   walking every material to find dependents.
7. **Material uniform arena** (added 2026-09-07) — group-1 uniforms
   suballocate from **append-only fixed-size chunks**, never one buffer per
   binding. Offsets are baked into the immutable bind group
   (`BindGroupEntry.offset`), *not* dynamic — the data never changes, so the
   mechanism for mutation would be pure cost. Conceptual walkthrough of both
   arenas: [[Uniform Storage]].

   Two mechanisms drive it, neither of them memory — memory is a wash (256-byte
   offset alignment inside an arena vs. driver slack per buffer). First, buffer
   *objects* are otherwise O(bindings): each is a Dawn wrapper, a backend
   resource and a validation-tracking entry, each paid for with a
   `wgpuDeviceCreateBuffer` at load — the expensive half of material creation,
   and the win banked immediately even creating materials one at a time.
   Second: **writes cannot coalesce across separate buffers**, so N materials
   are always N `writeBuffer` calls with N staging allocations, whereas
   contiguous arena ranges collapse into a handful. That second one is
   *latent* — it only pays once creation is batched (see below) — so chunking
   enables it rather than delivering it.

   **Chunked, not one growable buffer.** A recreated arena would strand every
   group-1 bind group referencing it — destroying "group 1 is eager and
   immutable forever", which is what makes MaterialID a stable sort and cache
   key. Fixed-size chunks are never recreated; growth appends a chunk, and a
   material's range lives entirely within one. Old chunks stay untouched, so
   nothing is stranded and piece 4's counter never has to cover group 1. Waste
   is bounded by one partially-filled chunk at any N — every chunk but the
   newest is full. Free, if materials ever gain one, is a free list rather than
   defrag: uniform sizes are `@sizeOf(T)`, comptime-fixed, and never change.
   Key it by **slot count over a single mixed-size chunk stream**, not by
   segregating chunks per size class — the latter turns that one O(1) tail into
   one tail per class.

   **Constraint that applies before the arena exists**: the record's uniform
   slot must carry `offset` even while it is always 0. Hardcoding offset 0
   bakes one-buffer-per-binding into bind-group construction and into `set`;
   carrying it keeps the switch local to the allocator. The API is unaffected
   either way — the app passes values, never buffers, and the binding stays the
   erased `{buffer, offset, size}` of [[GPU Layer]].

   Contrast with piece 8, which faces the same arena question and answers it
   the opposite way — see the deciding question at the end of piece 8.

   The bind group does **not** depend on the write — it names a *slot*, not
   contents — so `material()` stays fully synchronous: bump cursor, create
   group, return. Only the `writeBuffer` is deferrable, making a coalescing
   queue a pure optimization addable later without touching a call site.
   Current call: write immediately.

   Multiple uniform blocks in one group are never banned: the
   [[Lighting and Shadows]] convention itself puts `world` + `LightEnv` in
   group 0.

8. **Vertex layout store + geometry pools** (added 2026-09-10, revised
   2026-09-13) — store, `ArrayList` indexed by VertexLayoutID, **declared by
   the app at startup** (`renderer.declareLayout`, names + formats only,
   deduplicated by content) with one built-in default
   (`renderer.builtin_layouts.static`). App-facing, unlike piece 6: `MeshData`
   names its layout explicitly, and declaring everything up front is what
   closes piece 3's key space so pipelines can be precompiled instead of
   compiled when a mesh streams in. The renderer owns the packing — position
   in stream 0 alone, everything else interleaved in stream 1
   ([[Mesh Registry]]).

   The record owns the **geometry pool** for that layout: a list of fixed-size
   **pages**, one `.vertex | .copy_dst` buffer per stream, each with a
   first-fit, coalescing free list in vertex units (so every stream shares one
   `base_vertex`). Indices get a single u32 pool of the same shape. Pages are
   **never resized, recreated or released** — growth adds a page, a mesh
   larger than a page gets a dedicated one — so nothing that captures a page
   buffer (a future render bundle) ever goes stale, and piece 4 does not cover
   geometry. `unloadMesh` returns spans to the free list and recycles the
   record slot with a bumped generation. Result: `setVertexBuffer` per stream
   only on page change, `setIndexBuffer` only on index-page change, buffer
   objects O(pages).

   *(Revised 2026-09-13 from the 2026-09-10 "one arena per interned layout,
   grow by recreation, never free": a streamed world needs unload, and
   recreation copies the whole arena and strands everything naming it.
   The 2026-09-11 vertex-pulling revision was reversed at the same time —
   [[Mesh Registry]].)*

   Needs in gpu.zig: `VertexFormat.decode/encode` for the registration-time
   conversion and a byte-slice `writeBufferBytes`; `VertexLayout`
   (`{stride, attributes}`) already exists separately from `VertexBuffer`
   (`{ptr, layout}`) so an app can describe streams before any buffer
   exists. The renderer builds the pipeline's vertex state itself, one
   `VertexBufferLayout` per stream — [[GPU Layer]].

Frames and passes own no GPU objects — pure bookkeeping. Everything else is
app-owned (camera, textures via gpu.zig) or pass-scoped data.

## Constraint carried forward

All caches keyed on stable identities (record indexes) — required so
[[Scaling and Baking|bake]] bolts on later without reshaping the core.
