const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;
const l = @import("lena.zig");

const Reflected = @import("Mesh");

const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
    normal: [3]f32,
};

/// A shared corner needs a different uv on each face it touches, so the cube is
/// unwelded to 4 vertices per face. Corners run bottom-left, bottom-right,
/// top-right, top-left as seen from outside, which makes every face wind
/// counter-clockwise.
///
/// The same unwelding is what lets each face carry its own normal: all four of a
/// face's vertices get that face's axis, which is what makes a cube shade flat
/// rather than smooth.
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

const Camera = struct {
    pos: l.Vec3(f32) = .init(0, 0, 3),
    rot: l.Vec2(f32) = .init(0, 0),

    const Self = @This();

    pub fn forward(self: Self) l.Vec3(f32) {
        return .init(@cos(self.rot.x) * @sin(self.rot.y), -@sin(self.rot.x), -@cos(self.rot.x) * @cos(self.rot.y));
    }

    pub fn getViewMatrix(self: Self) l.Mat4x4(f32) {
        return l.Mat4x4(f32).lookAt(self.pos, self.pos.add(self.forward()), l.Vec3(f32).up());
    }
};

const CubeInstance = struct {
    pos: l.Vec3(f32),
    rot: f32,

    const Self = @This();

    pub fn modelMatrix(self: Self) l.Mat4x4(f32) {
        return l.Mat4x4(f32).translation(self.pos).mul(.rotation(.up(), self.rot));
    }
};

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
                        .format = .f32x3,
                        .offset = @offsetOf(Vertex, "normal"),
                    },
                    .{
                        .location = 2,
                        .format = .f32x2,
                        .offset = @offsetOf(Vertex, "uv"),
                    },
                },
            },
        },
    };

    const Shader = gpu.Shader(Reflected);

    const world_ub = try Shader.Uniform.world.init(gpu_context, .{});

    var cam = Camera{};

    var aspect: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), aspect, 0.01, 100);

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

    const instances = try Shader.Storage.instances.initCapacity(gpu_context, 3, .{});
    defer instances.deinit();
    try instances.upload(
        gpu_context,
        &.{
            .{
                .model = (CubeInstance{ .pos = .init(-2, 0, 0), .rot = 0 }).modelMatrix().toArray(),
                .tint = l.Vec4(f32).init(1, 0, 0, 1).toArray(),
            },
            .{
                .model = (CubeInstance{ .pos = .init(0, 0, 0), .rot = std.math.degreesToRadians(15) }).modelMatrix().toArray(),
                .tint = l.Vec4(f32).init(0, 1, 0, 1).toArray(),
            },
            .{
                .model = (CubeInstance{ .pos = .init(2, 0, 0), .rot = std.math.degreesToRadians(30) }).modelMatrix().toArray(),
                .tint = l.Vec4(f32).init(0, 0, 1, 1).toArray(),
            },
        },
    );

    const bg = try Shader.BindGroup(0).init(
        allocator,
        gpu_context,
        .{
            .world = world_ub.binding(),
            .texture = checker_view,
            .smp = sampler,
            .instances = instances.binding(),
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
        .instances = .initCount(3),
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
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                        _ = c.SDL_SetWindowRelativeMouseMode(window, !c.SDL_GetWindowRelativeMouseMode(window));
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    cam.rot.y += event.motion.xrel * 0.001;
                    cam.rot.x += event.motion.yrel * 0.001;
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
            const right = cam.forward().cross(.up()).normalize().scale(cam_speed);
            cam.pos = cam.pos.add(right);
        } else if (active_keys[c.SDL_SCANCODE_A]) {
            const left = cam.forward().cross(.up()).normalize().scale(-cam_speed);
            cam.pos = cam.pos.add(left);
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
            proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), aspect, 0.01, 100);
        }

        const view_proj = proj.mul(cam.getViewMatrix());
        world_ub.upload(gpu_context, .{
            .vp_matrix = view_proj.toArray(),
            .light_dir = l.Vec3(f32).init(2, 3, 1).normalize().toArray(),
            .ambient = 0.01,
        });

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
