const std = @import("std");
const gpu = @import("gpu.zig");
const build_options = @import("build_options");
const c = gpu.c;

pub const ShaderHandle = enum(u32) { _ };
pub const BufferHandle = enum(u32) { _ };
pub const TextureHandle = enum(u32) { _ };
pub const TextureViewHandle = enum(u32) { _ };
pub const SamplerHandle = enum(u32) { _ };
pub const BindGroupHandle = enum(u32) { _ };

pub const MAX_BIND_GROUP_COUNT = 4;

pub const Color = gpu.Color;

pub const ColorAttachment = struct {
    clear_value: Color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
    load_op: gpu.LoadOp = .clear,
    store_op: gpu.StoreOp = .store,
};

pub const DepthStencilAttachment = struct {
    depth_clear_value: f32 = 1.0,
    depth_load_op: gpu.LoadOp = .clear,
    depth_store_op: gpu.StoreOp = .store,
};

pub const RenderPassConfig = struct {
    color_attachment: ColorAttachment = .{},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
    label: []const u8 = "render pass",
};

pub const RenderPass = struct {
    render_pass: c.WGPURenderPassEncoder,
    shader_manager: *const ShaderManager,
    bind_group_layout_cache: *BindGroupLayoutCache,
    bind_group_cache: *BindGroupCache,

    const Self = @This();

    pub fn init(
        encoder: c.WGPUCommandEncoder,
        target_view: c.WGPUTextureView,
        bind_group_layout_cache: *BindGroupLayoutCache,
        bind_group_cache: *BindGroupCache,
        shader_manager: *const ShaderManager,
        config: RenderPassConfig,
    ) Self {
        var desc = gpu.z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();
        desc.label = gpu.toWGPUString(config.label);

        var color_attachment = gpu.z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
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

        const render_pass_encoder = c.wgpuCommandEncoderBeginRenderPass(encoder, &desc);

        return .{
            .render_pass = render_pass_encoder,
            .bind_group_layout_cache = bind_group_layout_cache,
            .bind_group_cache = bind_group_cache,
            .shader_manager = shader_manager,
        };
    }

    pub fn setPipeline(self: *Self, pipeline: c.WGPURenderPipeline) void {
        c.wgpuRenderPassEncoderSetPipeline(self.render_pass, pipeline);
    }

    pub fn setVertexBuffer(self: *Self, slot: u32, buffer: c.WGPUBuffer, offset: u64, size: u64) void {
        c.wgpuRenderPassEncoderSetVertexBuffer(self.render_pass, slot, buffer, offset, size);
    }

    pub fn setBindGroup(self: *Self, group_index: u32, bind_group: c.WGPUBindGroup) void {
        c.wgpuRenderPassEncoderSetBindGroup(self.render_pass, group_index, bind_group, 0, null);
    }

    /// Convenience: looks up the layout from shader metadata, resolves the bind group,
    /// and calls setBindGroup. The caller provides pre-resolved raw WebGPU resources.
    pub fn bindGroup(
        self: *Self,
        allocator: std.mem.Allocator,
        group_index: u32,
        shader_handle: ShaderHandle,
        entries: []const BindGroupEntry,
    ) !void {
        const shader = self.shader_manager.getShader(shader_handle) orelse {
            std.log.err("RenderPass.bindGroup: shader handle {d} not found", .{@intFromEnum(shader_handle)});
            return error.ShaderNotFound;
        };
        const bgl = shader.metadata.bind_group_layouts orelse {
            std.log.err("RenderPass.bindGroup: shader has no bind group layouts", .{});
            return error.ShaderHasNoBindGroups;
        };
        if (group_index >= bgl.len) {
            std.log.err("RenderPass.bindGroup: group index {d} out of range (shader has {d} groups)", .{ group_index, bgl.len });
            return error.BindGroupIndexOutOfRange;
        }

        const layout = try self.bind_group_layout_cache.getOrCreateBindGroupLayout(allocator, bgl[group_index]);
        const bg = try self.bind_group_cache.getOrCreateBindingGroup(allocator, .{
            .layout = layout,
            .entries = entries,
        });
        self.setBindGroup(group_index, bg);
    }

    pub fn draw(self: *Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        c.wgpuRenderPassEncoderDraw(self.render_pass, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn end(self: *Self) void {
        c.wgpuRenderPassEncoderEnd(self.render_pass);
    }

    pub fn deinit(self: *Self) void {
        c.wgpuRenderPassEncoderRelease(self.render_pass);
    }
};

pub const StencilFaceState = struct {
    compare: gpu.CompareFunction,
    fail_op: gpu.StencilOperation,
    depth_fail_op: gpu.StencilOperation,
    pass_op: gpu.StencilOperation,
};

pub const DepthStencilState = struct {
    depth_write_enabled: bool,
    depth_compare: gpu.CompareFunction,
    stencil_front: ?StencilFaceState = null,
    stencil_back: ?StencilFaceState = null,
    stencil_read_mask: u32 = 0xFFFFFFFF,
    stencil_write_mask: u32 = 0xFFFFFFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
};

pub const BlendComponent = struct {
    operation: gpu.BlendOperation,
    src_factor: gpu.BlendFactor,
    dst_factor: gpu.BlendFactor,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const VertexLayout = struct {
    step_mode: StepMode,
    array_stride: u64,
    attribute_count: u32,
    attributes: [MAX_ATTRIBUTES]VertexAttribute = std.mem.zeroes([MAX_ATTRIBUTES]VertexAttribute),

    const MAX_ATTRIBUTES = 16;

    pub const VertexAttribute = struct {
        format: gpu.VertexFormat = .u8,
        offset: u64 = 0,
        shader_location: u32 = 0,
    };

    pub const StepMode = enum(c.WGPUVertexStepMode) {
        undefined = c.WGPUVertexStepMode_Undefined,
        vertex = c.WGPUVertexStepMode_Vertex,
        instance = c.WGPUVertexStepMode_Instance,
    };
};

const MAX_VERTEX_LAYOUT_COUNT = 8;

pub const PipelineDescriptor = struct {
    color_format: ?gpu.TextureFormat = null,
    depth_format: ?gpu.TextureFormat = null,
    shader_module: c.WGPUShaderModule,
    vertex_layout_count: u32,
    vertex_layouts: [MAX_VERTEX_LAYOUT_COUNT]VertexLayout = std.mem.zeroes([MAX_VERTEX_LAYOUT_COUNT]VertexLayout),
    primitive_topology: gpu.PrimitiveTopology = .triangle_list,
    depth_stencil: ?DepthStencilState = .{
        .depth_write_enabled = true,
        .depth_compare = .less,
    },
    blend: ?BlendState = null,
    cull_mode: gpu.CullMode = .back,
};

pub const ShaderManager = struct {
    shaders: std.ArrayList(Shader),
    device: c.WGPUDevice,

    pub const ShaderReflectionJSON = struct {
        entry_points: []const EntryPointEntry,

        pub const EntryPointEntry = struct {
            name: []const u8,
            stage: []const u8,
            input_variables: []const InputVariableEntry,
            bindings: []const BindingEntry,
        };

        pub const InputVariableEntry = struct {
            name: []const u8,
            location: usize,
            component_type: []const u8,
            composition_type: []const u8,
        };

        pub const BindingEntry = struct {
            binding: usize,
            group: usize,
            size: usize,
            resource_type: []const u8,

            // Todo support smapler and Texture

        };
    };

    pub const Metadata = struct {
        vertex_entry: ?[]const u8 = null,
        fragment_entry: ?[]const u8 = null,
        bind_group_layouts: ?[]const []const gpu.BindGroupLayoutEntry = null,
        vertex_inputs: ?[]const gpu.VertexInput = &.{},
        arena_allocator: std.heap.ArenaAllocator,

        pub fn getBindingType(resource_type: []const u8) !gpu.BindingType {
            const map = std.StaticStringMap(gpu.BindingType).initComptime(.{
                .{
                    "UniformBuffer", gpu.BindingType{
                        .buffer = .uniform,
                    },
                },
                // TODO rest (add as needed)
            });

            return map.get(resource_type) orelse error.BindingTypeNotImplemented;
        }

        pub fn fromShadeSource(allocator: std.mem.Allocator, source_path: []const u8) !@This() {
            var arena_allocator = std.heap.ArenaAllocator.init(allocator);
            errdefer arena_allocator.deinit();
            const arena = arena_allocator.allocator();

            var child = std.process.Child.init(&.{ build_options.tint_path, source_path, "--json" }, allocator);
            child.stdout_behavior = .Pipe;
            _ = try child.spawn();

            var stream: [512]u8 = undefined;
            var json_buffer: [4096]u8 = undefined;

            var reader = child.stdout.?.readerStreaming(&stream);
            const read_bytes = try reader.interface.readSliceShort(&json_buffer);

            _ = try child.wait();

            const reflection_json: std.json.Parsed(ShaderReflectionJSON) = try std.json.parseFromSlice(
                ShaderReflectionJSON,
                allocator,
                json_buffer[0..read_bytes],
                .{ .ignore_unknown_fields = true },
            );
            defer reflection_json.deinit();

            var metadata: Metadata = .{ .arena_allocator = arena_allocator };

            var bind_groups: [MAX_BIND_GROUP_COUNT]?std.ArrayListUnmanaged(gpu.BindGroupLayoutEntry) = .{null} ** MAX_BIND_GROUP_COUNT;
            var max_bind_group_index: ?usize = null;

            for (reflection_json.value.entry_points) |ep| {
                if (ep.bindings.len > 0) {
                    for (ep.bindings) |be| {
                        max_bind_group_index = @max(be.group, max_bind_group_index orelse 0);
                        var list_p = blk: {
                            if (bind_groups[be.group]) |*ls| {
                                break :blk ls;
                            } else {
                                bind_groups[be.group] = try .initCapacity(arena, 4);
                                break :blk &bind_groups[be.group].?;
                            }
                        };
                        try list_p.append(
                            arena,
                            .{
                                .binding = @intCast(be.binding),
                                .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment,
                                .type = try getBindingType(be.resource_type),
                            },
                        );
                    }
                }

                if (std.mem.eql(u8, ep.stage, "vertex")) {
                    const name = try arena.alloc(u8, ep.name.len);
                    @memcpy(name, ep.name);
                    metadata.vertex_entry = name;

                    if (ep.input_variables.len > 0) {
                        var vertex_inputs = try arena.alloc(gpu.VertexInput, ep.input_variables.len);
                        for (ep.input_variables, 0..) |iv, i| {
                            vertex_inputs[i] = .{
                                .location = @intCast(iv.location),
                                .format = gpu.VertexFormat.getFormComponents(
                                    iv.component_type,
                                    iv.composition_type,
                                ),
                            };
                        }
                        metadata.vertex_inputs = vertex_inputs;
                    }
                } else if (std.mem.eql(u8, ep.stage, "fragment")) {
                    const name = try arena.alloc(u8, ep.name.len);
                    @memcpy(name, ep.name);
                    metadata.fragment_entry = name;
                } else {
                    return error.FragmentAndVertexOnly;
                }
            }

            if (max_bind_group_index) |mbi| {
                const bind_group_count = mbi + 1;
                var bgs = try arena.alloc([]const gpu.BindGroupLayoutEntry, bind_group_count);
                for (0..bind_group_count) |i| {
                    bgs[i] = try bind_groups[i].?.toOwnedSlice(arena);
                }

                metadata.bind_group_layouts = bgs;
            }

            return metadata;
        }

        pub fn deinit(self: *@This()) void {
            self.arena_allocator.deinit();
        }
    };

    pub const Shader = struct {
        module: c.WGPUShaderModule,
        metadata: Metadata,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        device: c.WGPUDevice,
    ) !Self {
        return .{
            .shaders = try .initCapacity(allocator, 8),
            .device = device,
        };
    }

    pub fn createShader(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime source_path: []const u8,
        label: []const u8,
    ) !ShaderHandle {
        const source_code = @embedFile(source_path);

        var desc = gpu.z_WGPU_SHADER_MODULE_DESCRIPTOR_INIT();
        desc.label = gpu.toWGPUString(label);
        var source = gpu.z_WGPU_SHADER_SOURCE_WGSL_INIT();
        source.code = gpu.toWGPUString(source_code);
        source.chain.next = null;
        source.chain.sType = c.WGPUSType_ShaderSourceWGSL;

        desc.nextInChain = &source.chain;

        const metadata = try Metadata.fromShadeSource(allocator, source_path);

        const module = c.wgpuDeviceCreateShaderModule(self.device, &desc);
        if (module == null) {
            std.log.err("ShaderManager: wgpuDeviceCreateShaderModule failed for '{s}'", .{label});
            return error.ShaderModuleCreationFailed;
        }

        try self.shaders.append(allocator, .{
            .module = module,
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
        for (self.shaders.items) |*shader| {
            c.wgpuShaderModuleRelease(shader.module);
            shader.metadata.deinit();
        }
        self.shaders.deinit(allocator);
    }
};

pub const ResourceManager = struct {
    // TODO: add generational indices for use after free tracking

    buffers: std.ArrayList(BufferEntry),
    textures: std.ArrayList(c.WGPUTexture),
    samplers: std.ArrayList(c.WGPUSampler),
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    const Self = @This();

    pub const BufferEntry = struct {
        ptr: c.WGPUBuffer,
        byte_size: usize,
    };

    pub fn init(allocator: std.mem.Allocator, device: c.WGPUDevice, queue: c.WGPUQueue) !Self {
        const INITIAL_CAPACITY = 16;
        return .{
            .buffers = try .initCapacity(allocator, INITIAL_CAPACITY),
            .textures = try .initCapacity(allocator, INITIAL_CAPACITY),
            .samplers = try .initCapacity(allocator, INITIAL_CAPACITY),
            .device = device,
            .queue = queue,
        };
    }

    pub fn createBuffer(
        self: *Self,
        allocator: std.mem.Allocator,
        contents: []const u8,
        label: []const u8,
        usage: c.WGPUBufferUsage,
    ) !BufferHandle {
        var desc = gpu.z_WGPU_BUFFER_DESCRIPTOR_INIT();
        desc.label = gpu.toWGPUString(label);
        desc.size = contents.len;
        desc.usage = @bitCast(usage);

        const buffer = c.wgpuDeviceCreateBuffer(self.device, &desc);
        if (buffer == null) {
            std.log.err("ResourceManager: wgpuDeviceCreateBuffer failed for '{s}'", .{label});
            return error.BufferCreationFailed;
        }
        const buffer_entry: BufferEntry = .{
            .ptr = buffer,
            .byte_size = contents.len,
        };
        try self.buffers.append(allocator, buffer_entry);

        c.wgpuQueueWriteBuffer(self.queue, buffer, 0, contents.ptr, contents.len);

        return @enumFromInt(self.buffers.items.len - 1);
    }

    pub fn updateBuffer(self: *Self, buffer_handle: BufferHandle, contents: []const u8) !void {
        const buffer_entry = self.getBuffer(buffer_handle) orelse return error.FailedToFindBuffer;
        c.wgpuQueueWriteBuffer(self.queue, buffer_entry.ptr, 0, contents.ptr, contents.len);
    }

    pub fn getBuffer(self: *const Self, handle: BufferHandle) ?BufferEntry {
        const index = @intFromEnum(handle);
        if (index >= self.buffers.items.len) return null;

        return self.buffers.items[index];
    }

    pub fn getSampler(self: *const Self, handle: SamplerHandle) ?c.WGPUSampler {
        const index = @intFromEnum(handle);
        if (index >= self.samplers.items.len) return null;

        return self.samplers.items[index];
    }

    pub fn getTexture(self: *const Self, handle: TextureHandle) ?c.WGPUTexture {
        const index = @intFromEnum(handle);
        if (index >= self.textures.items.len) return null;

        return self.textures.items[index];
    }

    pub const TextureViewDescriptor = struct {};
    pub fn getTextureView(self: *const Self, handle: TextureViewHandle, descriptor: TextureViewDescriptor) ?c.WGPUTextureView {
        _ = self;
        _ = handle;
        _ = descriptor;
        // TODO Implement
        return null;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.buffers.items) |item| {
            c.wgpuBufferRelease(item.ptr);
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

pub const PipelineCache = struct {
    pipelines: PipelineMap,
    device: c.WGPUDevice,
    default_color_format: gpu.TextureFormat,
    default_depth_format: gpu.TextureFormat,

    pub const PipelineEntry = struct {
        pipeline: c.WGPURenderPipeline,
    };

    const PipelineMap = std.HashMapUnmanaged(
        PipelineDescriptor,
        PipelineEntry,
        PipelineMapContext,
        std.hash_map.default_max_load_percentage,
    );
    const PipelineMapContext = struct {
        pub fn hash(_: @This(), key: PipelineDescriptor) u64 {
            var h = std.hash.Wyhash.init(0);

            if (key.color_format) |cf| {
                h.update(&[_]u8{1});
                h.update(std.mem.asBytes(&cf));
            } else {
                h.update(&[_]u8{0});
            }
            if (key.depth_format) |df| {
                h.update(&[_]u8{1});
                h.update(std.mem.asBytes(&df));
            } else {
                h.update(&[_]u8{0});
            }
            h.update(std.mem.asBytes(&key.shader_module));
            h.update(std.mem.asBytes(&key.vertex_layout_count));
            for (key.vertex_layouts[0..key.vertex_layout_count]) |vl| {
                h.update(std.mem.asBytes(&vl.step_mode));
                h.update(std.mem.asBytes(&vl.array_stride));
                h.update(std.mem.asBytes(&vl.attribute_count));
                for (vl.attributes[0..vl.attribute_count]) |attr| {
                    h.update(std.mem.asBytes(&attr.format));
                    h.update(std.mem.asBytes(&attr.offset));
                    h.update(std.mem.asBytes(&attr.shader_location));
                }
            }
            h.update(std.mem.asBytes(&key.primitive_topology));
            if (key.depth_stencil) |ds| {
                h.update(&[_]u8{1});
                h.update(std.mem.asBytes(&ds.depth_write_enabled));
                h.update(std.mem.asBytes(&ds.depth_compare));
                if (ds.stencil_front) |sf| {
                    h.update(&[_]u8{1});
                    h.update(std.mem.asBytes(&sf.compare));
                    h.update(std.mem.asBytes(&sf.fail_op));
                    h.update(std.mem.asBytes(&sf.depth_fail_op));
                    h.update(std.mem.asBytes(&sf.pass_op));
                } else {
                    h.update(&[_]u8{0});
                }
                if (ds.stencil_back) |sb| {
                    h.update(&[_]u8{1});
                    h.update(std.mem.asBytes(&sb.compare));
                    h.update(std.mem.asBytes(&sb.fail_op));
                    h.update(std.mem.asBytes(&sb.depth_fail_op));
                    h.update(std.mem.asBytes(&sb.pass_op));
                } else {
                    h.update(&[_]u8{0});
                }
                h.update(std.mem.asBytes(&ds.stencil_read_mask));
                h.update(std.mem.asBytes(&ds.stencil_write_mask));
                h.update(std.mem.asBytes(&ds.depth_bias));
                h.update(std.mem.asBytes(&ds.depth_bias_slope_scale));
                h.update(std.mem.asBytes(&ds.depth_bias_clamp));
            } else {
                h.update(&[_]u8{0});
            }
            if (key.blend) |b| {
                h.update(&[_]u8{1});
                h.update(std.mem.asBytes(&b.color.operation));
                h.update(std.mem.asBytes(&b.color.src_factor));
                h.update(std.mem.asBytes(&b.color.dst_factor));
                h.update(std.mem.asBytes(&b.alpha.operation));
                h.update(std.mem.asBytes(&b.alpha.src_factor));
                h.update(std.mem.asBytes(&b.alpha.dst_factor));
            } else {
                h.update(&[_]u8{0});
            }
            h.update(std.mem.asBytes(&key.cull_mode));
            return h.final();
        }
        pub fn eql(_: @This(), key1: PipelineDescriptor, key2: PipelineDescriptor) bool {
            if (key1.color_format != key2.color_format) return false;
            if (key1.depth_format != key2.depth_format) return false;
            if (key1.shader_module != key2.shader_module) return false;
            if (key1.vertex_layout_count != key2.vertex_layout_count) return false;
            for (key1.vertex_layouts[0..key1.vertex_layout_count], key2.vertex_layouts[0..key2.vertex_layout_count]) |vl1, vl2| {
                if (vl1.step_mode != vl2.step_mode) return false;
                if (vl1.array_stride != vl2.array_stride) return false;
                if (vl1.attribute_count != vl2.attribute_count) return false;
                for (vl1.attributes[0..vl1.attribute_count], vl2.attributes[0..vl2.attribute_count]) |a1, a2| {
                    if (a1.format != a2.format) return false;
                    if (a1.offset != a2.offset) return false;
                    if (a1.shader_location != a2.shader_location) return false;
                }
            }
            if (key1.primitive_topology != key2.primitive_topology) return false;
            const ds1_present = key1.depth_stencil != null;
            const ds2_present = key2.depth_stencil != null;
            if (ds1_present != ds2_present) return false;
            if (key1.depth_stencil) |ds1| {
                const ds2 = key2.depth_stencil.?;
                if (ds1.depth_write_enabled != ds2.depth_write_enabled) return false;
                if (ds1.depth_compare != ds2.depth_compare) return false;
                if (ds1.stencil_read_mask != ds2.stencil_read_mask) return false;
                if (ds1.stencil_write_mask != ds2.stencil_write_mask) return false;
                if (ds1.depth_bias != ds2.depth_bias) return false;
                if (@as(u32, @bitCast(ds1.depth_bias_slope_scale)) != @as(u32, @bitCast(ds2.depth_bias_slope_scale))) return false;
                if (@as(u32, @bitCast(ds1.depth_bias_clamp)) != @as(u32, @bitCast(ds2.depth_bias_clamp))) return false;
                const sf1_present = ds1.stencil_front != null;
                const sf2_present = ds2.stencil_front != null;
                if (sf1_present != sf2_present) return false;
                if (ds1.stencil_front) |sf1| {
                    const sf2 = ds2.stencil_front.?;
                    if (sf1.compare != sf2.compare) return false;
                    if (sf1.fail_op != sf2.fail_op) return false;
                    if (sf1.depth_fail_op != sf2.depth_fail_op) return false;
                    if (sf1.pass_op != sf2.pass_op) return false;
                }
                const sb1_present = ds1.stencil_back != null;
                const sb2_present = ds2.stencil_back != null;
                if (sb1_present != sb2_present) return false;
                if (ds1.stencil_back) |sb1| {
                    const sb2 = ds2.stencil_back.?;
                    if (sb1.compare != sb2.compare) return false;
                    if (sb1.fail_op != sb2.fail_op) return false;
                    if (sb1.depth_fail_op != sb2.depth_fail_op) return false;
                    if (sb1.pass_op != sb2.pass_op) return false;
                }
            }
            const b1_present = key1.blend != null;
            const b2_present = key2.blend != null;
            if (b1_present != b2_present) return false;
            if (key1.blend) |b1| {
                const b2 = key2.blend.?;
                if (b1.color.operation != b2.color.operation) return false;
                if (b1.color.src_factor != b2.color.src_factor) return false;
                if (b1.color.dst_factor != b2.color.dst_factor) return false;
                if (b1.alpha.operation != b2.alpha.operation) return false;
                if (b1.alpha.src_factor != b2.alpha.src_factor) return false;
                if (b1.alpha.dst_factor != b2.alpha.dst_factor) return false;
            }
            if (key1.cull_mode != key2.cull_mode) return false;
            return true;
        }
    };

    const Self = @This();

    pub fn init(
        device: c.WGPUDevice,
        default_color_format: gpu.TextureFormat,
        default_depth_format: gpu.TextureFormat,
    ) Self {
        return .{
            .pipelines = .{},
            .device = device,
            .default_color_format = default_color_format,
            .default_depth_format = default_depth_format,
        };
    }

    // TODO: Handle compute
    pub fn getOrCreatePipeline(
        self: *Self,
        allocator: std.mem.Allocator,
        label: []const u8,
        descriptor: PipelineDescriptor,
        vertex_entry: ?[]const u8,
        fragment_entry: ?[]const u8,
        bind_group_layouts: ?[]const c.WGPUBindGroupLayout,
    ) !PipelineEntry {
        if (self.pipelines.get(descriptor)) |pipeline| {
            return pipeline;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        var desc = gpu.z_WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT();
        desc.label = gpu.toWGPUString(label);

        if (bind_group_layouts) |bgls| {
            var pipeline_layout_desc = gpu.z_WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT();
            pipeline_layout_desc.bindGroupLayoutCount = bgls.len;
            pipeline_layout_desc.bindGroupLayouts = bgls.ptr;
            const layout = c.wgpuDeviceCreatePipelineLayout(self.device, &pipeline_layout_desc);
            if (layout == null) {
                std.log.err("PipelineCache: wgpuDeviceCreatePipelineLayout failed for '{s}'", .{label});
                return error.PipelineLayoutCreationFailed;
            }
            desc.layout = layout;
        }

        if (vertex_entry) |ve| {
            var vertex_state = gpu.z_WGPU_VERTEX_STATE_INIT();
            vertex_state.module = descriptor.shader_module;
            vertex_state.entryPoint = gpu.toWGPUString(ve);

            const buffers = try temp.alloc(c.WGPUVertexBufferLayout, descriptor.vertex_layout_count);
            for (0..descriptor.vertex_layout_count) |li| {
                const vertex_layout = descriptor.vertex_layouts[li];
                buffers[li] = gpu.z_WGPU_VERTEX_BUFFER_LAYOUT_INIT();
                buffers[li].stepMode = @intFromEnum(vertex_layout.step_mode);
                buffers[li].arrayStride = vertex_layout.array_stride;
                buffers[li].attributeCount = vertex_layout.attribute_count;
                var attributes = try temp.alloc(c.WGPUVertexAttribute, vertex_layout.attribute_count);
                for (0..vertex_layout.attribute_count) |ai| {
                    const attribute = vertex_layout.attributes[ai];
                    attributes[ai] = gpu.z_WGPU_VERTEX_ATTRIBUTE_INIT();
                    attributes[ai].offset = attribute.offset;
                    attributes[ai].format = @intFromEnum(attribute.format);
                    attributes[ai].shaderLocation = attribute.shader_location;
                }
                buffers[li].attributes = attributes.ptr;
            }

            vertex_state.bufferCount = descriptor.vertex_layout_count;
            vertex_state.buffers = buffers.ptr;

            desc.vertex = vertex_state;
        }

        // TODO handle constants

        // TODO multi target rendering
        if (fragment_entry) |fe| {
            var fragment_state = gpu.z_WGPU_FRAGMENT_STATE_INIT();
            fragment_state.module = descriptor.shader_module;
            fragment_state.entryPoint = gpu.toWGPUString(fe);
            fragment_state.targetCount = 1;

            var target_state = gpu.z_WGPU_COLOR_TARGET_STATE_INIT();
            if (descriptor.color_format) |cd| {
                target_state.format = @intFromEnum(cd);
            } else {
                target_state.format = @intFromEnum(self.default_color_format);
            }

            var blend_state = gpu.z_WGPU_BLEND_STATE_INIT();
            if (descriptor.blend) |b| {
                var alpha = gpu.z_WGPU_BLEND_COMPONENT_INIT();
                alpha.srcFactor = @intFromEnum(b.alpha.src_factor);
                alpha.dstFactor = @intFromEnum(b.alpha.dst_factor);
                alpha.operation = @intFromEnum(b.alpha.operation);
                blend_state.alpha = alpha;
                var color = gpu.z_WGPU_BLEND_COMPONENT_INIT();
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
        var primitive_state = gpu.z_WGPU_PRIMITIVE_STATE_INIT();
        primitive_state.topology = @intFromEnum(descriptor.primitive_topology);
        primitive_state.cullMode = @intFromEnum(descriptor.cull_mode);
        desc.primitive = primitive_state;

        if (descriptor.depth_stencil) |ds| {
            var depth_stencil_state = gpu.z_WGPU_DEPTH_STENCIL_STATE_INIT();
            depth_stencil_state.format = @intFromEnum(descriptor.depth_format orelse self.default_depth_format);
            depth_stencil_state.depthBias = ds.depth_bias;
            depth_stencil_state.depthBiasClamp = ds.depth_bias_clamp;
            depth_stencil_state.depthBiasSlopeScale = ds.depth_bias_slope_scale;
            depth_stencil_state.depthCompare = @intFromEnum(ds.depth_compare);
            depth_stencil_state.depthWriteEnabled = gpu.toWGPUOptBool(ds.depth_write_enabled);
            if (ds.stencil_back) |dsb| {
                depth_stencil_state.stencilBack = gpu.z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilBack.compare = @intFromEnum(dsb.compare);
                depth_stencil_state.stencilBack.depthFailOp = @intFromEnum(dsb.depth_fail_op);
                depth_stencil_state.stencilBack.failOp = @intFromEnum(dsb.fail_op);
                depth_stencil_state.stencilBack.passOp = @intFromEnum(dsb.pass_op);
            }
            if (ds.stencil_front) |dsf| {
                depth_stencil_state.stencilFront = gpu.z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilFront.compare = @intFromEnum(dsf.compare);
                depth_stencil_state.stencilFront.depthFailOp = @intFromEnum(dsf.depth_fail_op);
                depth_stencil_state.stencilFront.failOp = @intFromEnum(dsf.fail_op);
                depth_stencil_state.stencilFront.passOp = @intFromEnum(dsf.pass_op);
            }
            depth_stencil_state.stencilReadMask = ds.stencil_read_mask;
            depth_stencil_state.stencilWriteMask = ds.stencil_write_mask;
            desc.depthStencil = &depth_stencil_state;
        }

        const multisample_state = gpu.z_WGPU_MULTISAMPLE_STATE_INIT();
        desc.multisample = multisample_state;

        const pipeline = c.wgpuDeviceCreateRenderPipeline(self.device, &desc);
        if (pipeline == null) {
            std.log.err("PipelineCache: wgpuDeviceCreateRenderPipeline failed for '{s}'", .{label});
            return error.PipelineCreationFailed;
        }

        const entry: PipelineEntry = .{
            .pipeline = pipeline,
        };

        try self.pipelines.put(allocator, descriptor, entry);

        return entry;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var iter = self.pipelines.valueIterator();
        while (iter.next()) |e| {
            c.wgpuRenderPipelineRelease(e.pipeline);
        }
        self.pipelines.deinit(allocator);
    }
};

// ── Bind Group Layout Cache ────────────────────────────────────────────────────────────

pub const BindGroupLayoutCache = struct {
    bind_group_layouts: BindGroupLayoutMap,
    device: c.WGPUDevice,

    const Self = @This();

    const BindGroupLayoutMap = std.HashMapUnmanaged(
        []const gpu.BindGroupLayoutEntry,
        c.WGPUBindGroupLayout,
        BindGroupLayoutMapContext,
        std.hash_map.default_max_load_percentage,
    );

    pub const BindGroupLayoutMapContext = struct {
        pub fn hash(_: @This(), key: []const gpu.BindGroupLayoutEntry) u64 {
            var h = std.hash.Wyhash.init(0);
            for (key) |entry| {
                h.update(std.mem.asBytes(&entry.binding));
                h.update(std.mem.asBytes(&entry.visibility));
                const tag = std.meta.activeTag(entry.type);
                h.update(std.mem.asBytes(&tag));
                switch (entry.type) {
                    .buffer => |b| h.update(std.mem.asBytes(&b)),
                    .sampler => |s| h.update(std.mem.asBytes(&s)),
                    .texture => |t| h.update(std.mem.asBytes(&t)),
                    .storage_texture => |st| h.update(std.mem.asBytes(&st)),
                }
            }
            return h.final();
        }

        pub fn eql(_: @This(), key1: []const gpu.BindGroupLayoutEntry, key2: []const gpu.BindGroupLayoutEntry) bool {
            if (key1.len != key2.len) return false;
            for (key1, key2) |e1, e2| {
                if (e1.binding != e2.binding) return false;
                if (e1.visibility != e2.visibility) return false;
                if (std.meta.activeTag(e1.type) != std.meta.activeTag(e2.type)) return false;
                switch (e1.type) {
                    .buffer => |b1| if (b1 != e2.type.buffer) return false,
                    .sampler => |s1| if (s1 != e2.type.sampler) return false,
                    .texture => |t1| if (!std.meta.eql(t1, e2.type.texture)) return false,
                    .storage_texture => |st1| if (!std.meta.eql(st1, e2.type.storage_texture)) return false,
                }
            }
            return true;
        }
    };

    pub fn init(device: c.WGPUDevice) Self {
        return .{
            .bind_group_layouts = .empty,
            .device = device,
        };
    }

    pub fn getOrCreateBindGroupLayout(
        self: *Self,
        allocator: std.mem.Allocator,
        entries: []const gpu.BindGroupLayoutEntry,
    ) !c.WGPUBindGroupLayout {
        if (self.bind_group_layouts.get(entries)) |layout| {
            return layout;
        }

        var desc = gpu.z_WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT();
        desc.entryCount = entries.len;

        var layout_entries = try allocator.alloc(c.WGPUBindGroupLayoutEntry, entries.len);
        defer allocator.free(layout_entries);

        for (entries, 0..) |entry, i| {
            var layout_entry = gpu.z_WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT();
            layout_entry.binding = entry.binding;
            layout_entry.visibility = entry.visibility;
            switch (entry.type) {
                .buffer => |buf| {
                    var buffer_layout = gpu.z_WGPU_BUFFER_BINDING_LAYOUT_INIT();
                    buffer_layout.type = @intFromEnum(buf);
                    layout_entry.buffer = buffer_layout;
                },
                .sampler => |smp| {
                    var sampler_layout = gpu.z_WGPU_SAMPLER_BINDING_LAYOUT_INIT();
                    sampler_layout.type = @intFromEnum(smp);
                    layout_entry.sampler = sampler_layout;
                },
                .texture => |txt| {
                    layout_entry.texture.sampleType = @intFromEnum(txt.sample_type);
                    layout_entry.texture.viewDimension = @intFromEnum(txt.view_dimension);
                    layout_entry.texture.multisampled = gpu.toWGPUBool(txt.multi_sampled);
                },
                .storage_texture => |stx| {
                    var strg_texture_layout = gpu.z_WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT();
                    strg_texture_layout.access = @intFromEnum(stx.access);
                    strg_texture_layout.format = @intFromEnum(stx.format);
                    strg_texture_layout.viewDimension = @intFromEnum(stx.view_dimension);
                    layout_entry.storageTexture = strg_texture_layout;
                },
            }
            layout_entries[i] = layout_entry;
        }

        desc.entries = layout_entries.ptr;

        const layout = c.wgpuDeviceCreateBindGroupLayout(self.device, &desc);
        if (layout == null) {
            std.log.err("BindGroupLayoutCache: wgpuDeviceCreateBindGroupLayout failed", .{});
            return error.BindGroupLayoutCreationFailed;
        }
        try self.bind_group_layouts.put(allocator, entries, layout);
        return layout;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.bind_group_layouts.valueIterator();
        while (iter.next()) |layout| {
            c.wgpuBindGroupLayoutRelease(layout.*);
        }
    }
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

pub const BindGroupCache = struct {
    bind_groups: BindGroupMap,
    device: c.WGPUDevice,

    const Self = @This();

    pub const BindGroupDescriptor = struct {
        layout: c.WGPUBindGroupLayout,
        entries: []const BindGroupEntry,
    };

    pub fn init(device: c.WGPUDevice) Self {
        return .{
            .bind_groups = .empty,
            .device = device,
        };
    }

    pub fn getOrCreateBindingGroup(
        self: *Self,
        allocator: std.mem.Allocator,
        descriptor: BindGroupDescriptor,
    ) !c.WGPUBindGroup {
        if (self.bind_groups.get(descriptor)) |bg| {
            return bg;
        }

        var desc = gpu.z_WGPU_BIND_GROUP_DESCRIPTOR_INIT();
        desc.layout = descriptor.layout;
        desc.entryCount = descriptor.entries.len;

        var entries = try allocator.alloc(c.WGPUBindGroupEntry, descriptor.entries.len);
        defer allocator.free(entries);
        for (0..descriptor.entries.len) |i| {
            const desc_entry = descriptor.entries[i];
            var entry = gpu.z_WGPU_BIND_GROUP_ENTRY_INIT();
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

        const bind_group = c.wgpuDeviceCreateBindGroup(self.device, &desc);
        if (bind_group == null) {
            std.log.err("BindGroupCache: wgpuDeviceCreateBindGroup failed", .{});
            return error.BindGroupCreationFailed;
        }
        try self.bind_groups.put(allocator, descriptor, bind_group);
        return bind_group;
    }

    const BindGroupMap = std.HashMapUnmanaged(
        BindGroupDescriptor,
        c.WGPUBindGroup,
        BindGroupMapContext,
        std.hash_map.default_max_load_percentage,
    );
    const BindGroupMapContext = struct {
        pub fn hash(_: @This(), key: BindGroupDescriptor) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.layout));
            for (key.entries) |entry| {
                h.update(std.mem.asBytes(&entry.binding));
                switch (entry.resource) {
                    .buffer => |buf| {
                        h.update(&[_]u8{0});
                        h.update(std.mem.asBytes(&buf.buffer));
                        h.update(std.mem.asBytes(&buf.offset));
                        h.update(std.mem.asBytes(&buf.size));
                    },
                    .sampler => |smp| {
                        h.update(&[_]u8{1});
                        h.update(std.mem.asBytes(&smp));
                    },
                    .texture_view => |tv| {
                        h.update(&[_]u8{2});
                        h.update(std.mem.asBytes(&tv));
                    },
                }
            }
            return h.final();
        }
        pub fn eql(_: @This(), key1: BindGroupDescriptor, key2: BindGroupDescriptor) bool {
            if (key1.layout != key2.layout) return false;
            if (key1.entries.len != key2.entries.len) return false;
            for (key1.entries, key2.entries) |e1, e2| {
                if (e1.binding != e2.binding) return false;
                if (std.meta.activeTag(e1.resource) != std.meta.activeTag(e2.resource)) return false;
                switch (e1.resource) {
                    .buffer => |b1| {
                        const b2 = e2.resource.buffer;
                        if (b1.buffer != b2.buffer) return false;
                        if (b1.offset != b2.offset) return false;
                        if (b1.size != b2.size) return false;
                    },
                    .sampler => |s1| {
                        if (s1 != e2.resource.sampler) return false;
                    },
                    .texture_view => |t1| {
                        if (t1 != e2.resource.texture_view) return false;
                    },
                }
            }
            return true;
        }
    };

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var iter = self.bind_groups.valueIterator();
        while (iter.next()) |bg| {
            c.wgpuBindGroupRelease(bg.*);
        }
        self.bind_groups.deinit(allocator);
    }
};
