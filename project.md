# 3d-renderer

A WebGPU renderer in Zig for throwing game prototypes together fast. Exists to
kill the pipeline/shader/bind-group boilerplate that killed a previous raw-WebGPU
project. Targets native (Dawn) and web (emdawnwebgpu); windowing/input stay in
SDL and are not this library's business.

`src/main.zig` is the executable spec: it is written against the finished API
and we implement until it compiles and runs. This file records the same design
in prose.

## Layering

```
app (main.zig)  →  renderer.zig  →  gpu.zig  →  WebGPU
```

- **gpu.zig** — typed, context-explicit helpers over raw WebGPU: buffers,
  textures, samplers, surface, and the comptime shader reflection interface
  (`Shader(Reflected)` from build-time WGSL reflection/codegen). Usable
  standalone. Every call takes the context explicitly; no globals.
- **renderer.zig** — the opinionated layer. Owns instance/device/queue/surface,
  resize, frame/pass structure, the pipeline cache, the batcher, materials, and
  built-in primitive meshes. Consumes gpu.zig; re-exports `c` and `is_web` so
  the app needs no direct gpu import for platform glue. Apps may still use
  gpu.zig directly for raw resources (e.g. `gpu.Texture.init`).
- **app** — owns its camera, its loop, its assets, and submits immediate-mode
  draws every frame.

## API shape

Everything visible is immediate mode: lights and draws are submitted per pass,
per frame, and the queue dies at `endPass`. Retained state is only assets
(textures, materials, meshes) and whatever the app keeps for itself (camera).

```zig
var renderer = try Renderer.init(allocator, io, window);   // owns everything graphics

const checker = try gpu.Texture.init(.{ ... });            // raw resources from the gpu layer

// material = shader + its shared bindings, comptime-checked against reflection
const lit = try renderer.material(LitShader, .{
    .texture = checker,
    .smp = .{ .filter = .nearest },
});

var cam = Renderer.Camera{ .pos = .init(0, 0, 3) };        // app-owned value type

// per frame:
const frame = try renderer.beginFrame();                    // acquire, resize, encoder
const render_pass = frame.beginPass(.{ .clear_color = ... }); // default target: window + depth
render_pass.setCamera(cam);                                 // camera is pass state
render_pass.light(.directional, .{ .direction = ... });     // lights are pass state
render_pass.light(.ambient, .{ .intensity = 0.01 });
render_pass.draw(Renderer.PrimitiveMeshes.cube, lit, .{     // queued, batched at endPass
    .position = ...,
    .rotation = ...,
    .tint = ...,
});
frame.endPass(render_pass);                                 // sort, batch, encode
try frame.end();                                            // submit, present, pace
```

Key decisions, in order of precedence:

1. **Immediate mode.** A frame is a pure function of the calls submitted that
   frame. No scene graph, no retained draw handles.
2. **Passes are explicit but thin.** `beginPass`/`endPass` expose structure
   (targets, camera, lights), never plumbing (pipelines, bind groups,
   encoders). Draws queue and are encoded only at `endPass`, so the renderer
   may expand one declared pass into several GPU passes if a helper needs to.
   Frame ≈ encoder, pass ≈ render pass: the API maps honestly onto WebGPU.
3. **Materials are app-defined, not hard-coded.** A material is a reflected
   shader module plus a comptime-checked binding struct. The renderer has no
   built-in look; it ships example WGSL, but any shader honoring the contract
   (below) works.
4. **Meshes are plain CPU data.** `Mesh` = vertex bytes + named attribute
   layout + topology + optional indices. `PrimitiveMeshes` is a namespace of
   constants (cube, quad, ...); loaded models produce the same type. No
   registration: the renderer uploads and caches GPU buffers on first draw,
   keyed on mesh identity (data pointer; `id` field as escape hatch).
5. **No manual camera math in the app.** `Renderer.Camera` is a value type
   (pos, yaw, pitch, projection: perspective or orthographic, fov/near/far,
   `forward()`/`right()` helpers). The app mutates it; `setCamera` snapshots
   it. Multi-view = more passes with different cameras.

## Renderer ⇄ shader contract

