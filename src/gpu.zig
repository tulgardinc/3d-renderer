const std = @import("std");
const builtin = @import("builtin");

pub const is_web = builtin.os.tag == .emscripten;

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("sdl3webgpu.h");
    @cInclude("webgpu/webgpu.h");
});

// Asyncify sleep
extern fn emscripten_sleep(ms: u32) void;

// Does requestAnimationFrame
extern fn z_await_animation_frame() void;

pub fn waitForNextFrame() void {
    if (is_web) z_await_animation_frame();
}

fn pollTick(io: std.Io) !void {
    if (is_web) emscripten_sleep(1) else try io.sleep(.fromMilliseconds(200), .awake);
}

// Shim externs

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
pub extern fn z_WGPU_TEXTURE_DESCRIPTOR_INIT() c.WGPUTextureDescriptor;
pub extern fn z_WGPU_SAMPLER_DESCRIPTOR_INIT() c.WGPUSamplerDescriptor;
pub extern fn z_WGPU_TEXEL_COPY_TEXTURE_INFO_INIT() c.WGPUTexelCopyTextureInfo;
pub extern fn z_WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT() c.WGPUTexelCopyBufferLayout;
pub extern fn z_WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT() c.WGPURenderPassDepthStencilAttachment;

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

// Sync wrappers

pub fn getInstance() !c.WGPUInstance {
    const instance = c.wgpuCreateInstance(&.{});
    return instance orelse {
        std.log.err("failed to init WebGPU", .{});
        return error.Failed;
    };
}

pub fn requestAdapterSync(io: std.Io, instance: c.WGPUInstance, surface: c.WGPUSurface) !c.WGPUAdapter {
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
        try pollTick(io);
        c.wgpuInstanceProcessEvents(instance);
    }

    return cb_data.adapter orelse {
        std.log.err("failed to get adapter", .{});
        return error.Failed;
    };
}

pub fn requestDeviceSync(io: std.Io, instance: c.WGPUInstance, adapter: c.WGPUAdapter) !c.WGPUDevice {
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

    const uncapturedErrorCallback = struct {
        pub fn func(
            _: ?*const c.WGPUDevice,
            error_type: c.WGPUErrorType,
            message: c.WGPUStringView,
            _: ?*anyopaque,
            _: ?*anyopaque,
        ) callconv(.c) void {
            std.debug.panic("[WebGPU uncaptured] {s}: {s}", .{
                switch (error_type) {
                    c.WGPUErrorType_Validation => "Validation",
                    c.WGPUErrorType_OutOfMemory => "OOM",
                    c.WGPUErrorType_Internal => "Internal",
                    c.WGPUErrorType_Unknown => "Unknown",
                    else => "???",
                },
                wgpuStringToString(&message),
            });
        }
    }.func;

    var cb_data: CallbackData = .{};
    const cb = CallbackData.func;

    const cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .callback = &cb,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .userdata1 = @ptrCast(@alignCast(&cb_data)),
    };

    var device_desc = z_WGPU_DEVICE_DESCRIPTOR_INIT();
    device_desc.uncapturedErrorCallbackInfo = .{
        .callback = &uncapturedErrorCallback,
    };

    _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, cb_info);

    c.wgpuInstanceProcessEvents(instance);

    while (!cb_data.done) {
        try pollTick(io);
        c.wgpuInstanceProcessEvents(instance);
    }

    return cb_data.device orelse {
        std.log.err("failed to get device", .{});
        return error.Failed;
    };
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

    pub fn initSync(io: std.Io, instance: c.WGPUInstance, surface: c.WGPUSurface) !Self {
        const adapter = try requestAdapterSync(io, instance, surface);
        const device = try requestDeviceSync(io, instance, adapter);
        return .{
            .adapter = adapter,
            .device = device,
            .queue = c.wgpuDeviceGetQueue(device),
        };
    }

    pub fn getEncoder(self: Self) c.WGPUCommandEncoder {
        var desc = z_WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT();
        desc.label = toWGPUString("command encoder");
        return c.wgpuDeviceCreateCommandEncoder(self.device, &desc);
    }

    pub fn submitCommands(self: Self, commands: []const c.WGPUCommandBuffer) void {
        c.wgpuQueueSubmit(self.queue, commands.len, @ptrCast(commands));
        for (commands) |command| {
            c.wgpuCommandBufferRelease(command);
        }
    }

    pub fn deinit(self: *Self) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
    }
};

pub fn finishEncoder(encoder: c.WGPUCommandEncoder) c.WGPUCommandBuffer {
    var desc = z_WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT();
    desc.label = toWGPUString("command buffer");
    return c.wgpuCommandEncoderFinish(encoder, &desc);
}

pub const Surface = struct {
    surface: c.WGPUSurface,
    format: TextureFormat,

    const Self = @This();

    pub fn init(ctx: GPUContext, surface: c.WGPUSurface) Self {
        var capabilities = z_WGPU_SURFACE_CAPABILITIES_INIT();
        _ = c.wgpuSurfaceGetCapabilities(surface, ctx.adapter, &capabilities);

        return .{
            .surface = surface,
            .format = @enumFromInt(capabilities.formats[0]),
        };
    }

    pub fn configure(self: *Self, ctx: GPUContext, width: u32, height: u32) void {
        var conf = z_WGPU_SURFACE_CONFIGURATION_INIT();
        conf.width = width;
        conf.height = height;
        conf.device = ctx.device;
        conf.format = @intFromEnum(self.format);
        c.wgpuSurfaceConfigure(self.surface, &conf);
    }

    pub fn getCurrentView(self: *const Self) !c.WGPUTextureView {
        return try getNextSurfaceView(self.surface);
    }

    pub fn present(self: *const Self) !void {
        if (is_web) return;

        if (c.wgpuSurfacePresent(self.surface) == c.WGPUStatus_Error) {
            return error.FailedToPresent;
        }
    }

    pub fn deinit(self: *Self) void {
        c.wgpuSurfaceRelease(self.surface);
    }
};

