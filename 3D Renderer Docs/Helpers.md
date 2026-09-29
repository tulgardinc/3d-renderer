# Helpers

Written against the public API, **never inside the core**. Shadow mapping was
the litmus test for the core primitives: app-owned depth texture, ortho sun
camera, two passes — the core never knows shadows exist.

## Core primitives they build on (each general, none technique-specific)

- Off-screen pass targets (`.color_target = .none | <texture>`,
  `.depth_target = <texture>`); sampling a prior pass's target
- Orthographic projection
- Comparison samplers as a material binding option
- `material.set(.name, value)` per-frame material uniforms
- Pass-scoped app data (shape undecided — [[Lighting and Shadows]])
- Mesh topology (triangles, lines)
- Pass `samples` option (MSAA)

## Ship list, priority order

1. **Debug draw** — line/wireCube/axes/sphere, depth-tested or on-top
2. **Text overlay** — baked bitmap font, `debug.text(pos, fmt, args)`
3. **WGSL hot reload** (dev-only) — shader *bodies* only; error-magenta on
   compile failure
4. **Shadow map / lighting helper** — see [[Lighting and Shadows]]
5. **Sprites / 2D pass** (ortho + quads + transparency)
6. **Skybox**
7. **Fullscreen post pass** (tonemapping/vignette/fades)
8. **Screenshot readback** (gpu-layer utility)

Later, opt-in: [[Scaling and Baking|bake/drawList]].

Outside the library entirely: model loading (glTF → `Mesh` + textures) — the
CPU-data mesh design is the seam.

## What finished looks like

- Spec main.zig compiles and runs native + web: three tinted checkered cubes,
  fly camera, directional + ambient light, resize works.
- Core primitives exist; the shadow helper proves them.
- Debug draw + text overlay ship.
- New shader = WGSL + `renderer.material(...)`; new look = a `RenderState`
  field. Neither touches renderer internals.
