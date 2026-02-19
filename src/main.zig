const std = @import("std");
pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("SDL3/SDL.h");
    @cInclude("sdl3webgpu.h");
});

const wgpu = @import("wgpu.zig");

pub fn main() !void {
    // Initialize SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "WebGPU Clear Color",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    if (window == null) {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_DestroyWindow(window);

    // Get window size
    var width: i32 = 0;
    var height: i32 = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);

    const instance = try wgpu.getInstance();
    defer c.wgpuInstanceRelease(instance);

    const surface = c.SDL_GetWGPUSurface(instance, window);
    defer c.wgpuSurfaceRelease(surface);

    const adapter = try wgpu.requestAdapterSync(instance, surface);
    defer c.wgpuAdapterRelease(adapter);
    const device = try wgpu.requestDeviceSync(instance, adapter);
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device);
    defer c.wgpuQueueRelease(queue);

    // surface config (abstract this)
    var config = wgpu.z_WGPU_SURFACE_CONFIGURATION_INIT();
    config.width = @intCast(width);
    config.height = @intCast(height);
    config.device = device;
    var surface_capabilities = wgpu.z_WGPU_SURFACE_CAPABILITIES_INIT();
    _ = c.wgpuSurfaceGetCapabilities(surface, adapter, &surface_capabilities);
    config.format = surface_capabilities.formats[0];
    c.wgpuSurfaceCapabilitiesFreeMembers(surface_capabilities);
    config.presentMode = c.WGPUPresentMode_Fifo;
    config.alphaMode = c.WGPUCompositeAlphaMode_Auto;

    // configure the surface
    c.wgpuSurfaceConfigure(surface, &config);

    // Main loop
    var running = true;
    while (running) {
        // Handle events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        const encoder = wgpu.getEncoder(device);
        defer c.wgpuCommandEncoderRelease(encoder);

        // get the texture view
        const target_view = try wgpu.getNextSurfaceView(surface);
        defer c.wgpuTextureViewRelease(target_view);

        // render pass
        // abstract this
        var render_pass_desc = wgpu.z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();

        // color attachement
        var color_attachment = wgpu.z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
        color_attachment.loadOp = c.WGPULoadOp_Clear;
        color_attachment.storeOp = c.WGPUStoreOp_Store;
        color_attachment.clearValue = c.WGPUColor{ .a = 1.0, .r = 0.8, .g = 0.0, .b = 1.0 };
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;
        color_attachment.view = target_view;

        const render_pass_encoder = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
        defer c.wgpuRenderPassEncoderRelease(render_pass_encoder);

        c.wgpuRenderPassEncoderEnd(render_pass_encoder);

        const command_buffer = wgpu.getCommandBuffer(encoder);
        wgpu.submitCommand(queue, &.{command_buffer});

        _ = c.wgpuSurfacePresent(surface);

        std.Thread.sleep(1_000_000);
    }
}
