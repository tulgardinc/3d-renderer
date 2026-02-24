const std = @import("std");
pub const w = @import("wgpu.zig");
pub const c = w.c;

pub const ShaderHandle = enum(u32) { _ };
pub const BufferHandle = enum(u32) { _ };
pub const TextureHandle = enum(u32) { _ };
pub const SamplerHandle = enum(u32) { _ };

const MAX_BIND_GROUP_COUNT = 4;

pub const ShaderManager = struct {
    shaders: std.ArrayList(Shader),
    gpu_context: *const w.GPUContext,

    pub const Metadata = struct {
        vertex_entry: []const u8,
        fragment_entry: []const u8,
        bind_groups: []const []const w.BindEntry,
        vertex_inputs: []const w.VertexInput,
    };

    pub const Shader = struct {
        module: c.WGPUShaderModule,
        metadata: Metadata,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        gpu_context: *const w.GPUContext,
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

        var desc = w.z_WGPU_SHADER_MODULE_DESCRIPTOR_INIT();
        desc.label = w.toWGPUString(label);
        var source = w.z_WGPU_SHADER_SOURCE_WGSL_INIT();
        source.code = w.toWGPUString(source_code);
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

pub const ResourceManager = struct {
    // TODO: add generational indices for use after free tracking

    buffers: std.ArrayList(c.WGPUBuffer),
    textures: std.ArrayList(c.WGPUTexture),
    samplers: std.ArrayList(c.WGPUSampler),
    gpu_context: *const w.GPUContext,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, gpu_context: *const w.GPUContext) !Self {
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
        var desc = w.z_WGPU_BUFFER_DESCRIPTOR_INIT();
        desc.label = w.toWGPUString(lable);
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

    pub fn getSampler(self: *const Self, handle: SamplerHandle) ?c.WGPUSampler {
        const index = @intFromEnum(handle);
        if (index > self.samplers.items.len) return null;

        return self.samplers.items[index];
    }

    pub fn getTexture(self: *const Self, handle: TextureHandle) ?c.WGPUTexture {
        const index = @intFromEnum(handle);
        if (index > self.textures.items.len) return null;

        return self.textures.items[index];
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
        format: w.VertexFormat = .u8,
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
    pipelines: PipelineMap,
    default_color_format: w.TextureFormat,
    default_depth_format: w.TextureFormat,
    shader_manager: *const ShaderManager,
    gpu_context: *const w.GPUContext,

    const PipelineMap = std.HashMapUnmanaged(
        PipelineDescriptor,
        Entry,
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
            h.update(std.mem.asBytes(&key.shader));
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
            if (key1.shader != key2.shader) return false;
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

    pub const Entry = struct {
        pipeline: c.WGPURenderPipeline,
        bind_group_layouts: [MAX_BIND_GROUP_COUNT]?c.WGPUBindGroupLayout = .{null} ** MAX_BIND_GROUP_COUNT,
        shader: ShaderHandle,
    };

    const MAX_VERTEX_LAYOUT_COUNT = 8;

    const Self = @This();

    pub fn init(
        gpu_context: *const w.GPUContext,
        shader_manager: *const ShaderManager,
        surface: *const w.Surface,
        default_depth_format: w.TextureFormat,
    ) !Self {
        return .{
            .pipelines = .{},
            .gpu_context = gpu_context,
            .shader_manager = shader_manager,
            .default_color_format = surface.format,
            .default_depth_format = default_depth_format,
        };
    }

    // TODO: Handle compute
    pub fn getOrCreatePipeline(self: *Self, allocator: std.mem.Allocator, label: []const u8, descriptor: w.PipelineDescriptor) !Entry {
        if (self.pipelines.get(descriptor)) |pipeline| {
            return pipeline;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const shader = self.shader_manager.getShader(descriptor.shader) orelse return error.CouldNotFindShader;

        var desc = w.z_WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT();
        desc.label = w.toWGPUString(label);

        var layout_desc = w.z_WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT();
        var bind_group_layouts = try alloc.alloc(c.WGPUBindGroupLayout, shader.metadata.bind_groups.len);

        layout_desc.label = w.toWGPUString(label);
        layout_desc.bindGroupLayoutCount = shader.metadata.bind_groups.len;
        for (0..shader.metadata.bind_groups.len) |g_index| {
            var bind_group_desc = w.z_WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT();
            const entry_count = shader.metadata.bind_groups[g_index].len;
            var entries = try alloc.alloc(c.WGPUBindGroupLayoutEntry, entry_count);
            bind_group_desc.entryCount = entry_count;

            for (0..entry_count) |e_index| {
                const binding = shader.metadata.bind_groups[g_index][e_index];
                var layout_entry = w.z_WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT();
                layout_entry.binding = binding.binding;
                layout_entry.visibility = binding.visibility;
                switch (binding.type) {
                    .buffer => |buf| {
                        var buffer_layout = w.z_WGPU_BUFFER_BINDING_LAYOUT_INIT();
                        buffer_layout.type = @intFromEnum(buf);
                        layout_entry.buffer = buffer_layout;
                    },
                    .sampler => |smp| {
                        var sampler_layout = w.z_WGPU_SAMPLER_BINDING_LAYOUT_INIT();
                        sampler_layout.type = @intFromEnum(smp);
                        layout_entry.sampler = sampler_layout;
                    },
                    .texture => |txt| {
                        layout_entry.texture.sampleType = @intFromEnum(txt.sample_type);
                        layout_entry.texture.viewDimension = @intFromEnum(txt.view_dimension);
                        layout_entry.texture.multisampled = w.toWGPUBool(txt.multi_sampled);
                    },
                    .storage_texture => |stx| {
                        var strg_texture_layout = w.z_WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT();
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

        var vertex_state = w.z_WGPU_VERTEX_STATE_INIT();
        vertex_state.module = shader.module;
        vertex_state.entryPoint = w.toWGPUString(shader.metadata.vertex_entry);

        const buffers = try alloc.alloc(c.WGPUVertexBufferLayout, descriptor.vertex_layout_count);

        for (0..descriptor.vertex_layout_count) |li| {
            const vertex_layout = descriptor.vertex_layouts[li];
            buffers[li] = w.z_WGPU_VERTEX_BUFFER_LAYOUT_INIT();
            buffers[li].stepMode = @intFromEnum(vertex_layout.step_mode);
            buffers[li].arrayStride = vertex_layout.array_stride;
            buffers[li].attributeCount = vertex_layout.attribute_count;
            var attributes = try alloc.alloc(c.WGPUVertexAttribute, vertex_layout.attribute_count);
            for (0..vertex_layout.attribute_count) |ai| {
                const attribute = vertex_layout.attributes[ai];
                attributes[ai] = w.z_WGPU_VERTEX_ATTRIBUTE_INIT();
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
        var fragment_state = w.z_WGPU_FRAGMENT_STATE_INIT();
        fragment_state.module = shader.module;
        fragment_state.entryPoint = w.toWGPUString(shader.metadata.fragment_entry);
        fragment_state.targetCount = 1;

        var target_state = w.z_WGPU_COLOR_TARGET_STATE_INIT();
        if (descriptor.color_format) |cd| {
            target_state.format = @intFromEnum(cd);
        } else {
            target_state.format = @intFromEnum(self.default_color_format);
        }

        var blend_state = w.z_WGPU_BLEND_STATE_INIT();
        if (descriptor.blend) |b| {
            var alpha = w.z_WGPU_BLEND_COMPONENT_INIT();
            alpha.srcFactor = @intFromEnum(b.alpha.src_factor);
            alpha.dstFactor = @intFromEnum(b.alpha.dst_factor);
            alpha.operation = @intFromEnum(b.alpha.operation);
            blend_state.alpha = alpha;
            var color = w.z_WGPU_BLEND_COMPONENT_INIT();
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
        var primitive_state = w.z_WGPU_PRIMITIVE_STATE_INIT();
        primitive_state.topology = @intFromEnum(descriptor.primitive_topology);
        primitive_state.cullMode = @intFromEnum(descriptor.cull_mode);
        desc.primitive = primitive_state;

        if (descriptor.depth_stencil) |ds| {
            var depth_stencil_state = w.z_WGPU_DEPTH_STENCIL_STATE_INIT();
            depth_stencil_state.format = @intFromEnum(descriptor.depth_format orelse self.default_depth_format);
            depth_stencil_state.depthBias = ds.depth_bias;
            depth_stencil_state.depthBiasClamp = ds.depth_bias_clamp;
            depth_stencil_state.depthBiasSlopeScale = ds.depth_bias_slope_scale;
            depth_stencil_state.depthCompare = @intFromEnum(ds.depth_compare);
            depth_stencil_state.depthWriteEnabled = w.toWGPUOptBool(ds.depth_write_enabled);
            if (ds.stencil_back) |dsb| {
                depth_stencil_state.stencilBack = w.z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilBack.compare = @intFromEnum(dsb.compare);
                depth_stencil_state.stencilBack.depthFailOp = @intFromEnum(dsb.depth_fail_op);
                depth_stencil_state.stencilBack.failOp = @intFromEnum(dsb.fail_op);
                depth_stencil_state.stencilBack.passOp = @intFromEnum(dsb.pass_op);
            }
            if (ds.stencil_front) |dsf| {
                depth_stencil_state.stencilFront = w.z_WGPU_STENCIL_FACE_STATE_INIT();
                depth_stencil_state.stencilFront.compare = @intFromEnum(dsf.compare);
                depth_stencil_state.stencilFront.depthFailOp = @intFromEnum(dsf.depth_fail_op);
                depth_stencil_state.stencilFront.failOp = @intFromEnum(dsf.fail_op);
                depth_stencil_state.stencilFront.passOp = @intFromEnum(dsf.pass_op);
            }
            depth_stencil_state.stencilReadMask = ds.stencil_read_mask;
            depth_stencil_state.stencilWriteMask = ds.stencil_write_mask;
            desc.depthStencil = &depth_stencil_state;
        }

        const multisample_state = w.z_WGPU_MULTISAMPLE_STATE_INIT();
        desc.multisample = multisample_state;

        const pipeline = c.wgpuDeviceCreateRenderPipeline(self.gpu_context.device, &desc);
        var entry = Entry{
            .pipeline = pipeline,
            .shader = descriptor.shader,
        };
        for (0..MAX_BIND_GROUP_COUNT) |i| {
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

pub const Bindings = struct {
    bind_groups: BindGroupMap,
    gpu_context: *const w.GPUContext,
    resource_manager: *const ResourceManager,

    const Self = @This();

    pub const BindGroupEntry = struct {
        binding: u32,
        resource: union(enum) {
            buffer: Buffer,
            sampler: SamplerHandle,
            texture_view: c.WGPUTextureView,
        },

        pub const Buffer = struct {
            handle: BufferHandle,
            offset: u64 = 0,
            size: u64 = 0,
        };
    };

    pub const BindGroupDescriptor = struct {
        layout: c.WGPUBindGroupLayout,
        entry_count: u32,
        entries: [MAX_BIND_GROUP_COUNT]BindGroupEntry,
    };

    pub fn init(gpu_context: *const w.GPUContext, resource_manager: *const ResourceManager) Self {
        return .{
            .bind_groups = .empty,
            .gpu_context = gpu_context,
            .resource_manager = resource_manager,
        };
    }

    pub fn getOrCreateBindingGroup(
        self: *Self,
        allocator: std.mem.Allocator,
        lable: []const u8,
        descriptor: BindGroupDescriptor,
    ) !c.WGPUBindGroup {
        if (self.bind_groups.get(descriptor)) |bg| {
            return bg;
        }

        var desc = w.z_WGPU_BIND_GROUP_DESCRIPTOR_INIT();
        desc.label = w.toWGPUString(lable);
        desc.layout = descriptor.layout;
        desc.entryCount = descriptor.entry_count;

        var entries = try allocator.alloc(c.WGPUBindGroupEntry, descriptor.entry_count);
        defer allocator.free(entries);
        for (0..descriptor.entry_count) |i| {
            const desc_entry = descriptor.entries[i];
            var entry = w.z_WGPU_BIND_GROUP_ENTRY_INIT();
            entry.binding = desc_entry.binding;
            switch (desc_entry.resource) {
                .buffer => |b| {
                    entry.offset = b.offset;
                    entry.size = b.size;
                    entry.buffer = self.resource_manager.getBuffer(b.handle) orelse return error.CouldNotFindBuffer;
                },
                .sampler => |s| {
                    entry.sampler = self.resource_manager.getSampler(s);
                },
                .texture_view => |tv| {
                    entry.textureView = tv;
                },
            }
            entries[i] = entry;
        }

        desc.entries = entries.ptr;

        const bind_group = c.wgpuDeviceCreateBindGroup(self.gpu_context.device, &desc);
        try self.bind_groups.put(allocator, descriptor, bind_group);
    }

    const BindGroupMap = std.HashMapUnmanaged(
        BindGroupDescriptor,
        c.WGPUBindGroup,
        PipelineMapContext,
        std.hash_map.default_max_load_percentage,
    );
    const PipelineMapContext = struct {
        pub fn hash(_: @This(), key: BindGroupDescriptor) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.layout));
            h.update(std.mem.asBytes(&key.entry_count));
            for (key.entries[0..key.entry_count]) |entry| {
                h.update(std.mem.asBytes(&entry.binding));
                switch (entry.resource) {
                    .buffer => |buf| {
                        h.update(&[_]u8{0});
                        h.update(std.mem.asBytes(&buf.handle));
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
            if (!std.mem.eql(u8, key1.label, key2.label)) return false;
            if (key1.entry_count != key2.entry_count) return false;
            for (key1.entries[0..key1.entry_count], key2.entries[0..key2.entry_count]) |e1, e2| {
                if (e1.binding != e2.binding) return false;
                if (std.meta.activeTag(e1.resource) != std.meta.activeTag(e2.resource)) return false;
                switch (e1.resource) {
                    .buffer => |b1| {
                        const b2 = e2.resource.buffer;
                        if (b1.handle != b2.handle) return false;
                        if (b1.offset != b2.offset) return false;
                        if (b1.size != b2.size) return false;
                    },
                    .sampler => |s1| {
                        const s2 = e2.resource.sampler;
                        if (s1 != s2) return false;
                    },
                    .texture_view => |t1| {
                        const t2 = e2.resource.texture_view;
                        if (t1 != t2) return false;
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
