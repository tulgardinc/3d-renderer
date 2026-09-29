# Shader Contract

The renderer fills in what the app never passes, negotiated **per shader
through reflection at comptime**: declared names are filled, undeclared names
are skipped, wrong shapes are compile errors. Decided 2026-09-06: the contract
is **two-tier** — a hard contract of what the renderer inherently derives, and
an opt-in lighting convention. Lighting is a look; the core has no look.

## Hard contract (all shaders)

- **Reserved draw-param fields** (renderer-computed): `position`, `rotation`,
  `scale` → folded into the model matrix written to the shader's per-instance
  `model` field. All other draw-param fields forward to the instance struct by
  name (e.g. `tint`). See [[Materials and Draw Params]].
- **Vertex input**: a `VertexInput` struct with `@location`s, fields matched
  to the mesh layout's attributes **by name** at pipeline creation. The
  scalar class must match the format (`f32` inputs for float and normalized
  formats); the component count may differ — a `snorm16x4` normal feeds
  `vec3<f32>`, missing components read `(0,0,0,1)`. The app never sees a
  stride, offset, or buffer. Mechanics: [[Mesh Registry]]. *(A 2026-09-11
  revision to a no-`@location`, `vertex(vi)` pulling form was reversed
  2026-09-13.)*
- **Pass globals**: a `world` uniform with `vp_matrix` and other
  renderer-derived values, written per pass at flush time. (They are *pass*
  globals, not frame globals — multi-view means different values per pass.)
- **The instance stream**: the `instances` storage binding, filled with the
  pass's flat instance array. See [[Instancing and Flush]].
- **Fixed group slots** (revised 2026-09-07 from "convention, not enforced"):

  | group | meaning | if absent |
  |---|---|---|
  | 0 | pass globals — `world`, lighting convention, `pass.set` data | material has no world group |
  | 1 | material bindings ("this bind group IS a material's GPU identity") | material has no bind group |
  | 2 | the instance stream (`instances`) | non-instanced shader |
  | 3+ | app's own | renderer never touches them |

  **Fixed slots, optional occupancy**: the *meaning* of an index is fixed, but
  a shader may omit any group. Reserved names are still located by reflection
  — just within their known group (`world` must live in group 0; its binding
  number stays whatever the shader says).

  Why enforced rather than inferred: the alternative rule — "the material
  group is whichever group holds no reserved names" — has no good failure
  mode. A stray uniform in group 3 either silently becomes the material group
  or yields "ambiguous: groups 1 and 3 both qualify", which tells the author
  nothing. Fixed slots give a comptime error that names the fix
  (`"PbrShader: material bindings must be declared in @group(1)"`). The one
  counter-example that motivated the flexible rule — Shadow.wgsl collapsing
  into group 0 — is the twin-shader that `mirror(.vertex_only)` exists to
  delete ([[Lighting and Shadows]]), so the flexibility was never
  load-bearing.

  Implementation cost: `gpu.Shader.pipelineLayouts()` currently returns
  `error.UndefinedBindGroup` on any gap. Optional occupancy means filling gaps
  with an **empty** bind group layout instead of erroring.

## Lighting convention (opt-in by declaration)

Shaders declaring the conventional names (`light_dir`, `ambient`; for shadows
`shadow_map`, `shadow_smp`, `light_vp`) get them filled from the pass's light
calls. Declare none → never meet it. Custom lighting models bind their own
pass-scoped app data instead. No lights submitted ⇒ ambient-only black —
obviously dark, not mysteriously broken. Being generalized in
[[Lighting and Shadows]] (sketch).

## Conventions, not contract

- **Reserved names are BINDING names, not struct names.** The instance struct
  is found by following the `instances: array<T>` binding's element type;
  calling it `Instance` is only convention. Similarly `VertexInput` is only
  the conventional name for the vertex-stage input struct. The only reserved
  *field* inside the instance struct is `model`.

## Known drift

- `src/shaders/Mesh.wgsl` uses `light_pos` where the convention says
  `light_dir` — see [[Open Questions]].
- `src/shaders/Shadow.wgsl` puts `instances` in group 0, non-conformant under
  fixed group slots. Not worth fixing: it is the twin-shader
  `mirror(.vertex_only)` deletes.

Shaders in `src/shaders/` are synthetic fixtures for the reflection tool, not
signal about renderer scope.
