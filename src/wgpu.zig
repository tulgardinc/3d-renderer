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
pub extern fn z_WGPU_SHADER_MODULE_DESCRIPTOR_INIT() c.WGPUShaderModuleDescriptor;
pub extern fn z_WGPU_SHADER_SOURCE_WGSL_INIT() c.WGPUShaderSourceWGSL;
pub extern fn z_WGPU_BUFFER_DESCRIPTOR_INIT() c.WGPUBufferDescriptor;
pub extern fn z_WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT() c.WGPURenderPipelineDescriptor;
pub extern fn z_WGPU_VERTEX_STATE_INIT() c.WGPUVertexState;
pub extern fn z_WGPU_FRAGMENT_STATE_INIT() c.WGPUFragmentState;
pub extern fn z_WGPU_PRIMITIVE_STATE_INIT() c.WGPUPrimitiveState;
pub extern fn z_WGPU_DEPTH_STENCIL_STATE_INIT() c.WGPUDepthStencilState;
pub extern fn z_WGPU_MULTISAMPLE_STATE_INIT() c.WGPUMultisampleState;
pub extern fn z_WGPU_COLOR_TARGET_STATE_INIT() c.WGPUColorTargetState;
pub extern fn z_WGPU_VERTEX_BUFFER_LAYOUT_INIT() c.WGPUVertexBufferLayout;
pub extern fn z_WGPU_VERTEX_ATTRIBUTE_INIT() c.WGPUVertexAttribute;
pub extern fn z_WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT() c.WGPUBindGroupLayoutEntry;
pub extern fn z_WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT() c.WGPUBindGroupLayoutDescriptor;
pub extern fn z_WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT() c.WGPUPipelineLayoutDescriptor;
pub extern fn z_WGPU_BLEND_STATE_INIT() c.WGPUBlendState;
pub extern fn z_WGPU_BLEND_COMPONENT_INIT() c.WGPUBlendComponent;
pub extern fn z_WGPU_BUFFER_BINDING_LAYOUT_INIT() c.WGPUBufferBindingLayout;
pub extern fn z_WGPU_SAMPLER_BINDING_LAYOUT_INIT() c.WGPUSamplerBindingLayout;
pub extern fn z_WGPU_TEXTURE_BINDING_LAYOUT_INIT() c.WGPUTextureBindingLayout;
pub extern fn z_WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT() c.WGPUStorageTextureBindingLayout;
pub extern fn z_WGPU_STENCIL_FACE_STATE_INIT() c.WGPUStencilFaceState;

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

pub inline fn toWGPUBool(val: bool) c.WGPUBool {
    if (val) return c.WGPU_TRUE;
    return c.WGPU_FALSE;
}

