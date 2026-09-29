# 3d-renderer design

A WebGPU renderer in Zig for throwing game prototypes together fast. Exists to
kill the pipeline/shader/bind-group boilerplate that killed a previous
raw-WebGPU TS project. Native (Dawn) + web (emdawnwebgpu); windowing/input stay
in SDL.

**Sources of truth:** this vault is the design record; `src/main.zig` will be
the executable spec — written against the finished API, implemented until it
compiles. (`project.md` was deleted 2026-09-07 after drifting; its content
lives here, its history in git.) The *current* main.zig is still the old
raw-gpu program: proof of mechanics, not the spec.

## Map

- [[Architecture]] — layering, immediate mode, the five key decisions
- [[Shader Contract]] — the two-tier renderer ⇄ shader contract
- [[Instancing and Flush]] — storage-buffer pulling, sort keys, batching
- [[Renderer Machinery]] — ownership map: per-frame uploads, handles/IDs, registries, caches, generations
- [[Uniform Storage]] — the two uniform arenas: why group 0 pools for correctness and group 1 chunks
- [[Mesh Registry]] — app-declared vertex layouts, paged geometry pools with unload, classic fetch
- [[Materials and Draw Params]] — `material()`, `Material(S)`, `DrawParams` *(sketch)*
- [[Lighting and Shadows]] — lighting convention, `mirror`, pass-scoped data *(sketch, NOT locked)*
- [[Scaling and Baking]] — why immediate mode holds, the bake escape hatch
- [[Reflection Pipeline]] — tree-sitter WGSL → generated Zig → `gpu.Shader`
- [[GPU Layer]] — gpu.zig rules (fixed identity, erased bindings)
- [[Helpers]] — everything shipped outside the core
- [[Open Questions]] — undecided points, tracked

## Status (2026-09-13)

Mid-rewrite: renderer.zig is being rebuilt from scratch against the spec.
What current main.zig uses or ignores is **not** signal about a type's worth.
Lighting/mirror/pass-data API is in "sketch until locked" mode — no code
until it's locked.

Newly settled 2026-09-13 — **design only; the code is being written by hand**
(a throwaway reference implementation with GPU-free tests sits on branch
`claude/declared-layouts-pools`, not for merging): **vertex
layouts are declared by the app at startup** (built-in default shipped),
**geometry lives in fixed pages with a free list** so meshes can be unloaded,
and **vertex fetch is classic fixed-function** — the 2026-09-11 vertex-pulling
decision was reversed. Target workload driving this: a dense, streamed open
world, where the pipeline set must be closed (precompile, no compile at
stream-in) and residency must go down as well as up. [[Mesh Registry]] has
the design and the reversal rationale; piece 8 of [[Renderer Machinery]] is
revised; [[Reflection Pipeline]] is back to read-only.

Previously settled: the full ownership/machinery story ([[Renderer Machinery]],
2026-09-07); the two uniform arenas explainer ([[Uniform Storage]],
2026-09-08).

Next: implement piece 8 by hand — `declareLayout` + built-in default, the
paged pools with a free list, `mesh`/`unloadMesh` with the format conversion
(`VertexFormat.decode/encode` in gpu.zig) — then the flush against the
page-bound draw path ([[Instancing and Flush]]).

## Vault maintenance note (2026-09-11)

The vault's files were discovered misnamed — every file held a different doc's
content, shuffled across filenames — and two docs ([[Mesh Registry]] and
[[Materials and Draw Params]]) were lost entirely in the shuffle. Files were
restored to name-matches-content and the two lost docs rewritten from
cross-references and code. The vault is git-ignored, so if it matters, back it
up or un-ignore it.
