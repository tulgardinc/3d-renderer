const std = @import("std");
pub const c = @import("main.zig").c;

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
pub extern fn z_WGPU_BIND_GROUP_DESCRIPTOR_INIT() c.WGPUBindGroupDescriptor;
pub extern fn z_WGPU_BIND_GROUP_ENTRY_INIT() c.WGPUBindGroupEntry;

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

pub const PresentMode = enum(c.WGPUPresentMode) {
    undefined = c.WGPUPresentMode_Undefined,
    fifo = c.WGPUPresentMode_Fifo,
    fifo_relaxed = c.WGPUPresentMode_FifoRelaxed,
    immediate = c.WGPUPresentMode_Immediate,
    mailbox = c.WGPUPresentMode_Mailbox,
};

pub const CompositeAlphaMode = enum(c.WGPUCompositeAlphaMode) {
    auto = c.WGPUCompositeAlphaMode_Auto,
    @"opaque" = c.WGPUCompositeAlphaMode_Opaque,
    pre_multiplied = c.WGPUCompositeAlphaMode_Premultiplied,
    un_pre_multiplied = c.WGPUCompositeAlphaMode_Unpremultiplied,
    inherit = c.WGPUCompositeAlphaMode_Inherit,
};

pub fn getSurfaceCapabilities(surface: c.WGPUSurface, adapter: c.WGPUAdapter) c.WGPUSurfaceCapabilities {
    var surface_capabilities = z_WGPU_SURFACE_CAPABILITIES_INIT();
    _ = c.wgpuSurfaceGetCapabilities(
        surface,
        adapter,
        &surface_capabilities,
    );
    return surface_capabilities;
}

pub fn configureSurface(surface: c.WGPUSurface, config: SurfaceConfiguration) void {
    var conf = z_WGPU_SURFACE_CONFIGURATION_INIT();
    conf.width = config.width;
    conf.height = config.height;
    conf.device = config.device;
    conf.format = @intCast(config.format);
    conf.presentMode = @intCast(config.present_mode);
    conf.alphaMode = @intCast(config.alpha_mode);

    c.wgpuSurfaceConfigure(surface, &conf);
}

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

pub const TextureUsage = struct {
    pub const none: c.WGPUTextureUsage = c.WGPUTextureUsage_None;
    pub const copy_src: c.WGPUTextureUsage = c.WGPUTextureUsage_CopySrc;
    pub const copy_dst: c.WGPUTextureUsage = c.WGPUTextureUsage_CopyDst;
    pub const texture_binding: c.WGPUTextureUsage = c.WGPUTextureUsage_TextureBinding;
    pub const storage_binding: c.WGPUTextureUsage = c.WGPUTextureUsage_StorageBinding;
    pub const render_attachment: c.WGPUTextureUsage = c.WGPUTextureUsage_RenderAttachment;
    pub const transient_attachment: c.WGPUTextureUsage = c.WGPUTextureUsage_TransientAttachment;
    pub const storage_attachment: c.WGPUTextureUsage = c.WGPUTextureUsage_StorageAttachment;
};

pub const SurfaceCapabilities = struct {
    usages: u64,
    formats: [8]TextureFormat,
    format_count: usize,
    present_modes: [8]PresentMode,
    present_mode_count: usize,
    alpha_modes: [8]CompositeAlphaMode,
    alpha_mode_count: usize,
};

pub const SurfaceConfiguration = struct {
    width: u32,
    height: u32,
    device: c.WGPUDevice,
    present_mode: ?PresentMode = null,
    alpha_mode: CompositeAlphaMode,
    format: ?TextureFormat = null,
};

