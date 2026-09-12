const std = @import("std");
const gpu = @import("gpu");
const c = gpu.c;

gpu_context: gpu.GPUContext,
target_surface: gpu.Surface,

draw_commands: std.ArrayList(DrawCmd),
instance_buffer: std.ArrayList(u8),

materials: std.ArrayList(MaterialRecord),
shaders: std.ArrayList(ShaderRecord),
vertex_buffers: std.ArrayList(VertexBufferRecord),
meshes: std.ArrayList(MeshRecord),

world_uniforms: c.WGPUBuffer,
material_unfiorms: std.ArrayList(c.WGPUBuffer),

index_buffer: GPUArena,

const Self = @This();

pub const PipelineID = enum(u32) {};
pub const MaterialID = enum(u32) {};
pub const MeshID = enum(u32) {};
pub const ShaderID = enum(u32) {};
pub const VertexBufferID = enum(u32) {};

const GPUArena = struct {
    ptr: c.WGPUBuffer,
    len: u32,
    cap: u32,
    usage: gpu.BufferUsage,

    // forces copy dst and copy src on
    pub const ArenaUsage = packed struct(c.WGPUBufferUsage) {
        map_read: bool = false,
        map_write: bool = false,
        _forced0: u1 = 1,
        _forced1: u1 = 1,
        index: bool = false,
        vertex: bool = false,
        uniform: bool = false,
        storage: bool = false,
        indirect: bool = false,
        query_resolve: bool = false,
        _padding: u54 = 0,
    };

    pub fn init(ctx: gpu.GPUContext, capacity: u32, usage: ArenaUsage) !@This() {
        const buffer = try gpu.createBuffer(ctx, capacity, @bitCast(usage), .{ .label = "arena" });
        return .{
            .ptr = buffer,
            .cap = capacity,
            .len = 0,
            .usage = usage,
        };
    }

    pub fn append(self: *@This(), ctx: gpu.GPUContext, data: []const u8) !void {
        if (self.len + data.len > self.cap) {
            const encoder = ctx.getEncoder();
            const new_size = @max(self.cap * 2, self.cap + data.len);
            const new_buffer = try gpu.createBuffer(ctx, new_size, self.usage, .{ .label = "arena" });
            c.wgpuCommandEncoderCopyBufferToBuffer(
                encoder,
                self.ptr,
                0,
                new_buffer,
                0,
                new_buffer.len,
            );
            const cmds = gpu.finishEncoder(encoder);
            c.wgpuQueueSubmit(self.gpu_context.queue, 1, cmds);
            c.wgpuCommandEncoderRelease(encoder);
            c.wgpuCommandBufferRelease(cmds);
            c.wgpuBufferRelease(self.buffer);
            self.buffer = new_buffer;
            self.cap = new_size;
        }
        gpu.writeBuffer(ctx, self.buffer, self.len, data);
        self.len += data.len;
    }

    pub fn deinit(self: *@This()) void {
        c.wgpuBufferRelease(self.ptr);
        self.* = undefined;
    }
};

pub const MaterialRecord = struct {
    shaderID: ShaderID,
    // bind group 1
    bind_group: c.WGPUBindGroup,
    base_vertex: u32,

    uniforms: []const gpu.BindGroupEntry.BufferEntry,

    const UniformSlot = struct {
        chunk: usize,
        size: u32,
        offset: u32,
    };
};

pub const ShaderRecord = struct {
    name: []const u8,
    module: c.WGPUShaderModule,
    group_layouts: []const ?c.WGPUBindGroupLayout,
    vs: [][]const gpu.VertexInputMeta,
    fs: [][]const u8,
};

pub const VertexBufferRecord = struct {
    arena: GPUArena,

    stride: u32,
    attributes: []const gpu.VertexBuffer.AttributeDesc,
};

pub const MeshRecord = struct {
    buffer: VertexBufferID,
    base_vertex: u32,
    vertex_count: u32,
    indices: ?struct {
        base_index: u32,
        index_count: u32,
    },
};

pub fn getOrCreateShader(self: *Self, allocator: std.mem.Allocator, S: type) !ShaderID {
    for (self.shaders.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, S.NAME)) {
            return ShaderID(i);
        }
    }
    const shader = try gpu.Shader(S).init(allocator, self.gpu_context);
    try self.shaders.append(allocator, .{
        .name = S.NAME,
        .group_layouts = shader.group_layouts,
        .module = shader.module,
        .vs = S.VS,
        .fs = S.FS,
    });
    return ShaderID(self.shaders.items.len - 1);
}