The renderer fills in what the app never passes, negotiated per shader through
reflection at comptime — declared names are filled, undeclared names are
skipped, wrong shapes are compile errors:

- **Reserved draw-param fields** (renderer-computed): `position`, `rotation`,
  later `scale` → folded into the model matrix written to the shader's
  per-instance `model` field. All other draw-param fields are forwarded to the
  shader's instance struct by name (`tint`).
- **Frame globals**: a `world` uniform with `vp_matrix` and folded light values
  (`light_dir`, `ambient`), written per pass at flush time.
- **Optional extensions** (e.g. shadows): `shadow_map`, `shadow_smp`,
  `light_vp` — filled only if declared.

No lights submitted ⇒ ambient-only black: forgetting the light call looks
obviously dark, not mysteriously broken.

## Core: three general structures, no feature subsystems

Transparency, depth variants, MSAA, topology, wireframe, additive particles —
none of these get dedicated code. They fall out of giving three core structures
their full general shape from day one (retrofitting the narrow versions is the
expensive path):

1. **Pipeline cache** keyed on the complete truth of what a pipeline is:
   `(shader, vertex layout, pass-target formats + sample count, RenderState)`.
   `RenderState` = blend, depth test/write, cull, topology; carried by
   material (topology by mesh). Every "variant" is a cache miss, not a feature.
2. **Sort-key batcher.** The draw queue is `(sort key, draw record)`; flush =
   sort, then instance-batch consecutive runs of identical (mesh, material).
   Opaque key = (pipeline, material, mesh) → grouping + minimal state changes.
   Transparent key = (transparent bit, back-to-front depth). One code path;
   the renderer never contains the word "transparent" outside key computation.
3. **Transient target cache**: renderer-owned textures keyed on
   (size, format, samples) — the window depth buffer, MSAA color + resolve.
   MSAA's only explicit code is intermediate allocation + resolve at pass end.

Plus two init-time conveniences: a 1×1 white default texture (tint-only
materials work) and an error-magenta fallback material (shader failure renders
loudly instead of crashing).

## Primitives the core must expose (each general, none technique-specific)

- Off-screen pass targets: `.color_target = .none | <texture>`,
  `.depth_target = <texture>`; sampling a target rendered by an earlier pass.
- Orthographic camera projection.
- Comparison samplers as a material binding option.
- Per-frame settable material uniforms: `material.set(.name, value)`.
- Mesh topology (triangles, lines).
- Pass `samples` option (MSAA).

Shadow mapping was the litmus test: with these six, the app (or a shipped
helper) builds it entirely from outside — app-owned depth texture, ortho sun
camera, depth-only material, two passes. The core never knows shadows exist.

## Helpers to ship (written against the public API, never inside the core)

Priority order for prototyping value:

1. **Debug draw**: `debug.line/wireCube/axes/sphere`, depth-tested or on-top.
2. **Text overlay**: baked bitmap font, `debug.text(pos, fmt, args)`.
3. **WGSL hot reload** (dev-only): watch files, rebuild pipelines, fall back
   to error-magenta on compile failure. Reloads shader *bodies* only —
   interface changes require recompile (reflection is comptime).
4. **Shadow map helper**: owns map texture + sun camera + the double-submit
   loop; one-line ergonomics, built on the six primitives.
5. **Sprites / 2D pass** (ortho + quads + transparency).
6. **Skybox** (cube + depth-equal trick).
7. **Fullscreen post pass** (fullscreen triangle + material) — with off-screen
   targets this unlocks tonemapping/vignette/fades.
8. **Screenshot readback** (gpu-layer utility).

Outside the library entirely: model loading (glTF → `Mesh` + textures) is a
separate loader module; the CPU-data mesh design is the seam.

## What finished looks like

- `main.zig` as written compiles and runs on native and web: three tinted
  checkered cubes, fly camera, directional + ambient light, resize works.
- The six core primitives exist and the shadow helper proves them.
- Debug draw + text overlay ship.
- Adding a new shader = write WGSL + `renderer.material(...)`; adding a new
  look (wireframe, additive, no-depth) = a `RenderState` field; neither ever
  touches renderer internals.
