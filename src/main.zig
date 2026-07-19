const std = @import("std");
const gpu = @import("gpu.zig");
const gs = @import("gpu-system.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");
const c = gpu.c;
const Renderer = @import("renderer.zig");
const Shader = @import("shaders/compiled/2DVertexColors.zig");

const vertices = [_]f32{
    // x     y       r    g    b
    0.0, 0.5, 1.0, 0.0, 0.0, // top    - red
    -0.5, -0.5, 0.0, 1.0, 0.0, // left   - green
    0.5, -0.5, 0.0, 0.0, 1.0, // right  - blue
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.smp_allocator,
    };

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    const instance = try gpu.GPUInstance.init();
    const surface = c.SDL_GetWGPUSurface(instance.webgpu_instance, window);

    const gpu_context = try gpu.GPUContext.initSync(io, instance.webgpu_instance, surface);
    var target_surface = gpu.Surface.init(gpu_context, surface);
    target_surface.configure(gpu_context, @intCast(width), @intCast(height));

    var bind_group = try gpu.BindGroup(Shader, 0).init(allocator, gpu_context, .{});
    defer bind_group.deinit();

    bind_group.set_uniform(gpu_context, .time, 0);

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&vertices),
        "vertex buffer",
        gpu.BufferUsage.vertex | gpu.BufferUsage.copy_dst,
    );

    const triangle_mesh: gpu.Mesh = .{
        .buffers = &.{vertex_buffer},
        .vertex_count = 3,
        .strides = &.{5 * @sizeOf(f32)},
        .attributes = &.{
            .{
                .semantic = .position,
                .format = .f32x2,
                .offset = 0,
                .buffer = 0,
            },
            .{
                .semantic = .color,
                .format = .f32x3,
                .offset = 2 * @sizeOf(f32),
                .buffer = 0,
            },
        },
    };

    const pipeline = try gpu.createPipelineFromMesh(
        Shader,
        allocator,
        gpu_context,
        triangle_mesh,
        &.{bind_group.layout},
        .{ .color_format = target_surface.format },
    );

    const start_time = std.Io.Clock.real.now(io).toMilliseconds();

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        const new_time = @as(f32, @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds() - start_time)) / 1000.0;
        bind_group.set_uniform(gpu_context, .time, new_time);

        const view = try gpu.getNextSurfaceView(surface); // stateless helper, keep it
        defer c.wgpuTextureViewRelease(view);

        var enc_desc = gpu.z_WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT();
        enc_desc.label = gpu.toWGPUString("frame encoder");
        const encoder = c.wgpuDeviceCreateCommandEncoder(gpu_context.device, &enc_desc);
        defer c.wgpuCommandEncoderRelease(encoder);

        var color = gpu.z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
        color.view = view;
        color.loadOp = c.WGPULoadOp_Clear;
        color.storeOp = c.WGPUStoreOp_Store;
        color.clearValue = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 };

        var rp_desc = gpu.z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();
        rp_desc.label = gpu.toWGPUString("main pass");
        rp_desc.colorAttachmentCount = 1;
        rp_desc.colorAttachments = &color; // &color must outlive BeginRenderPass (it copies) — fine, same scope

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp_desc);

        c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group.group, 0, null);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertex_buffer, 0, @sizeOf(@TypeOf(vertices)));
        c.wgpuRenderPassEncoderDraw(pass, vertices.len / 5, 1, 0, 0);

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        var cmd_desc = gpu.z_WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT();
        cmd_desc.label = gpu.toWGPUString("frame commands");
        const cmd = c.wgpuCommandEncoderFinish(encoder, &cmd_desc);
        c.wgpuQueueSubmit(gpu_context.queue, 1, &cmd);
        c.wgpuCommandBufferRelease(cmd);

        _ = c.wgpuSurfacePresent(surface);

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
