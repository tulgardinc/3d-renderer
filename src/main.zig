const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;
const l = @import("lena.zig");

const Reflected = @import("Mesh");

const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
};

/// A shared corner needs a different uv on each face it touches, so the cube is
/// unwelded to 4 vertices per face. Corners run bottom-left, bottom-right,
/// top-right, top-left as seen from outside, which makes every face wind
/// counter-clockwise.
const vertices = [_]Vertex{
    // +z
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0, 0 } },
    // -z
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 0, 0 } },
    // +x
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 0, 0 } },
    // -x
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0, 0 } },
    // +y
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0, 0 } },
    // -y
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1, 0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0, 0 } },
};

const indices = [_]u16{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

/// 2x2 rgba8unorm checkerboard, row-major.
const checker_pixels = [_][4]u8{
    .{ 255, 255, 255, 255 }, .{ 40, 40, 40, 255 },
    .{ 40, 40, 40, 255 },    .{ 255, 255, 255, 255 },
};

extern fn emscripten_console_error(utf8: [*:0]const u8) void;

pub const std_options: std.Options = if (gpu.is_web) .{ .logFn = webLog } else .{};
pub const panic = if (gpu.is_web)
    std.debug.FullPanic(webPanic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

fn webLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] " ++
        (if (scope == .default) "" else @tagName(scope) ++ ": ");

    var buf: [1024]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, prefix ++ format, args) catch
        prefix ++ "<message too long>";
    emscripten_console_error(msg.ptr);
}

fn webPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    const truncated = msg[0..@min(msg.len, buf.len - 1)];
    @memcpy(buf[0..truncated.len], truncated);
    buf[truncated.len] = 0;
    emscripten_console_error(@ptrCast(&buf));
    @trap();
}

pub fn main() if (gpu.is_web) void else anyerror!void {
    if (gpu.is_web) {
        run() catch |err| std.log.err("fatal: {s}", .{@errorName(err)});
    } else {
        try run();
    }
}

pub fn run() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = if (gpu.is_web)
        std.heap.c_allocator
    else switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.smp_allocator,
    };

    var threaded: if (gpu.is_web) void else std.Io.Threaded =
        if (gpu.is_web) {} else .init(allocator, .{});
    defer if (!gpu.is_web) threaded.deinit();
    const io: std.Io = if (gpu.is_web) undefined else threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "3D scene",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    if (window == null) {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_DestroyWindow(window);

    var width: i32 = 0;
    var height: i32 = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);

    const instance = try gpu.GPUInstance.init();
    const surface = c.SDL_GetWGPUSurface(instance.webgpu_instance, window);

    const gpu_context = try gpu.GPUContext.initSync(io, instance.webgpu_instance, surface);
    var target_surface = gpu.Surface.init(gpu_context, surface);
    target_surface.configure(gpu_context, @intCast(width), @intCast(height));

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&vertices),
        "cube vertices",
        .{ .vertex = true, .copy_dst = true },
    );

    const index_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&indices),
        "cube indices",
        .{ .index = true, .copy_dst = true },
    );

    const cube_mesh: gpu.Mesh = .{
        .vertex_count = vertices.len,
        .indices = .{
            .buffer = index_buffer,
            .format = .u16,
            .index_count = indices.len,
        },
        .buffers = &.{
            .{
                .ptr = vertex_buffer,
                .stride = @sizeOf(Vertex),
                .attributes = &.{
                    .{
                        .location = 0,
                        .format = .f32x3,
                        .offset = @offsetOf(Vertex, "position"),
                    },
                    .{
                        .location = 1,
                        .format = .f32x2,
                        .offset = @offsetOf(Vertex, "uv"),
                    },
                },
            },
        },
    };

    const Shader = gpu.Shader(Reflected);

    const view_matrix_ub = try Shader.Uniform.view_matrix.init(gpu_context, .{});

    const cam_pos = l.Vec3(f32).init(0, 2, 3);
    const view = l.Mat4x4(f32).lookAt(cam_pos, l.Vec3(f32).splat(0), l.Vec3(f32).init(0, 1, 0));
    var aspect: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), aspect, 0.01, 5);
    var view_proj = proj.mul(view);
    view_matrix_ub.upload(gpu_context, view_proj.toArray());

    const checker_tex = gpu.Texture.init(
        gpu_context,
        "checker texture",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer checker_tex.deinit();

    const checker_texel = gpu.TexelData{
        .width = 2,
        .height = 2,
        .format = .rgba8_unorm,
        .data = std.mem.asBytes(&checker_pixels),
    };
    checker_tex.writeTexture(gpu_context, checker_texel, .{});

    const checker_view = checker_tex.createView("checker view");
    defer c.wgpuTextureViewRelease(checker_view);

    const sampler = gpu.createSampler(gpu_context, "checker sampler");
    defer c.wgpuSamplerRelease(sampler);

    const bg = try Shader.BindGroup(0).init(
        allocator,
        gpu_context,
        .{
            .view_matrix = view_matrix_ub.binding(),
            .texture = checker_view,
            .smp = sampler,
        },
    );
    defer bg.deinit();

    const pipeline = try gpu.createPipelineFromMesh(
        Reflected,
        allocator,
        gpu_context,
        cube_mesh,
        &.{},
        &.{bg.layout},
        .{
            .label = "mesh",
            .color_format = target_surface.format,
            .depth_stencil_state = .{},
            .depth_format = .depth32_float,
        },
    );

    const draw_object: gpu.DrawObject = .{
        .bind_groups = &.{bg.group},
        .mesh = cube_mesh,
        .pipeline = pipeline,
        .instances = .initCount(1),
    };

    var depth_texture = gpu.Texture.init(
        gpu_context,
        "depth texture",
        @intCast(width),
        @intCast(height),
        .@"2d",
        .depth32_float,
        .{
            .copy_dst = true,
            .render_attachment = true,
        },
    );

    var depth_view = depth_texture.createView("depth view");

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                else => {},
            }
        }

        var cur_width: i32 = 0;
        var cur_height: i32 = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &cur_width, &cur_height);

        if (cur_width != width or cur_height != height) {
            width = cur_width;
            height = cur_height;
            target_surface.configure(gpu_context, @intCast(width), @intCast(height));

            depth_texture = gpu.Texture.init(
                gpu_context,
                "depth texture",
                @intCast(width),
                @intCast(height),
                .@"2d",
                .depth32_float,
                .{
                    .copy_dst = true,
                    .render_attachment = true,
                },
            );
            depth_view = depth_texture.createView("depth view");

            aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
            proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), aspect, 0.01, 5);
            view_proj = proj.mul(view);
            view_matrix_ub.upload(gpu_context, view_proj.toArray());
        }

        const encoder = gpu_context.getEncoder();
        defer c.wgpuCommandEncoderRelease(encoder);

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(
            encoder,
            target_texture_view,
            .{
                .color_attachment = .{ .clear_value = .{ .r = 0.05, .g = 0.06, .b = 0.09 } },
                .depth_stencil_attachment = .{
                    .view = depth_view,
                },
            },
        );
        rp.draw(draw_object);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        gpu.waitForNextFrame();
    }
}