pub inline fn toWGPUOptBool(val: bool) c.WGPUOptionalBool {
    if (val) return c.WGPU_TRUE;
    return c.WGPU_FALSE;
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

pub const TextureFormat = enum(c.WGPUTextureFormat) {
    undefined = c.WGPUTextureFormat_Undefined,
    r8_unorm = c.WGPUTextureFormat_R8Unorm,
    r8_snorm = c.WGPUTextureFormat_R8Snorm,
    r8_uint = c.WGPUTextureFormat_R8Uint,
    r8_sint = c.WGPUTextureFormat_R8Sint,
    r16_unorm = c.WGPUTextureFormat_R16Unorm,
    r16_snorm = c.WGPUTextureFormat_R16Snorm,
    r16_uint = c.WGPUTextureFormat_R16Uint,
    r16_sint = c.WGPUTextureFormat_R16Sint,
    r16_float = c.WGPUTextureFormat_R16Float,
    rg8_unorm = c.WGPUTextureFormat_RG8Unorm,
    rg8_snorm = c.WGPUTextureFormat_RG8Snorm,
    rg8_uint = c.WGPUTextureFormat_RG8Uint,
    rg8_sint = c.WGPUTextureFormat_RG8Sint,
    r32_float = c.WGPUTextureFormat_R32Float,
    r32_uint = c.WGPUTextureFormat_R32Uint,
    r32_sint = c.WGPUTextureFormat_R32Sint,
    rg16_unorm = c.WGPUTextureFormat_RG16Unorm,
    rg16_snorm = c.WGPUTextureFormat_RG16Snorm,
    rg16_uint = c.WGPUTextureFormat_RG16Uint,
    rg16_sint = c.WGPUTextureFormat_RG16Sint,
    rg16_float = c.WGPUTextureFormat_RG16Float,
    rgba8_unorm = c.WGPUTextureFormat_RGBA8Unorm,
    rgba8_unorm_srgb = c.WGPUTextureFormat_RGBA8UnormSrgb,
    rgba8_snorm = c.WGPUTextureFormat_RGBA8Snorm,
    rgba8_uint = c.WGPUTextureFormat_RGBA8Uint,
    rgba8_sint = c.WGPUTextureFormat_RGBA8Sint,
    bgra8_unorm = c.WGPUTextureFormat_BGRA8Unorm,
    bgra8_unorm_srgb = c.WGPUTextureFormat_BGRA8UnormSrgb,
    rgb10a2_uint = c.WGPUTextureFormat_RGB10A2Uint,
    rgb10a2_unorm = c.WGPUTextureFormat_RGB10A2Unorm,
    rg11b10_ufloat = c.WGPUTextureFormat_RG11B10Ufloat,
    rgb9e5_ufloat = c.WGPUTextureFormat_RGB9E5Ufloat,
    rg32_float = c.WGPUTextureFormat_RG32Float,
    rg32_uint = c.WGPUTextureFormat_RG32Uint,
    rg32_sint = c.WGPUTextureFormat_RG32Sint,
    rgba16_unorm = c.WGPUTextureFormat_RGBA16Unorm,
    rgba16_snorm = c.WGPUTextureFormat_RGBA16Snorm,
    rgba16_uint = c.WGPUTextureFormat_RGBA16Uint,
    rgba16_sint = c.WGPUTextureFormat_RGBA16Sint,
    rgba16_float = c.WGPUTextureFormat_RGBA16Float,
    rgba32_float = c.WGPUTextureFormat_RGBA32Float,
    rgba32_uint = c.WGPUTextureFormat_RGBA32Uint,
    rgba32_sint = c.WGPUTextureFormat_RGBA32Sint,
    stencil8 = c.WGPUTextureFormat_Stencil8,
    depth16_unorm = c.WGPUTextureFormat_Depth16Unorm,
    depth24_plus = c.WGPUTextureFormat_Depth24Plus,
    depth24_plus_stencil8 = c.WGPUTextureFormat_Depth24PlusStencil8,
    depth32_float = c.WGPUTextureFormat_Depth32Float,
    depth32_float_stencil8 = c.WGPUTextureFormat_Depth32FloatStencil8,
    bc1_rgba_unorm = c.WGPUTextureFormat_BC1RGBAUnorm,
    bc1_rgba_unorm_srgb = c.WGPUTextureFormat_BC1RGBAUnormSrgb,
    bc2_rgba_unorm = c.WGPUTextureFormat_BC2RGBAUnorm,
    bc2_rgba_unorm_srgb = c.WGPUTextureFormat_BC2RGBAUnormSrgb,
    bc3_rgba_unorm = c.WGPUTextureFormat_BC3RGBAUnorm,
    bc3_rgba_unorm_srgb = c.WGPUTextureFormat_BC3RGBAUnormSrgb,
    bc4_r_unorm = c.WGPUTextureFormat_BC4RUnorm,
    bc4_r_snorm = c.WGPUTextureFormat_BC4RSnorm,
    bc5_rg_unorm = c.WGPUTextureFormat_BC5RGUnorm,
    bc5_rg_snorm = c.WGPUTextureFormat_BC5RGSnorm,
    bc6h_rgb_ufloat = c.WGPUTextureFormat_BC6HRGBUfloat,
    bc6h_rgb_float = c.WGPUTextureFormat_BC6HRGBFloat,
    bc7_rgba_unorm = c.WGPUTextureFormat_BC7RGBAUnorm,
    bc7_rgba_unorm_srgb = c.WGPUTextureFormat_BC7RGBAUnormSrgb,
    etc2_rgb8_unorm = c.WGPUTextureFormat_ETC2RGB8Unorm,
    etc2_rgb8_unorm_srgb = c.WGPUTextureFormat_ETC2RGB8UnormSrgb,
    etc2_rgb8a1_unorm = c.WGPUTextureFormat_ETC2RGB8A1Unorm,
    etc2_rgb8a1_unorm_srgb = c.WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
    etc2_rgba8_unorm = c.WGPUTextureFormat_ETC2RGBA8Unorm,
    etc2_rgba8_unorm_srgb = c.WGPUTextureFormat_ETC2RGBA8UnormSrgb,
    eac_r11_unorm = c.WGPUTextureFormat_EACR11Unorm,
    eac_r11_snorm = c.WGPUTextureFormat_EACR11Snorm,
    eac_rg11_unorm = c.WGPUTextureFormat_EACRG11Unorm,
    eac_rg11_snorm = c.WGPUTextureFormat_EACRG11Snorm,
    astc4x4_unorm = c.WGPUTextureFormat_ASTC4x4Unorm,
    astc4x4_unorm_srgb = c.WGPUTextureFormat_ASTC4x4UnormSrgb,
    astc5x4_unorm = c.WGPUTextureFormat_ASTC5x4Unorm,
    astc5x4_unorm_srgb = c.WGPUTextureFormat_ASTC5x4UnormSrgb,
    astc5x5_unorm = c.WGPUTextureFormat_ASTC5x5Unorm,
    astc5x5_unorm_srgb = c.WGPUTextureFormat_ASTC5x5UnormSrgb,
    astc6x5_unorm = c.WGPUTextureFormat_ASTC6x5Unorm,
    astc6x5_unorm_srgb = c.WGPUTextureFormat_ASTC6x5UnormSrgb,
    astc6x6_unorm = c.WGPUTextureFormat_ASTC6x6Unorm,
    astc6x6_unorm_srgb = c.WGPUTextureFormat_ASTC6x6UnormSrgb,
    astc8x5_unorm = c.WGPUTextureFormat_ASTC8x5Unorm,
    astc8x5_unorm_srgb = c.WGPUTextureFormat_ASTC8x5UnormSrgb,
    astc8x6_unorm = c.WGPUTextureFormat_ASTC8x6Unorm,
    astc8x6_unorm_srgb = c.WGPUTextureFormat_ASTC8x6UnormSrgb,
    astc8x8_unorm = c.WGPUTextureFormat_ASTC8x8Unorm,
    astc8x8_unorm_srgb = c.WGPUTextureFormat_ASTC8x8UnormSrgb,
    astc10x5_unorm = c.WGPUTextureFormat_ASTC10x5Unorm,
    astc10x5_unorm_srgb = c.WGPUTextureFormat_ASTC10x5UnormSrgb,
    astc10x6_unorm = c.WGPUTextureFormat_ASTC10x6Unorm,
    astc10x6_unorm_srgb = c.WGPUTextureFormat_ASTC10x6UnormSrgb,
    astc10x8_unorm = c.WGPUTextureFormat_ASTC10x8Unorm,
    astc10x8_unorm_srgb = c.WGPUTextureFormat_ASTC10x8UnormSrgb,
    astc10x10_unorm = c.WGPUTextureFormat_ASTC10x10Unorm,
    astc10x10_unorm_srgb = c.WGPUTextureFormat_ASTC10x10UnormSrgb,
    astc12x10_unorm = c.WGPUTextureFormat_ASTC12x10Unorm,
    astc12x10_unorm_srgb = c.WGPUTextureFormat_ASTC12x10UnormSrgb,
    astc12x12_unorm = c.WGPUTextureFormat_ASTC12x12Unorm,
    astc12x12_unorm_srgb = c.WGPUTextureFormat_ASTC12x12UnormSrgb,
    r8bg8_biplanar420_unorm = c.WGPUTextureFormat_R8BG8Biplanar420Unorm,
    r10x6bg10x6_biplanar420_unorm = c.WGPUTextureFormat_R10X6BG10X6Biplanar420Unorm,
    r8bg8a8_triplanar420_unorm = c.WGPUTextureFormat_R8BG8A8Triplanar420Unorm,
    r8bg8_biplanar422_unorm = c.WGPUTextureFormat_R8BG8Biplanar422Unorm,
    r8bg8_biplanar444_unorm = c.WGPUTextureFormat_R8BG8Biplanar444Unorm,
    r10x6bg10x6_biplanar422_unorm = c.WGPUTextureFormat_R10X6BG10X6Biplanar422Unorm,
    r10x6bg10x6_biplanar444_unorm = c.WGPUTextureFormat_R10X6BG10X6Biplanar444Unorm,
    external = c.WGPUTextureFormat_External,
};

pub const GPUInstance = struct {
    webgpu_instance: c.WGPUInstance,

    const Self = @This();

    pub fn init() !Self {
        return .{ .webgpu_instance = try getInstance() };
    }

    pub fn deinit(self: *Self) void {
        c.wgpuInstanceRelease(self.webgpu_instance);
    }
};

pub const GPUContext = struct {
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    const Self = @This();

    pub fn initSync(instance: c.WGPUInstance, surface: c.WGPUSurface) !Self {
        const adapter = try requestAdapterSync(instance, surface);
        const device = try requestDeviceSync(instance, adapter);
        return .{
            .adapter = adapter,
            .device = device,
            .queue = c.wgpuDeviceGetQueue(device),
        };
    }

    pub fn submitCommands(self: *Self, commandBuffer: []const c.WGPUCommandBuffer) void {
        submitCommand(self.queue, commandBuffer);
    }

    pub fn deinit(self: *Self) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
    }
};