pub fn attributeSort(_: anytype, a: gpu.VertexBuffer.AttributeDesc, b: gpu.VertexBuffer.AttributeDesc) bool {
    return std.mem.order(u8, a.name, b.name).compare(.lt);
}

pub fn attributesEql(a: []gpu.VertexBuffer.AttributeDesc, b: []gpu.VertexBuffer.AttributeDesc) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i].format != b[i].format) return false;
        if (!std.mem.eql(u8, a[i].name, b[i].name)) return false;
    }
    return true;
}

pub fn getOrCreateVertexBuffer(self: *Self, allocator: std.mem.Allocator, desc: gpu.VertexLayout) !VertexBufferID {
    const MAX_ATTR_COUNT = 20;
    var attrs: [MAX_ATTR_COUNT]gpu.VertexBuffer.AttributeDesc = undefined;
    std.mem.copyForwards(gpu.VertexBuffer.AttributeDesc, attrs[0..], desc.attributes);
    std.mem.sort(gpu.VertexBuffer.AttributeDesc, attrs[0..desc.attributes.len], {}, attributeSort);
    for (self.vertex_buffers.items, 0..) |vb, i| {
        if (attributesEql(vb.layout.attributes, attrs[0..desc.attributes.len])) {
            return @intFromEnum(i);
        }
    }
    const owned_attrs = try allocator.dupe(gpu.VertexBuffer.AttributeDesc, attrs[0..desc.attributes.len]);
    var offset = 0;
    for (owned_attrs) |attr| {
        attr.offset = offset;
        offset += attr.format.byteSize();
    }
    const stride = offset;
    const arena: GPUArena = try .init(self.gpu_context, 4096, .{ .storage = true });
    try self.vertex_buffers.append(allocator, .{
        .arena = arena,
        .attributes = owned_attrs,
        .stride = stride,
    });
    return @intFromEnum(self.vertex_buffers.items.len - 1);
}

pub fn DrawParams(Instance: type) type {
    const instance_info = @typeInfo(Instance);

    const fields = instance_info.@"struct".fields;

    const max_fields = 100;
    comptime var count = 0;

    var field_names: [max_fields][]const u8 = undefined;
    var field_types: [max_fields]type = undefined;
    var field_attrs: [max_fields]std.builtin.Type.StructField.Attributes = undefined;

    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "model")) {
            field_names[count] = "position";
            field_types[count] = [3]f32;
            field_attrs[count] = .{
                .default_value_ptr = @ptrCast(&[3]f32{ 0, 0, 0 }),
            };
            field_names[count + 1] = "rotation";
            field_types[count + 1] = [3]f32;
            field_attrs[count + 1] = .{
                .default_value_ptr = @ptrCast(&[3]f32{ 0, 0, 0 }),
            };
            field_names[count + 2] = "scale";
            field_types[count + 2] = [3]f32;
            field_attrs[count + 2] = .{
                .default_value_ptr = @ptrCast(&[3]f32{ 1, 1, 1 }),
            };
            count += 3;
            continue;
        }
        field_names[count] = f.name;
        field_types[count] = f.type;
        field_attrs[count] = .{};
        count += 1;
    }

    return @Struct(
        .auto,
        null,
        field_names[0..count],
        field_types[0..count],
        field_attrs[0..count],
    );
}

pub fn init(io: std.Io, allocator: std.mem.Allocator, instance: c.WGPUInstance, surface: c.WGPUSurface) !Self {
    const gpu_context = try gpu.GPUContext.initSync(io, instance.webgpu_instance, surface);
    const target_surface = gpu.Surface.init(gpu_context, surface);
    return .{
        .gpu_context = gpu_context,
        .target_surface = target_surface,
        .draw_commands = try .initCapacity(allocator, 512),
        .instance_buffer = try .initCapacity(allocator, 524_288),
    };
}

pub fn configureTarget(self: *Self, width: u32, height: u32) void {
    self.target_surface.configure(self.gpu_context, width, height);
}

pub fn beginFrame(self: Self) Frame {
    return .{
        .encoder = self.gpu_context.getEncoder(),
    };
}

