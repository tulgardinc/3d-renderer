const std = @import("std");
const gpu = @import("gpu");
const builtin = @import("builtin");
const c = gpu.c;

const Reflected = @import("InstancedQuad");
const QuadShader = gpu.Shader(Reflected);

const Instance = Reflected.Instance;
const InstanceStorage = QuadShader.Storage.instances;

// --- The point of this sample -------------------------------------------
//
// Everything below is drawn in ONE draw call, from ONE storage array, in a
// fixed instance order. Nothing is sorted on the CPU. What ends up in front
// of what is decided purely by the depth texture.
//
// The scene is a carousel: `card_count` quads orbiting a circle, plus one
// large panel sitting at mid depth. The panel is instance 0, i.e. it is
// rasterized *first*, so a painter's-algorithm renderer would paint it
// underneath every card. With depth testing on, the cards on the far half of
// the orbit are correctly hidden behind it, and the near half is drawn over
// it -- and cards cross each other every frame as they orbit.
//
// The shader (InstancedQuad.wgsl) does `inst.model * vec4(vpos, 0, 1)` with
// no projection matrix, so clip space == NDC and the translation column's z
// component *is* the depth value. WebGPU's NDC z range is [0, 1], and the
// depth attachment clears to 1.0 with `depth_compare = .less`, so smaller z
// is nearer.
//
// Press SPACE (tap, on iOS) to switch to a pipeline with `depth_compare =
// .always` and depth writes off: same buffer, same draw order, no depth
// texture in play. The scene collapses back into "last instance wins" and the
// illusion dies.

const card_count = 14;
const instance_count = card_count + 1; // + the panel

const panel_depth = 0.5;
const orbit_radius = 0.62;
const depth_span = 0.42; // cards sweep panel_depth +/- this

// Winding: the pipeline culls back faces and WebGPU's default front face is
// "ccw" -- but the spec judges winding in *framebuffer* coordinates, whose +y
// points DOWN, while NDC's +y points up. The y-flip between the two reverses
// the apparent order, so a front-facing triangle must be authored CLOCKWISE in
// the y-up space we write vertices in. Reverse any of these triples and the
// quad silently vanishes.
const quad_vertices = [_]f32{
    // x     y     u    v
    -0.5, 0.5, 0.0, 0.0, // 0 tl
    -0.5, -0.5, 0.0, 1.0, // 1 bl
    0.5, -0.5, 1.0, 1.0, // 2 br
    0.5, 0.5, 1.0, 0.0, // 3 tr
};

// The two triangles that were spelled out longhand above. tl and br each
// appear in both, which is the whole point: 4 vertices feed 6 slots. Each
// triple keeps the clockwise-in-y-up order the cull mode demands.
const quad_indices = [_]u16{
    0, 1, 2, // tl, bl, br
    2, 3, 0, // br, tr, tl
};

const checker_texture = [_]u8{
    255, 255, 255, 255, 110, 110, 110, 255,
    110, 110, 110, 255, 255, 255, 255, 255,
};

/// Column-major mat4x4: each inner array is a *column*. Column 3 is the
/// translation, and its z slot is what the depth test ends up comparing.
fn model(tx: f32, ty: f32, tz: f32, scale_x: f32, scale_y: f32, angle: f32) [4][4]f32 {
    const ca = @cos(angle);
    const sa = @sin(angle);
    return .{
        .{ ca * scale_x, sa * scale_x, 0.0, 0.0 },
        .{ -sa * scale_y, ca * scale_y, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ tx, ty, tz, 1.0 },
    };
}

