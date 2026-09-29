# Materials and Draw Params

*Status: **SKETCH.** (Rewritten 2026-09-11 — the original was lost in the
vault misnaming; reconstructed from cross-references and the in-progress
renderer.zig. Treat details as the code's current shape, not locked design.)*

The app-facing half of [[Renderer Machinery]] piece 2: how a material is
created, what the app holds afterwards, and how `draw` parameters reach the
shader.

## `renderer.material(S, params)`

`S` is the reflected shader module ([[Reflection Pipeline]]). The call:

1. Interns the shader (piece 6) — first use per shader pays WGSL compilation.
2. Builds `MaterialParams(S)` — a comptime-generated struct with one field
   per group-1 binding, by name: uniforms take their reflected value type;
   textures take `{tex, view_config}`; samplers take `SamplerConfig`
   (defaulted); storage takes the erased `{buffer, offset, size}` of
   [[GPU Layer]]. Zero group-1 bindings ⇒ `void` — a material with no GPU
   identity beyond its shader is legal.
3. Allocates uniform slots from the piece-7 arena, writes values, creates the
   **eager, immutable** group-1 bind group, appends the record, returns a
   handle.

Wrong names or shapes in `params` are comptime errors — the negotiation of
[[Shader Contract]].

## `Material(S)`: the handle binds the type

The returned handle is a thin phantom-typed value — `material_id` plus
comptime `InstanceType` and `Shader`. `Material(S)` requires the shader to
declare an `instances` storage array ([[Shader Contract]]) and extracts its
element type; that type drives `DrawParams`. Binding type-to-handle is
deliberate: it lets `draw` typecheck params against the *material's* shader
with no runtime lookup, and it is why a bare ShaderID has no app-side
consumer ([[Renderer Machinery]] piece 6).

## `DrawParams(Instance)`

A comptime transform of the shader's instance struct into the ergonomic
callsite shape:

- The reserved `model: mat4x4` field is **replaced** by `position`,
  `rotation`, `scale` (each defaulted — identity transform), folded into the
  model matrix by the renderer at record time. Reserved *fields*, hard
  contract: [[Shader Contract]].
- Every other field forwards by name (e.g. `tint`), so a shader gains a
  per-instance parameter by declaring it — no renderer change.

At `draw`, the folded instance struct is serialized type-erased into the
frame's byte arena; `DrawCmd` records offset/size and pure-integer IDs
([[Instancing and Flush]]).

## `material.set` (planned)

Per-frame material uniforms — the material-frequency analog of `pass.set`
([[Helpers]] core primitive list). Requires the piece-7 slot's `{chunk,
offset, size}` addressing that records carry from day one. Shape not locked.

## Open points

Tracked in [[Open Questions]]: rotation representation (`[3]f32` Euler is
currently implied), where `RenderState` enters `material()`, and
`default_value_ptr` mechanics for the generated struct defaults.
