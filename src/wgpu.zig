const std = @import("std");
const c = @import("main.zig").c;

pub extern fn z_WGPU_DEVICE_DESCRIPTOR_INIT() c.WGPUDeviceDescriptor;
pub extern fn z_WGPU_REQUEST_ADAPTER_OPTIONS_INIT() c.WGPURequestAdapterOptions;
pub extern fn z_WGPU_LIMITS_INIT() c.WGPULimits;
pub extern fn z_WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT() c.WGPUCommandEncoderDescriptor;
pub extern fn z_WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT() c.WGPUCommandBufferDescriptor;
pub extern fn z_WGPU_SURFACE_CONFIGURATION_INIT() c.WGPUSurfaceConfiguration;
pub extern fn z_WGPU_SURFACE_CAPABILITIES_INIT() c.WGPUSurfaceCapabilities;
pub extern fn z_WGPU_SURFACE_TEXTURE_INIT() c.WGPUSurfaceTexture;
pub extern fn z_WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT() c.WGPUTextureViewDescriptor;
pub extern fn z_WGPU_RENDER_PASS_DESCRIPTOR_INIT() c.WGPURenderPassDescriptor;
pub extern fn z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT() c.WGPURenderPassColorAttachment;

pub fn wgpuStringToString(sv: *const c.WGPUStringView) []const u8 {
    if (sv.data == null) {
        return &.{};
    }
    if (sv.length != c.WGPU_STRLEN) {
        return sv.data[0..sv.length];
    }
    return std.mem.span(sv.data);
}

pub fn toWGPUString(str: []const u8) c.WGPUStringView {
    return .{ .data = @ptrCast(str), .length = str.len };
}

pub fn getInstance() !c.WGPUInstance {
    const instance = c.wgpuCreateInstance(&.{});
    return instance orelse {
        std.log.err("failed to init WebGPU", .{});
        return error.Failed;
    };
}

pub fn requestAdapterSync(instance: c.WGPUInstance, surface: c.WGPUSurface) !c.WGPUAdapter {
    const CallbackData = struct {
        adapter: ?c.WGPUAdapter = null,
        done: bool = false,

        const Self = @This();

        pub fn func(
            status: c.WGPURequestAdapterStatus,
            adapter: c.WGPUAdapter,
            message: c.WGPUStringView,
            user_data_p: ?*anyopaque,
            _: ?*anyopaque,
        ) callconv(.c) void {
            const data_p: *Self = @ptrCast(@alignCast(user_data_p));

            if (status == c.WGPURequestAdapterStatus_Success) {
                data_p.adapter = adapter;
            } else {
                std.log.err("Failed to get adapter: {s}", .{wgpuStringToString(&message)});
            }
            data_p.done = true;
        }
    };
    var cb_data: CallbackData = .{};
    const cb = CallbackData.func;

    const cb_info: c.WGPURequestAdapterCallbackInfo = .{
        .callback = &cb,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .userdata1 = @ptrCast(@alignCast(&cb_data)),
    };

    var options = z_WGPU_REQUEST_ADAPTER_OPTIONS_INIT();
    options.compatibleSurface = surface;
    _ = c.wgpuInstanceRequestAdapter(instance, &options, cb_info);

    c.wgpuInstanceProcessEvents(instance);

    while (!cb_data.done) {
        std.Thread.sleep(200);
        c.wgpuInstanceProcessEvents(instance);
    }

    return cb_data.adapter orelse {
        std.log.err("failed to get adapter", .{});
        return error.Failed;
    };
}

pub fn requestDeviceSync(instance: c.WGPUInstance, adapter: c.WGPUAdapter) !c.WGPUDevice {
    const CallbackData = struct {
        device: ?c.WGPUDevice = null,
        done: bool = false,

        const Self = @This();

        pub fn func(
            status: c.WGPURequestDeviceStatus,
            device: c.WGPUDevice,
            message: c.WGPUStringView,
            user_data_p: ?*anyopaque,
            _: ?*anyopaque,
        ) callconv(.c) void {
            const data_p: *Self = @ptrCast(@alignCast(user_data_p));

            if (status == c.WGPURequestDeviceStatus_Success) {
                data_p.device = device;
            } else {
                std.log.err("Failed to get device: {s}", .{wgpuStringToString(&message)});
            }
            data_p.done = true;
        }
    };
    var cb_data: CallbackData = .{};
    const cb = CallbackData.func;

    const cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .callback = &cb,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .userdata1 = @ptrCast(@alignCast(&cb_data)),
    };

    _ = c.wgpuAdapterRequestDevice(adapter, &z_WGPU_DEVICE_DESCRIPTOR_INIT(), cb_info);

    c.wgpuInstanceProcessEvents(instance);

    while (!cb_data.done) {
        std.Thread.sleep(200);
        c.wgpuInstanceProcessEvents(instance);
    }

    return cb_data.device orelse {
        std.log.err("failed to get device", .{});
        return error.Failed;
    };
}

pub fn getEncoder(device: c.WGPUDevice) c.WGPUCommandEncoder {
    var desc = z_WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT();
    desc.label = toWGPUString("command encoder");
    return c.wgpuDeviceCreateCommandEncoder(device, &desc);
}