fn fillInstances(out: *[instance_count]Instance, t: f32, aspect: f32) void {
    // Instance 0: the panel. Drawn first, parked at mid depth. Anything the
    // carousel puts behind it must be rejected by the depth test, because
    // draw order alone would let every card paint over it.
    out[0] = .{
        .model = model(0.0, 0.0, panel_depth, 1.15 / aspect, 1.15, 0.0),
        .tint = .{ 0.16, 0.19, 0.30, 1.0 },
    };

    for (0..card_count) |i| {
        const fi = @as(f32, @floatFromInt(i));
        const theta = t * 0.6 + fi * (std.math.tau / @as(f32, card_count));

        // Orbit in the xz plane: cos drives screen x, sin drives depth.
        // sin(theta) == +1 is the nearest point of the orbit.
        const near = @sin(theta);
        const depth = panel_depth - depth_span * near;

        // Fake perspective so the near half reads as near. Purely cosmetic --
        // the occlusion itself comes from `depth` above.
        const size = 0.30 + 0.14 * near;

        // A slow vertical bob, so cards also cross *each other* rather than
        // only crossing the panel.
        const ty = 0.22 * @sin(t * 0.9 + fi * 0.7);

        const hue = fi / @as(f32, card_count) * std.math.tau;

        out[i + 1] = .{
            .model = model(
                orbit_radius * @cos(theta) / aspect,
                ty,
                depth,
                size / aspect,
                size,
                0.25 * @sin(t * 0.7 + fi),
            ),
            .tint = .{
                0.5 + 0.5 * @sin(hue),
                0.5 + 0.5 * @sin(hue + 2.094),
                0.5 + 0.5 * @sin(hue + 4.188),
                1.0,
            },
        };
    }
}

// --- Browser plumbing ----------------------------------------------------
//
// Zig 0.16.0's std.Io.Threaded does not compile for wasm32-emscripten (the
// emscripten W.STOPSIG shim returns the wrong type), and std.debug reaches for
// exactly that io to write to stderr. So on web every std path that would touch
// stderr -- logging, panicking, and the error trace std.start dumps when main
// returns an error -- has to be replaced with one that goes to the JS console.

/// Emscripten's console bridge, from emscripten/console.h.
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