pub fn MaterialParams(Reflected: type) type {
    const uniforms = Reflected.Uniforms[1];
    const resources = Reflected.Resources[1];
    const uniform_count = if (uniforms) |u| u.len orelse 0;
    const resource_count = if (resources) |r| r.len orelse 0;
    const field_count = uniform_count + resource_count;
    if (field_count == 0) return void;

    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;

    inline for (0..uniform_count) |i| {
        field_names[i] = uniforms[i].name;
        field_types[i] = uniforms[i].Type;
        field_attrs[i] = .{};
    }

    inline for (0..resource_count) |i| {
        field_names[field_count + i] = resources[i].name;
        field_types[field_count + i] =
            switch (resources[i].resource_type) {
                .texture => struct {
                    tex: gpu.Texture,
                    view_config: gpu.Texture.ViewConfig = .{},
                },
                .sampler => gpu.SamplerConfig,
                .storage => gpu.BindGroupEntry.BufferEntry,
            };
        field_attrs[uniform_count + i] = switch (resources[i].resource_type) {
            .sampler => .{ .default_value_ptr = &gpu.SamplerConfig{} },
            else => &.{},
        };
    }

    return @Struct(
        .auto,
        null,
        field_names[0..field_count],
        field_types[0..field_count],
        field_attrs[0..field_count],
    );
}

pub const MeshData = struct {
    streams: []const Stream,
    indices: ?[]const u32 = null,
    vertex_count: u32,

    pub const Stream = struct {
        layout: gpu.VertexLayout,
        data: []const u8,
    };
};

pub fn mesh(self: *Self, allocator: std.mem.Allocator, mesh_data: MeshData) !MeshID {
    const MAX_ATTR_COUNT = 20;
    const vb_id = blk: {
        if (mesh_data.streams.len == 1) {
            break :blk try getOrCreateVertexBuffer(self, allocator, mesh_data.streams[0].layout);
        } else {
            var attrs: [MAX_ATTR_COUNT]gpu.VertexBuffer.AttributeDesc = undefined;
            var attr_count = 0;
            var total_stride = 0;
            for (mesh_data.streams) |s| {
                std.mem.copyForwards(gpu.VertexBuffer, attrs[attr_count..], s.layout.attrbiutes[0..]);
                attr_count += s.layout.attrbiutes.len;
                total_stride += s.layout.stride;
            }
            break :blk try getOrCreateVertexBuffer(self, allocator, .{
                .stride = total_stride,
                .attributes = attrs[0..attr_count],
            });
        }
    };
    const indices = blk: {
        if (mesh_data.indices) |idx| {
            const base = self.index_buffer.len / @sizeOf(u32);
            try self.index_buffer.append(self.gpu_context, std.mem.sliceAsBytes(idx));
            break :blk .{
                .base_index = base,
                .index_count = idx.len,
            };
        }
        break :blk null;
    };
    var vertex_buffer = &self.vertex_buffers.items[vb_id];
    const stride = vertex_buffer.stride;
    const canon_attr = vertex_buffer.attributes;
    var vertex_data = try allocator.alloc(u8, stride * mesh_data.vertex_count);
    defer allocator.free(vertex_data);
    // TODO: optimize via partial eval
    for (0..mesh_data.vertex_count) |vi| {
        for (canon_attr) |ca| {
            for (mesh_data.streams) |s| {
                for (s.layout.attributes) |a| {
                    if (std.mem.eql(u8, ca.name, a.name)) {
                        std.mem.copyForwards(
                            u8,
                            vertex_data[(vi * stride + ca.offset)..],
                            s.data[(vi * s.layout.stride + a.offset)..(vi * s.layout.stride + a.offset + a.format.byteSize())],
                        );
                    }
                }
            }
        }
    }
    const base_vertex = vertex_buffer.arena.len / stride;
    try vertex_buffer.arena.append(self.gpu_context, vertex_data);
    const mesh_id = self.meshes.items.len;
    try self.meshes.append(allocator, .{
        .buffer = vb_id,
        .base_vertex = base_vertex,
        .vertex_count = mesh_data.vertex_count,
        .indices = indices,
    });
    return @intFromEnum(mesh_id);
}