pub fn createBuffer(
    ctx: GPUContext,
    contents: []const u8,
    label: []const u8,
    usage: BufferUsage,
) !c.WGPUBuffer {
    var desc = z_WGPU_BUFFER_DESCRIPTOR_INIT();
    desc.label = toWGPUString(label);
    desc.size = contents.len;
    desc.usage = usage.toC();

    const buffer = c.wgpuDeviceCreateBuffer(ctx.device, &desc);
    if (buffer == null) {
        std.log.err("ResourceManager: wgpuDeviceCreateBuffer failed for '{s}'", .{label});
        return error.BufferCreationFailed;
    }

    c.wgpuQueueWriteBuffer(ctx.queue, buffer, 0, contents.ptr, contents.len);
    return buffer;
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

pub const Color = struct { r: f32 = 0.0, g: f32 = 0.0, b: f32 = 0.0, a: f32 = 1.0 };

pub const LoadOp = enum(c.WGPULoadOp) {
    undefined = c.WGPULoadOp_Undefined,
    load = c.WGPULoadOp_Load,
    clear = c.WGPULoadOp_Clear,
};

pub const StoreOp = enum(c.WGPUStoreOp) {
    undefined = c.WGPUStoreOp_Undefined,
    store = c.WGPUStoreOp_Store,
    discard = c.WGPUStoreOp_Discard,
    force32 = c.WGPUStoreOp_Force32,
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

    // Null means no defined layout
    pub fn sizeOf(self: @This()) ?u32 {
        return switch (self) {
            .r8_unorm,
            .r8_snorm,
            .r8_uint,
            .r8_sint,
            .stencil8,
            => 1,

            .r16_unorm,
            .r16_snorm,
            .r16_uint,
            .r16_sint,
            .r16_float,
            .rg8_unorm,
            .rg8_snorm,
            .rg8_uint,
            .rg8_sint,
            .depth16_unorm,
            => 2,

            .r32_float,
            .r32_uint,
            .r32_sint,
            .rg16_unorm,
            .rg16_snorm,
            .rg16_uint,
            .rg16_sint,
            .rg16_float,
            .rgba8_unorm,
            .rgba8_unorm_srgb,
            .rgba8_snorm,
            .rgba8_uint,
            .rgba8_sint,
            .bgra8_unorm,
            .bgra8_unorm_srgb,
            .rgb10a2_uint,
            .rgb10a2_unorm,
            .rg11b10_ufloat,
            .rgb9e5_ufloat,
            .depth32_float,
            => 4,

            .rg32_float,
            .rg32_uint,
            .rg32_sint,
            .rgba16_unorm,
            .rgba16_snorm,
            .rgba16_uint,
            .rgba16_sint,
            .rgba16_float,
            => 8,

            .rgba32_float,
            .rgba32_uint,
            .rgba32_sint,
            => 16,

            // 4x4 blocks
            .bc1_rgba_unorm,
            .bc1_rgba_unorm_srgb,
            .bc4_r_unorm,
            .bc4_r_snorm,
            .etc2_rgb8_unorm,
            .etc2_rgb8_unorm_srgb,
            .etc2_rgb8a1_unorm,
            .etc2_rgb8a1_unorm_srgb,
            .eac_r11_unorm,
            .eac_r11_snorm,
            => 8,

            .bc2_rgba_unorm,
            .bc2_rgba_unorm_srgb,
            .bc3_rgba_unorm,
            .bc3_rgba_unorm_srgb,
            .bc5_rg_unorm,
            .bc5_rg_snorm,
            .bc6h_rgb_ufloat,
            .bc6h_rgb_float,
            .bc7_rgba_unorm,
            .bc7_rgba_unorm_srgb,
            .etc2_rgba8_unorm,
            .etc2_rgba8_unorm_srgb,
            .eac_rg11_unorm,
            .eac_rg11_snorm,
            => 16,

            // ASTC blocks
            .astc4x4_unorm,
            .astc4x4_unorm_srgb,
            .astc5x4_unorm,
            .astc5x4_unorm_srgb,
            .astc5x5_unorm,
            .astc5x5_unorm_srgb,
            .astc6x5_unorm,
            .astc6x5_unorm_srgb,
            .astc6x6_unorm,
            .astc6x6_unorm_srgb,
            .astc8x5_unorm,
            .astc8x5_unorm_srgb,
            .astc8x6_unorm,
            .astc8x6_unorm_srgb,
            .astc8x8_unorm,
            .astc8x8_unorm_srgb,
            .astc10x5_unorm,
            .astc10x5_unorm_srgb,
            .astc10x6_unorm,
            .astc10x6_unorm_srgb,
            .astc10x8_unorm,
            .astc10x8_unorm_srgb,
            .astc10x10_unorm,
            .astc10x10_unorm_srgb,
            .astc12x10_unorm,
            .astc12x10_unorm_srgb,
            .astc12x12_unorm,
            .astc12x12_unorm_srgb,
            => 16,

            .undefined,
            .depth24_plus,
            .depth24_plus_stencil8,
            .depth32_float_stencil8,
            => null,
        };
    }
};

pub const TextureDimension = enum(c.WGPUTextureDimension) {
    undefined = c.WGPUTextureDimension_Undefined,
    @"1d" = c.WGPUTextureDimension_1D,
    @"2d" = c.WGPUTextureDimension_2D,
    @"3d" = c.WGPUTextureDimension_3D,
};

pub const TextureAspect = enum(c.WGPUTextureAspect) {
    undefined = c.WGPUTextureAspect_Undefined,
    all = c.WGPUTextureAspect_All,
    stencil_only = c.WGPUTextureAspect_StencilOnly,
    depth_only = c.WGPUTextureAspect_DepthOnly,
};

pub const AddressMode = enum(c.WGPUAddressMode) {
    undefined = c.WGPUAddressMode_Undefined,
    clamp_to_edge = c.WGPUAddressMode_ClampToEdge,
    repeat = c.WGPUAddressMode_Repeat,
    mirror_repeat = c.WGPUAddressMode_MirrorRepeat,
};

pub const FilterMode = enum(c.WGPUFilterMode) {
    undefined = c.WGPUFilterMode_Undefined,
    nearest = c.WGPUFilterMode_Nearest,
    linear = c.WGPUFilterMode_Linear,
};

pub const MipmapFilterMode = enum(c.WGPUMipmapFilterMode) {
    undefined = c.WGPUMipmapFilterMode_Undefined,
    nearest = c.WGPUMipmapFilterMode_Nearest,
    linear = c.WGPUMipmapFilterMode_Linear,
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

    pub const ComponentType = enum { u8, i8, u16, i16, f16, f32, u32, i32 };
    pub const CompositionType = enum { scalar, vec2, vec3, vec4 };

    pub fn getFormComponents(component_type: []const u8, composition_type: []const u8) @This() {
        const ct = std.meta.stringToEnum(ComponentType, component_type) orelse @panic("unknown component type");
        const comp = std.meta.stringToEnum(CompositionType, composition_type) orelse @panic("unknown composition type");

        return switch (ct) {
            .u8 => switch (comp) {
                .scalar => .u8,
                .vec2 => .u8x2,
                .vec3 => @panic("no u8x3 vertex format"),
                .vec4 => .u8x4,
            },
            .i8 => switch (comp) {
                .scalar => .i8,
                .vec2 => .i8x2,
                .vec3 => @panic("no i8x3 vertex format"),
                .vec4 => .i8x4,
            },
            .u16 => switch (comp) {
                .scalar => .u16,
                .vec2 => .u16x2,
                .vec3 => @panic("no u16x3 vertex format"),
                .vec4 => .u16x4,
            },
            .i16 => switch (comp) {
                .scalar => .i16,
                .vec2 => .i16x2,
                .vec3 => @panic("no i16x3 vertex format"),
                .vec4 => .i16x4,
            },
            .f16 => switch (comp) {
                .scalar => .f16,
                .vec2 => .f16x2,
                .vec3 => @panic("no f16x3 vertex format"),
                .vec4 => .f16x4,
            },
            .f32 => switch (comp) {
                .scalar => .f32,
                .vec2 => .f32x2,
                .vec3 => .f32x3,
                .vec4 => .f32x4,
            },
            .u32 => switch (comp) {
                .scalar => .u32,
                .vec2 => .u32x2,
                .vec3 => .u32x3,
                .vec4 => .u32x4,
            },
            .i32 => switch (comp) {
                .scalar => .i32,
                .vec2 => .i32x2,
                .vec3 => .i32x3,
                .vec4 => .i32x4,
            },
        };
    }

    pub fn byteSize(self: @This()) u64 {
        return switch (self) {
            .undefined => 0,
            .u8, .i8, .unorm8, .snorm8 => 1,
            .u8x2, .i8x2, .unorm8x2, .snorm8x2, .u16, .i16, .unorm16, .snorm16, .f16 => 2,
            .u8x4, .i8x4, .unorm8x4, .snorm8x4, .u16x2, .i16x2, .unorm16x2, .snorm16x2, .f16x2, .u32, .i32, .f32, .unorm10_10_10_2, .unorm8x4bgra => 4,
            .u16x4, .i16x4, .unorm16x4, .snorm16x4, .f16x4, .f32x2, .u32x2, .i32x2 => 8,
            .f32x3, .u32x3, .i32x3 => 12,
            .f32x4, .u32x4, .i32x4 => 16,
        };
    }
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

pub const TextureUsage = packed struct(c.WGPUTextureUsage) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    transient_attachment: bool = false,
    _padding: u58 = 0,

    pub const none: TextureUsage = .{};

    pub fn toC(self: TextureUsage) c.WGPUTextureUsage {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert((TextureUsage{ .copy_src = true }).toC() == c.WGPUTextureUsage_CopySrc);
        std.debug.assert((TextureUsage{ .copy_dst = true }).toC() == c.WGPUTextureUsage_CopyDst);
        std.debug.assert((TextureUsage{ .texture_binding = true }).toC() == c.WGPUTextureUsage_TextureBinding);
        std.debug.assert((TextureUsage{ .storage_binding = true }).toC() == c.WGPUTextureUsage_StorageBinding);
        std.debug.assert((TextureUsage{ .render_attachment = true }).toC() == c.WGPUTextureUsage_RenderAttachment);
        std.debug.assert((TextureUsage{ .transient_attachment = true }).toC() == c.WGPUTextureUsage_TransientAttachment);
        std.debug.assert(TextureUsage.none.toC() == c.WGPUTextureUsage_None);
    }
};

pub const BufferUsage = packed struct(c.WGPUBufferUsage) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _padding: u54 = 0,

    pub const none: BufferUsage = .{};

    pub fn toC(self: BufferUsage) c.WGPUBufferUsage {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert((BufferUsage{ .map_read = true }).toC() == c.WGPUBufferUsage_MapRead);
        std.debug.assert((BufferUsage{ .map_write = true }).toC() == c.WGPUBufferUsage_MapWrite);
        std.debug.assert((BufferUsage{ .copy_src = true }).toC() == c.WGPUBufferUsage_CopySrc);
        std.debug.assert((BufferUsage{ .copy_dst = true }).toC() == c.WGPUBufferUsage_CopyDst);
        std.debug.assert((BufferUsage{ .index = true }).toC() == c.WGPUBufferUsage_Index);
        std.debug.assert((BufferUsage{ .vertex = true }).toC() == c.WGPUBufferUsage_Vertex);
        std.debug.assert((BufferUsage{ .uniform = true }).toC() == c.WGPUBufferUsage_Uniform);
        std.debug.assert((BufferUsage{ .storage = true }).toC() == c.WGPUBufferUsage_Storage);
        std.debug.assert((BufferUsage{ .indirect = true }).toC() == c.WGPUBufferUsage_Indirect);
        std.debug.assert((BufferUsage{ .query_resolve = true }).toC() == c.WGPUBufferUsage_QueryResolve);
        std.debug.assert(BufferUsage.none.toC() == c.WGPUBufferUsage_None);
    }
};

