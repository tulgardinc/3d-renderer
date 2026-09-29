# Lighting and Shadows

*Status: **SKETCH — NOT LOCKED.** Constraint in force: nothing but API
sketching until fully done and locked in; then it gets locked into the vault
and spec-main. No code.*

Requirement: express **arbitrary** lights — multiple directional, point, spot,
shadowed or not — not just the single test spike in old main.zig. `light()` as
a core primitive is skipped; lighting is helpers + convention over two new
core primitives.

## New core primitives (sketch)

- **`pass.set(name, value)`** — pass-scoped app data, the pass-frequency
  analog of `material.set`. Must accept uniforms, textures, samplers, AND
  storage buffers. The lighting convention is sugar over it. Exact shape
  undecided.
- **`pass.mirror(...)`** — re-encode the pass's draw queue (possible because
  draws queue until `endPass`) with overrides: camera, color/depth targets
  (incl. array-layer selection `.depth_target = .{ .texture, .layer }`),
  material, include filter. Multiple mirrors per pass. Shading modes:
  - `.vertex_only` (default): reuse each draw's own vertex stage, no fragment
    stage / no color targets. Kills the separate Shadow.wgsl twin-shader and
    its cross-shader Instance-layout coupling.
  - `.{ .material = m }`: override with a stripped shader (the old approach;
    needed e.g. for alpha-tested materials, which want a fragment stage in
    shadow passes).
  - `.full`.

## Generalized lighting convention (sketch)

Storage-buffer array of lights + env uniform, replacing the single-light
names:

```wgsl
struct Light { kind, color, intensity, pos, range, dir, cone, shadow_index, light_vp }
var<storage, read> lights: array<Light>;
// LightEnv uniform: count, ambient
shadow_maps: texture_depth_2d_array;  shadow_smp: sampler_comparison;
```

## Lighting helper (sketch)

Owns light list + shadow map array; built entirely on public primitives:

```zig
lighting.directional(.{ .dir = ..., .shadow = true });
lighting.point(.{ .pos = ..., .range = ... });
lighting.spot(...); lighting.ambient(0.01);
lighting.apply(render_pass);   // fills convention bindings, adds shadow mirrors
```

Undecided points tracked in [[Open Questions]].
