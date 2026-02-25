const std = @import("std");
const gpu = @import("gpu.zig");
const gs = @import("gpu-system.zig");
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

    var surface = gpu.Surface.init(
        surface_raw,
        gpu_context.adapter,
    );
    defer surface.deinit();

    surface.configure(gpu_context.device, @intCast(width), @intCast(height));

    var resources = try gs.ResourceManager.init(allocator, &gpu_context);
    defer resources.deinit(allocator);

    var shaders = try gs.ShaderManager.init(allocator, &gpu_context);
    defer shaders.deinit(allocator);

    var pipelines = gs.PipelineCache.init(
        &gpu_context,
        &shaders,
        &surface,
        .depth24_plus,
    );
    defer pipelines.deinit(allocator);

    var bindings = gs.Bindings.init(&gpu_context, &resources);
    defer bindings.deinit(allocator);

    // create the shader
    const shader_handle = try shaders.createShader(
        allocator,
        "shaders/2DVertexColors.wgsl",
        "test shader",
    );

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

    var pipeline_desc: gs.PipelineDescriptor = .{
        .shader = shader_handle,
        .vertex_layout_count = 1,
        .depth_stencil = null,
    };
    pipeline_desc.vertex_layouts[0] = .{
        .step_mode = .vertex,
        .array_stride = 5 * @sizeOf(f32),
        .attribute_count = 2,
    };
    pipeline_desc.vertex_layouts[0].attributes[0] = .{
        .shader_location = 0,
        .offset = 0,
        .format = .f32x2,
    };
    pipeline_desc.vertex_layouts[0].attributes[1] = .{
        .shader_location = 1,
        .offset = 2 * @sizeOf(f32),
        .format = .f32x3,
    };

    const pipeline_entry = try pipelines.getOrCreatePipeline(
        allocator,
        "2d pipeline",
        pipeline_desc,
    );

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

        var frame = try gpu.Frame.init(&gpu_context, &surface);
        defer frame.deinit();

        var pass = gs.RenderPass.init(frame.encoder, frame.target_view, .{});
        defer pass.deinit();

        c.wgpuRenderPassEncoderSetPipeline(pass.render_pass, pipeline_entry.pipeline);
        c.wgpuRenderPassEncoderSetVertexBuffer(
            pass.render_pass,
            0,
            resources.getBuffer(vb_handle).?,
            0,
            @sizeOf(f32) * vertices.len,
        );
        c.wgpuRenderPassEncoderDraw(
            pass.render_pass,
            3,
            1,
            0,
            0,
        );

        pass.end();

        const render_commands = frame.end();
        gpu_context.submitCommands(&.{render_commands});
        try surface.present();

        std.Thread.sleep(1_000_000);
    }
}