pub const ShaderStage = struct {
    pub const vertex = c.WGPUShaderStage_Vertex;
    pub const fragment = c.WGPUShaderStage_Fragment;
    pub const compute = c.WGPUShaderStage_Compute;
};

// Binding type

pub const BindingResourceTypes = enum {
    buffer,
    sampler,
    texture,
    storage_texture,
};

pub const BindingType = union(BindingResourceTypes) {
    buffer: BufferBindingInfo,
    sampler: SamplerBT,
    texture: TextureBindingInfo,
    storage_texture: StorageTextureBindingInfo,

    const BufferBT = enum(c.WGPUBufferBindingType) {
        uniform = c.WGPUBufferBindingType_Uniform,
        storage = c.WGPUBufferBindingType_Storage,
        read_only_storage = c.WGPUBufferBindingType_ReadOnlyStorage,
    };
    const SamplerBT = enum(c.WGPUSamplerBindingType) {
        filtering = c.WGPUSamplerBindingType_Filtering,
        non_filtering = c.WGPUSamplerBindingType_NonFiltering,
        comparison = c.WGPUSamplerBindingType_Comparison,
    };
    const TextureSampleBT = enum(c.WGPUTextureSampleType) {
        float = c.WGPUTextureSampleType_Float,
        unfilterable_float = c.WGPUTextureSampleType_UnfilterableFloat,
        depth = c.WGPUTextureSampleType_Depth,
        sint = c.WGPUTextureSampleType_Sint,
        uint = c.WGPUTextureSampleType_Uint,
    };
    const StorageTextureAccess = enum(c.WGPUStorageTextureAccess) {
        write_only = c.WGPUStorageTextureAccess_WriteOnly,
        read_only = c.WGPUStorageTextureAccess_ReadOnly,
        read_write = c.WGPUStorageTextureAccess_ReadWrite,
    };
    const TextureViewDimension = enum(c.WGPUTextureViewDimension) {
        @"1d" = c.WGPUTextureViewDimension_1D,
        @"2d" = c.WGPUTextureViewDimension_2D,
        @"2d_array" = c.WGPUTextureViewDimension_2DArray,
        cube = c.WGPUTextureViewDimension_Cube,
        cube_array = c.WGPUTextureViewDimension_CubeArray,
        @"3d" = c.WGPUTextureViewDimension_3D,
    };
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
    const BufferBindingInfo = struct {
        type: BufferBT,
        has_dynamic_offset: bool,
        min_binding_size: u64,
    };
};

