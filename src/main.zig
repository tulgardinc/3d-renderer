const std = @import("std");
const gpu = @import("gpu.zig");
const gs = @import("gpu-system.zig");
const build_options = @import("build_options");
const c = gpu.c;

pub fn main() !void {
    // get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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

    var instance = try gpu.GPUInstance.init();
    defer instance.deinit();

    const surface_raw = c.SDL_GetWGPUSurface(instance.webgpu_instance, window);

    var gpu_context = try gpu.GPUContext.initSync(instance.webgpu_instance, surface_raw);
    defer gpu_context.deinit();

    var surface = gpu.Surface.init(surface_raw, gpu_context.adapter);
    defer surface.deinit();

    surface.configure(gpu_context.device, @intCast(width), @intCast(height));

    // Initialize modules

    var resources = try gs.ResourceManager.init(allocator, gpu_context.device, gpu_context.queue);
    defer resources.deinit(allocator);

    var shaders = try gs.ShaderManager.init(allocator, gpu_context.device);
    defer shaders.deinit(allocator);

    var bind_group_layout_cache = gs.BindGroupLayoutCache.init(gpu_context.device);
    defer bind_group_layout_cache.deinit();

    var bind_group_cache = gs.BindGroupCache.init(gpu_context.device);
    defer bind_group_cache.deinit(allocator);

    var pipelines = gs.PipelineCache.init(
        gpu_context.device,
        surface.format,
        .depth24_plus,
    );
    defer pipelines.deinit(allocator);

    // Create shader

    const shader_handle = try shaders.createShader(
        allocator,
        build_options.shaders_dir ++ "/2DVertexColors.wgsl",
        "test shader",
    );
    const shader = shaders.getShader(shader_handle).?;

    // Create Buffers

    const vertices = [_]f32{
        -0.5, -0.5, 1.0, 0.0, 0.0,
        0.5,  -0.5, 0.0, 1.0, 0.0,
        0,    0.5,  0.0, 0.0, 1.0,
    };

    const vb_handle = try resources.createBuffer(
        allocator,
        std.mem.sliceAsBytes(&vertices),
        "vertex buffer",
        gpu.BufferUsage.vertex | gpu.BufferUsage.copy_dst,
    );

    var uniform = [_]f32{0};
    const uniform_handle = try resources.createBuffer(
        allocator,
        std.mem.sliceAsBytes(&uniform),
        "uniform",
        gpu.BufferUsage.uniform | gpu.BufferUsage.copy_dst,
    );

    // ── Resolve bind group layouts from shader metadata ───────────────────────

    var bg_layout_buf: [gs.MAX_BIND_GROUP_COUNT]c.WGPUBindGroupLayout = undefined;
    var bg_layouts: ?[]const c.WGPUBindGroupLayout = null;
    if (shader.metadata.bind_group_layouts) |bgs| {
        for (bgs, 0..) |entries, i| {
            bg_layout_buf[i] = try bind_group_layout_cache.getOrCreateBindGroupLayout(allocator, entries);
        }
        bg_layouts = bg_layout_buf[0..bgs.len];
    }

    // Create pipeline

    const pipeline_desc: gs.PipelineDescriptor = .{
        .shader_module = shader.module,
        .depth_stencil = null,
        .vertex_layouts = &.{
            .{
                .step_mode = .vertex,
                .array_stride = 5 * @sizeOf(f32),
                .attributes = &.{
                    .{
                        .shader_location = 0,
                        .offset = 0,
                        .format = .f32x2,
                    },
                    .{
                        .shader_location = 1,
                        .offset = 2 * @sizeOf(f32),
                        .format = .f32x3,
                    },
                },
            },
        },
    };

    const pipeline_entry = try pipelines.getOrCreatePipeline(
        allocator,
        "2d pipeline",
        pipeline_desc,
        shader.metadata.vertex_entry,
        shader.metadata.fragment_entry,
        bg_layouts,
    );

    const start_time = std.time.milliTimestamp();

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        uniform[0] = @as(f32, @floatFromInt(std.time.milliTimestamp() - start_time)) / 1000.0;
        try resources.updateBuffer(uniform_handle, std.mem.sliceAsBytes(&uniform));

        var frame = try gpu.Frame.init(&gpu_context, &surface);
        defer frame.deinit();

        var pass = gs.RenderPass.init(
            frame.encoder,
            frame.target_view,
            &bind_group_layout_cache,
            &bind_group_cache,
            &shaders,
            .{
                .color_attachment = .{
                    .clear_value = .{ .a = 1.0, .r = 0.1, .g = 0.1, .b = 0.1 },
                },
            },
        );
        defer pass.deinit();

        const vb = resources.getBuffer(vb_handle).?;
        const ub = resources.getBuffer(uniform_handle).?;

        pass.setPipeline(pipeline_entry.pipeline);
        pass.setVertexBuffer(0, vb.ptr, 0, @sizeOf(f32) * vertices.len);
        try pass.bindGroup(allocator, 0, shader_handle, &.{
            .{
                .binding = 0,
                .resource = .{ .buffer = .{
                    .buffer = ub.ptr,
                    .size = ub.byte_size,
                } },
            },
        });
        pass.draw(3, 1, 0, 0);
        pass.end();

        const render_commands = frame.end();
        gpu_context.submitCommands(&.{render_commands});
        try surface.present();

        std.Thread.sleep(1_000_000);
    }
}
