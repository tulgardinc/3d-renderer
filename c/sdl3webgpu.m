/**
 * This is an extension of SDL3 for WebGPU, abstracting away the details of
 * OS-specific operations.
 *
 * This file is part of the "Learn WebGPU for C++" book.
 *   https://eliemichel.github.io/LearnWebGPU
 *
 * Most of this code comes from the wgpu-native triangle example:
 *   https://github.com/gfx-rs/wgpu-native/blob/master/examples/triangle/main.c
 *
 * MIT License
 * Copyright (c) 2022-2024 Elie Michel and the wgpu-native authors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "sdl3webgpu.h"

#include <webgpu/webgpu.h>

#if defined(SDL_PLATFORM_MACOS)
#include <Cocoa/Cocoa.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/CAMetalLayer.h>
#elif defined(SDL_PLATFORM_IOS)
// Just CAMetalLayer -- SDL owns the view. Deliberately NOT <Metal/Metal.h>:
// the iOS 26 SDK's Metal headers use post-14 types unguarded and clang
// promotes that to an error at this deployment target.
#include <Foundation/Foundation.h>
#include <QuartzCore/CAMetalLayer.h>
#elif defined(SDL_PLATFORM_WIN32)
#include <windows.h>
#endif

#include <SDL3/SDL.h>

WGPUSurface SDL_GetWGPUSurface(WGPUInstance instance, SDL_Window *window) {
  SDL_PropertiesID props = SDL_GetWindowProperties(window);

#if defined(SDL_PLATFORM_MACOS)
  {
    id metal_layer = NULL;
    NSWindow *ns_window = (__bridge NSWindow *)SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!ns_window)
      return NULL;
    [ns_window.contentView setWantsLayer:YES];
    metal_layer = [CAMetalLayer layer];
    [ns_window.contentView setLayer:metal_layer];

    WGPUSurfaceSourceMetalLayer fromMetalLayer;
    fromMetalLayer.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
    fromMetalLayer.chain.next = NULL;
    fromMetalLayer.layer = metal_layer;

    WGPUSurfaceDescriptor surfaceDescriptor;
    surfaceDescriptor.nextInChain = &fromMetalLayer.chain;
    surfaceDescriptor.label = (WGPUStringView){NULL, WGPU_STRLEN};

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  }
#elif defined(SDL_PLATFORM_IOS)
  {
    // Upstream hand-rolled a CAMetalLayer sublayer here (with a typo that
    // means this branch never compiled, and a point-sized drawableSize).
    // SDL's own Metal view sizes the layer in pixels, sets contentsScale,
    // and tracks rotation/resize -- so let it own the layer instead.
    (void)props;
    SDL_MetalView view = SDL_Metal_CreateView(window);
    if (!view)
      return NULL;
    CAMetalLayer *metal_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(view);
    if (!metal_layer)
      return NULL;

    WGPUSurfaceSourceMetalLayer fromMetalLayer;
    fromMetalLayer.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
    fromMetalLayer.chain.next = NULL;
    fromMetalLayer.layer = metal_layer;

    WGPUSurfaceDescriptor surfaceDescriptor;
    surfaceDescriptor.nextInChain = &fromMetalLayer.chain;
    surfaceDescriptor.label = (WGPUStringView){NULL, WGPU_STRLEN};

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  }
#elif defined(SDL_PLATFORM_LINUX)
  if (SDL_strcmp(SDL_GetCurrentVideoDriver(), "x11") == 0) {
    void *x11_display = SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    uint64_t x11_window =
        SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (!x11_display || !x11_window)
      return NULL;

    WGPUSurfaceSourceXlibWindow fromXlibWindow;
    fromXlibWindow.chain.sType = WGPUSType_SurfaceSourceXlibWindow;
    fromXlibWindow.chain.next = NULL;
    fromXlibWindow.display = x11_display;
    fromXlibWindow.window = x11_window;

    WGPUSurfaceDescriptor surfaceDescriptor;
    surfaceDescriptor.nextInChain = &fromXlibWindow.chain;
    surfaceDescriptor.label = (WGPUStringView){NULL, WGPU_STRLEN};

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  } else if (SDL_strcmp(SDL_GetCurrentVideoDriver(), "wayland") == 0) {
    void *wayland_display = SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    void *wayland_surface = SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    if (!wayland_display || !wayland_surface)
      return NULL;

    WGPUSurfaceSourceWaylandSurface fromWaylandSurface;
    fromWaylandSurface.chain.sType = WGPUSType_SurfaceSourceWaylandSurface;
    fromWaylandSurface.chain.next = NULL;
    fromWaylandSurface.display = SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    fromWaylandSurface.surface = wayland_surface;

    WGPUSurfaceDescriptor surfaceDescriptor;
    surfaceDescriptor.nextInChain = &fromWaylandSurface.chain;
    surfaceDescriptor.label = (WGPUStringView){NULL, WGPU_STRLEN};

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  }
#elif defined(SDL_PLATFORM_WIN32)
  {
    HWND hwnd = (HWND)SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!hwnd)
      return NULL;
    HINSTANCE hinstance = GetModuleHandle(NULL);

    WGPUSurfaceSourceWindowsHWND fromWindowsHWND;
    fromWindowsHWND.chain.sType = WGPUSType_SurfaceSourceWindowsHWND;
    fromWindowsHWND.chain.next = NULL;
    fromWindowsHWND.hinstance = hinstance;
    fromWindowsHWND.hwnd = hwnd;

    WGPUSurfaceDescriptor surfaceDescriptor;
    surfaceDescriptor.nextInChain = &fromWindowsHWND.chain;
    surfaceDescriptor.label = (WGPUStringView){NULL, WGPU_STRLEN};

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  }
#elif defined(__EMSCRIPTEN__)
  {
    // Upstream's version of this branch predates the current webgpu.h, where
    // `selector` is a WGPUStringView rather than a const char* and the legacy
    // WGPUSurfaceDescriptorFromCanvasHTMLSelector no longer exists. "#canvas"
    // is the CSS selector for the canvas SDL's emscripten backend renders into.
    (void)window;

    WGPUEmscriptenSurfaceSourceCanvasHTMLSelector fromCanvasHTMLSelector =
        WGPU_EMSCRIPTEN_SURFACE_SOURCE_CANVAS_HTML_SELECTOR_INIT;
    fromCanvasHTMLSelector.selector = (WGPUStringView){"#canvas", WGPU_STRLEN};

    WGPUSurfaceDescriptor surfaceDescriptor = WGPU_SURFACE_DESCRIPTOR_INIT;
    surfaceDescriptor.nextInChain = &fromCanvasHTMLSelector.chain;

    return wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
  }
#else
#error "Unsupported WGPU_TARGET"
#endif
}