pub fn getCommandBuffer(encoder: c.WGPUCommandEncoder) c.WGPUCommandBuffer {
    var desc = z_WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT();
    desc.label = toWGPUString("command buffer");
    return c.wgpuCommandEncoderFinish(encoder, &desc);
}

pub fn submitCommand(queue: c.WGPUQueue, commands: []const c.WGPUCommandBuffer) void {
    c.wgpuQueueSubmit(queue, commands.len, @ptrCast(commands));
    for (commands) |command| {
        c.wgpuCommandBufferRelease(command);
    }
}

pub fn getNextSurfaceView(surface: c.WGPUSurface) !c.WGPUTextureView {
    var surface_texture = z_WGPU_SURFACE_TEXTURE_INIT();
    c.wgpuSurfaceGetCurrentTexture(surface, &surface_texture);
    if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
        surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
    {
        return error.FailedToGetTexture;
    }

    var view_descriptor = z_WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT();
    view_descriptor.label = toWGPUString("Surface Texture View");
    view_descriptor.dimension = c.WGPUTextureViewDimension_2D;
    const target_view = c.wgpuTextureCreateView(
        surface_texture.texture,
        &view_descriptor,
    );
    return target_view;
}

const GPUContext = struct {
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    const Self = @This();

    pub fn initSync(surface: c.WGPUSurface) !Self {
        const instance = try getInstance();
        const adapter = try requestAdapterSync(instance, surface);
        const device = try requestDeviceSync(instance, adapter);
        const queue = c.wgpuDeviceGetQueue(device);

        return .{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Self) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuInstanceRelease(self.instance);
    }
};

const SurfaceRenderer = struct {
    surface: c.WGPUSurface,
    gpu_context: *GPUContext,

    const Self = @This();

    pub fn init(
        surface: c.WGPUSurface,
        gpu_context: *GPUContext,
        width: u32,
        height: u32,
    ) Self {
        var config = z_WGPU_SURFACE_CONFIGURATION_INIT();
        config.width = width;
        config.height = height;
        config.device = gpu_context.device;
        var surface_capabilities = z_WGPU_SURFACE_CAPABILITIES_INIT();
        _ = c.wgpuSurfaceGetCapabilities(
            surface,
            gpu_context.adapter,
            &surface_capabilities,
        );
        config.format = surface_capabilities.formats[0];
        c.wgpuSurfaceCapabilitiesFreeMembers(surface_capabilities);
        config.presentMode = c.WGPUPresentMode_Fifo;
        config.alphaMode = c.WGPUCompositeAlphaMode_Auto;

        // configure the surface
        c.wgpuSurfaceConfigure(surface, &config);

        return .{
            .surface = surface,
            .gpu_context = gpu_context,
        };
    }

    pub fn beginFrame(self: Self) Frame {
        return Frame.init(
            self.gpu_context.device,
            self.surface,
        );
    }

    pub fn endFrame(self: *Self, frame: *Frame) void {
        const command_buffer = getCommandBuffer(frame.encoder);
        submitCommand(self.gpu_context.queue, &.{command_buffer});

        _ = c.wgpuSurfacePresent(self.surface);

        frame.deinit();
    }

    pub fn deinit(self: *Self) void {
        c.wgpuSurfaceRelease(self.surface);
    }
};

const Frame = struct {
    encoder: c.WGPUCommandEncoder,
    target_view: c.WGPUTextureView,

    const Self = @This();

    pub fn init(
        device: c.WGPUDevice,
        surface: c.WGPUSurface,
    ) Self {
        return .{
            .encoder = getEncoder(device),
            .target_view = getNextSurfaceView(surface),
        };
    }

    pub fn beginRenderPass(self: *Self) RenderPass {
        return RenderPass.init(self.encoder, self.target_view);
    }

    pub fn deinit(self: *Self) void {
        c.wgpuCommandEncoderRelease(self.encoder);
        c.wgpuTextureViewRelease(self.target_view);
    }
};

const RenderPass = struct {
    render_pass: c.WGPURenderPassEncoder,

    const Self = @This();

    pub fn init(encoder: c.WGPUCommandEncoder, target_view: c.WGPUTextureView) Self {
        var render_pass_desc = z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();

        // color attachement
        var color_attachment = z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
        color_attachment.loadOp = c.WGPULoadOp_Clear;
        color_attachment.storeOp = c.WGPUStoreOp_Store;
        color_attachment.clearValue = c.WGPUColor{ .a = 1.0, .r = 0.8, .g = 0.0, .b = 1.0 };
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;
        color_attachment.view = target_view;

        const render_pass_encoder = c.wgpuCommandEncoderBeginRenderPass(
            encoder,
            &render_pass_desc,
        );

        return .{
            .render_pass = render_pass_encoder,
        };
    }

    pub fn end(self: *Self) void {
        c.wgpuRenderPassEncoderEnd(self.render_pass);
        c.wgpuRenderPassEncoderRelease(self.render_pass);
    }
};