pub const Surface = struct {
    surface: c.WGPUSurface,
    format: TextureFormat,
    gpu_context: *const GPUContext,

    const Self = @This();

    pub fn init(
        surface: c.WGPUSurface,
        gpu_context: *const GPUContext,
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
            .format = @enumFromInt(config.format),
            .gpu_context = gpu_context,
        };
    }

    pub fn beginFrame(self: Self) !Frame {
        return try Frame.init(
            self.gpu_context.device,
            try getNextSurfaceView(self.surface),
        );
    }

    pub fn deinit(self: *Self) void {
        c.wgpuSurfaceRelease(self.surface);
    }
};

pub const Frame = struct {
    encoder: c.WGPUCommandEncoder,
    target_view: c.WGPUTextureView,

    const Self = @This();

    pub fn init(
        device: c.WGPUDevice,
        view: c.WGPUTextureView,
    ) !Self {
        return .{
            .encoder = getEncoder(device),
            .target_view = view,
        };
    }

    pub fn beginRenderPass(self: *Self) RenderPass {
        return RenderPass.init(self.encoder, self.target_view);
    }

    pub fn end(self: *Self) c.WGPUCommandBuffer {
        return getCommandBuffer(self.encoder);
    }

    pub fn deinit(self: *Self) void {
        c.wgpuCommandEncoderRelease(self.encoder);
        c.wgpuTextureViewRelease(self.target_view);
    }
};

pub const RenderPass = struct {
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

    pub fn deinit(self: *Self) void {
        c.wgpuRenderPassEncoderEnd(self.render_pass);
        c.wgpuRenderPassEncoderRelease(self.render_pass);
    }
};

