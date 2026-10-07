const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;
const l = @import("lena.zig");
const r = @import("renderer.zig");

const Basic = @import("Basic");

const Renderer = r.Renderer(.{});

const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
    normal: [3]f32,
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

const vertex_layout: r.StreamLayout = .{
    .stride = @sizeOf(Vertex),
    .attributes = &.{
        .{ .name = "position", .format = .f32x3, .offset = @offsetOf(Vertex, "position") },
        .{ .name = "uv", .format = .f32x2, .offset = @offsetOf(Vertex, "uv") },
        .{ .name = "normal", .format = .f32x3, .offset = @offsetOf(Vertex, "normal") },
        .{ .name = "color", .format = .unorm8x4, .offset = @offsetOf(Vertex, "color") },
    },
};

/// Corners run bottom-left, bottom-right, top-right, top-left as seen from outside
const vertices = [_]Vertex{
    // +z
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1, 0 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0, 0 }, .normal = .{ 0, 0, 1 } },
    // -z
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 0, 1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 1, 1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 1, 0 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 0, 0 }, .normal = .{ 0, 0, -1 } },
    // +x
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 0, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1, 0 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 0, 0 }, .normal = .{ 1, 0, 0 } },
    // -x
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 1, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 1, 0 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0, 0 }, .normal = .{ -1, 0, 0 } },
    // +y
    .{ .position = .{ -0.5, 0.5, 0.5 }, .uv = .{ 0, 1 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .uv = .{ 1, 1 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .uv = .{ 1, 0 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .uv = .{ 0, 0 }, .normal = .{ 0, 1, 0 } },
    // -y
    .{ .position = .{ -0.5, -0.5, -0.5 }, .uv = .{ 0, 1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .uv = .{ 1, 1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .uv = .{ 1, 0 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .uv = .{ 0, 0 }, .normal = .{ 0, -1, 0 } },
};

const indices = [_]u32{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

// 2x2 rgba8unorm checkerboard, row-major.
const checker_pixels = [_][4]u8{
    .{ 255, 255, 255, 255 }, .{ 40, 40, 40, 255 },
    .{ 40, 40, 40, 255 },    .{ 255, 255, 255, 255 },
};

// 1x1 white texture
const simple_pixel = [_][4]u8{
    .{ 255, 255, 255, 255 },
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

    _ = c.SDL_SetWindowRelativeMouseMode(window, true);

    var instance = try gpu.GPUInstance.init();
    defer instance.deinit();
    const surface = c.SDL_GetWGPUSurface(instance.webgpu_instance, window);

    var renderer = try Renderer.init(allocator, io, instance.webgpu_instance, surface);
    defer renderer.deinit(allocator);

    renderer.setSampleCount(4);
    renderer.configureTarget(@intCast(width), @intCast(height));

    const cube = try renderer.mesh(allocator, .{
        .streams = &.{.{ .layout = vertex_layout, .data = std.mem.sliceAsBytes(&vertices) }},
        .indices = &indices,
        .vertex_count = vertices.len,
    });

    const checker_tex = gpu.Texture.init(
        renderer.gpu_context,
        "checker texture",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
        .{},
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer checker_tex.deinit();

    checker_tex.writeTexture(renderer.gpu_context, .{
        .width = 2,
        .height = 2,
        .format = .rgba8_unorm,
        .data = std.mem.asBytes(&checker_pixels),
    }, .{});

    const white_tex = gpu.Texture.init(
        renderer.gpu_context,
        "white texture",
        1,
        1,
        .@"2d",
        .rgba8_unorm,
        .{},
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer white_tex.deinit();

    white_tex.writeTexture(renderer.gpu_context, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .data = std.mem.asBytes(&simple_pixel),
    }, .{});

    const checker_mat = try renderer.material(allocator, Basic, .{
        .texture = .{ .tex = checker_tex },
        .smp = .{},
    }, .{});

    const white_mat = try renderer.material(allocator, Basic, .{
        .texture = .{ .tex = white_tex },
        .smp = .{},
    }, .{});

    const glass_mat = try renderer.material(allocator, Basic, .{
        .texture = .{ .tex = checker_tex },
        .smp = .{},
    }, .{ .render_state = .transparent() });

    var cam: r.Camera = .{ .pos = .init(0, 1, 5) };

    var running = true;
    while (running) : (gpu.waitForNextFrame()) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                        _ = c.SDL_SetWindowRelativeMouseMode(window, !c.SDL_GetWindowRelativeMouseMode(window));
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    cam.yaw += event.motion.xrel * 0.001;
                    cam.pitch += event.motion.yrel * 0.001;
                },
                else => {},
            }
        }

        const active_keys = c.SDL_GetKeyboardState(null);
        const cam_speed = 0.1;
        if (active_keys[c.SDL_SCANCODE_W]) {
            cam.pos = cam.pos.add(cam.forward().scale(cam_speed));
        } else if (active_keys[c.SDL_SCANCODE_S]) {
            cam.pos = cam.pos.add(cam.forward().scale(-cam_speed));
        }
        if (active_keys[c.SDL_SCANCODE_D]) {
            cam.pos = cam.pos.add(cam.right().scale(cam_speed));
        } else if (active_keys[c.SDL_SCANCODE_A]) {
            cam.pos = cam.pos.add(cam.right().scale(-cam_speed));
        }
        if (active_keys[c.SDL_SCANCODE_E]) {
            cam.pos = cam.pos.add(l.Vec3(f32).up().scale(cam_speed));
        } else if (active_keys[c.SDL_SCANCODE_Q]) {
            cam.pos = cam.pos.add(l.Vec3(f32).up().scale(-cam_speed));
        }

        var cur_width: i32 = 0;
        var cur_height: i32 = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &cur_width, &cur_height);

        if (cur_width != width or cur_height != height) {
            width = cur_width;
            height = cur_height;
            renderer.configureTarget(@intCast(width), @intCast(height));
        }

        var frame = renderer.beginFrame() catch {
            renderer.configureTarget(@intCast(width), @intCast(height));
            continue;
        };
        defer frame.deinit();

        const main_pass = try frame.pass(allocator, .{
            .label = "main",
            .color_attachment = .{
                .target = .surface,
                .clear_value = .{ .r = 0.05, .g = 0.06, .b = 0.09 },
            },
            .depth_stencil_attachment = .{ .target = .surface_depth },
        });
        try main_pass.setCamera(allocator, cam);

        try main_pass.draw(allocator, cube, checker_mat, .{
            .position = .{ 0, -1, 0 },
            .scale = .{ 8, 1, 8 },
            .tint = .{ 1, 1, 1, 1 },
        });
        try main_pass.draw(allocator, cube, checker_mat, .{
            .position = .{ 2, 0, 0 },
            .rotation = .{ 0, std.math.degreesToRadians(30), 0 },
            .tint = .{ 0, 0, 1, 1 },
        });
        try main_pass.draw(allocator, cube, white_mat, .{
            .position = .{ 4, 0, 0 },
            .rotation = .{ 0, std.math.degreesToRadians(45), 0 },
            .tint = .{ 1, 0.5, 0, 1 },
        });
        try main_pass.draw(allocator, cube, white_mat, .{
            .position = .{ -4, 0, 0 },
            .rotation = .{ 0, std.math.degreesToRadians(60), 0 },
            .tint = .{ 0.6, 0, 1, 1 },
        });
        try main_pass.draw(allocator, cube, glass_mat, .{
            .position = .{ 0, 0, 0 },
            .rotation = .{ 0, std.math.degreesToRadians(15), 0 },
            .tint = .{ 0, 1, 0, 0.3 },
        });
        try main_pass.draw(allocator, cube, glass_mat, .{
            .position = .{ -2, 0, 0 },
            .tint = .{ 1, 0, 0, 0.3 },
        });

        try frame.submit(allocator);
    }
}
