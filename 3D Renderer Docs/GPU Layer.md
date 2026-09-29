# GPU Layer (gpu.zig)

Typed, context-explicit helpers over raw WebGPU. Usable standalone; every call
takes the context explicitly, no globals. Uses extern `z_*_INIT` C helpers for
descriptor defaults (web/native compat).

## Load-bearing layering rule

*The gpu layer owns objects whose identity is fixed at init; anything whose
identity evolves over time belongs to the renderer/app.*

- `StorageValue`/`StorageArray`/`StorageBuffer` are fixed-capacity; `upload`
  returns `error.CapacityExceeded` instead of growing.
- Why no growth machinery: WebGPU buffers can't resize and bind groups are
  immutable, so growth = new buffer + stale bind groups; *how* to bookkeep
  that is app policy. Even a dormant generation counter would pre-commit one
  scheme. Growth/ring-buffers/per-frame dynamics get built in the renderer on
  top of `binding()` — never as gpu.zig hooks.
- The one obligation to those policies: recreating a bind group from current
  resources stays a cheap one-liner.
- The renderer's chosen policy (2026-09-07): grow by recreation + one
  renderer-level generation counter — [[Renderer Machinery]].

## Vertex layout is a separate type from vertex buffer

`VertexLayout` = `{stride, attributes:[{name, format, offset}]}`;
`VertexBuffer` = `{ptr, layout}`. The split is required by the renderer's
per-layout geometry arenas ([[Mesh Registry]]): a layout must be derivable
before any buffer exists, and interning a struct containing a `WGPUBuffer`
would never dedup. `VertexLayout.of(T, formats)` keeps today's comptime
offset/stride checks; `VertexBuffer.of` delegates.

The renderer's declared layouts (planned 2026-09-13) build on this: a layout
record packs names + formats into up to two streams, and at pipeline creation
each stream becomes one `VertexBufferLayout` with shader locations matched by
name (`indexOfVertexInput`, to be made `pub`). Needed additions:
`VertexFormat.decode/encode` over every format (registration-time
conversion) and a byte-slice `writeBufferBytes` — today's `writeBuffer` takes
one value. See [[Mesh Registry]].

The draw path carries a `Geometry {first_index, base_vertex, count}` range,
mirroring `Instances`, so a draw can address a sub-range of a shared buffer.
Consistent with the layering rule: gpu.zig exposes the *addressing*, the
renderer owns the *allocation policy*.

## Vertex slot rule

The index into `vertex_layouts` **is** the slot number, and slot = stream
index of the renderer's layout (0 = position, 1 = attributes). A stream the
shader doesn't read still gets a `VertexBufferLayout` (with zero attributes)
and the draw path binds every stream unconditionally — a `.vertex`-step slot
with no buffer bound is a validation error. Pages are bound whole, offset 0,
so the 4-byte offset-alignment rule never comes up. *(A 2026-09-11 plan
deleted this rule along with vertex state; reversed 2026-09-13 —
[[Mesh Registry]].)*

## Erased binding contract

`binding()` returns `{buffer, offset, size}` and `ShaderBindGroup` storage
fields take exactly that — deliberately no structural type check (goal is
killing boilerplate, not preventing runtime bugs). This lets one buffer feed a
compute shader's group and a render shader's group.

Gotcha: `StorageArray.binding()` sizes to capacity, so WGSL `arrayLength()`
reports capacity, not live count; the wrapped shape carries `count` in a
header.
