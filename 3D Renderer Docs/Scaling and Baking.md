# Scaling and Baking

Explored 2026-09-06: does immediate mode hold up for a mostly-static open
world at 160fps? Verdict: **yes, with an opt-in escape hatch** — kept out of
project.md except a pointer note (door-we're-keeping-open, not scheduled work).

## The real cost model

- Upload bandwidth is never the wall: a real scene is ~4–7 MB/frame. Trivial.
- The wall is **CPU work proportional to visible draws** — walk, matrix math,
  sort, instance fill, encode — re-paid every frame and **every view**
  (shadow cascades multiply it). ~95% recomputes unchanged results in a
  static world. Streaming assets per se is fine — assets are retained state.
- Retained scene graphs fix this via temporal coherence but cost lifetime
  bookkeeping in every app — the boilerplate disease this project cures.
- GPU-driven is not an alternative to retention; it's the **extreme form** of
  it (the scene must persist somewhere for the GPU to traverse). Ladder:
  immediate = CPU touches everything/frame → retained-CPU = O(changed) but CPU
  still walks+encodes → GPU-driven = scene GPU-resident, deltas only.

## The escape hatch: bake / drawList

- `renderer.bake(&draws)` sorts/batches/records **once** (WebGPU render
  bundles); `render_pass.drawList(chunk)` replays for near-zero CPU. Kills
  the per-view multiplier too (replay into main + cascades; needs a
  depth-only bundle variant per chunk).
- Baked lists and immediate draws mix freely in one pass — `endPass` already
  treats a pass as a list to splice.
- `bake` is the *explicit, opt-in* registration step the core deliberately
  lacks; frame stays a pure function of submitted calls (decision 1 intact).

## Graceful rungs (all inside the helper, core untouched)

1. Front-to-back chunk ordering (early-Z)
2. Depth prepass (kills overdraw)
3. CPU occlusion — PVS or software occluder boxes
4. HW occlusion queries per chunk (query sets; 1-frame latency)
5. **GPU-driven islands**: bake as geometry + instance buffer + indirect
   args; compute pass culls per object. Core WebGPU lacks
   multi-draw-indirect — portable version encodes fixed
   `drawIndexedIndirect` slots, compute zeroes culled ones.

Baking creates retained GPU-resident data — it **reopens the GPU-driven
door**. Only Nanite-class whole-scene cluster hierarchy is out of reach
(that's a different renderer). Rungs 1–3 historically suffice pre-Nanite.

What the core design provides for this (2026-09-13, [[Mesh Registry]]):
geometry lives in fixed pages that are never recreated, so a render bundle
can capture page buffers and stay valid; `drawIndexedIndirect` args carry
`baseVertex`/`firstIndex` into a page, so rung 5 needs only the indirect-args
buffer and the culling compute pass (which reads per-mesh bounds, never
vertices). Declared layouts keep the pipeline set closed, so a chunk streaming
in never triggers a compile before its bundle can be recorded.

**Residency for a streamed world**: a baked chunk owns the lifetime of its
geometry — `mesh()` on load, `unloadMesh()` on evict — and pages are the
residency unit. There is no global arena growth to copy or invalidate. What
bake adds on top is CPU-side: bundles, indirect args, per-chunk depth-only
variants.

Ceilings that stay: no bindless textures in WebGPU (a batch is one material)
and no multi-draw-indirect in core (one `drawIndexedIndirect` per slot, made
free by bundle replay). The frame-time wins come from bundles and indirect
replay, i.e. from *bake*; the vertex path neither helps nor hinders.

**Constraint on today's code:** stable cache identities — see
[[Instancing and Flush]].
