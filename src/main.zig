const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;

const la = @import("lena.zig");
const Vec3 = la.Vec3(f32);
const Vec4 = la.Vec4(f32);
const Mat4 = la.Mat4x4(f32);

const Reflected = @import("Scene3D");
const SceneShader = gpu.Shader(Reflected);

const Camera = Reflected.Camera;
const Instance = Reflected.Instance;
const CameraUniform = SceneShader.Uniform.camera;
const InstanceStorage = SceneShader.Storage.instances;

const orbiter_count = 8;
const pillar_count = 4;
const instance_count = 1 + 1 + orbiter_count + pillar_count;

const ground_extent = 12.0;
const orbit_radius = 3.6;
const pillar_radius = 5.4;

const light_dir = Vec3.init(0.45, 1.0, 0.32);

const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

const Face = struct { normal: [3]f32, right: [3]f32, up: [3]f32 };

const cube_faces = [_]Face{
    .{ .normal = .{ 1, 0, 0 }, .right = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 } },
    .{ .normal = .{ -1, 0, 0 }, .right = .{ 0, 0, 1 }, .up = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 1, 0 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 0, -1 } },
    .{ .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 0, 1 } },
    .{ .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 } },
    .{ .normal = .{ 0, 0, -1 }, .right = .{ -1, 0, 0 }, .up = .{ 0, 1, 0 } },
};

const CubeMesh = struct {
    vertices: [cube_faces.len * 4]Vertex,
    indices: [cube_faces.len * 6]u16,
};

const cube: CubeMesh = blk: {
    var verts: [cube_faces.len * 4]Vertex = undefined;
    var indices: [cube_faces.len * 6]u16 = undefined;

    for (cube_faces, 0..) |f, fi| {
        const signs = [4][2]f32{
            .{ -1, 1 },
            .{ 1, 1 },
            .{ 1, -1 },
            .{ -1, -1 },
        };
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

        for (signs, uvs, 0..) |s, uv, ci| {
            var pos: [3]f32 = undefined;
            for (0..3) |axis| {
                pos[axis] = (f.normal[axis] + s[0] * f.right[axis] + s[1] * f.up[axis]) * 0.5;
            }
            verts[fi * 4 + ci] = .{ .pos = pos, .normal = f.normal, .uv = uv };
        }

        const base: u16 = @intCast(fi * 4);
        indices[fi * 6 + 0] = base + 0;
        indices[fi * 6 + 1] = base + 3;
        indices[fi * 6 + 2] = base + 2;
        indices[fi * 6 + 3] = base + 2;
        indices[fi * 6 + 4] = base + 1;
        indices[fi * 6 + 5] = base + 0;
    }

    break :blk .{ .vertices = verts, .indices = indices };
};

const checker_size = 16;

const checker_texture = blk: {
    var texels: [checker_size * checker_size * 4]u8 = undefined;
    for (0..checker_size) |y| {
        for (0..checker_size) |x| {
            const light = (x + y) % 2 == 0;
            const v: u8 = if (light) 235 else 170;
            const i = (y * checker_size + x) * 4;
            texels[i + 0] = v;
            texels[i + 1] = v;
            texels[i + 2] = v;
            texels[i + 3] = 255;
        }
    }
    break :blk texels;
};

const cube_uv_scale: [2]f32 = @splat(2.0 / @as(f32, checker_size));
const ground_uv_scale: [2]f32 = @splat(1.0);

fn object(
    translate: Vec3,
    axis: Vec3,
    angle: f32,
    scale: Vec3,
    color: [4]f32,
    uv_scale: [2]f32,
) Instance {
    const rotation = Mat4.rotation(axis, angle);

    const model = Mat4.translation(translate)
        .mul(rotation)
        .mul(Mat4.scale(scale));

    const normal = rotation.mul(Mat4.scale(.init(
        1.0 / scale.x,
        1.0 / scale.y,
        1.0 / scale.z,
    )));

    return .{
        .model = @bitCast(model),
        .normal = @bitCast(normal),
        .color = color,
        .uv_scale = uv_scale,
    };
}

fn fillInstances(out: *[instance_count]Instance, t: f32) void {
    out[0] = object(
        .init(0, -0.25, 0),
        .init(0, 1, 0),
        0,
        .init(ground_extent, 0.5, ground_extent),
        .{ 0.62, 0.64, 0.70, 1.0 },
        ground_uv_scale,
    );

    out[1] = object(
        .init(0, 1.35, 0),
        .init(0.3, 1.0, 0.15),
        t * 0.55,
        Vec3.splat(1.9),
        .{ 0.95, 0.72, 0.28, 1.0 },
        cube_uv_scale,
    );

    for (0..orbiter_count) |i| {
        const fi: f32 = @floatFromInt(i);
        const phase = fi * (std.math.tau / @as(f32, orbiter_count));
        const theta = t * 0.4 + phase;

        const hue = fi / @as(f32, orbiter_count) * std.math.tau;

        out[2 + i] = object(
            .init(
                orbit_radius * @cos(theta),
                0.85 + 0.45 * @sin(t * 1.1 + phase),
                orbit_radius * @sin(theta),
            ),
            .init(0.2, 1.0, 0.4),
            t * 1.3 + phase,
            Vec3.splat(0.8),
            .{
                0.45 + 0.45 * @sin(hue),
                0.45 + 0.45 * @sin(hue + 2.094),
                0.45 + 0.45 * @sin(hue + 4.188),
                1.0,
            },
            cube_uv_scale,
        );
    }

    for (0..pillar_count) |i| {
        const fi: f32 = @floatFromInt(i);
        const theta = fi * (std.math.tau / @as(f32, pillar_count)) + std.math.pi / 4.0;
        const height = 2.2 + fi * 0.7;

        out[2 + orbiter_count + i] = object(
            .init(
                pillar_radius * @cos(theta),
                height / 2.0,
                pillar_radius * @sin(theta),
            ),
            .init(0, 1, 0),
            theta,
            .init(0.7, height, 0.7),
            .{ 0.36, 0.44, 0.58, 1.0 },
            cube_uv_scale,
        );
    }
}

