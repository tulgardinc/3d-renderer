const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;

const Reflected = @import("InstancedQuad");
const QuadShader = gpu.Shader(Reflected);

const Instance = Reflected.Instance;
const InstanceStorage = QuadShader.Storage.instances;

const grid_cols = 16;
const grid_rows = 12;
const quad_count = grid_cols * grid_rows;

const quad_vertices = [_]f32{
    // x y   u v
    -0.5, 0.5, 0.0, 0.0, // tl
    -0.5, -0.5, 0.0, 1.0, // bl
    0.5, -0.5, 1.0, 1.0, // br
    0.5, -0.5, 1.0, 1.0, // br
    0.5, 0.5, 1.0, 0.0, // tr
    -0.5, 0.5, 0.0, 0.0, // tl
};

const checker_texture = [_]u8{
    255, 255, 255, 255, 110, 110, 110, 255,
    110, 110, 110, 255, 255, 255, 255, 255,
};

fn model(tx: f32, ty: f32, scale_x: f32, scale_y: f32, angle: f32) [4][4]f32 {
    const ca = @cos(angle);
    const sa = @sin(angle);
    return .{
        .{ ca * scale_x, sa * scale_y, 0.0, 0.0 },
        .{ -sa * scale_x, ca * scale_y, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ tx, ty, 0.0, 1.0 },
    };
}

fn fillInstances(out: *[quad_count]Instance, t: f32, aspect: f32) void {
    const cell_w = 2.0 / @as(f32, grid_cols);
    const cell_h = 2.0 / @as(f32, grid_rows);

    for (0..grid_rows) |row| {
        for (0..grid_cols) |col| {
            const fx = @as(f32, @floatFromInt(col));
            const fy = @as(f32, @floatFromInt(row));

            const tx = -1.0 + cell_w * (fx + 0.5);
            const ty = 1.0 - cell_h * (fy + 0.5);

            const phase = t + (fx + fy) * 0.35;
            const pulse = 0.55 + 0.45 * @sin(phase);
            const size = cell_h * 0.8 * pulse;

            out[row * grid_cols + col] = .{
                .model = model(tx, ty, size / aspect, size, phase * 0.5),
                .tint = .{
                    0.5 + 0.5 * @sin(phase),
                    0.5 + 0.5 * @sin(phase + 2.094),
                    0.5 + 0.5 * @sin(phase + 4.188),
                    1.0,
                },
            };
        }
    }
}

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
        "Storage-buffer instanced quads",
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

    const sampler = gpu.createSampler(gpu_context, "checker sampler");
    defer c.wgpuSamplerRelease(sampler);

    // Group 0: the material side
    var material_group = try QuadShader.BindGroup(0).init(
        allocator,
        gpu_context,
        .{
            .smp = sampler,
            .tex = checker_view,
        },
    );
    defer material_group.deinit();

    // Group 1: the instance array
    const instance_storage = try InstanceStorage.initCapacity(
        gpu_context,
        quad_count,
        .{ .label = "quad instances" },
    );
    defer instance_storage.deinit();

    var instance_group = try QuadShader.BindGroup(1).init(
        allocator,
        gpu_context,
        .{ .instances = instance_storage.binding() },
    );
    defer instance_group.deinit();

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&quad_vertices),
        "vertex buffer",
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

    const pipeline = try gpu.createPipelineFromMesh(
        Reflected,
        allocator,
        gpu_context,
        quad_mesh,
        &.{},
        &.{ material_group.layout, instance_group.layout },
        .{ .color_format = target_surface.format },
    );

    const quads: gpu.DrawObject = .{
        .bind_groups = &.{ material_group.group, instance_group.group },
        .mesh = quad_mesh,
        .pipeline = pipeline,
        .instances = .initCount(quad_count),
    };

    var instance_data: [quad_count]Instance = undefined;
    var frame: u32 = 0;

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

        _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

        // Frame-count time: the loop paces itself at ~16ms below.
        const t = @as(f32, @floatFromInt(frame)) * 0.016;
        frame +%= 1;

        fillInstances(&instance_data, t, aspect);
        try instance_storage.upload(gpu_context, &instance_data);

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(encoder, target_texture_view, .{});
        rp.draw(quads);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