pub fn material(
    self: *Self,
    allocator: std.mem.Allocator,
    Reflected: type,
    params: MaterialParams(Reflected),
) !Material(Reflected) {
    const Shader = gpu.Shader(Reflected);
    const shader_id = try self.getOrCreateShader(allocator, Shader);
    const resources: Shader.Resources(1) = undefined;
    const uniform_count = if (Reflected.Uniforms[1]) |bg| bg.len else 0;
    var uniforms = try allocator.alloc(c.WGPUBuffer, uniform_count);
    if (Reflected.Uniforms[1]) |elements| {
        inline for (elements, 0..) |el, i| {
            const data = @field(params, el.name);
            const size = @sizeOf(@TypeOf(data));
            const buffer = try gpu.createBuffer(
                self.gpu_context,
                .{
                    .label = el.name,
                    .size = size,
                    .usage = .{ .copy_dst = true, .uniform = true },
                },
            );
            gpu.writeBuffer(self.gpu_context, buffer, 0, data);
            const buffer_entry = gpu.BindGroupEntry.BufferEntry{ .buffer = buffer, .size = size };
            @field(resources, el.name) = buffer_entry;
            uniforms[i] = buffer_entry;
        }
    }
    if (Reflected.Resources[1]) |elements| {
        inline for (elements) |el| {
            const data = @field(params, el.name);
            switch (el.resource_type) {
                .texture => @field(resources, el.name) = data.tex.createView(data.config),
                .smp => @field(resources, el.name) = gpu.createSampler(self.gpu_context, data),
                .storage => @field(resources, el.name) = data,
            }
        }
    }
    const bind_group = try gpu.ShaderBindGroup(Reflected, 1).create(
        allocator,
        self.gpu_context,
        self.shaders[ShaderID].group_layouts,
        resources,
    );
    const material_record: MaterialRecord = .{
        .shaderID = shader_id,
        .bind_group = bind_group,
        .uniforms = uniforms,
    };
    try self.materials.append(allocator, material_record);
    const material_id = self.materials.items.len - 1;
    return .{
        .material_id = material_id,
    };
}

pub fn Material(S: type) type {
    const IT: type = comptime blk: {
        for (S.Resources) |group| {
            if (group == null) continue;
            for (group.?) |r| {
                if (std.mem.eql(u8, r.name, "instances")) {
                    if (r.resource_type != .storage) @compileError("'instances' must be defined as a storage array");
                    if (r.resource_type.storage != .array) @compileError("'instances' must be defined as a storage array");
                    break :blk r.resource_type.storage.array;
                }
            }
        }
        @compileError("Shader has no instances array which is required");
    };

    return struct {
        material_id: MaterialID,

        pub const InstanceType: type = IT;
        pub const Shader = S;
    };
}

pub const DrawCmd = struct {
    transparent: bool,
    pipeline: PipelineID,
    material: MaterialID,
    mesh: MeshID,
    depth: f32 = 0,

    instance_offset: u32,
    instance_size: u32,

    pub fn lessThan(_: void, a: DrawCmd, b: DrawCmd) bool {
        if (a.transparent != b.transparent) return !a.transparent;
        if (a.transparent) return a.depth > b.depth;
        if (a.pipeline != b.pipeline) return a.pipeline < b.pipeline;
        if (a.material != b.material) return a.material < b.material;
        return a.mesh < b.mesh;
    }
};

pub const Frame = struct {
    renderer: *Self,
    encoder: c.WGPUCommandEncoder,
    surface_view: c.WGPUTextureView,
    world_buffer_cursor: u32 = 0,

    pub fn beginPass(config: gpu.RenderPassConfig) RenderPass {
        return RenderPass.init(config);
    }

    pub fn endPass(self: *@This(), pass: RenderPass) void {
        std.mem.sort(DrawCmd, self.renderer.draw_commands.items, {}, DrawCmd.lessThan);

        // clear the instance cursor
        self.renderer.instance_buffer.items.len = 0;
    }

    pub fn end(self: *@This()) void {
        c.wgpuCommandEncoderRelease(self.encoder);
        c.wgpuTextureViewRelease(self.surface_view);
    }
};

const RenderPass = struct {
    draw_commands: *std.ArrayList(DrawCmd),

    pub fn setCamera() void {}

    pub fn draw(
        self: *@This(),
        allocator: std.mem.Allocator,
        mesh: MeshID,
        material: anytype,
        params: DrawParams(@TypeOf(material).InstanceType),
    ) !void {
        try self.draw_commands.append(allocator, .{});
    }
};
