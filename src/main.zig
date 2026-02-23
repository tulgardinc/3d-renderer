const std = @import("std");
pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("SDL3/SDL.h");
    @cInclude("sdl3webgpu.h");
});

const w = @import("wgpu.zig");

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

    var instance = try w.GPUInstance.init();
    defer instance.deinit();

    const surface_raw = c.SDL_GetWGPUSurface(instance.webgpu_instance, window);

    var gpu_context = try w.GPUContext.initSync(instance.webgpu_instance, surface_raw);
    defer gpu_context.deinit();

    var surface = w.Surface.init(
        surface_raw,
        &gpu_context,
        @intCast(width),
        @intCast(height),
    );
    defer surface.deinit();

    var resources = try w.ResourceManager.init(allocator, &gpu_context);
    defer resources.deinit(allocator);

    var shaders = try w.ShaderManager.init(allocator, &gpu_context);
    defer shaders.deinit(allocator);

    var pipelines = try w.PipelineCache.init(
        &gpu_context,
        &shaders,
        &surface,
        .depth24_plus,
    );

    // create the shader
    const shader_handle = try shaders.createShader(
        allocator,
        "./shaders/2DVertexColors.wgsl",
        "test shader",
        .{
            .vertex_entry = "vs",
            .fragment_entry = "fs",
            .bind_groups = &.{},
            .vertex_inputs = &.{
                .{
                    .location = 0,
                    .format = .f32x2,
                },
                .{
                    .location = 1,
                    .format = .f32x3,
                },
            },
        },
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
        w.BufferUsage.vertex | w.BufferUsage.copy_dst,
    );

    var pipeline_desc = w.PipelineCache.PipelineDescriptor{
        .shader = shader_handle,
        .vertex_layout_count = 1,
    };
    pipeline_desc.vertex_layouts[0] = w.VertexLayout{
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

    const pipeline_entry = try pipelines.getPipeline(
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

        var frame = try surface.beginFrame();
        defer frame.deinit();

        var pass = frame.beginRenderPass();
        defer pass.deinit();

        const render_commands = frame.end();
        gpu_context.submitCommands(&.{render_commands});

        std.Thread.sleep(1_000_000);
    }
}