pub const Surface = struct {
    surface: c.WGPUSurface,
    capabilities: SurfaceCapabilities,

    const Self = @This();

    pub fn init(surface: c.WGPUSurface, adapter: c.WGPUAdapter) Self {
        const capabilities = getSurfaceCapabilities(surface, adapter);
        var caps: SurfaceCapabilities = undefined;
        caps.usages = capabilities.usages;
        caps.format_count = capabilities.formatCount;
        caps.present_mode_count = capabilities.presentModeCount;
        caps.alpha_mode_count = capabilities.alphaModeCount;
        for (0..capabilities.formatCount) |i| caps.formats[i] = @enumFromInt(capabilities.formats[i]);
        for (0..capabilities.presentModeCount) |i| caps.present_modes[i] = @enumFromInt(capabilities.presentModes[i]);
        for (0..capabilities.alphaModeCount) |i| caps.alpha_modes[i] = @enumFromInt(capabilities.alphaModes[i]);

        return .{
            .surface = surface,
            .capabilities = caps,
        };
    }

    pub fn configure(self: *Self, config: SurfaceConfiguration) void {
        var conf = config;
        if (conf.format == null) conf.format = self.capabilities.formats[0];
        if (conf.present_mode == null) conf.format = self.capabilities.present_modes[0];
        configureSurface(self.surface, conf);
    }

    pub fn beginFrame(self: Self) !Frame {
        return try Frame.init(
            self.gpu_context.device,
            try getNextSurfaceView(self.surface),
        );
    }

    pub fn present(self: Self) !void {
        if (c.wgpuSurfacePresent(self.surface) == c.WGPUStatus_Error) {
            return error.FailedToPresent;
        }
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

pub const Color = struct { r: f32 = 0.0, g: f32 = 0.0, b: f32 = 0.0, a: f32 = 1.0 };
pub const LoadOp = enum(c.WGPULoadOp) {
    undefined = c.WGPULoadOp_Undefined,
    load = c.WGPULoadOp_Load,
    clear = c.WGPULoadOp_Clear,
    expand_resolve_texture = c.WGPULoadOp_ExpandResolveTexture,
};
pub const StoreOp = enum(c.WGPUStoreOp) {
    undefined = c.WGPUStoreOp_Undefined,
    store = c.WGPUStoreOp_Store,
    discard = c.WGPUStoreOp_Discard,
    force32 = c.WGPUStoreOp_Force32,
};

pub const ColorAttachment = struct {
    clear_value: Color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
};

pub const DepthStencilAttachment = struct {
    depth_clear_value: f32 = 1.0,
    depth_load_op: LoadOp = .clear,
    depth_store_op: StoreOp = .store,
};

pub const RenderPassDescriptor = struct {
    color_attachments: ?[]const ColorAttachment = &.{.{}},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
};

pub const RenderPass = struct {
    render_pass: c.WGPURenderPassEncoder,

    const Self = @This();

    pub fn init(
        encoder: c.WGPUCommandEncoder,
        target_view: c.WGPUTextureView,
        label: []const u8,
        descriptor: RenderPassDescriptor,
    ) Self {
        var render_pass_desc = z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();
        render_pass_desc.label = toWGPUString(label);

        // color attachement
        var color_attachment = z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
        color_attachment.view = target_view;
        if (descriptor.color_attachments) |attachments| {
            for (attachments) |att| {
                color_attachment.loadOp = @intFromEnum(att.load_op);
                color_attachment.storeOp = @intFromEnum(att.store_op);
                color_attachment.clearValue = c.WGPUColor{ .r = att.clear_value.r, .g = att.clear_value.g, .b = att.clear_value.b, .a = att.clear_value.a };
            }
        }
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;

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
    }

    pub fn deinit(self: *Self) void {
        c.wgpuRenderPassEncoderRelease(self.render_pass);
    }
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

pub const CullMode = enum(c.WGPUCullMode) {
    undefined = c.WGPUCullMode_Undefined,
    none = c.WGPUCullMode_None,
    front = c.WGPUCullMode_Front,
    back = c.WGPUCullMode_Back,
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

pub const PipelineDescriptor = struct {
    color_format: ?w.TextureFormat = null,
    depth_format: ?w.TextureFormat = null,
    shader: ShaderHandle,
    vertex_layout_count: u32,
    vertex_layouts: [MAX_VERTEX_LAYOUT_COUNT]VertexLayout = std.mem.zeroes([MAX_VERTEX_LAYOUT_COUNT]VertexLayout),
    primitive_topology: w.PrimitiveTopology = .triangle_list,
    depth_stencil: ?DepthStencilState = .{
        .depth_write_enabled = true,
        .depth_compare = .less,
    },
    blend: ?BlendState = null,
    cull_mode: w.CullMode = .back,
};

pub const StencilFaceState = struct {
    compare: w.CompareFunction,
    fail_op: w.StencilOperation,
    depth_fail_op: w.StencilOperation,
    pass_op: w.StencilOperation,
};

pub const DepthStencilState = struct {
    depth_write_enabled: bool,
    depth_compare: w.CompareFunction,
    stencil_front: ?StencilFaceState = null,
    stencil_back: ?StencilFaceState = null,
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,

    // ERROR causing problem here
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
};

pub const BlendComponent = struct {
    operation: w.BlendOperation,
    src_factor: w.BlendFactor,
    dst_factor: w.BlendFactor,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};
