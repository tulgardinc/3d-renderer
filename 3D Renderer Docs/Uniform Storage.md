# Uniform Storage

Explainer for the two uniform arenas ([[Renderer Machinery]] pieces 5 and 7).
Both suballocate from pooled buffers, but for *different reasons* and with
*different growth rules*, and conflating them is the easy mistake. Group 0's
pool is forced by a correctness bug; group 1's is an optimization.

## The rule that starts all of this

`queue.writeBuffer` is a **queue-timeline** operation — the same timeline as
`submit`, executed in issue order. The frame is one encoder, all passes encoded
into it, one submit at the end. Therefore **every `writeBuffer` issued that
frame executes before *any* pass runs.** Encoding a pass is not executing it.

### The failure this causes

Shadow pass and main pass both bind group 0; both want a `world`-shaped uniform
differing in the view-projection matrix (light's vs. camera's). The natural
implementation — one `world` uniform in the shader, therefore one buffer:

```
writeBuffer(world_buf, 0, light_view)    // for the shadow pass
encode shadow pass
writeBuffer(world_buf, 0, camera_view)   // for the main pass
encode main pass
submit
```

Both writes land before submit. `world_buf` holds `camera_view`. **The shadow
pass renders the shadow map from the camera.** No validation error — nothing in
the API is misused — just a wrong image. This is the two-pass configuration in
old main.zig, not a hypothetical.

### What actually fixes it

**Disjoint ranges.** Pass A's data and pass B's must occupy different memory at
submit time. Nothing less works; nothing more is needed. So `pass.set("world",
x)` cannot mean "write to the world buffer" — it means *allocate a fresh slot,
write there, record the offset for encode*.

The rule that covers every case, including two `set` calls inside one pass:
**each `set` allocates a slot; each queued draw records the slot current when
it was issued.** Pass boundaries stop being special — a pass is just a place
where `set` happens to get called. Slot count is therefore ≥ pass count, and
draws carry their offsets rather than reading whatever is current at encode.

## Why the fix takes the shape of a pool

Disjoint ranges have two implementations:

1. **A buffer per (pass, uniform).** Correct, but a bind group is immutable and
   names concrete buffers, so a new buffer means a new bind group — bind group
   creation proportional to pass count, every frame.
2. **One pooled buffer, 256-aligned slots, `hasDynamicOffset: true`.** One bind
   group created once; the offset moves to `setBindGroup`'s dynamic-offset
   array, a per-call argument.

(2) wins because the offset is the *only* thing varying per pass, and dynamic
offsets are precisely the mechanism for varying an offset without touching the
bind group. The pool also makes the fix structural: with a bump allocator that
resets per frame, reuse isn't expressible.

## The two arenas side by side

Both are pools. They differ in where the offset lives and how they grow.

|                     | Group 0 (pass uniforms)          | Group 1 (material uniforms)        |
| ------------------- | -------------------------------- | ---------------------------------- |
| Driver              | **correctness** (aliasing bug)   | optimization                       |
| Data lifetime       | rewritten every frame            | written once at creation           |
| Offset lives in     | dynamic-offset array at bind     | `BindGroupEntry.offset`, baked in  |
| Cost per bind       | marshal an offsets array         | nothing                            |
| Fan-in (bind groups naming it) | 1                     | N (one per material)               |
| Safe rebuild point  | `beginFrame`                     | none                               |
| Growth              | **reallocate** bigger            | **append** another chunk           |
| Reset               | cursor resets at `beginFrame`    | never; free list on destroy        |

Alignment is 256 in both — `minUniformBufferOffsetAlignment` applies to the
static `offset` in a bind group entry exactly as it does to a dynamic one.

## Why group 1 does not use dynamic offsets

Dynamic offsets exist to let **one** bind group serve **many** values over
time. Material uniforms are written once at `material()` and never again —
there is no "over time". Baking the offset into the immutable bind group is
strictly better: same layout, no per-draw marshalling, and the bind group stays
a pure constant that MaterialID can key on.

The tempting bigger version — one group-1 bind group for everything, material
switch becomes an offset change — fails on three counts:

- **Textures and samplers have no dynamic-offset equivalent.** A bind group
  naming texture X is a different object from one naming Y. `Mesh.wgsl` group 1
  is texture + sampler and *zero* uniforms. Since distinct textures are roughly
  what makes materials distinct, you end up with one bind group per material
  anyway, plus offset marshalling. Net loss.
- **No aliasing to avoid.** Two materials aren't one value at different times;
  they're different values, permanently.
- **It un-bakes work.** Baked offsets mean encode does `setBindGroup(1, group)`.
  Dynamic offsets mean every batch carries N offsets and encode marshals an
  array per material switch.

