const std = @import("std");
const gpu = @import("gpu.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");
const c = gpu.c;
const Shader = @import("shaders/compiled/2DVertexColors.zig");

const vertices = [_]f32{
    // x     y       r    g    b
    0.0, 0.5, 1.0, 0.0, 0.0, //   top    - red
    -0.5, -0.5, 0.0, 1.0, 0.0, // left   - green
    0.5, -0.5, 0.0, 0.0, 1.0, //  right  - blue
};

pub fn main() !void {
    // TODO: Texture quad

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

    var bind_group = try gpu.ShaderBindGroup(Shader, 0).init(allocator, gpu_context, .{});
    defer bind_group.deinit();

    bind_group.set_uniform(gpu_context, .time, 0);

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&vertices),
        "vertex buffer",
        gpu.BufferUsage.vertex | gpu.BufferUsage.copy_dst,
    );

    const triangle_mesh: gpu.Mesh = .{
        .vertex_count = 3,
        .buffers = &.{
            .{
                .index = 0,
                .ptr = vertex_buffer,
                .stride = 5 * @sizeOf(f32),

                .attributes = &.{
                    .{
                        .semantic = .position,
                        .format = .f32x2,
                        .offset = 0,
                    },
                    .{
                        .semantic = .color,
                        .format = .f32x3,
                        .offset = 2 * @sizeOf(f32),
                    },
                },
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

    const draw_object: gpu.DrawObject = .{
        .bind_groups = &.{bind_group.group},
        .mesh = triangle_mesh,
        .pipeline = pipeline,
    };

    const start_time = std.Io.Clock.real.now(io).toMilliseconds();

    var running = true;
    while (running) {
        const encoder = gpu_context.getEncoder();
        defer c.wgpuCommandEncoderRelease(encoder);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        const new_time = @as(f32, @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds() - start_time)) / 1000.0;
        bind_group.set_uniform(gpu_context, .time, new_time);

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(encoder, target_texture_view, .{});
        rp.draw(draw_object);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