pub const VertexFormat = enum(c.WGPUVertexFormat) {
    undefined = 0,
    u8 = c.WGPUVertexFormat_Uint8,
    u8x2 = c.WGPUVertexFormat_Uint8x2,
    u8x4 = c.WGPUVertexFormat_Uint8x4,
    i8 = c.WGPUVertexFormat_Sint8,
    i8x2 = c.WGPUVertexFormat_Sint8x2,
    i8x4 = c.WGPUVertexFormat_Sint8x4,
    unorm8 = c.WGPUVertexFormat_Unorm8,
    unorm8x2 = c.WGPUVertexFormat_Unorm8x2,
    unorm8x4 = c.WGPUVertexFormat_Unorm8x4,
    snorm8 = c.WGPUVertexFormat_Snorm8,
    snorm8x2 = c.WGPUVertexFormat_Snorm8x2,
    snorm8x4 = c.WGPUVertexFormat_Snorm8x4,
    u16 = c.WGPUVertexFormat_Uint16,
    u16x2 = c.WGPUVertexFormat_Uint16x2,
    u16x4 = c.WGPUVertexFormat_Uint16x4,
    i16 = c.WGPUVertexFormat_Sint16,
    i16x2 = c.WGPUVertexFormat_Sint16x2,
    i16x4 = c.WGPUVertexFormat_Sint16x4,
    unorm16 = c.WGPUVertexFormat_Unorm16,
    unorm16x2 = c.WGPUVertexFormat_Unorm16x2,
    unorm16x4 = c.WGPUVertexFormat_Unorm16x4,
    snorm16 = c.WGPUVertexFormat_Snorm16,
    snorm16x2 = c.WGPUVertexFormat_Snorm16x2,
    snorm16x4 = c.WGPUVertexFormat_Snorm16x4,
    f16 = c.WGPUVertexFormat_Float16,
    f16x2 = c.WGPUVertexFormat_Float16x2,
    f16x4 = c.WGPUVertexFormat_Float16x4,
    f32 = c.WGPUVertexFormat_Float32,
    f32x2 = c.WGPUVertexFormat_Float32x2,
    f32x3 = c.WGPUVertexFormat_Float32x3,
    f32x4 = c.WGPUVertexFormat_Float32x4,
    u32 = c.WGPUVertexFormat_Uint32,
    u32x2 = c.WGPUVertexFormat_Uint32x2,
    u32x3 = c.WGPUVertexFormat_Uint32x3,
    u32x4 = c.WGPUVertexFormat_Uint32x4,
    i32 = c.WGPUVertexFormat_Sint32,
    i32x2 = c.WGPUVertexFormat_Sint32x2,
    i32x3 = c.WGPUVertexFormat_Sint32x3,
    i32x4 = c.WGPUVertexFormat_Sint32x4,
    unorm10_10_10_2 = c.WGPUVertexFormat_Unorm10_10_10_2,
    unorm8x4bgra = c.WGPUVertexFormat_Unorm8x4BGRA,
};

pub const BindingType = union(enum) {
    buffer: BufferBT,
    sampler: SamplerBT,
    texture: TextureBindingInfo,
    storage_texture: StorageTextureBindingInfo,

    const BufferBT = enum(c.WGPUBufferBindingType) { uniform = c.WGPUBufferBindingType_Uniform, storage = c.WGPUBufferBindingType_Storage, read_only_storage = c.WGPUBufferBindingType_ReadOnlyStorage };
    const SamplerBT = enum(c.WGPUSamplerBindingType) { filtering = c.WGPUSamplerBindingType_Filtering, non_filtering = c.WGPUSamplerBindingType_NonFiltering, comparison = c.WGPUSamplerBindingType_Comparison };
    const TextureSampleBT = enum(c.WGPUTextureSampleType) { float = c.WGPUTextureSampleType_Float, unfilterable_float = c.WGPUTextureSampleType_UnfilterableFloat, depth = c.WGPUTextureSampleType_Depth, sint = c.WGPUTextureSampleType_Sint, uint = c.WGPUTextureSampleType_Uint };
    const StorageTextureAccess = enum(c.WGPUStorageTextureAccess) {
        write_only = c.WGPUStorageTextureAccess_WriteOnly,
        read_only = c.WGPUStorageTextureAccess_ReadOnly,
        read_write = c.WGPUStorageTextureAccess_ReadWrite,
    };
    const TextureViewDimension = enum(c.WGPUTextureViewDimension) { @"1d" = c.WGPUTextureViewDimension_1D, @"2d" = c.WGPUTextureViewDimension_2D, @"2d_array" = c.WGPUTextureViewDimension_2DArray, cube = c.WGPUTextureViewDimension_Cube, cube_array = c.WGPUTextureViewDimension_CubeArray, @"3d" = c.WGPUTextureViewDimension_3D };
    const TextureBindingInfo = struct {
        sample_type: TextureSampleBT,
        view_dimension: TextureViewDimension,
        multi_sampled: bool,
    };
    const StorageTextureBindingInfo = struct {
        access: StorageTextureAccess,
        format: TextureFormat,
        view_dimension: TextureViewDimension,
    };
};

pub const ShaderStage = struct {
    pub const vertex = c.WGPUShaderStage_Vertex;
    pub const fragment = c.WGPUShaderStage_Fragment;
    pub const compute = c.WGPUShaderStage_Compute;
};

pub const VertexInput = struct {
    location: u32,
    format: VertexFormat,
};

pub const BindEntry = struct {
    binding: u32,
    type: BindingType,
    visibility: c.WGPUShaderStage,
};

const ShaderHandle = enum(u32) { _ };

