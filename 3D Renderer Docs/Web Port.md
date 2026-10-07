# Web Port

The renderer runs in a browser. Validated 2026-08-30 on branch
`web-asyncify-spike` (headless Chrome over CDP: three distinct frames, no
exceptions). Not merged; the spike is the proof, not the shipping path.

## The load-bearing finding

**emscripten's `emdawnwebgpu` port is API-compatible with the in-tree native
Dawn headers.** Every `WGPU_*_INIT` macro `c/wgpu_init_shim.c` uses and every
`wgpu*` function gpu.zig calls exists in the port's header. Only 13
Dawn-native-only *enum constants* are missing (multiplanar video formats,
storage attachment, `LoadOp_ExpandResolveTexture`) — none reachable in a
browser.

So no WebGPU API rewrite is needed for web. The port is a platform/toolchain
problem, not an abstraction problem — [[Architecture]]'s layering holds as-is,
with `is_web` re-exported by renderer.zig as the only switch.

## Build rules

- The web build must use the **port's** `webgpu.h`, not the in-tree one. They
  are different Dawn vintages; mixing them desyncs struct layouts between Zig
  and the C shims (`c/wgpu_init_shim.c`, `c/web_frame.c`).
- gpu.zig's extern `z_*_INIT` C helpers exist for exactly this: descriptor
  defaults come from whichever header the target compiled against
  ([[GPU Layer]]).

## Runtime rules

- **Never block.** Asyncify's `emscripten_sleep` yields to the browser;
  emdawnwebgpu's `wgpuSurfacePresent` is a hard abort — the browser presents
  on yield, there is no explicit present on web.
- Asyncify is the cheap path. The honest fix is still restructuring init +
  loop into callbacks so the platform owns the loop (`web/shell.html` is the
  host page).

## Zig 0.16 on `wasm32-emscripten`

Toolchain landmines hit building the spike (Zig 0.16.0):

- `std.Io.Threaded` fails to compile on emscripten, and it is `std.debug`'s
  default stderr io. So `std.debug.print`, `std.log`'s default `logFn`, and
  `std.debug.simple_panic` all break the build. Fix: root decls
  `pub const std_options: std.Options = .{ .logFn = myLog }` and
  `pub const panic = std.debug.FullPanic(myPanic)`, both routed to
  `extern fn emscripten_console_error`.
- An error-union `main` also breaks it (`std.start` calls
  `dumpErrorReturnTrace`). Use
  `pub fn main() if (is_web) void else anyerror!void` and catch inside on web.
- `std.start` already exports the entry point for an emscripten static lib
  (`__main_argc_argv` when `link_libc` and root has `main`) — do NOT
  hand-export a C `main`.
- `usize` is 32-bit: WebGPU calls taking `size_t` (e.g.
  `wgpuQueueWriteBuffer`'s size) need `@intCast` from u64 arithmetic that
  compiles fine natively.

## Definition of done

Per [[Helpers]]: spec main.zig compiles and runs native **and** web with the
same source — three tinted checkered cubes, fly camera, lights, resize.