The case where engines *do* use it: uniform-only parameter blocks sharing a
texture set (Unreal-style material instances off a common parent). The general
version is bindless — material params in one storage buffer, indexed by a
`material_index` in the instance stream, textures via a texture array + layer.
That erases group 1 entirely and is one small step from the instance stream
already in place. Blocked on WebGPU having no `binding_array`, so it belongs in
[[Scaling and Baking]], not the core.

## Why group 1 cannot reallocate

The operative property is **fan-in plus the absence of a rebuild point**, not
"materials are static" — staticness is what *produces* that shape.

Group 0's pool is named by exactly one bind group, owned by the renderer, and
`beginFrame` is a moment when nothing is encoded and rebuilding is free.
Group 1's chunk is named by every material bind group ever built from it, and
the growth trigger is `material()`, which the app calls at arbitrary times.

Reallocating group 1 is *possible*, not impossible — the registry holds every
record. The costs:

- Each record would have to retain its full `WGPUBindGroupEntry` array — every
  texture view, sampler, app-owned storage buffer — permanently, solely so a
  rebuild is possible. Today the record drops all that once the group exists.
- Fixed-size chunks + reallocation is **O(N²)** total rebuild work (rebuild at
  256, again at 512, again at 768…). Avoiding that needs *doubling*, which is
  amortized O(1) but always up to 2× oversized with ever-bigger cliffs. Append
  is O(1) worst case at every N, no amortization argument needed.
- A bind group costs low single-digit microseconds (validation +
  `vkAllocateDescriptorSets`/descriptor copy + refcount per resource). 256 of
  them is a sub-millisecond hitch; 10k is a hard stall. It lands on whichever
  `material()` call overflows — a cliff, not a gradient.

**And the payoff is zero**: slots are fixed-size-class and never move, so a
bigger buffer would have the identical layout with the identical holes.
Reallocation normally buys contiguity or defrag; here it buys neither. That is
what makes the append-only constraint *free* to accept, and free constraints
are the ones worth taking — it is what keeps MaterialID a permanently valid
cache key for the sort.

Not a cost: mid-frame invalidation. `DrawCmd` holds a MaterialID, not a bind
group pointer, and resolves through the registry at encode. A rebuild before
encoding would be safe by construction.

## What "chunked" concretely means

Not one buffer per material. A **short list** of buffers, each shared by many
materials:

```
world_pool: WGPUBuffer (grown by reallocation)
  [0..256)    pass A's world     <- dynamic offset 0
  [256..512)  pass B's world     <- dynamic offset 256

chunks: ArrayList(WGPUBuffer)
  chunks[0] (64KB)
    [0..256)     material 0     <- BindGroupEntry{buffer: chunks[0], offset: 0,   size: 144}
    [256..512)   material 1     <- BindGroupEntry{buffer: chunks[0], offset: 256, size: 144}
    ...
    [65280..)    material 255
  chunks[1] (64KB)              <- allocated only when chunk 0 filled
    [0..256)     material 256
```

- **Chunks are separate `WGPUBuffer` objects with no address relationship.**
  "Appending a chunk" means appending to a list, not to memory. There is no
  WGSL or WebGPU primitive involved.
- **A chunk is created at full size and never resized** — WebGPU buffers cannot
  be resized at all, so "expand" is not an operation. A chunk holding one
  material is still 64KB.
- **Appending a chunk invalidates nothing.** Material 5's bind group names
  `chunks[0]` forever. Even the `ArrayList` growing reallocates the host-side
  array of *handles*; the buffers those handles point at don't move.
- **64KB matches `maxUniformBufferBindingSize`**, so no legal uniform block can
  straddle a chunk. Allocation never handles a spanning case: if the current
  chunk can't fit, start a new one and waste the tail.
- **Waste is bounded by one partially-filled chunk at any N** — every chunk but
  the newest is full. O(1), not O(N). Caveat that would break it: segregating
  chunks *by size class* gives one tail per class. Avoid — bump-allocate mixed
  sizes into a single chunk stream and key the free list by slot count. Since
  everything is 256-aligned, blocks collapse into a handful of slot sizes and a
  freed 2-slot hole serves anything needing ≤2 slots.
- **Nothing about this is shader-visible.** The shader sees
  `@group(1) @binding(0) var<uniform> params: Params;` and cannot tell whether
  the buffer is 144 dedicated bytes or bytes 512..656 of a 64KB slab —
  `BindGroupEntry.offset`/`size` window it down first. Chunking is CPU-side
  bookkeeping only.

## Chunked vs. one buffer per material

The rejected alternative. Both create exactly one bind group per material,
once, never rebuilt — bind group cost is *identical* and is not part of this
decision.