pub const ShaderManager = struct {
    shaders: std.ArrayList(Shader),
    gpu_context: *const GPUContext,

    pub const Metadata = struct {
        vertex_entry: []const u8,
        fragment_entry: []const u8,
        bind_groups: []const []const BindEntry,
        vertex_inputs: []const VertexInput,
    };

    pub const Shader = struct {
        module: c.WGPUShaderModule,
        metadata: Metadata,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        gpu_context: *const GPUContext,
    ) !Self {
        return .{
            .shaders = try .initCapacity(allocator, 8),
            .gpu_context = gpu_context,
        };
    }

    pub fn createShader(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime source_path: []const u8,
        label: []const u8,
        comptime metadata: Metadata,
    ) !ShaderHandle {
        const source_code = @embedFile(source_path);

        var desc = z_WGPU_SHADER_MODULE_DESCRIPTOR_INIT();
        desc.label = toWGPUString(label);
        var source = z_WGPU_SHADER_SOURCE_WGSL_INIT();
        source.code = toWGPUString(source_code);
        source.chain.next = null;
        source.chain.sType = c.WGPUSType_ShaderSourceWGSL;

        desc.nextInChain = &source.chain;

        try self.shaders.append(allocator, .{
            .module = c.wgpuDeviceCreateShaderModule(self.gpu_context.device, &desc),
            .metadata = metadata,
        });

        return @enumFromInt(self.shaders.items.len - 1);
    }

    pub fn getShader(self: *const Self, handle: ShaderHandle) ?Shader {
        const index = @intFromEnum(handle);
        if (index >= self.shaders.items.len) {
            return null;
        }

        return self.shaders.items[index];
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.shaders.items) |shader| {
            c.wgpuShaderModuleRelease(shader.module);
        }
        self.shaders.deinit(allocator);
    }
};

pub const BufferUsage = struct {
    pub const map_read: c.WGPUBufferUsage = c.WGPUBufferUsage_MapRead;
    pub const map_write: c.WGPUBufferUsage = c.WGPUBufferUsage_MapWrite;
    pub const copy_src: c.WGPUBufferUsage = c.WGPUBufferUsage_CopySrc;
    pub const copy_dst: c.WGPUBufferUsage = c.WGPUBufferUsage_CopyDst;
    pub const index: c.WGPUBufferUsage = c.WGPUBufferUsage_Index;
    pub const vertex: c.WGPUBufferUsage = c.WGPUBufferUsage_Vertex;
    pub const uniform: c.WGPUBufferUsage = c.WGPUBufferUsage_Uniform;
    pub const storage: c.WGPUBufferUsage = c.WGPUBufferUsage_Storage;
    pub const indirect: c.WGPUBufferUsage = c.WGPUBufferUsage_Indirect;
    pub const query_resolve: c.WGPUBufferUsage = c.WGPUBufferUsage_QueryResolve;
    pub const texel_buffer: c.WGPUBufferUsage = c.WGPUBufferUsage_TexelBuffer;
};

pub const ResourceManager = struct {
    // TODO: add generational indices for use after free tracking

    buffers: std.ArrayList(c.WGPUBuffer),
    textures: std.ArrayList(c.WGPUTexture),
    samplers: std.ArrayList(c.WGPUSampler),
    gpu_context: *const GPUContext,

    const Self = @This();

    pub const BufferHandle = enum(u32) { _ };
    pub const TextureHandle = enum(u32) { _ };
    pub const SamplerHandle = enum(u32) { _ };

    pub fn init(allocator: std.mem.Allocator, gpu_context: *const GPUContext) !Self {
        const INITIAL_CAPACITY = 16;
        return .{
            .buffers = try .initCapacity(allocator, INITIAL_CAPACITY),
            .textures = try .initCapacity(allocator, INITIAL_CAPACITY),
            .samplers = try .initCapacity(allocator, INITIAL_CAPACITY),
            .gpu_context = gpu_context,
        };
    }

    pub fn createBuffer(
        self: *Self,
        allocator: std.mem.Allocator,
        contents: []const u8,
        lable: []const u8,
        usage: c.WGPUBufferUsage,
    ) !BufferHandle {
        var desc = z_WGPU_BUFFER_DESCRIPTOR_INIT();
        desc.label = toWGPUString(lable);
        desc.size = contents.len;
        desc.usage = @bitCast(usage);

        const buffer = c.wgpuDeviceCreateBuffer(self.gpu_context.device, &desc);
        try self.buffers.append(allocator, buffer);

        c.wgpuQueueWriteBuffer(self.gpu_context.queue, buffer, 0, contents.ptr, contents.len);

        return @enumFromInt(self.buffers.items.len - 1);
    }

    pub fn getBuffer(self: *const Self, handle: BufferHandle) ?c.WGPUBuffer {
        const index = @intFromEnum(handle);
        if (index > self.buffers.items.len) return null;

        return self.buffers.items[index];
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.buffers.items) |item| {
            c.wgpuBufferRelease(item);
        }

        for (self.textures.items) |item| {
            c.wgpuTextureRelease(item);
        }

        for (self.samplers.items) |item| {
            c.wgpuSamplerRelease(item);
        }

        self.buffers.deinit(allocator);
        self.textures.deinit(allocator);
        self.samplers.deinit(allocator);
    }
};