pub const VertexInput = struct {
    location: u32,
    format: VertexFormat,
};

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    type: BindingType,
    // DO NOT CHANGE FOR NOW
    visibility: c.WGPUShaderStage = ShaderStage.fragment | ShaderStage.vertex,
};

pub const VertexBufferLayout = struct {
    step_mode: StepMode,
    array_stride: u64,
    attributes: []const VertexAttribute,

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

pub const StencilFaceState = struct {
    compare: CompareFunction,
    fail_op: StencilOperation,
    depth_fail_op: StencilOperation,
    pass_op: StencilOperation,
};

pub const DepthStencilState = struct {
    depth_write_enabled: bool = true,
    depth_compare: CompareFunction = .less,
    stencil_front: ?StencilFaceState = null,
    stencil_back: ?StencilFaceState = null,
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
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

pub const PipelineDescriptor = struct {
    color_format: TextureFormat,
    shader_module: c.WGPUShaderModule,
    vertex_layouts: []const VertexBufferLayout = &.{},
    depth_format: ?TextureFormat = null,
    primitive_topology: PrimitiveTopology = .triangle_list,
    depth_stencil: ?DepthStencilState = null,
    blend: ?BlendState = null,
    cull_mode: CullMode = .back,
};

pub const BindGroupEntry = struct {
    binding: u32,
    resource: union(enum) {
        buffer: BufferEntry,
        sampler: c.WGPUSampler,
        texture_view: c.WGPUTextureView,
    },

    pub const BufferEntry = struct {
        buffer: c.WGPUBuffer,
        size: u64,
        offset: u64 = 0,
    };
};

pub const BindGroupDescriptor = struct {
    layout: c.WGPUBindGroupLayout,
    entries: []const BindGroupEntry,
};

pub const BindGroupUniformEntryMeta = struct {
    Type: type,
    binding: u32,
    name: []const u8,
};

pub const StorageShape = union(enum) {
    /// `var<storage> x: Config;`
    value: type,
    /// `var<storage> x: array<Element>;`
    array: type,
    /// `var<storage> x: Header;` where Header ends in `array<Element>`.
    /// Header carries <FIELD>_OFFSET / <FIELD>_STRIDE.
    buffer: struct { Header: type, Element: type },
};

pub const BindGroupResourceEntryMeta = struct {
    binding: u32,
    name: []const u8,
    resource_type: union(enum) {
        sampler: void,
        texture: void,
        storage: StorageShape,
    },
};

pub const UniformConfig = struct {
    label: []const u8 = "uniform buffer",
    usage: BufferUsage = .{ .uniform = true, .copy_dst = true },
};

pub fn UniformValue(T: type) type {
    return struct {
        ptr: c.WGPUBuffer,

        const Self = @This();

        pub fn init(ctx: GPUContext, config: UniformConfig) !Self {
            var desc = z_WGPU_BUFFER_DESCRIPTOR_INIT();
            desc.label = toWGPUString(config.label);
            desc.size = @sizeOf(T);
            desc.usage = config.usage.toC();

            const buffer = c.wgpuDeviceCreateBuffer(ctx.device, &desc);
            if (buffer == null) {
                std.log.err("wgpuDeviceCreateBuffer failed for '{s}'", .{config.label});
                return error.BufferCreationFailed;
            }
            return .{ .ptr = buffer };
        }

        pub fn upload(self: Self, ctx: GPUContext, value: T) void {
            c.wgpuQueueWriteBuffer(ctx.queue, self.ptr, 0, &std.mem.toBytes(value), @sizeOf(T));
        }

        pub fn binding(self: Self) BindGroupEntry.BufferEntry {
            return .{ .buffer = self.ptr, .offset = 0, .size = @sizeOf(T) };
        }

        pub fn deinit(self: Self) void {
            c.wgpuBufferDestroy(self.ptr);
        }
    };
}

pub const StorageConfig = struct {
    label: []const u8 = "storage buffer",
    usage: BufferUsage = .{ .storage = true, .copy_dst = true },
};

fn createStorageBuffer(ctx: GPUContext, size: u64, config: StorageConfig) !c.WGPUBuffer {
    var desc = z_WGPU_BUFFER_DESCRIPTOR_INIT();
    desc.label = toWGPUString(config.label);
    desc.size = size;
    desc.usage = config.usage.toC();

    const buffer = c.wgpuDeviceCreateBuffer(ctx.device, &desc);
    if (buffer == null) {
        std.log.err("wgpuDeviceCreateBuffer failed for '{s}'", .{config.label});
        return error.BufferCreationFailed;
    }
    return buffer;
}

/// Backs `StorageShape.value`.
pub fn StorageValue(T: type) type {
    return struct {
        ptr: c.WGPUBuffer,

        const Self = @This();

        pub fn init(ctx: GPUContext, config: StorageConfig) !Self {
            return .{ .ptr = try createStorageBuffer(ctx, @sizeOf(T), config) };
        }

        pub fn upload(self: Self, ctx: GPUContext, value: T) void {
            c.wgpuQueueWriteBuffer(ctx.queue, self.ptr, 0, &std.mem.toBytes(value), @sizeOf(T));
        }

        pub fn binding(self: Self) BindGroupEntry.BufferEntry {
            return .{ .buffer = self.ptr, .offset = 0, .size = @sizeOf(T) };
        }

        pub fn deinit(self: Self) void {
            c.wgpuBufferDestroy(self.ptr);
        }
    };
}

pub fn StorageArray(Element: type) type {
    return struct {
        ptr: c.WGPUBuffer,
        capacity: u32,

        const Self = @This();
        const stride: u64 = @sizeOf(Element);

        pub fn initCapacity(ctx: GPUContext, capacity: u32, config: StorageConfig) !Self {
            return .{
                .ptr = try createStorageBuffer(ctx, capacity * stride, config),
                .capacity = capacity,
            };
        }

        pub fn upload(self: Self, ctx: GPUContext, items: []const Element) !void {
            if (items.len > self.capacity) return error.CapacityExceeded;
            // `size` is a size_t, which is 32-bit on wasm while `stride` is a
            // WebGPU u64 -- so the product has to be narrowed explicitly.
            c.wgpuQueueWriteBuffer(ctx.queue, self.ptr, 0, items.ptr, @intCast(items.len * stride));
        }

        pub fn binding(self: Self) BindGroupEntry.BufferEntry {
            return .{ .buffer = self.ptr, .offset = 0, .size = self.capacity * stride };
        }

        pub fn deinit(self: Self) void {
            c.wgpuBufferDestroy(self.ptr);
        }
    };
}

pub fn StorageBuffer(Header: type, Element: type) type {
    return struct {
        ptr: c.WGPUBuffer,
        capacity: u32,

        const Self = @This();
        const items_offset: u64 = @sizeOf(Header);
        const stride: u64 = @sizeOf(Element);

        pub fn initCapacity(ctx: GPUContext, capacity: u32, config: StorageConfig) !Self {
            return .{
                .ptr = try createStorageBuffer(ctx, items_offset + capacity * stride, config),
                .capacity = capacity,
            };
        }

        pub fn upload(self: Self, ctx: GPUContext, header: Header, items: []const Element) !void {
            try self.uploadItems(ctx, items);
            self.uploadHeader(ctx, header);
        }

        pub fn uploadHeader(self: Self, ctx: GPUContext, header: Header) void {
            c.wgpuQueueWriteBuffer(ctx.queue, self.ptr, 0, &std.mem.toBytes(header), @sizeOf(Header));
        }

        pub fn uploadItems(self: Self, ctx: GPUContext, items: []const Element) !void {
            if (items.len > self.capacity) return error.CapacityExceeded;
            c.wgpuQueueWriteBuffer(ctx.queue, self.ptr, items_offset, items.ptr, items.len * stride);
        }

        pub fn binding(self: Self) BindGroupEntry.BufferEntry {
            return .{ .buffer = self.ptr, .offset = 0, .size = items_offset + self.capacity * stride };
        }

        pub fn deinit(self: Self) void {
            c.wgpuBufferDestroy(self.ptr);
        }
    };
}

fn StorageWrapper(comptime shape: StorageShape) type {
    return switch (shape) {
        .value => |T| StorageValue(T),
        .array => |Element| StorageArray(Element),
        .buffer => |b| StorageBuffer(b.Header, b.Element),
    };
}

fn UniformNamespace(Reflected: type) type {
    const count = blk: {
        var n: usize = 0;
        for (Reflected.Uniforms) |maybe_group| {
            const group = maybe_group orelse continue;
            n += group.len;
        }
        break :blk n;
    };

    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;

    var i: usize = 0;
    for (Reflected.Uniforms) |maybe_group| {
        const group = maybe_group orelse continue;
        for (group) |entry| {
            names[i] = entry.name;
            types[i] = type;
            attrs[i] = .{
                .@"comptime" = true,
                .default_value_ptr = @ptrCast(&UniformValue(entry.Type)),
            };
            i += 1;
        }
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

fn StorageNamespace(Reflected: type) type {
    const count = blk: {
        var n: usize = 0;
        for (Reflected.Resources) |maybe_group| {
            const group = maybe_group orelse continue;
            for (group) |entry| switch (entry.resource_type) {
                .storage => n += 1,
                else => {},
            };
        }
        break :blk n;
    };

    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;

    var i: usize = 0;
    for (Reflected.Resources) |maybe_group| {
        const group = maybe_group orelse continue;
        for (group) |entry| {
            const shape = switch (entry.resource_type) {
                .storage => |s| s,
                else => continue,
            };
            names[i] = entry.name;
            types[i] = type;
            attrs[i] = .{
                .@"comptime" = true,
                .default_value_ptr = @ptrCast(&StorageWrapper(shape)),
            };
            i += 1;
        }
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn Shader(Reflected: type) type {
    return struct {
        pub const reflected = Reflected;
        pub const Uniform: UniformNamespace(Reflected) = .{};
        pub const Storage: StorageNamespace(Reflected) = .{};

        pub fn BindGroup(comptime index: u32) type {
            return ShaderBindGroup(Reflected, index);
        }
    };
}

pub const VertexInputMeta = struct {
    location: u32,
    name: []const u8,
};

pub fn ShaderBindGroup(Reflected: type, comptime index: u32) type {
    if (Reflected.layouts[index] == null) {
        @compileError("This group is not defined in the shader");
    }

    const uniforms_meta: ?[]const BindGroupUniformEntryMeta = Reflected.Uniforms[index];
    const resources_meta: ?[]const BindGroupResourceEntryMeta = Reflected.Resources[index];

    const uniform_count = if (uniforms_meta) |um| um.len else 0;
    const resource_count = if (resources_meta) |rm| rm.len else 0;

    comptime {
        const declared = Reflected.layouts[index].?.len;
        if (declared != uniform_count + resource_count) {
            @compileError(std.fmt.comptimePrint(
                "group {d} of '{s}': layout declares {d} bindings but reflection lists {d} " ++
                    "({d} uniform + {d} resource)",
                .{ index, Reflected.NAME, declared, uniform_count + resource_count, uniform_count, resource_count },
            ));
        }
    }

    const ResourcesStruct: type = comptime blk: {
        const total = uniform_count + resource_count;
        if (total == 0) break :blk struct {};

        var field_names: [total][]const u8 = undefined;
        var field_types: [total]type = undefined;
        var field_attrs: [total]std.builtin.Type.StructField.Attributes = undefined;
        var i: usize = 0;

        if (uniforms_meta) |um| for (um) |meta| {
            field_names[i] = meta.name;
            field_types[i] = BindGroupEntry.BufferEntry;
            field_attrs[i] = .{};
            i += 1;
        };

        if (resources_meta) |rm| for (rm) |meta| {
            field_names[i] = meta.name;
            field_types[i] = switch (meta.resource_type) {
                .storage => BindGroupEntry.BufferEntry,
                .texture => c.WGPUTextureView,
                .sampler => c.WGPUSampler,
            };
            field_attrs[i] = .{};
            i += 1;
        };

        break :blk @Struct(
            .auto,
            null,
            &field_names,
            &field_types,
            &field_attrs,
        );
    };

    return struct {
        resources: ResourcesStruct,
        layout: c.WGPUBindGroupLayout,
        group: BindGroup,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, ctx: GPUContext, resources: ResourcesStruct) !Self {
            var group_entries: [uniform_count + resource_count]BindGroupEntry = undefined;
            var group_entries_index: usize = 0;

            if (uniforms_meta) |um| {
                inline for (um) |u| {
                    group_entries[group_entries_index] =
                        .{
                            .binding = u.binding,
                            .resource = .{ .buffer = @field(resources, u.name) },
                        };
                    group_entries_index += 1;
                }
            }

            if (resources_meta) |rm| {
                inline for (rm) |r| {
                    const value = @field(resources, r.name);
                    group_entries[group_entries_index] =
                        .{
                            .binding = r.binding,
                            .resource = switch (r.resource_type) {
                                .storage => .{ .buffer = value },
                                .texture => .{ .texture_view = value },
                                .sampler => .{ .sampler = value },
                            },
                        };
                    group_entries_index += 1;
                }
            }

            const group_layout = try createBindGroupLayout(allocator, ctx, Reflected.layouts[index].?);

            const group = try createBindGroup(allocator, ctx, .{
                .layout = group_layout,
                .entries = &group_entries,
            });

            return .{
                .resources = resources,
                .layout = group_layout,
                .group = .{ .ptr = group, .index = index },
            };
        }

        pub fn deinit(self: Self) void {
            c.wgpuBindGroupRelease(self.group.ptr);
            c.wgpuBindGroupLayoutRelease(self.layout);
        }
    };
}

// Translate gpu.zig bind group layouts to WebGPU bind group layouts
pub fn createBindGroupLayout(allocator: std.mem.Allocator, ctx: GPUContext, entries: []const BindGroupLayoutEntry) !c.WGPUBindGroupLayout {
    var desc = z_WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT();
    desc.entryCount = entries.len;

    var layout_entries = try allocator.alloc(c.WGPUBindGroupLayoutEntry, entries.len);
    defer allocator.free(layout_entries);

    for (entries, 0..) |entry, i| {
        var layout_entry = z_WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT();
        layout_entry.binding = entry.binding;
        layout_entry.visibility = entry.visibility;
        switch (entry.type) {
            .buffer => |buf| {
                var buffer_layout = z_WGPU_BUFFER_BINDING_LAYOUT_INIT();
                buffer_layout.type = @intFromEnum(buf.type);
                buffer_layout.hasDynamicOffset = @intFromBool(buf.has_dynamic_offset);
                buffer_layout.minBindingSize = buf.min_binding_size;
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
        layout_entries[i] = layout_entry;
    }

    desc.entries = layout_entries.ptr;

    const layout = c.wgpuDeviceCreateBindGroupLayout(ctx.device, &desc);
    if (layout == null) {
        std.log.err("Failed to create bind group layout", .{});
        return error.BindGroupLayoutCreationFailed;
    }
    return layout;
}

pub fn createBindGroupLayouts(
    allocator: std.mem.Allocator,
    ctx: GPUContext,
    groups: []const []const BindGroupLayoutEntry,
) ![]const c.WGPUBindGroupLayout {
    var bg_layouts = try allocator.alloc(c.WGPUBindGroupLayout, groups.len);
    for (groups, 0..) |entries, i| {
        bg_layouts[i] = try createBindGroupLayout(allocator, ctx, entries);
    }
    return bg_layouts;
}

pub fn createShader(
    ctx: GPUContext,
    src: []const u8,
    label: []const u8,
) !c.WGPUShaderModule {
    var desc = z_WGPU_SHADER_MODULE_DESCRIPTOR_INIT();
    desc.label = toWGPUString(label);
    var source = z_WGPU_SHADER_SOURCE_WGSL_INIT();
    source.code = toWGPUString(src);
    source.chain.next = null;
    source.chain.sType = c.WGPUSType_ShaderSourceWGSL;

    desc.nextInChain = &source.chain;

    const module = c.wgpuDeviceCreateShaderModule(ctx.device, &desc);
    if (module == null) {
        std.log.err("ShaderManager: wgpuDeviceCreateShaderModule failed for '{s}'", .{label});
        return error.ShaderModuleCreationFailed;
    }
    return module;
}

pub fn createPipeline(
    allocator: std.mem.Allocator,
    ctx: GPUContext,
    label: []const u8,
    descriptor: PipelineDescriptor,
    vertex_entry: ?[]const u8,
    fragment_entry: ?[]const u8,
    bind_group_layouts: ?[]const c.WGPUBindGroupLayout,
) !c.WGPURenderPipeline {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var desc = z_WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT();
    desc.label = toWGPUString(label);

    if (bind_group_layouts) |bgls| {
        var pipeline_layout_desc = z_WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT();
        pipeline_layout_desc.bindGroupLayoutCount = bgls.len;
        pipeline_layout_desc.bindGroupLayouts = bgls.ptr;
        const layout = c.wgpuDeviceCreatePipelineLayout(ctx.device, &pipeline_layout_desc);
        if (layout == null) {
            std.log.err("PipelineCache: wgpuDeviceCreatePipelineLayout failed for '{s}'", .{label});
            return error.PipelineLayoutCreationFailed;
        }
        desc.layout = layout;
    }

    if (vertex_entry) |ve| {
        var vertex_state = z_WGPU_VERTEX_STATE_INIT();
        vertex_state.module = descriptor.shader_module;
        vertex_state.entryPoint = toWGPUString(ve);

        const buffers = try temp.alloc(c.WGPUVertexBufferLayout, descriptor.vertex_layouts.len);
        for (descriptor.vertex_layouts, 0..) |vertex_layout, li| {
            buffers[li] = z_WGPU_VERTEX_BUFFER_LAYOUT_INIT();
            buffers[li].stepMode = @intFromEnum(vertex_layout.step_mode);
            buffers[li].arrayStride = vertex_layout.array_stride;
            buffers[li].attributeCount = vertex_layout.attributes.len;
            var attributes = try temp.alloc(c.WGPUVertexAttribute, vertex_layout.attributes.len);
            for (0..vertex_layout.attributes.len) |ai| {
                const attribute = vertex_layout.attributes[ai];
                attributes[ai] = z_WGPU_VERTEX_ATTRIBUTE_INIT();
                attributes[ai].offset = attribute.offset;
                attributes[ai].format = @intFromEnum(attribute.format);
                attributes[ai].shaderLocation = attribute.shader_location;
            }
            buffers[li].attributes = attributes.ptr;
        }

        vertex_state.bufferCount = descriptor.vertex_layouts.len;
        vertex_state.buffers = buffers.ptr;

        desc.vertex = vertex_state;
    }

    // TODO handle constants

    // TODO multi target rendering
    if (fragment_entry) |fe| {
        var fragment_state = z_WGPU_FRAGMENT_STATE_INIT();
        fragment_state.module = descriptor.shader_module;
        fragment_state.entryPoint = toWGPUString(fe);
        fragment_state.targetCount = 1;

        var target_state = z_WGPU_COLOR_TARGET_STATE_INIT();
        target_state.format = @intFromEnum(descriptor.color_format);

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
    }

    // TODO consider covering other fields
    var primitive_state = z_WGPU_PRIMITIVE_STATE_INIT();
    primitive_state.topology = @intFromEnum(descriptor.primitive_topology);
    primitive_state.cullMode = @intFromEnum(descriptor.cull_mode);
    primitive_state.frontFace = c.WGPUFrontFace_CCW;
    desc.primitive = primitive_state;

    if (descriptor.depth_stencil) |ds| {
        var depth_stencil_state = z_WGPU_DEPTH_STENCIL_STATE_INIT();
        depth_stencil_state.format = @intFromEnum(descriptor.depth_format.?);
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

    const pipeline = c.wgpuDeviceCreateRenderPipeline(ctx.device, &desc);
    if (pipeline == null) {
        std.log.err("Failed to create pipeline for '{s}'", .{label});
        return error.PipelineCreationFailed;
    }

    return pipeline;
}

pub fn createBindGroup(
    allocator: std.mem.Allocator,
    ctx: GPUContext,
    descriptor: BindGroupDescriptor,
) !c.WGPUBindGroup {
    var desc = z_WGPU_BIND_GROUP_DESCRIPTOR_INIT();
    desc.layout = descriptor.layout;
    desc.entryCount = descriptor.entries.len;

    var entries = try allocator.alloc(c.WGPUBindGroupEntry, descriptor.entries.len);
    defer allocator.free(entries);
    for (0..descriptor.entries.len) |i| {
        const desc_entry = descriptor.entries[i];
        var entry = z_WGPU_BIND_GROUP_ENTRY_INIT();
        entry.binding = desc_entry.binding;
        switch (desc_entry.resource) {
            .buffer => |b| {
                entry.buffer = b.buffer;
                entry.offset = b.offset;
                entry.size = b.size;
            },
            .sampler => |s| {
                entry.sampler = s;
            },
            .texture_view => |tv| {
                entry.textureView = tv;
            },
        }
        entries[i] = entry;
    }

    desc.entries = entries.ptr;

    const bind_group = c.wgpuDeviceCreateBindGroup(ctx.device, &desc);
    if (bind_group == null) {
        std.log.err("Failed to create bind group\n", .{});
        return error.BindGroupCreationFailed;
    }
    return bind_group;
}

pub const Instances = struct {
    buffers: []const VertexBuffer,
    count: u32,

    pub fn initCount(count: u32) @This() {
        return .{ .buffers = &.{}, .count = count };
    }
};

pub const VertexBuffer = struct {
    ptr: c.WGPUBuffer,
    stride: u32,
    attributes: []const AttributeDesc,

    pub const AttributeDesc = struct {
        location: u32,
        format: VertexFormat,
        offset: u32,
    };
};

pub const Mesh = struct {
    buffers: []const VertexBuffer,
    indices: ?IndexBuffer = null,
    vertex_count: u32,

    pub const IndexBuffer = struct {
        buffer: c.WGPUBuffer,
        format: Format,
        index_count: u32,

        pub const Format = enum(c.WGPUIndexFormat) {
            undefined = c.WGPUIndexFormat_Undefined,
            u16 = c.WGPUIndexFormat_Uint16,
            u32 = c.WGPUIndexFormat_Uint32,

            pub fn byteSize(self: @This()) u64 {
                return switch (self) {
                    .u16 => 2,
                    .u32 => 4,
                    .undefined => unreachable,
                };
            }
        };

        /// Byte span of the whole index range, for `SetIndexBuffer`.
        pub fn byteLength(self: @This()) u64 {
            return self.index_count * self.format.byteSize();
        }
    };
};

pub fn createPipelineFromMesh(
    Reflected: type,
    allocator: std.mem.Allocator,
    ctx: GPUContext,
    mesh: Mesh,
    instance_buffers: []const VertexBuffer,
    bind_group_layouts: ?[]const c.WGPUBindGroupLayout,
    config: struct {
        color_format: TextureFormat,
        label: ?[]const u8 = null,
        depth_stencil_state: ?DepthStencilState = null,
        depth_format: ?TextureFormat = null,
    },
) !c.WGPURenderPipeline {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();
    const shader_module = try createShader(ctx, Reflected.SOURCE, "vert color");

    var vertex_layouts: std.ArrayList(VertexBufferLayout) = .empty;
    for (mesh.buffers) |buf| {
        const stride = buf.stride;
        var vertex_attributes: std.ArrayList(VertexBufferLayout.VertexAttribute) = .empty;
        for (buf.attributes) |attr| {
            try vertex_attributes.append(arena_alloc, .{
                .offset = attr.offset,
                .format = attr.format,
                .shader_location = attr.location,
            });
        }
        try vertex_layouts.append(arena_alloc, .{
            .attributes = vertex_attributes.items,
            .array_stride = stride,
            .step_mode = .vertex,
        });
    }

    for (instance_buffers) |buf| {
        const stride = buf.stride;
        var vertex_attributes: std.ArrayList(VertexBufferLayout.VertexAttribute) = .empty;
        for (buf.attributes) |attr| {
            try vertex_attributes.append(arena_alloc, .{
                .offset = attr.offset,
                .format = attr.format,
                .shader_location = attr.location,
            });
        }
        try vertex_layouts.append(arena_alloc, .{
            .attributes = vertex_attributes.items,
            .array_stride = stride,
            .step_mode = .instance,
        });
    }

    const pipeline_descriptor: PipelineDescriptor = .{
        .color_format = config.color_format,
        .shader_module = shader_module,
        .vertex_layouts = vertex_layouts.items,
        .depth_stencil = config.depth_stencil_state,
        .depth_format = config.depth_format,
    };

    return try createPipeline(
        allocator,
        ctx,
        if (config.label) |label| label else "Pipeline",
        pipeline_descriptor,
        Reflected.VS,
        Reflected.FS,
        bind_group_layouts,
    );
}

pub const BindGroup = struct {
    ptr: c.WGPUBindGroup,
    index: u32,
};

pub const DrawObject = struct {
    mesh: Mesh,
    pipeline: c.WGPURenderPipeline,
    bind_groups: []const BindGroup,
    instances: Instances,
};

pub const DepthStencilAttachment = struct {
    depth_clear_value: f32 = 1.0,
    depth_load_op: LoadOp = .clear,
    depth_store_op: StoreOp = .store,
    view: c.WGPUTextureView,
};

pub const ColorAttachment = struct {
    clear_value: Color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
};

pub const RenderPassConfig = struct {
    color_attachment: ColorAttachment = .{},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
    label: []const u8 = "render pass",
};

pub const RenderPass = struct {
    render_pass: c.WGPURenderPassEncoder,

    const Self = @This();

    pub fn init(
        encoder: c.WGPUCommandEncoder,
        target_view: c.WGPUTextureView,
        config: RenderPassConfig,
    ) Self {
        var desc = z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();
        desc.label = toWGPUString(config.label);

        var color_attachment = z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
        color_attachment.view = target_view;
        color_attachment.loadOp = @intFromEnum(config.color_attachment.load_op);
        color_attachment.storeOp = @intFromEnum(config.color_attachment.store_op);
        color_attachment.clearValue = c.WGPUColor{
            .r = config.color_attachment.clear_value.r,
            .g = config.color_attachment.clear_value.g,
            .b = config.color_attachment.clear_value.b,
            .a = config.color_attachment.clear_value.a,
        };
        desc.colorAttachmentCount = 1;
        desc.colorAttachments = &color_attachment;

        if (config.depth_stencil_attachment) |dsa| {
            var depth_stencil_attachment = z_WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT();
            depth_stencil_attachment.depthClearValue = dsa.depth_clear_value;
            depth_stencil_attachment.depthLoadOp = @intFromEnum(dsa.depth_load_op);
            depth_stencil_attachment.depthStoreOp = @intFromEnum(dsa.depth_store_op);
            depth_stencil_attachment.view = dsa.view;

            desc.depthStencilAttachment = &depth_stencil_attachment;
        }

        const render_pass_encoder = c.wgpuCommandEncoderBeginRenderPass(encoder, &desc);

        return .{
            .render_pass = render_pass_encoder,
        };
    }

    pub fn draw(self: Self, draw_object: DrawObject) void {
        c.wgpuRenderPassEncoderSetPipeline(self.render_pass, draw_object.pipeline);
        for (draw_object.bind_groups) |bg| {
            c.wgpuRenderPassEncoderSetBindGroup(
                self.render_pass,
                bg.index,
                bg.ptr,
                0,
                null,
            );
        }
        var buffer_index: u32 = 0;
        for (draw_object.mesh.buffers) |buf| {
            c.wgpuRenderPassEncoderSetVertexBuffer(
                self.render_pass,
                buffer_index,
                buf.ptr,
                0,
                draw_object.mesh.vertex_count * buf.stride,
            );
            buffer_index += 1;
        }
        for (draw_object.instances.buffers) |buf| {
            c.wgpuRenderPassEncoderSetVertexBuffer(
                self.render_pass,
                buffer_index,
                buf.ptr,
                0,
                draw_object.instances.count * buf.stride,
            );
            buffer_index += 1;
        }
        if (draw_object.mesh.indices) |ib| {
            c.wgpuRenderPassEncoderSetIndexBuffer(
                self.render_pass,
                ib.buffer,
                @intFromEnum(ib.format),
                0,
                ib.byteLength(),
            );

            c.wgpuRenderPassEncoderDrawIndexed(
                self.render_pass,
                ib.index_count,
                draw_object.instances.count,
                0,
                0,
                0,
            );
        } else {
            c.wgpuRenderPassEncoderDraw(
                self.render_pass,
                draw_object.mesh.vertex_count,
                draw_object.instances.count,
                0,
                0,
            );
        }
    }

    pub fn end(self: Self) void {
        c.wgpuRenderPassEncoderEnd(self.render_pass);
        c.wgpuRenderPassEncoderRelease(self.render_pass);
    }
};

pub const TexelData = struct {
    data: []const u8,
    format: TextureFormat,
    width: u32,
    height: u32,
};

pub const Texture = struct {
    ptr: c.WGPUTexture,
    width: u32,
    height: u32,
    format: TextureFormat,

    const Self = @This();

    pub fn init(
        ctx: GPUContext,
        label: []const u8,
        width: u32,
        height: u32,
        dimension: TextureDimension,
        format: TextureFormat,
        usage: TextureUsage,
    ) Self {
        const size: c.WGPUExtent3D = .{
            .width = width,
            .height = height,
            .depthOrArrayLayers = 1,
        };

        var desc = z_WGPU_TEXTURE_DESCRIPTOR_INIT();
        desc.label = toWGPUString(label);
        desc.dimension = @intFromEnum(dimension);
        desc.format = @intFromEnum(format);
        desc.size = size;
        desc.usage = usage.toC();

        const texture = c.wgpuDeviceCreateTexture(ctx.device, &desc);

        return .{
            .ptr = texture,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn writeTexture(
        self: Self,
        ctx: GPUContext,
        data: TexelData,
        write_size: struct {
            width: ?u32 = null,
            height: ?u32 = null,
            depthOrArrayLayers: u32 = 1,
        },
    ) void {
        var dest = z_WGPU_TEXEL_COPY_TEXTURE_INFO_INIT();
        dest.texture = self.ptr;

        const extent: c.WGPUExtent3D = .{
            .width = write_size.width orelse data.width,
            .height = write_size.height orelse data.height,
            .depthOrArrayLayers = write_size.depthOrArrayLayers,
        };

        var layout = z_WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT();
        layout.offset = 0;
        layout.bytesPerRow = data.format.sizeOf().? * data.width;
        layout.rowsPerImage = data.height;

        c.wgpuQueueWriteTexture(
            ctx.queue,
            &dest,
            data.data.ptr,
            data.data.len,
            &layout,
            &extent,
        );
    }

    pub fn createView(self: Self, label: []const u8) c.WGPUTextureView {
        var desc = z_WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT();
        desc.label = toWGPUString(label);

        return c.wgpuTextureCreateView(self.ptr, &desc);
    }

    pub fn deinit(self: Self) void {
        c.wgpuTextureRelease(self.ptr);
    }
};

pub fn createSampler(ctx: GPUContext, label: []const u8) c.WGPUSampler {
    var desc = z_WGPU_SAMPLER_DESCRIPTOR_INIT();
    desc.label = toWGPUString(label);
    return c.wgpuDeviceCreateSampler(ctx.device, &desc);
}