fn cameraFor(t: f32, aspect: f32) Camera {
    const eye = Vec3.init(
        9.5 * @cos(t * 0.22),
        3.4 + 1.7 * @sin(t * 0.16),
        9.5 * @sin(t * 0.22),
    );
    const target = Vec3.init(0, 1.1, 0);

    const view = Mat4.lookAt(eye, target, .init(0, 1, 0));
    const projection = Mat4.perspective(std.math.degreesToRadians(55.0), aspect, 0.1, 120.0);

    return .{
        .view_proj = @bitCast(projection.mul(view)),
        .eye = eye.toArray(),
        .light_dir = light_dir.normalize().toArray(),
    };
}

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

    const texture = gpu.Texture.init(
        gpu_context,
        "checker",
        checker_size,
        checker_size,
        .@"2d",
        .rgba8_unorm,
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer texture.deinit();

    texture.writeTexture(gpu_context, .{
        .data = &checker_texture,
        .format = .rgba8_unorm,
        .width = checker_size,
        .height = checker_size,
    }, .{});

    const checker_view = texture.createView("checker view");
    defer c.wgpuTextureViewRelease(checker_view);

    const sampler = gpu.createSampler(gpu_context, "checker sampler");
    defer c.wgpuSamplerRelease(sampler);

    const camera_uniform = try CameraUniform.init(gpu_context, .{ .label = "camera" });
    defer camera_uniform.deinit();

    var frame_group = try SceneShader.BindGroup(0).init(
        allocator,
        gpu_context,
        .{
            .camera = camera_uniform.binding(),
            .smp = sampler,
            .tex = checker_view,
        },
    );
    defer frame_group.deinit();

    const instance_storage = try InstanceStorage.initCapacity(
        gpu_context,
        instance_count,
        .{ .label = "scene instances" },
    );
    defer instance_storage.deinit();

    var instance_group = try SceneShader.BindGroup(1).init(
        allocator,
        gpu_context,
        .{ .instances = instance_storage.binding() },
    );
    defer instance_group.deinit();

    const vertex_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&cube.vertices),
        "cube vertices",
        .{ .vertex = true, .copy_dst = true },
    );

    const index_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&cube.indices),
        "cube indices",
        .{ .index = true, .copy_dst = true },
    );

    const cube_mesh: gpu.Mesh = .{
        .vertex_count = cube.vertices.len,
        .indices = .{
            .buffer = index_buffer,
            .format = .u16,
            .index_count = cube.indices.len,
        },
        .buffers = &.{
            .{
                .ptr = vertex_buffer,
                .stride = @sizeOf(Vertex),
                .attributes = &.{
                    .{
                        .location = 0,
                        .format = .f32x3,
                        .offset = @offsetOf(Vertex, "pos"),
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

    const depth_format: gpu.TextureFormat =
        if (builtin.os.tag == .ios and builtin.abi == .simulator)
            .depth32_float
        else
            .depth16_unorm;

    var depth_texture = gpu.Texture.init(
        gpu_context,
        "depth",
        @intCast(width),
        @intCast(height),
        .@"2d",
        depth_format,
        .{ .render_attachment = true },
    );
    defer depth_texture.deinit();

    var depth_view = depth_texture.createView("depth texture view");
    defer c.wgpuTextureViewRelease(depth_view);

    const pipeline = try gpu.createPipelineFromMesh(
        Reflected,
        allocator,
        gpu_context,
        cube_mesh,
        &.{},
        &.{ frame_group.layout, instance_group.layout },
        .{
            .label = "scene",
            .color_format = target_surface.format,
            .depth_format = depth_format,
            .depth_stencil_state = .{
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
        },
    );

    const scene: gpu.DrawObject = .{
        .bind_groups = &.{ frame_group.group, instance_group.group },
        .mesh = cube_mesh,
        .pipeline = pipeline,
        .instances = .initCount(instance_count),
    };

    var instance_data: [instance_count]Instance = undefined;
    var frame: u32 = 0;

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

            c.wgpuTextureViewRelease(depth_view);
            depth_texture.deinit();

            depth_texture = gpu.Texture.init(
                gpu_context,
                "depth",
                @intCast(width),
                @intCast(height),
                .@"2d",
                depth_format,
                .{ .render_attachment = true },
            );
            depth_view = depth_texture.createView("depth texture view");
        }

        const encoder = gpu_context.getEncoder();
        defer c.wgpuCommandEncoderRelease(encoder);

        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

        const t = @as(f32, @floatFromInt(frame)) * 0.016;
        frame +%= 1;

        camera_uniform.upload(gpu_context, cameraFor(t, aspect));

        fillInstances(&instance_data, t);
        try instance_storage.upload(gpu_context, &instance_data);

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(
            encoder,
            target_texture_view,
            .{
                .color_attachment = .{ .clear_value = .{ .r = 0.05, .g = 0.06, .b = 0.09 } },
                .depth_stencil_attachment = .{
                    .view = depth_view,
                    .depth_clear_value = 1.0,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                },
            },
        );
        rp.draw(scene);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        gpu.waitForNextFrame();
    }
}
