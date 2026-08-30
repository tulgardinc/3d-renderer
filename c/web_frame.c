// The browser's frame clock. Web-only: build.zig compiles it into the app only
// for the emscripten target, so it needs no #ifdef of its own.
//
// Native pacing comes from the swapchain -- the surface is configured FIFO, so
// wgpuSurfaceGetCurrentTexture blocks until the display hands back an image,
// once per refresh. The browser has no swapchain to block on, and its canvas is
// only composited while we are unwound, so requestAnimationFrame is both the
// pace and the yield.
//
// EM_ASYNC_JS wraps the body in Asyncify.handleAsync and names the wasm import
// __asyncjs__<name>. emscripten's DEFAULT_ASYNCIFY_IMPORTS is `__asyncjs__*`,
// so the unwind point registers itself with no extra -s flag.
//
// The parameter list is stringified verbatim into the generated JS signature,
// so it has to be `()` -- `(void)` would declare a JS parameter named `void`.
#include <emscripten.h>

EM_ASYNC_JS(void, js_await_animation_frame, (), {
  await new Promise(resolve => requestAnimationFrame(resolve));
});

// Zig calls this wrapper rather than the EM_ASYNC_JS function directly, for two
// reasons. The EM_ASYNC_JS function is a wasm *import* named
// `__asyncjs__js_await_animation_frame`, so a Zig `extern fn` of the C name asks
// the linker for an import called `z_await_animation_frame` instead -- wasm-ld
// rejects that pair as an "import name mismatch". And EM_JS on its own defines
// no symbol at all (the body lives in an `em_js` data section emcc scans at link
// time), so nothing would pull this translation unit out of the static archive
// and the section would never be seen. An ordinary defined function fixes both.
void z_await_animation_frame(void) {
  js_await_animation_frame();
}
