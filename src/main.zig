const std = @import("std");
const gpu = @import("gpu");
const build_options = @import("build_options");
const builtin = @import("builtin");
const c = gpu.c;
const Shader = @import("2DTextured");

const triangle_vertices = [_]f32{
    // x y   r g b
    0.0, 0.5, 1.0, 0.0, 0.0, //   top    - red
    -0.5, -0.5, 0.0, 1.0, 0.0, // left   - green
    0.5, -0.5, 0.0, 0.0, 1.0, //  right  - blue
};

const quad_vertices = [_]f32{
    // x y   u v
    -0.5, 0.5, 0.0, 0.0, //  tl
    -0.5, -0.5, 0.0, 1.0, // bl
    0.5, -0.5, 1.0, 1.0, //  br
    0.5, -0.5, 1.0, 1.0, //  br
    0.5, 0.5, 1.0, 0.0, //   tr
    -0.5, 0.5, 0.0, 0.0, //  tl
};

const checker_texture = [_]u8{
    255, 255, 255, 255, 0,   0,   0,   255,
    0,   0,   0,   255, 255, 255, 255, 255,
};

const checker_texture2 = [_]u8{
    255, 0, 0, 255, 0,   0, 0, 255,
    0,   0, 0, 255, 255, 0, 0, 255,
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

    const texture = gpu.Texture.init(
        gpu_context,
        &checker_texture,
        "checker",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
    );
    defer texture.deinit();

    const checker_view = texture.createView("checker view");
    defer c.wgpuTextureViewRelease(checker_view);

    const texture2 = gpu.Texture.init(
        gpu_context,
        &checker_texture2,
        "checker",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
    );
    defer texture2.deinit();

    const checker_view2 = texture2.createView("checker view 2");
    defer c.wgpuTextureViewRelease(checker_view2);

    const sampler = gpu.createSampler(gpu_context, "checker sampler");
    defer c.wgpuSamplerRelease(sampler);

    var bind_group = try gpu.ShaderBindGroup(Shader, 0).init(
        allocator,
        gpu_context,
        .{
            .smp = sampler,
            .tex = checker_view,
        },
    );
    defer bind_group.deinit();

    var bind_group2 = try gpu.ShaderBindGroup(Shader, 0).init(
        allocator,
        gpu_context,
        .{
            .smp = sampler,
            .tex = checker_view2,
        },
    );
    defer bind_group2.deinit();

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&quad_vertices),
        "vertex buffer",
        gpu.BufferUsage.vertex | gpu.BufferUsage.copy_dst,
    );

    const pos = [_]f32{ -0.6, 0, 0.6, 0 };

    const instance_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&pos),
        "test",
        gpu.BufferUsage.vertex | gpu.BufferUsage.copy_dst,
    );

    const quad_mesh: gpu.Mesh = .{
        .vertex_count = 6,
        .buffers = &.{
            .{
                .ptr = vertex_buffer,
                .stride = 4 * @sizeOf(f32),
                .attributes = &.{
                    .{
                        .location = 0,
                        .format = .f32x2,
                        .offset = 0,
                    },
                    .{
                        .location = 1,
                        .format = .f32x2,
                        .offset = 2 * @sizeOf(f32),
                    },
                },
            },
        },
    };

    const instances: gpu.Instances =
        .{
            .count = 2,
            .buffers = &.{
                .{
                    .ptr = instance_buffer,
                    .stride = 2 * @sizeOf(f32),
                    .attributes = &.{
                        .{
                            .location = 2,
                            .format = .f32x2,
                            .offset = 0,
                        },
                    },
                },
            },
        };

    const pipeline = try gpu.createPipelineFromMesh(
        Shader,
        allocator,
        gpu_context,
        quad_mesh,
        instances,
        &.{bind_group.layout},
        .{ .color_format = target_surface.format },
    );

    const quad1_object: gpu.DrawObject = .{
        .bind_groups = &.{bind_group.group},
        .mesh = quad_mesh,
        .pipeline = pipeline,
        .instances = instances,
    };

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

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(encoder, target_texture_view, .{});
        rp.draw(quad1_object);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