// pub so the iOS root (main_ios.zig) can call it -- on iOS the entry point is
// C's main via SDL_RunApp, not Zig's std.start, so this file is not the root
// there and `main` below is never analyzed.
pub fn run() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = if (gpu.is_web)
        // DebugAllocator wants a page allocator underneath it; on wasm the
        // simplest correct answer is emscripten's own malloc.
        std.heap.c_allocator
    else switch (builtin.mode) {
        .Debug => debug_allocator.allocator(),
        else => std.heap.smp_allocator,
    };

    // std.Io.Threaded doesn't compile for wasm32-emscripten, and there would be
    // nothing for it to schedule: the web build never blocks on io at all, it
    // yields through asyncify instead. So the io is never constructed there --
    // and never touched, which is what makes the `undefined` safe.
    var threaded: if (gpu.is_web) void else std.Io.Threaded =
        if (gpu.is_web) {} else .init(allocator, .{});
    defer if (!gpu.is_web) threaded.deinit();
    const io: std.Io = if (gpu.is_web) undefined else threaded.io();

    // Initialize SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDL_FAILED;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "Depth-sorted carousel -- SPACE toggles the depth test",
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
        "checker",
        2,
        2,
        .@"2d",
        .rgba8_unorm,
        .{ .copy_dst = true, .texture_binding = true },
    );
    defer texture.deinit();

    const texel_data = gpu.TexelData{
        .data = &checker_texture,
        .format = .rgba8_sint,
        .height = 2,
        .width = 2,
    };
    texture.writeTexture(gpu_context, texel_data, .{});

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
        instance_count,
        .{ .label = "carousel instances" },
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
        .{ .vertex = true, .copy_dst = true },
    );

    const index_buffer = try gpu.createBuffer(
        gpu_context,
        std.mem.sliceAsBytes(&quad_indices),
        "index buffer",
        .{ .index = true, .copy_dst = true },
    );

    const quad_mesh: gpu.Mesh = .{
        // Vertices in the buffer (4), not slots drawn (6) -- the index count
        // drives the draw now.
        .vertex_count = 4,
        .indices = .{
            .buffer = index_buffer,
            .format = .u16,
            .index_count = quad_indices.len,
        },
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

    // depth16 is all the precision this scene needs -- except on the iOS
    // *simulator*, whose Metal implementation doesn't support Depth16Unorm (a
    // documented Metal-simulator gap; real devices are fine). Nothing fails
    // validation there either: the depth test just reads garbage and rejects
    // every fragment, leaving a clear-color screen.
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

    // Two pipelines over the identical mesh/bind groups. The only difference
    // is the depth-stencil state, so toggling between them isolates exactly
    // what the depth texture contributes.
    const depth_pipeline = try gpu.createPipelineFromMesh(
        Reflected,
        allocator,
        gpu_context,
        quad_mesh,
        &.{},
        &.{ material_group.layout, instance_group.layout },
        .{
            .label = "quads (depth tested)",
            .color_format = target_surface.format,
            .depth_format = depth_format,
            .depth_stencil_state = .{
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
        },
    );

    const no_depth_pipeline = try gpu.createPipelineFromMesh(
        Reflected,
        allocator,
        gpu_context,
        quad_mesh,
        &.{},
        &.{ material_group.layout, instance_group.layout },
        .{
            .label = "quads (draw order only)",
            .color_format = target_surface.format,
            // The attachment is still bound, so the pipeline must still
            // declare the format -- it just never tests or writes.
            .depth_format = depth_format,
            .depth_stencil_state = .{
                .depth_write_enabled = false,
                .depth_compare = .always,
            },
        },
    );

    const bind_groups: []const gpu.BindGroup = &.{ material_group.group, instance_group.group };

    const depth_tested: gpu.DrawObject = .{
        .bind_groups = bind_groups,
        .mesh = quad_mesh,
        .pipeline = depth_pipeline,
        .instances = .initCount(instance_count),
    };

    const draw_order_only: gpu.DrawObject = .{
        .bind_groups = bind_groups,
        .mesh = quad_mesh,
        .pipeline = no_depth_pipeline,
        .instances = .initCount(instance_count),
    };

    var instance_data: [instance_count]Instance = undefined;
    var frame: u32 = 0;
    var depth_enabled = true;

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_SPACE and !event.key.repeat) {
                        depth_enabled = !depth_enabled;
                        std.log.info(
                            "depth test: {s}",
                            .{if (depth_enabled) "on" else "off (draw order only)"},
                        );
                    }
                },
                // Touch stands in for SPACE on iOS. Comptime-gated: macOS
                // trackpads also emit finger events, which would make every
                // trackpad touch toggle the depth test on desktop.
                c.SDL_EVENT_FINGER_DOWN => if (comptime builtin.os.tag == .ios) {
                    depth_enabled = !depth_enabled;
                    std.log.info(
                        "depth test: {s}",
                        .{if (depth_enabled) "on" else "off (draw order only)"},
                    );
                },
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

            // The depth attachment has to match the color attachment's size,
            // so it is rebuilt with the swapchain -- and the old one released.
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

        // Frame-count time, assuming a 60Hz display. The loop now paces on the
        // display itself, so this runs fast on anything quicker -- it wants a
        // measured delta rather than a constant.
        const t = @as(f32, @floatFromInt(frame)) * 0.016;
        frame +%= 1;

        fillInstances(&instance_data, t, aspect);
        try instance_storage.upload(gpu_context, &instance_data);

        const target_texture_view = try target_surface.getCurrentView();
        defer c.wgpuTextureViewRelease(target_texture_view);

        const rp = gpu.RenderPass.init(
            encoder,
            target_texture_view,
            .{
                .color_attachment = .{ .clear_value = .{ .r = 0.05, .g = 0.05, .b = 0.07 } },
                // Clearing to 1.0 (the far plane) each frame is what makes
                // `.less` mean "nearer than anything drawn so far".
                .depth_stencil_attachment = .{
                    .view = depth_view,
                    .depth_clear_value = 1.0,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                },
            },
        );
        rp.draw(if (depth_enabled) depth_tested else draw_order_only);
        rp.end();

        const buffer = gpu.finishEncoder(encoder);

        gpu_context.submitCommands(&.{buffer});

        try target_surface.present();

        gpu.waitForNextFrame();
    }
}