pub const VertexLayout = struct {
    step_mode: StepMode,
    array_stride: u64,
    attribute_count: u32,
    attributes: [MAX_ATTRIBUTES]VertexAttribute = std.mem.zeroes([MAX_ATTRIBUTES]VertexAttribute),

    const MAX_ATTRIBUTES = 16;

    pub const VertexAttribute = struct {
        format: VertexFormat = .u8,
        offset: u64 = 0,
        shader_location: u32 = 0,
    };

    pub const StepMode = enum(c.WGPUVertexStepMode) {
        undefined = c.WGPUVertexStepMode_Undefined,
        vertex = c.WGPUVertexStepMode_Vertex,
        instance = c.WGPUVertexStepMode_Instance,
    };
};

pub const PipelineCache = struct {
    pipelines: std.AutoHashMapUnmanaged(PipelineDescriptor, Entry),
    default_color_format: TextureFormat,
    default_depth_format: TextureFormat,
    shader_manager: *const ShaderManager,
    gpu_context: *const GPUContext,

    pub const Entry = struct {
        pipeline: c.WGPURenderPipeline,
        bind_group_layouts: [MAX_BIND_GROUP_LAYOUT_COUNT]?c.WGPUBindGroupLayout = .{null} ** MAX_BIND_GROUP_LAYOUT_COUNT,
        shader: ShaderHandle,
    };

    const MAX_BIND_GROUP_LAYOUT_COUNT = 4;
    const MAX_VERTEX_LAYOUT_COUNT = 8;

    pub const PipelineDescriptor = struct {
        color_format: ?TextureFormat = null,
        depth_format: ?TextureFormat = null,
        shader: ShaderHandle,
        vertex_layout_count: u32,
        vertex_layouts: [MAX_VERTEX_LAYOUT_COUNT]VertexLayout = std.mem.zeroes([MAX_VERTEX_LAYOUT_COUNT]VertexLayout),
        primitive_topology: PrimitiveTopology = .triangle_list,
        depth_stencil: ?DepthStencilState = .{
            .depth_write_enabled = true,
            .depth_compare = .less,
        },
        blend: ?BlendState = null,
        cull_mode: CullMode = .back,
    };

    pub const PrimitiveTopology = enum(c.WGPUPrimitiveTopology) {
        undefined = c.WGPUPrimitiveTopology_Undefined,
        point_list = c.WGPUPrimitiveTopology_PointList,
        line_list = c.WGPUPrimitiveTopology_LineList,
        line_strip = c.WGPUPrimitiveTopology_LineStrip,
        triangle_list = c.WGPUPrimitiveTopology_TriangleList,
        triangle_strip = c.WGPUPrimitiveTopology_TriangleStrip,
    };

    pub const CompareFunction = enum(c.WGPUCompareFunction) {
        undefined = c.WGPUCompareFunction_Undefined,
        never = c.WGPUCompareFunction_Never,
        less = c.WGPUCompareFunction_Less,
        equal = c.WGPUCompareFunction_Equal,
        less_equal = c.WGPUCompareFunction_LessEqual,
        greater = c.WGPUCompareFunction_Greater,
        not_equal = c.WGPUCompareFunction_NotEqual,
        greater_equal = c.WGPUCompareFunction_GreaterEqual,
        always = c.WGPUCompareFunction_Always,
    };

    pub const StencilOperation = enum(c.WGPUStencilOperation) {
        undefined = c.WGPUStencilOperation_Undefined,
        keep = c.WGPUStencilOperation_Keep,
        zero = c.WGPUStencilOperation_Zero,
        replace = c.WGPUStencilOperation_Replace,
        invert = c.WGPUStencilOperation_Invert,
        increment_clamp = c.WGPUStencilOperation_IncrementClamp,
        decrement_clamp = c.WGPUStencilOperation_DecrementClamp,
        increment_wrap = c.WGPUStencilOperation_IncrementWrap,
        decrement_wrap = c.WGPUStencilOperation_DecrementWrap,
    };

    pub const StencilFaceState = struct {
        compare: CompareFunction,
        fail_op: StencilOperation,
        depth_fail_op: StencilOperation,
        pass_op: StencilOperation,
    };

    pub const DepthStencilState = struct {
        depth_write_enabled: bool,
        depth_compare: CompareFunction,
        stencil_front: ?StencilFaceState = null,
        stencil_back: ?StencilFaceState = null,
        stencil_read_mask: u32 = 0xFFFFFFFF,
        stencil_write_mask: u32 = 0xFFFFFFFF,
        depth_bias: i32 = 0,

        // ERROR causing problem here
        depth_bias_slope_scale: f32 = 0,
        depth_bias_clamp: f32 = 0,
    };

    pub const BlendOperation = enum(c.WGPUBlendOperation) {
        undefined = c.WGPUBlendOperation_Undefined,
        add = c.WGPUBlendOperation_Add,
        subtract = c.WGPUBlendOperation_Subtract,
        reverse_subtract = c.WGPUBlendOperation_ReverseSubtract,
        min = c.WGPUBlendOperation_Min,
        max = c.WGPUBlendOperation_Max,
    };

    pub const BlendFactor = enum(c.WGPUBlendFactor) {
        undefined = c.WGPUBlendFactor_Undefined,
        zero = c.WGPUBlendFactor_Zero,
        one = c.WGPUBlendFactor_One,
        src = c.WGPUBlendFactor_Src,
        one_minus_src = c.WGPUBlendFactor_OneMinusSrc,
        src_alpha = c.WGPUBlendFactor_SrcAlpha,
        one_minus_src_alpha = c.WGPUBlendFactor_OneMinusSrcAlpha,
        dst = c.WGPUBlendFactor_Dst,
        one_minus_dst = c.WGPUBlendFactor_OneMinusDst,
        dst_alpha = c.WGPUBlendFactor_DstAlpha,
        one_minus_dst_alpha = c.WGPUBlendFactor_OneMinusDstAlpha,
        src_alpha_saturated = c.WGPUBlendFactor_SrcAlphaSaturated,
        constant = c.WGPUBlendFactor_Constant,
        one_minus_constant = c.WGPUBlendFactor_OneMinusConstant,
        src1 = c.WGPUBlendFactor_Src1,
        one_minus_src1 = c.WGPUBlendFactor_OneMinusSrc1,
        src1_alpha = c.WGPUBlendFactor_Src1Alpha,
        one_minus_src1_alpha = c.WGPUBlendFactor_OneMinusSrc1Alpha,
    };

    pub const BlendComponent = struct {
        operation: BlendOperation,
        src_factor: BlendFactor,
        dst_factor: BlendFactor,
    };

    pub const BlendState = struct {
        color: BlendComponent,
        alpha: BlendComponent,
    };

    pub const CullMode = enum(c.WGPUCullMode) {
        undefined = c.WGPUCullMode_Undefined,
        none = c.WGPUCullMode_None,
        front = c.WGPUCullMode_Front,
        back = c.WGPUCullMode_Back,
    };

    const Self = @This();

    pub fn init(gpu_context: *const GPUContext, shader_manager: *const ShaderManager, surface: *const Surface, default_depth_format: TextureFormat) !Self {
        return .{
            .pipelines = .{},
            .gpu_context = gpu_context,
            .shader_manager = shader_manager,
            .default_color_format = surface.format,
            .default_depth_format = default_depth_format,
        };
    }

    // TODO: Handle compute
    pub fn getPipeline(self: *Self, allocator: std.mem.Allocator, label: []const u8, descriptor: PipelineDescriptor) !Entry {
        if (self.pipelines.get(descriptor)) |pipeline| {
            return pipeline;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const shader = self.shader_manager.getShader(descriptor.shader) orelse return error.CouldNotFindShader;

        var desc = z_WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT();
        desc.label = toWGPUString(label);

        var layout_desc = z_WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT();
        var bind_group_layouts = try alloc.alloc(c.WGPUBindGroupLayout, shader.metadata.bind_groups.len);

        layout_desc.label = toWGPUString(label);
        layout_desc.bindGroupLayoutCount = shader.metadata.bind_groups.len;
        for (0..shader.metadata.bind_groups.len) |g_index| {
            var bind_group_desc = z_WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT();
            const entry_count = shader.metadata.bind_groups[g_index].len;
            var entries = try alloc.alloc(c.WGPUBindGroupLayoutEntry, entry_count);
            bind_group_desc.entryCount = entry_count;

            for (0..entry_count) |e_index| {
                const binding = shader.metadata.bind_groups[g_index][e_index];
                var layout_entry = z_WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT();
                layout_entry.binding = binding.binding;
                layout_entry.visibility = binding.visibility;
                switch (binding.type) {
                    .buffer => |buf| {
                        var buffer_layout = z_WGPU_BUFFER_BINDING_LAYOUT_INIT();
                        buffer_layout.type = @intFromEnum(buf);
                        layout_entry.buffer = buffer_layout;
                    },
                    .sampler => |smp| {
                        var sampler_layout = z_WGPU_SAMPLER_BINDING_LAYOUT_INIT();
                        sampler_layout.type = @intFromEnum(smp);
                        layout_entry.sampler = sampler_layout;
                    },
                    .texture => |txt| {
                        layout_entry.texture.sampleType = @intFromEnum(txt.sample_type);
                        layout_entry.texture.viewDimension = @intFromEnum(txt.view_dimension);
                        layout_entry.texture.multisampled = toWGPUBool(txt.multi_sampled);
                    },
                    .storage_texture => |stx| {
                        var strg_texture_layout = z_WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT();
                        strg_texture_layout.access = @intFromEnum(stx.access);
                        strg_texture_layout.format = @intFromEnum(stx.format);
                        strg_texture_layout.viewDimension = @intFromEnum(stx.view_dimension);
                        layout_entry.storageTexture = strg_texture_layout;
                    },
                }
                entries[e_index] = layout_entry;
            }
            bind_group_desc.entries = entries.ptr;
            bind_group_layouts[g_index] = c.wgpuDeviceCreateBindGroupLayout(self.gpu_context.device, &bind_group_desc);
        }
        layout_desc.bindGroupLayouts = bind_group_layouts.ptr;
        desc.layout = c.wgpuDeviceCreatePipelineLayout(self.gpu_context.device, &layout_desc);

        var vertex_state = z_WGPU_VERTEX_STATE_INIT();
        vertex_state.module = shader.module;
        vertex_state.entryPoint = toWGPUString(shader.metadata.vertex_entry);

        const buffers = try alloc.alloc(c.WGPUVertexBufferLayout, descriptor.vertex_layout_count);

        for (0..descriptor.vertex_layout_count) |li| {
            const vertex_layout = descriptor.vertex_layouts[li];
            buffers[li] = z_WGPU_VERTEX_BUFFER_LAYOUT_INIT();
            buffers[li].stepMode = @intFromEnum(vertex_layout.step_mode);
            buffers[li].arrayStride = vertex_layout.array_stride;
            buffers[li].attributeCount = vertex_layout.attribute_count;
            var attributes = try alloc.alloc(c.WGPUVertexAttribute, vertex_layout.attribute_count);
            for (0..vertex_layout.attribute_count) |ai| {
                const attribute = vertex_layout.attributes[ai];
                attributes[ai] = z_WGPU_VERTEX_ATTRIBUTE_INIT();
                attributes[ai].offset = attribute.offset;
                attributes[ai].format = @intFromEnum(attribute.format);
                attributes[ai].shaderLocation = attribute.shader_location;
            }
            buffers[li].attributes = attributes.ptr;
        }

        vertex_state.bufferCount = descriptor.vertex_layout_count;
        vertex_state.buffers = buffers.ptr;

        // TODO handle constants
        desc.vertex = vertex_state;

        // TODO multi target rendering
        var fragment_state = z_WGPU_FRAGMENT_STATE_INIT();
        fragment_state.module = shader.module;
        fragment_state.entryPoint = toWGPUString(shader.metadata.fragment_entry);
        fragment_state.targetCount = 1;

        var target_state = z_WGPU_COLOR_TARGET_STATE_INIT();
        if (descriptor.color_format) |cd| {
            target_state.format = @intFromEnum(cd);
        } else {
            target_state.format = @intFromEnum(self.default_color_format);
        }

        var blend_state = z_WGPU_BLEND_STATE_INIT();
        if (descriptor.blend) |b| {
            var alpha = z_WGPU_BLEND_COMPONENT_INIT();
            alpha.srcFactor = @intFromEnum(b.alpha.src_factor);
            alpha.dstFactor = @intFromEnum(b.alpha.dst_factor);
            alpha.operation = @intFromEnum(b.alpha.operation);
            blend_state.alpha = alpha;
            var color = z_WGPU_BLEND_COMPONENT_INIT();
            color.srcFactor = @intFromEnum(b.color.src_factor);
            color.dstFactor = @intFromEnum(b.color.dst_factor);
            color.operation = @intFromEnum(b.color.operation);
            blend_state.color = color;
            target_state.blend = &blend_state;
        }

        // TODO MAYBE expose this
        target_state.writeMask = c.WGPUColorWriteMask_All;

        fragment_state.targets = &target_state;
        desc.fragment = &fragment_state;

        // TODO consider covering other fields
        var primitive_state = z_WGPU_PRIMITIVE_STATE_INIT();
        primitive_state.topology = @intFromEnum(descriptor.primitive_topology);
        primitive_state.cullMode = @intFromEnum(descriptor.cull_mode);
        desc.primitive = primitive_state;

        if (descriptor.depth_stencil) |ds| {
            var depth_stencil_state = z_WGPU_DEPTH_STENCIL_STATE_INIT();
            depth_stencil_state.format = @intFromEnum(descriptor.depth_format orelse self.default_depth_format);
            depth_stencil_state.depthBias = ds.depth_bias;
            depth_stencil_state.depthBiasClamp = ds.depth_bias_clamp;
            depth_stencil_state.depthBiasSlopeScale = ds.depth_bias_slope_scale;
            depth_stencil_state.depthCompare = @intFromEnum(ds.depth_compare);
            depth_stencil_state.depthWriteEnabled = toWGPUOptBool(ds.depth_write_enabled);
            if (ds.stencil_back) |dsb| {
                depth_stencil_state.stencilBack = z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilBack.compare = @intFromEnum(dsb.compare);
                depth_stencil_state.stencilBack.depthFailOp = @intFromEnum(dsb.depth_fail_op);
                depth_stencil_state.stencilBack.failOp = @intFromEnum(dsb.fail_op);
                depth_stencil_state.stencilBack.passOp = @intFromEnum(dsb.pass_op);
            }
            if (ds.stencil_front) |dsf| {
                depth_stencil_state.stencilFront = z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilFront.compare = @intFromEnum(dsf.compare);
                depth_stencil_state.stencilFront.depthFailOp = @intFromEnum(dsf.depth_fail_op);
                depth_stencil_state.stencilFront.failOp = @intFromEnum(dsf.fail_op);
                depth_stencil_state.stencilFront.passOp = @intFromEnum(dsf.pass_op);
            }
            depth_stencil_state.stencilReadMask = ds.stencil_read_mask;
            depth_stencil_state.stencilWriteMask = ds.stencil_write_mask;
            desc.depthStencil = &depth_stencil_state;
        }

        const multisample_state = z_WGPU_MULTISAMPLE_STATE_INIT();
        desc.multisample = multisample_state;

        const pipeline = c.wgpuDeviceCreateRenderPipeline(self.gpu_context.device, &desc);
        var entry = Entry{
            .pipeline = pipeline,
            .shader = descriptor.shader,
        };
        for (0..MAX_BIND_GROUP_LAYOUT_COUNT) |i| {
            entry.bind_group_layouts[i] = if (i >= bind_group_layouts.len) null else bind_group_layouts[i];
        }
        try self.pipelines.put(allocator, descriptor, entry);

        return entry;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var iter = self.pipelines.valueIterator();
        while (iter.next()) |e| {
            c.wgpuRenderPipelineRelease(e.pipeline);
            for (e.bind_group_layouts) |opt_layout| {
                if (opt_layout) |layout| c.wgpuBindGroupLayoutRelease(layout);
            }
        }
        self.pipelines.deinit(allocator);
    }
};
