# Reflection Pipeline

WGSL → tree-sitter shader-tool (build-time exe) → generated Zig module per
shader → `gpu.Shader(Reflected)`.

## Generated module (e.g. src/shaders/compiled-copy/Mesh.zig)

`NAME`, `SOURCE`, extern structs (World, Instance), per-group `Uniforms` /
`Resources` / layouts (`.resource_type = .{ .storage = .{ .array = Instance } }`),
named VS inputs.

## gpu.zig consumption

- `Shader(Reflected)` builds module + bind group layouts.
- `createBindGroup(group, ...)` takes a comptime-built struct with
  binding-name fields (`ShaderBindGroup`).
- `Shader.Uniform.<name>.init` / `Shader.Storage.<name>.initCapacity` give
  typed buffers per binding.
- Vertex attributes matched mesh ↔ shader **by name**; the mesh (the declared
  layout) owns stride/offset, the shader owns which attributes it consumes.
  The renderer does the matching at pipeline creation ([[Mesh Registry]]).

The tool only *reads* WGSL. A 2026-09-11 plan to have it generate and splice
vertex-fetch code (for vertex pulling) was reversed on 2026-09-13 with pulling
itself — [[Mesh Registry]].

Gap: `VertexInputMeta` carries name and location but not the input's scalar
type, so "format base type matches shader input" (`snorm16x4` → `vec3<f32>`
fine, `u8x4` → `vec3<f32>` not) is validated by Dawn at pipeline creation,
not in Zig — [[Open Questions]].

## Guiding principle

*Codegen where the shader is authoritative* (bind group layouts, pipeline
layout, entry points, uniform/storage struct layouts with std140/std430
padding); *validate-and-route where it's only a constraint* (vertex buffers:
the layout owns stride/offset, the shader owns which attributes it consumes,
matched by name into classic vertex state at pipeline creation).

Gotcha: Zig skips unused pub decls in analysis — compile-gate generated code
via a consumer referencing every pub decl.

`src/shaders/*.wgsl` are synthetic fixtures exercising the reflection tool;
scope the library by reflection/WGSL support, and add fixtures for gaps.
