const std = @import("std");
const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("SDL3/SDL.h");
    @cInclude("sdl3webgpu.h");
});

const AdapterRequest = struct {
    done: bool,
    adapter: c.WGPUAdapter,
};

fn onAdapterRequest(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: [*]const u8,
    userdata: *void,
) void {
    var req_ptr: *AdapterRequest = @ptrCast(userdata);
    _ = message;
    if (status == c.WGPURequestAdapterStatus_Success) {
        req_ptr.adapter = adapter;
        req_ptr.done = true;
    }
}

const DeviceRequest = struct { done: bool, device: c.WGPUDevice };

fn onDeviceRequest(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: [*]const u8,
    userdata: *void,
) void {
    _ = message;

    var req_ptr: *DeviceRequest = @ptrCast(userdata);
    _ = message;
    if (status == c.WGPURequestDeviceStatus_Success) {
        req_ptr.device = device;
        req_ptr.done = true;
    }
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_Quit();

    const win_ptr = c.SDL_CreateWindow(
        "Test Window",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    defer c.SDL_DestroyWindow(win_ptr);

    var width: i32 = 0;
    var height: i32 = 0;
    _ = c.SDL_GetWindowSizeInPixels(win_ptr, &width, &height);

    if (win_ptr == null) {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }

    const instDesc = c.WGPUInstanceDescriptor{};
    const instance_ptr = c.wgpuCreateInstance(&instDesc);

    const surface_ptr = c.SDL_GetWGPUSurface(instance_ptr, win_ptr);

    var adapterOptions = c.WGPURequestAdapterOptions{};
    adapterOptions.compatibleSurface = surface_ptr;
    c.wgpuInstanceRequestAdapter(instance_ptr, &adapterOptions, onAdapterRequest);

    var running = true;
    while (running) {
        var e: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&e)) {
            if (e.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        c.SDL_Delay(10);
    }
}
