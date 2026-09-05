const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;
const l = @import("lena.zig");

const Mesh = @import("Mesh");
const Shadow = @import("Shadow");

const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
    normal: [3]f32,
};

const DrawCmd = struct {
    transparent: bool,
    pipeline: usize,
    material: usize,
    mesh: usize,
    depth: f32 = 0,

    instance: Mesh.Instance,

    pub fn lessThan(_: void, a: DrawCmd, b: DrawCmd) bool {
        if (a.transparent != b.transparent) return !a.transparent;
        if (a.transparent) return a.depth > b.depth;
        if (a.pipeline != b.pipeline) return a.pipeline < b.pipeline;
        if (a.material != b.material) return a.material < b.material;
        return a.mesh < b.mesh;
    }
};

/// A run of sort-adjacent commands with identical state: one draw call.
/// `first`/`count` index the flat instance array uploaded this frame.
const Batch = struct {
    transparent: bool,
    pipeline: usize,
    material: usize,
    mesh: usize,
    first: u32,
    count: u32,
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

const indices = [_]u16{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const instance_count: u32 = 4;

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

// always facing 0,0,0
const DirectionalLight = struct {
    pos: l.Vec3(f32) = .init(30, 30, 20),
    ambient: f32 = 0.05,
    texture_size: f32 = 512,

    const Self = @This();

    pub fn getVPMatrix(self: Self) l.Mat4x4(f32) {
        const proj = l.Mat4x4(f32).orthographic(-2, 2, 2, -2, 0.01, 50);
        return proj.mul(.lookAt(self.pos, .splat(0), .up()));
    }
};

const CubeInstance = struct {
    scale: l.Vec3(f32) = .splat(1),
    pos: l.Vec3(f32) = .splat(0),
    rot: f32 = 0,

    const Self = @This();

    pub fn modelMatrix(self: Self) l.Mat4x4(f32) {
        return l.Mat4x4(f32).translation(self.pos).mul(.rotation(.up(), self.rot)).mul(.scale(self.scale));
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
        .buffers = &.{.of(Vertex, vertex_buffer, .{
            .position = .f32x3,
            .uv = .f32x2,
            .normal = .f32x3,
        })},
    };

    const MeshShader = gpu.Shader(Mesh);
    const ShadowShader = gpu.Shader(Shadow);

    const mesh_shader = try MeshShader.init(allocator, gpu_context);
    defer mesh_shader.deinit();

    const shadow_shader = try ShadowShader.init(allocator, gpu_context);
    defer shadow_shader.deinit();

    const world_ub = try MeshShader.Uniform.world.init(gpu_context, .{});

    var cam = Camera{};

    var cam_aspect: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var cam_proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), cam_aspect, 0.01, 100);

    const checker_tex = gpu.Texture.init(
        gpu_context,
        "checker texture",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
        .{},
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

    const white_tex = gpu.Texture.init(
        gpu_context,
        "white texture",
        1,
        1,
        .@"2d",
        .rgba8_unorm,
        .{},
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer white_tex.deinit();

    white_tex.writeTexture(gpu_context, .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .data = std.mem.asBytes(&simple_pixel),
    }, .{});

    const white_view = white_tex.createView("white view");
    defer c.wgpuTextureViewRelease(white_view);

    const sampler = gpu.createSampler(gpu_context, .{});
    defer c.wgpuSamplerRelease(sampler);

    const instance_storage = try MeshShader.Storage.instances.initCapacity(gpu_context, 8, .{});
    defer instance_storage.deinit();

    const dir_light = DirectionalLight{};
    const dir_light_ub = try ShadowShader.Uniform.light_vp.init(gpu_context, .{});

    const shadow_map = gpu.Texture.init(
        gpu_context,
        "shadow map",
        @intCast(2048),
        @intCast(2048),
        .@"2d",
        .depth32_float,
        .{},
        .{
            .texture_binding = true,
            .render_attachment = true,
        },
    );
    defer shadow_map.deinit();

    const shadow_map_view = shadow_map.createView("shadow view");
    defer c.wgpuTextureViewRelease(shadow_map_view);

    const shadow_smp = gpu.createSampler(
        gpu_context,
        .{
            .compare = .less_equal,
            .min_filter = .linear,
            .mag_filter = .linear,
        },
    );

    const frame_bg = try mesh_shader.createBindGroup(
        0,
        allocator,
        gpu_context,
        .{
            .world = world_ub.binding(),
            .shadow_map = shadow_map_view,
            .shadow_smp = shadow_smp,
        },
    );
    defer c.wgpuBindGroupRelease(frame_bg);

    // Two materials sharing render_pipeline: the sort has to group by pipeline
    // first, then by material bind group within it.
    const checker_bg = try mesh_shader.createBindGroup(
        1,
        allocator,
        gpu_context,
        .{
            .texture = checker_view,
            .smp = sampler,
        },
    );
    defer c.wgpuBindGroupRelease(checker_bg);

    const white_bg = try mesh_shader.createBindGroup(
        1,
        allocator,
        gpu_context,
        .{
            .texture = white_view,
            .smp = sampler,
        },
    );
    defer c.wgpuBindGroupRelease(white_bg);

    const instances_bg = try mesh_shader.createBindGroup(
        2,
        allocator,
        gpu_context,
        .{
            .instances = instance_storage.binding(),
        },
    );
    defer c.wgpuBindGroupRelease(instances_bg);

    const light_bg = try shadow_shader.createBindGroup(
        0,
        allocator,
        gpu_context,
        .{
            .light_vp = dir_light_ub.binding(),
            .instances = instance_storage.binding(),
        },
    );
    defer c.wgpuBindGroupRelease(light_bg);

    const shadow_pipeline = try gpu.createPipelineFromMesh(
        allocator,
        gpu_context,
        shadow_shader,
        cube_mesh,
        &.{},
        .{
            .label = "shadow",
            .depth_stencil_state = .{},
            .depth_format = .depth32_float,
        },
    );
    defer c.wgpuRenderPipelineRelease(shadow_pipeline);

    const render_pipeline = try gpu.createPipelineFromMesh(
        allocator,
        gpu_context,
        mesh_shader,
        cube_mesh,
        &.{},
        .{
            .label = "mesh",
            .color_format = target_surface.format,
            .depth_stencil_state = .{},
            .depth_format = .depth32_float,
            .fragment_entry = "fs",
            .sample_count = 4,
        },
    );
    defer c.wgpuRenderPipelineRelease(render_pipeline);

    const transparent_pipeline = try gpu.createPipelineFromMesh(
        allocator,
        gpu_context,
        mesh_shader,
        cube_mesh,
        &.{},
        .{
            .label = "transparent",
            .color_format = target_surface.format,
            .depth_stencil_state = .{
                .depth_write_enabled = false,
            },
            .depth_format = .depth32_float,
            .fragment_entry = "fs",
            .sample_count = 4,
            .blend = .{
                .color = .{
                    .operation = .add,
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
                .alpha = .{
                    .operation = .add,
                    .src_factor = .one,
                    .dst_factor = .one_minus_src_alpha,
                },
            },
        },
    );
    defer c.wgpuRenderPipelineRelease(transparent_pipeline);




    var depth_texture = gpu.Texture.init(
        gpu_context,
        "depth texture",
        @intCast(width),
        @intCast(height),
        .@"2d",
        .depth32_float,
        .{ .sample_count = 4 },
        .{
            .render_attachment = true,
        },
    );
    defer depth_texture.deinit();

    var depth_view = depth_texture.createView("depth view");
    defer c.wgpuTextureViewRelease(depth_view);

    var msaa_texture = gpu.Texture.init(
        gpu_context,
        "msaa texture",
        @intCast(width),
        @intCast(height),
        .@"2d",
        target_surface.format,
        .{ .sample_count = 4 },
        .{
            .render_attachment = true,
        },
    );
    defer msaa_texture.deinit();

    var msaa_view = msaa_texture.createView("msaa view");
    defer c.wgpuTextureViewRelease(msaa_view);

    dir_light_ub.upload(gpu_context, dir_light.getVPMatrix().toArray());

    var draw_cmds: std.ArrayList(DrawCmd) = .empty;
    defer draw_cmds.deinit(allocator);

    var flat_instances: std.ArrayList(Mesh.Instance) = .empty;
    defer flat_instances.deinit(allocator);

    var batches: std.ArrayList(Batch) = .empty;
    defer batches.deinit(allocator);

    var running = true;
    while (running) {
        draw_cmds.clearRetainingCapacity();

        try draw_cmds.append(
            allocator,
            .{
                .transparent = false,
                .pipeline = @intFromPtr(render_pipeline),
                .material = @intFromPtr(checker_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(2, 0, 0), .rot = std.math.degreesToRadians(30) }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(0, 0, 1, 1).toArray(),
                },
            },
        );

        try draw_cmds.append(
            allocator,
            .{
                .transparent = false,
                .pipeline = @intFromPtr(render_pipeline),
                .material = @intFromPtr(white_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(4, 0, 0), .rot = std.math.degreesToRadians(45) }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(1, 0.5, 0, 1).toArray(),
                },
            },
        );

        try draw_cmds.append(
            allocator,
            .{
                .transparent = true,
                .pipeline = @intFromPtr(transparent_pipeline),
                .material = @intFromPtr(checker_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(0, 0, 0), .rot = std.math.degreesToRadians(15) }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(0, 1, 0, 0.3).toArray(),
                },
            },
        );

        try draw_cmds.append(
            allocator,
            .{
                .transparent = false,
                .pipeline = @intFromPtr(render_pipeline),
                .material = @intFromPtr(checker_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(0, -1, 0), .scale = .init(8, 1, 8) }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(1, 1, 1, 1).toArray(),
                },
            },
        );

        try draw_cmds.append(
            allocator,
            .{
                .transparent = false,
                .pipeline = @intFromPtr(render_pipeline),
                .material = @intFromPtr(white_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(-4, 0, 0), .rot = std.math.degreesToRadians(60) }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(0.6, 0, 1, 1).toArray(),
                },
            },
        );

        try draw_cmds.append(
            allocator,
            .{
                .transparent = true,
                .pipeline = @intFromPtr(transparent_pipeline),
                .material = @intFromPtr(checker_bg),
                .mesh = @intFromPtr(&cube_mesh),
                .instance = .{
                    .model = (CubeInstance{ .pos = .init(-2, 0, 0), .rot = 0 }).modelMatrix().toArray(),
                    .tint = l.Vec4(f32).init(1, 0, 0, 0.3).toArray(),
                },
            },
        );

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

            c.wgpuTextureViewRelease(depth_view);
            depth_texture.deinit();

            depth_texture = gpu.Texture.init(
                gpu_context,
                "depth texture",
                @intCast(width),
                @intCast(height),
                .@"2d",
                .depth32_float,
                .{ .sample_count = 4 },
                .{
                    .render_attachment = true,
                },
            );
            depth_view = depth_texture.createView("depth view");

            c.wgpuTextureViewRelease(msaa_view);
            msaa_texture.deinit();

            msaa_texture = gpu.Texture.init(
                gpu_context,
                "msaa texture",
                @intCast(width),
                @intCast(height),
                .@"2d",
                target_surface.format,
                .{ .sample_count = 4 },
                .{
                    .render_attachment = true,
                },
            );
            msaa_view = msaa_texture.createView("msaa view");

            cam_aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
            cam_proj = l.Mat4x4(f32).perspective(std.math.degreesToRadians(90), cam_aspect, 0.01, 100);
        }

        const view_proj = cam_proj.mul(cam.getViewMatrix());
        world_ub.upload(gpu_context, .{
            .vp_matrix = view_proj.toArray(),
            .light_vp = dir_light.getVPMatrix().toArray(),
            .light_pos = dir_light.pos.toArray(),
            .ambient = dir_light.ambient,
        });

        // Flush: everything is recorded and the camera is final, so order can
        // be decided. Depth is distance along the view direction, read from the
        // model matrix's translation column.
        for (draw_cmds.items) |*cmd| {
            const pos = l.Vec3(f32).init(cmd.instance.model[3][0], cmd.instance.model[3][1], cmd.instance.model[3][2]);
            cmd.depth = pos.sub(cam.pos).dot(cam.forward());
        }

        std.mem.sort(DrawCmd, draw_cmds.items, {}, DrawCmd.lessThan);

        // Flatten: one walk emits the contiguous instance array and the batch
        // list together. A command extends the last batch only if every state
        // key matches -- depth deliberately excluded, it orders but never splits.
        flat_instances.clearRetainingCapacity();
        batches.clearRetainingCapacity();
        for (draw_cmds.items) |cmd| {
            const extends = batches.items.len > 0 and blk: {
                const b = batches.items[batches.items.len - 1];
                break :blk b.transparent == cmd.transparent and
                    b.pipeline == cmd.pipeline and
                    b.material == cmd.material and
                    b.mesh == cmd.mesh;
            };
            if (extends) {
                batches.items[batches.items.len - 1].count += 1;
            } else {
                try batches.append(allocator, .{
                    .transparent = cmd.transparent,
                    .pipeline = cmd.pipeline,
                    .material = cmd.material,
                    .mesh = cmd.mesh,
                    .first = @intCast(flat_instances.items.len),
                    .count = 1,
                });
            }
            try flat_instances.append(allocator, cmd.instance);
        }

        try instance_storage.upload(gpu_context, flat_instances.items);

        const encoder = gpu_context.getEncoder();
        defer c.wgpuCommandEncoderRelease(encoder);

        const color_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(color_view);

        const shadow_pass = gpu.RenderPass.init(encoder, .{
            .depth_stencil_attachment = .{
                .view = shadow_map_view,
            },
        });
        for (batches.items) |batch| {
            if (batch.transparent) break;
            shadow_pass.draw(.{
                .bind_groups = &.{.{ .group = 0, .bind_group = light_bg }},
                .mesh = @as(*const gpu.Mesh, @ptrFromInt(batch.mesh)).*,
                .pipeline = shadow_pipeline,
                .instances = .initCount(batch.first, batch.count),
            });
        }
        shadow_pass.end();

        const rp = gpu.RenderPass.init(
            encoder,
            .{
                .color_attachment = .{
                    .clear_value = .{ .r = 0.05, .g = 0.06, .b = 0.09 },
                    .view = msaa_view,
                    .resolve_target = color_view,
                    .store_op = .discard,
                },
                .depth_stencil_attachment = .{
                    .view = depth_view,
                },
            },
        );
        for (batches.items) |batch| {
            rp.draw(.{
                .bind_groups = &.{
                    .{ .group = 0, .bind_group = frame_bg },
                    .{ .group = 1, .bind_group = @ptrFromInt(batch.material) },
                    .{ .group = 2, .bind_group = instances_bg },
                },
                .mesh = @as(*const gpu.Mesh, @ptrFromInt(batch.mesh)).*,
                .pipeline = @ptrFromInt(batch.pipeline),
                .instances = .initCount(batch.first, batch.count),
            });
        }
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        gpu.waitForNextFrame();
    }
}