|                      | 1 buffer/material               | Chunked                     |
| -------------------- | ------------------------------- | --------------------------- |
| Bind groups          | N, created once                 | N, created once             |
| Bind group rebuilds  | never                           | never                       |
| `WGPUBuffer` objects | N                               | ⌈N / slots-per-chunk⌉       |
| Per-material create  | `createBuffer` + `writeBuffer`  | `writeBuffer` + cursor bump |
| Free                 | release buffer                  | slot → free list            |

What actually differs:

- **Buffer object count comes off the material count.** Each `WGPUBuffer` is a
  Dawn wrapper + backend resource + validation-tracking entry.
- **`createBuffer` per material disappears** — the expensive half of the pair.
  This is banked immediately, even creating materials one at a time.
- **Write coalescing is latent, not realized.** It only pays if creation is
  ever batched (a load creating 1000 at once, or deferring writes to end of
  frame). One at a time, each still does its own `writeBuffer`. Chunking
  *enables* the coalesced path; it doesn't deliver it today.
- **Memory is a wash** — 144 bytes in a 256-byte slot vs. a 144-byte buffer the
  backend rounds up anyway. Only per-object host overhead differs.
- **Cost of chunking**: a chunk list, a bump cursor, a size-class free list.

A cheap structural win, not a dramatic one. Shipping one-buffer-per-material
first stays non-breaking **only** because the record carries `offset` from day
one — see the constraint in [[Renderer Machinery]] piece 7.

## What is synchronous at material creation

The bind group does **not** depend on the write. A bind group naming bytes
512..656 of `chunks[0]` is valid whether or not those bytes hold anything —
it depends on the *slot*, not the contents.

- **Synchronous in `material()`**: bump the cursor → `{chunk, offset, size}`
  (creating a chunk if the current one is full); create the bind group naming
  that range; return a fully valid MaterialID.
- **Deferrable**: only the `writeBuffer`. It is a queue-timeline op, legal at
  any time, no encoder involved — so it can equally well be immediate.

A deferred-write queue is therefore a **pure optimization**, never structural.
If added: a CPU-side mirror of the chunk bytes (`ArrayList(u8)` per chunk) plus
a dirty range, flushed as one `writeBuffer` per dirty chunk over `min..max`.
Two constraints:

- **Flush before encoding, not at `beginFrame`.** A material created mid-frame
  and drawn that same frame would miss a `beginFrame` flush and read garbage.
  Flushing at the top of encode covers every case without reasoning about when
  creation happened.
- The mirror must match chunk layout exactly, alignment padding included —
  contiguity is the entire point. Two back-to-back creations land at 512 and
  768 and flush as one 512..1024 write, padding riding along free.

**Current call: write immediately, no queue.** The `createBuffer` saving is
already banked by chunking itself; coalescing only pays on bursts, and it can
be added later without touching a call site because the slot is assigned
synchronously either way.

## Is any of this conventional

Yes — this is the paved road, arrived at from the correctness side rather than
the usual performance side.

- **Bump allocator + dynamic offsets** is Bevy's `DynamicUniformBuffer<T>`:
  `push()` returns an offset, stored as a `ViewUniformOffset` and supplied at
  `set_bind_group`. Its `ViewUniforms` is exactly group 0 here. Same API
  (wgpu), same constraint, same conclusion, arrived at independently.
- Vulkan has `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC` for precisely this —
  a descriptor set outliving the offsets it reads at. WebGPU's
  `hasDynamicOffset` is a direct port.
- **Per-view pooled buffers** is Unreal (`FViewUniformShaderParameters`,
  allocated fresh per view per frame from a recycling pool). Equally correct;
  trades a bump allocator for a buffer pool plus a bind-group pool.
- **Record-the-mutation-and-replay** is bgfx: uniform sets go into a CPU
  command stream interleaved with draws, replayed in sorted order. **Closed to
  us** — it needs writes ordered against draws, and `queue.writeBuffer` is on
  the wrong timeline. The command-timeline equivalent,
  `encoder.copyBufferToBuffer`, cannot be called inside a render pass, so
  replay works at pass granularity and not at draw granularity.
- **Render graph** (Frostbite FrameGraph, Unreal RDG) makes the problem
  *evaporate* rather than solving it: passes are declared before resources are
  allocated, so there is no "set called twice on a live pass". This is the one
  genuine structural alternative, and it is the one [[Architecture]] rejects —
  a graph is a declarative API and the premise here is immediate mode.

Deferred encoding itself is **not** exotic; building a draw list, sorting, and
encoding at the end is what serious engines do. Immediate encoding is the
simple case, not the sophisticated one. What deferral costs is exactly one
thing: a draw must carry its offsets instead of inheriting whatever is current
at encode time.
