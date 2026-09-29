# Instancing and Flush

## Instancing = storage-buffer vertex pulling

NOT vertex-step buffers. `@group(G) var<storage, read> instances:
array<Instance>` indexed by `@builtin(instance_index)`. Batches are addressed
via firstInstance/instanceCount; the buffer is bound **once per pass**. The
same storage buffer can be shared across shaders in a frame (old Mesh group 2
and Shadow group 0 bind one buffer) — which forced cross-shader Instance
layout agreement; the `mirror` vertex-only default in [[Lighting and Shadows]]
dissolves that coupling.

Vertex attributes do **not** take this road (a 2026-09-11 decision to pull
them was reversed 2026-09-13 — [[Mesh Registry]]): they stay fixed-function,
read from the mesh's page. Consequence for flush: on a vertex-page change
bind the page's stream buffers (`setVertexBuffer` per stream, whole page,
offset 0); on an index-page change `setIndexBuffer`; then
`drawIndexed(index_count, n, first_index, base_vertex, first_instance)`.
Consecutive draws from one page rebind nothing, so the sort's mesh key keeps
same-page meshes together.

## Flush reference algorithm

Lives in **old main.zig** (sort-key experiment, commit `ac5048f`) — the quarry
for renderer.zig's `endPass`. Port, don't reinvent:

- **Sort key** (`DrawCmd.lessThan`): opaque first; transparent back-to-front
  by view depth (model translation · camera forward); opaque by pipeline →
  material → mesh.
- **One flatten walk** over the sorted commands emits the flat instance array
  + batch list. A batch extends only if ALL state keys match; depth orders
  but never splits batches.
- Shadow pass replays the same sorted batches, `break` on first transparent.
- MSAA 4x, `.discard` + resolve to surface; depth32_float; resize recreates
  depth + MSAA textures.

## Record-time vs flush-time

Draw commands are recorded type-erased: the folded instance struct is
serialized into a byte arena at `draw`; `DrawCmd` stores offset/size.
**Pipelines are resolved at flush, never at record time** — they are derived
from (shader, render state, mesh layout, pass targets) and cached; the current
sketch's `pipeline: usize` in `DrawCmd` at record time is a leftover to fix
([[Open Questions]]).

## Cache-identity constraint (from [[Scaling and Baking]])

Keep internal caches keyed on **stable identities** (material handle, mesh
handle, render state) so `bake` bolts on later without reshaping the core.
Mesh identity resolved 2026-09-07: explicit registration
(`renderer.mesh()` → handle) — no invisible cache, no invalidation. The
pipeline key takes the mesh's interned **VertexLayoutID**, not its MeshID:
identical-but-distinct PipelineIDs would make same-format meshes unbatchable
([[Mesh Registry]]). Full ownership map: [[Renderer Machinery]].
