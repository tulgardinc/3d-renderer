# Open Questions

Tracked undecided points, 2026-09-06.

## Lighting / mirror sketch (blocking lock-in — [[Lighting and Shadows]])

- Exact shape of **pass-scoped app data** (`pass.set` vs struct at beginPass
  vs other)
- **Mirror include-filter** shape (per-draw flag? material property? layer
  mask?)
- One array-based lighting convention vs keeping the simple single-light one
  too (lean: **one**, array-based)
- `light_dir` vs `light_pos` naming (Mesh.wgsl fixture currently says
  `light_pos`)
- Sun/directional parameterization details for shadow cascades

## Materials / draw ([[Materials and Draw Params]])

- **Rotation representation**: `[3]f32` currently implies Euler XYZ; decide
  deliberately (Euler vs axis-angle vs quat `[4]f32`) — DrawParams freezes it
  into every call site of the spec
- Where **RenderState** enters `material()` (part of the binding struct? a
  separate param?)
- `pipeline: usize` in `DrawCmd` at record time is stale — pipelines resolve
  at flush ([[Instancing and Flush]])
- `default_value_ptr` mechanics: needs `@ptrCast` + stable comptime const home
- **Optional bind-group occupancy**: `getOrCreatePipeline` still returns
  `error.UndefinedBindGroup` on a gap in the shader's groups; the contract
  says fill gaps with an empty layout ([[Shader Contract]]).

## Mesh registry ([[Mesh Registry]])

- **Page sizing**: proposed defaults are 262 144 vertices and 1 M indices per
  page. Per-layout override? Smaller pages for rarely-used declared layouts?
- **Fragmentation / compaction**: the free list coalesces but never moves
  spans. Compaction is legal (nothing outside the registry names an offset,
  MeshIDs stay stable) but unbuilt; decide a trigger if a streamed world
  fragments in practice.
- **Format ↔ shader input validation**: `VertexInputMeta` has no type, so a
  layout whose format base type (`uint`/`sint`/`float`) doesn't match the
  shader's input is caught by Dawn at pipeline creation — as an error
  *object*, not null, so it currently slips past `createPipeline`'s null
  check. Fix: shader-tool emits the input's scalar type; the renderer's
  vertex-state builder compares it against the format's base type
  (float / uint / sint).
- **Layout count visibility**: `precompilePipelines` logs K; is a warning
  threshold wanted?
- **Skinned built-in layout**: joints `u8x4` + weights `unorm8x4` as the
  second built-in, when skinning lands.
- **`MeshID` generation width**: 8 bits wrap after 256 reuses of one slot;
  acceptable for now, widen if a streaming pattern hammers one slot.
- **Topology's home**: per-mesh record or folded into the declared layout? A
  pipeline-key component either way; only the storage site is open.
- **Streaming uploads off the main thread**: `writeBuffer` is queue-timeline;
  a staging/mapped path for chunk loads is unbuilt.

## Later

- Whether shader-tool stays a build-time exe or grows a runtime mode —
  [[Reflection Pipeline]]

## Resolved

- ~~Mesh upload cache identity/invalidation~~ → **explicit registration**
  (`renderer.mesh()` → handle), 2026-09-07. Pointer-keyed invisible caching
  rejected: fragile identity (realloc-at-same-address renders stale data), no
  free/eviction story. See [[Renderer Machinery]].
- ~~Renderer buffer growth policy~~ → **grow by recreation + one
  renderer-level generation counter**, 2026-09-07 — [[Renderer Machinery]].
  *Scope narrowed 2026-09-13: covers the instance buffer and pass-uniform
  pool; geometry pages are never recreated.*
- ~~Where mesh vertex/index buffers live~~ → **per-layout geometry arenas**,
  2026-09-10; **revised to per-layout paged pools**, 2026-09-13. Exact-size
  per-mesh buffers stay rejected: buffer objects O(meshes), a
  `setVertexBuffer` per batch, and no path to indirect draws. Piece 8 in
  [[Renderer Machinery]]; walkthrough in [[Mesh Registry]].
- ~~Vertex layout identity~~ → **app-declared at startup** via
  `declareLayout`, deduplicated by content, with a built-in default,
  2026-09-13. Interning on demand rejected: it lets a streamed chunk
  introduce a pipeline compile mid-frame. A single fixed format rejected: no
  escape hatch for genuinely custom attributes. [[Mesh Registry]].
- ~~Mesh free/eviction~~ → **span free list inside fixed pages**,
  `unloadMesh`, generation-checked `MeshID`, 2026-09-13. [[Mesh Registry]].
- ~~Vertex fetch mechanism~~ → **classic fixed-function fetch**, 2026-09-13,
  reversing the 2026-09-11 vertex-pulling decision. Pulling delivered no
  measured win and cost a WGSL-writing tool pass, bind-group invalidation for
  geometry, f32-only attributes and per-load robustness clamps; its one real
  capability (arbitrary vertex reads) is available opt-in via a side-channel
  storage buffer. Rationale in [[Mesh Registry]].
- ~~Vertex packing policy / position-attribute split~~ → **fixed two-stream
  policy**: `position` in stream 0 alone, everything else interleaved in
  stream 1, 2026-09-13. The iOS target (tile-based binning) and shadow passes
  are the payoff; Arm/AMD guidance, Unreal's `FPositionVertexBuffer`. Sources
  from the 2026-09-12 research: Arm GPU Best Practices; learn.arm.com
  "Optimizing graphics vertex efficiency"; Vulkan Guide "Tile Based Rendering
  Best Practices"; anteru.net "Storing vertex data: to interleave or not to
  interleave" (2016); bevyengine/bevy#16156.
- ~~Default vertex format~~ → `position f32x3 | normal snorm16x4, uv f32x2,
  color unorm8x4` (32 B), 2026-09-13. Chosen over octahedral normals (needs a
  shader decode convention) and `f16` uvs (precision above ~8).
- ~~Index formats~~ → **u32 only**, 2026-09-13.
