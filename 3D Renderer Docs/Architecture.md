# Architecture

```
app (main.zig)  →  renderer.zig  →  gpu.zig  →  WebGPU
```

- **gpu.zig** — typed, context-explicit helpers over raw WebGPU: buffers,
  textures, samplers, surface, comptime shader reflection interface. Usable
  standalone; no globals. See [[GPU Layer]].
- **renderer.zig** — the opinionated layer. Owns instance/device/queue/surface,
  resize, frame/pass structure, materials, primitive meshes. Re-exports `c` and
  `is_web`. Apps may still hit gpu.zig directly for raw resources.
- **app** — owns its camera, loop, assets; submits immediate-mode draws every
  frame.

## Key decisions (in order of precedence)

1. **Immediate mode.** A frame is a pure function of the calls submitted that
   frame. No scene graph, no retained draw handles. Retained state = assets
   only (textures, materials, meshes) + whatever the app keeps (camera).
   Validated against scaling in [[Scaling and Baking]].
2. **Passes are explicit but thin.** `beginFrame`/`beginPass`/`endPass` expose
   structure (targets, camera, lights), never plumbing (pipelines, bind
   groups, encoders). Draws **queue** and encode only at `endPass` — this
   queue-until-endPass property is load-bearing: it's what enables sorting,
   batching, [[Lighting and Shadows|mirror]], and future render bundles. The
   renderer may expand one declared pass into several GPU passes.
3. **Materials are app-defined, not hard-coded.** Material = reflected shader
   module + comptime-checked binding struct. The renderer has no built-in
   look. See [[Materials and Draw Params]].
4. **Meshes are plain CPU data — until registered.** Vertex bytes + named
   attribute layout + topology + optional indices; loaded models produce the
   same type (the loader seam). `renderer.mesh(data)` uploads once and
   returns a thin handle; `draw` takes the handle. *(Revised 2026-09-07 from
   "no registration step" — that rule overshot: the boilerplate disease was
   descriptor sync, not one-line register calls, and invisible pointer-keyed
   caching had fragile identity and no free story. See
   [[Renderer Machinery]].)* Registration converts the data into one of the
   app-declared vertex layouts (the renderer ships a default) and places it
   in that layout's paged pool; `unloadMesh` frees it — [[Mesh Registry]].
   Primitives come pre-registered from `init` (`renderer.primitives.cube`).
5. **No manual camera math in the app.** `Renderer.Camera` is a value type
   (pos, yaw, pitch, projection, fov/near/far, `forward()`/`right()`); the app
   mutates it, `setCamera` snapshots it. Multi-view = more passes.

## No feature subsystems

Transparency, MSAA, wireframe, additive particles, depth variants — never
features with dedicated code. They are compositions of general options:

- Materials carry `RenderState` (blend, depth test/write, cull).
- Meshes carry topology.
- Passes carry targets + sample count.
- Invisible intermediates (window depth, MSAA color) are the renderer's.

Plus two init-time conveniences: 1×1 white default texture, error-magenta
fallback material.

## API shape (target callsite — the shape spec-main.zig is written against)

```zig
var renderer = try Renderer.init(allocator, io, window);
const checker = try gpu.Texture.init(.{ ... });
const lit = try renderer.material(LitShader, .{ .texture = checker, .smp = .{ .filter = .nearest } });
const monster = try renderer.mesh(monster_data);           // explicit registration → thin handle
var cam = Renderer.Camera{ .pos = .init(0, 0, 3) };

// per frame:
const frame = try renderer.beginFrame();
const render_pass = frame.beginPass(.{ .clear_color = ... });
render_pass.setCamera(cam);
render_pass.light(.directional, .{ .direction = ... });   // convention sugar — see [[Lighting and Shadows]]
render_pass.draw(renderer.primitives.cube, lit, .{ .position = ..., .rotation = ..., .tint = ... });
frame.endPass(render_pass);
try frame.end();
```
