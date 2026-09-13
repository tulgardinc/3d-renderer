const std = @import("std");
const gpu = @import("gpu");
const c = gpu.c;

gpu_context: gpu.GPUContext,
target_surface: gpu.Surface,

surface_targets: SurfaceTargets = .{},

draw_commands: std.ArrayList(DrawCmd) = .empty,
instance_buffer: std.ArrayList(u8) = .empty,

materials: std.ArrayList(MaterialRecord) = .empty,
render_states: std.ArrayList(gpu.MaterialRenderState) = .empty,
modules: std.ArrayList(ModuleRecord) = .empty,
shaders: std.ArrayList(ShaderRecord) = .empty,
layouts: std.ArrayList(VertexLayoutRecord) = .empty,
meshes: std.ArrayList(MeshRecord) = .empty,
free_mesh_slots: std.ArrayList(u32) = .empty,
pipelines: std.ArrayList(c.WGPURenderPipeline) = .empty,
pipeline_ids: std.AutoHashMapUnmanaged(PipelineKey, PipelineID) = .empty,

world_uniforms: c.WGPUBuffer = null,
material_uniforms: std.ArrayList(c.WGPUBuffer) = .empty,

/// All indices live here, in u32 pages, regardless of vertex layout.
index_pool: Pool,
/// Capacity in vertices of every vertex page created from now on.
vertex_page_capacity: u32 = default_vertex_page_capacity,

/// Layouts every app gets without declaring anything.
builtin_layouts: BuiltinLayouts,

const Self = @This();

pub const RenderStateID = enum(u32) { _ };
pub const MaterialID = enum(u32) { _ };
pub const ModuleID = enum(u32) { _ };
pub const ShaderID = enum(u32) { _ };
pub const PipelineID = enum(u32) { _ };
pub const VertexLayoutID = enum(u32) { _ };

/// A mesh handle carries the slot's generation so a handle kept past
/// `unloadMesh` is caught (asserted) instead of drawing whatever reused the slot.
pub const MeshID = packed struct(u32) { index: u24, generation: u8 };

// ---------------------------------------------------------------------------
// Geometry pools
//
// Geometry lives in fixed-size pages that are never resized or recreated, so a
// bind group or render bundle that captures a page buffer stays valid for the
// renderer's lifetime. Meshes are spans inside a page; unloading returns the
// span to the page's free list.
// ---------------------------------------------------------------------------

pub const max_streams = 2;
pub const max_layout_attributes = 16; // WebGPU maxVertexAttributes
pub const default_vertex_page_capacity: u32 = 262_144;
pub const default_index_page_capacity: u32 = 1 << 20;
/// WebGPU's default maxBufferSize. Dawn hands back an error object rather than
/// null above it, so this is checked before creation.
const max_page_bytes: u64 = 256 << 20;

pub const Span = struct { start: u32, len: u32 };

/// Free spans over [0, capacity), sorted by start and never adjacent.
/// First-fit allocation, coalescing on free. Knows nothing about the GPU.
pub const FreeList = struct {
    spans: std.ArrayList(Span) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !FreeList {
        var list: FreeList = .{};
        try list.spans.append(allocator, .{ .start = 0, .len = capacity });
        return list;
    }

    pub fn deinit(self: *FreeList, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
    }

    pub fn alloc(self: *FreeList, len: u32) ?u32 {
        std.debug.assert(len > 0);
        for (self.spans.items, 0..) |*span, i| {
            if (span.len < len) continue;
            const start = span.start;
            if (span.len == len) {
                _ = self.spans.orderedRemove(i);
            } else {
                span.start += len;
                span.len -= len;
            }
            return start;
        }
        return null;
    }

    pub fn free(self: *FreeList, allocator: std.mem.Allocator, start: u32, len: u32) !void {
        std.debug.assert(len > 0);
        const end = start + len;
        // index of the first free span past the freed one
        var i: usize = 0;
        while (i < self.spans.items.len and self.spans.items[i].start < start) : (i += 1) {}
        const prev: ?*Span = if (i > 0) &self.spans.items[i - 1] else null;
        const next: ?*Span = if (i < self.spans.items.len) &self.spans.items[i] else null;
        // overlap here means a double free or a span that was never allocated
        if (prev) |p| std.debug.assert(p.start + p.len <= start);
        if (next) |n| std.debug.assert(end <= n.start);
        const joins_prev = prev != null and prev.?.start + prev.?.len == start;
        const joins_next = next != null and next.?.start == end;
        if (joins_prev and joins_next) {
            prev.?.len += len + next.?.len;
            _ = self.spans.orderedRemove(i);
        } else if (joins_prev) {
            prev.?.len += len;
        } else if (joins_next) {
            next.?.start = start;
            next.?.len += len;
        } else {
            try self.spans.insert(allocator, i, .{ .start = start, .len = len });
        }
    }

    pub fn isEmpty(self: FreeList, capacity: u32) bool {
        return self.spans.items.len == 1 and self.spans.items[0].start == 0 and self.spans.items[0].len == capacity;
    }
};

pub const Page = struct {
    /// One buffer per stream; the index pool uses only `buffers[0]`.
    buffers: [max_streams]c.WGPUBuffer,
    /// In elements (vertices or indices).
    capacity: u32,
    free: FreeList,
};

pub const Placement = struct { page: u32, base: u32 };

/// One per vertex layout, plus one for indices. Pages are added, never removed.
pub const Pool = struct {
    pages: std.ArrayList(Page) = .empty,
    page_capacity: u32,

    pub fn allocSpan(self: *Pool, count: u32) ?Placement {
        for (self.pages.items, 0..) |*page, i| {
            if (page.free.alloc(count)) |base| return .{ .page = @intCast(i), .base = base };
        }
        return null;
    }

    pub fn addPage(self: *Pool, allocator: std.mem.Allocator, buffers: [max_streams]c.WGPUBuffer, capacity: u32) !u32 {
        try self.pages.append(allocator, .{
            .buffers = buffers,
            .capacity = capacity,
            .free = try FreeList.init(allocator, capacity),
        });
        return @intCast(self.pages.items.len - 1);
    }

    pub fn freeSpan(self: *Pool, allocator: std.mem.Allocator, placement: Placement, count: u32) !void {
        try self.pages.items[placement.page].free.free(allocator, placement.base, count);
    }

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        for (self.pages.items) |*page| {
            for (page.buffers) |buffer| {
                if (buffer != null) c.wgpuBufferRelease(buffer);
            }
            page.free.deinit(allocator);
        }
        self.pages.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Vertex layouts
//
// Apps declare layouts up front (names + formats only); the renderer owns the
// packing. Every layout the renderer will ever see is therefore known before
// the first frame, so pipelines can be precompiled instead of compiled when a
// mesh streams in.
// ---------------------------------------------------------------------------

pub const VertexLayoutDesc = struct {
    attributes: []const Attribute,

    pub const Attribute = struct {
        name: []const u8,
        format: gpu.VertexFormat,
    };
};

/// The built-in static layout: 12-byte position stream, 20-byte attribute stream.
pub const static_layout: VertexLayoutDesc = .{ .attributes = &.{
    .{ .name = "position", .format = .f32x3 },
    .{ .name = "normal", .format = .snorm16x4 },
    .{ .name = "uv", .format = .f32x2 },
    .{ .name = "color", .format = .unorm8x4 },
} };

pub const BuiltinLayouts = struct {
    static: VertexLayoutID,
};

pub const LayoutAttribute = struct {
    name: []const u8,
    format: gpu.VertexFormat,
    stream: u8,
    offset: u32,
};

pub const VertexLayoutRecord = struct {
    attributes: []const LayoutAttribute,
    strides: [max_streams]u32,
    stream_count: u8,
    pool: Pool,
};

/// Packing policy: `position` gets stream 0 to itself (depth-only passes and
/// tile-based GPUs read just that), everything else is interleaved in stream 1
/// in declaration order. Declaring the same attributes again returns the same ID.
pub fn declareLayout(self: *Self, allocator: std.mem.Allocator, desc: VertexLayoutDesc) !VertexLayoutID {
    if (desc.attributes.len == 0 or desc.attributes.len > max_layout_attributes) return error.InvalidLayout;

    for (self.layouts.items, 0..) |rec, i| {
        if (rec.attributes.len != desc.attributes.len) continue;
        var same = true;
        for (rec.attributes, desc.attributes) |a, b| {
            if (a.format != b.format or !std.mem.eql(u8, a.name, b.name)) {
                same = false;
                break;
            }
        }
        if (same) return @enumFromInt(i);
    }

    const attrs = try allocator.alloc(LayoutAttribute, desc.attributes.len);
    errdefer allocator.free(attrs);
    var cursor: [max_streams]u32 = .{ 0, 0 };
    var has_position = false;
    for (desc.attributes, 0..) |attr, i| {
        if (attr.format == .undefined) return error.InvalidLayout;
        for (desc.attributes[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, attr.name)) return error.DuplicateAttribute;
        }
        const is_position = std.mem.eql(u8, attr.name, "position");
        has_position = has_position or is_position;
        const stream: u8 = if (is_position) 0 else 1;
        const size: u32 = @intCast(attr.format.byteSize());
        const offset = std.mem.alignForward(u32, cursor[stream], @min(4, size));
        cursor[stream] = offset + size;
        attrs[i] = .{ .name = attr.name, .format = attr.format, .stream = stream, .offset = offset };
    }
    if (!has_position) return error.MissingPosition;

    var strides: [max_streams]u32 = undefined;
    for (&strides, cursor) |*stride, end| stride.* = std.mem.alignForward(u32, end, 4);
    if (strides[0] > 2048 or strides[1] > 2048) return error.InvalidLayout; // maxVertexBufferArrayStride

    // names are duped last so the validation paths above leak nothing
    var duped: usize = 0;
    errdefer for (attrs[0..duped]) |attr| allocator.free(attr.name);
    for (attrs) |*attr| {
        attr.name = try allocator.dupe(u8, attr.name);
        duped += 1;
    }

    try self.layouts.append(allocator, .{
        .attributes = attrs,
        .strides = strides,
        .stream_count = if (cursor[1] == 0) 1 else 2,
        .pool = .{ .page_capacity = self.vertex_page_capacity },
    });
    return @enumFromInt(self.layouts.items.len - 1);
}

// ---------------------------------------------------------------------------
// Meshes
// ---------------------------------------------------------------------------

/// Pure bookkeeping: page indexes and offsets, never buffer handles.
pub const MeshRecord = struct {
    layout: VertexLayoutID,
    vertices: Placement,
    vertex_count: u32,
    indices: ?struct { placement: Placement, count: u32 },
    generation: u8,
    alive: bool,
};

pub const MeshData = struct {
    layout: VertexLayoutID,
    /// Any named attributes in any formats; matched to the layout by name.
    /// Attributes the layout lacks are dropped, attributes the app lacks read
    /// (0, 0, 0, 1).
    streams: []const Stream,
    indices: ?[]const u32 = null,
    vertex_count: u32,

    pub const Stream = struct {
        layout: gpu.VertexLayout,
        data: []const u8,
    };
};

fn getMesh(self: *Self, id: MeshID) *MeshRecord {
    const rec = &self.meshes.items[id.index];
    std.debug.assert(rec.alive and rec.generation == id.generation);
    return rec;
}

pub fn mesh(self: *Self, allocator: std.mem.Allocator, data: MeshData) !MeshID {
    if (data.vertex_count == 0) return error.EmptyMesh;
    for (data.streams) |s| {
        if (s.data.len < @as(usize, s.layout.stride) * data.vertex_count) return error.StreamTooShort;
    }
    if (data.indices) |indices| {
        if (indices.len == 0) return error.EmptyMesh;
        if (std.debug.runtime_safety) {
            // WebGPU only bounds-checks an index against the page, not the mesh:
            // a bad index would silently read a neighbouring mesh.
            for (indices) |i| std.debug.assert(i < data.vertex_count);
        }
    }
    const rec = &self.layouts.items[@intFromEnum(data.layout)];

    const vertices = try self.allocVertices(allocator, data.layout, data.vertex_count);
    errdefer rec.pool.freeSpan(allocator, vertices, data.vertex_count) catch {};
    for (0..rec.stream_count) |s| {
        const stride = rec.strides[s];
        const bytes = try allocator.alloc(u8, @as(usize, stride) * data.vertex_count);
        defer allocator.free(bytes);
        packStream(rec, @intCast(s), data.streams, data.vertex_count, bytes);
        const page = rec.pool.pages.items[vertices.page];
        gpu.writeBufferBytes(self.gpu_context, page.buffers[s], @as(u64, vertices.base) * stride, bytes);
    }

    var record: MeshRecord = .{
        .layout = data.layout,
        .vertices = vertices,
        .vertex_count = data.vertex_count,
        .indices = null,
        .generation = 0,
        .alive = true,
    };
    if (data.indices) |indices| {
        const count: u32 = @intCast(indices.len);
        const placement = try self.allocIndices(allocator, count);
        const page = self.index_pool.pages.items[placement.page];
        gpu.writeBufferBytes(self.gpu_context, page.buffers[0], @as(u64, placement.base) * @sizeOf(u32), std.mem.sliceAsBytes(indices));
        record.indices = .{ .placement = placement, .count = count };
    }
    if (self.free_mesh_slots.pop()) |slot| {
        record.generation = self.meshes.items[slot].generation +% 1;
        self.meshes.items[slot] = record;
        return .{ .index = @intCast(slot), .generation = record.generation };
    }
    if (self.meshes.items.len >= 1 << 24) return error.TooManyMeshes;
    try self.meshes.append(allocator, record);
    return .{ .index = @intCast(self.meshes.items.len - 1), .generation = 0 };
}

/// Returns the mesh's vertex and index spans to their pages and recycles the
/// slot. The handle is dead afterwards; using it again asserts.
pub fn unloadMesh(self: *Self, allocator: std.mem.Allocator, id: MeshID) !void {
    const rec = self.getMesh(id);
    const layout = &self.layouts.items[@intFromEnum(rec.layout)];
    try layout.pool.freeSpan(allocator, rec.vertices, rec.vertex_count);
    if (rec.indices) |ib| {
        try self.index_pool.freeSpan(allocator, ib.placement, ib.count);
    }
    rec.alive = false;
    try self.free_mesh_slots.append(allocator, id.index);
}

const AttributeSource = struct { stream: u8, offset: u32, format: gpu.VertexFormat };

fn findSource(streams: []const MeshData.Stream, name: []const u8) ?AttributeSource {
    for (streams, 0..) |s, si| {
        for (s.layout.attributes) |a| {
            if (std.mem.eql(u8, a.name, name)) {
                return .{ .stream = @intCast(si), .offset = a.offset, .format = a.format };
            }
        }
    }
    return null;
}

/// Packs one canonical stream of `rec` for `vertex_count` vertices out of the
/// app's streams into `out` (exactly stride * vertex_count bytes). GPU-free.
fn packStream(rec: *const VertexLayoutRecord, stream: u8, streams: []const MeshData.Stream, vertex_count: u32, out: []u8) void {
    const stride = rec.strides[stream];
    std.debug.assert(out.len == @as(usize, stride) * vertex_count);
    @memset(out, 0);
    for (rec.attributes) |attr| {
        if (attr.stream != stream) continue;
        const size: usize = @intCast(attr.format.byteSize());
        if (findSource(streams, attr.name)) |src| {
            const src_stream = streams[src.stream];
            for (0..vertex_count) |vi| {
                const dst = out[vi * stride + attr.offset ..][0..size];
                const src_bytes = src_stream.data[vi * src_stream.layout.stride + src.offset ..];
                if (src.format == attr.format) {
                    @memcpy(dst, src_bytes[0..size]);
                } else {
                    attr.format.encode(src.format.decode(src_bytes), dst);
                }
            }
        } else {
            var default: [16]u8 = undefined;
            attr.format.encode(.{ 0, 0, 0, 1 }, &default);
            for (0..vertex_count) |vi| {
                @memcpy(out[vi * stride + attr.offset ..][0..size], default[0..size]);
            }
        }
    }
}

fn allocVertices(self: *Self, allocator: std.mem.Allocator, layout_id: VertexLayoutID, count: u32) !Placement {
    const rec = &self.layouts.items[@intFromEnum(layout_id)];
    if (rec.pool.allocSpan(count)) |placement| return placement;
    // a mesh bigger than a page gets a page of its own size
    const capacity = @max(rec.pool.page_capacity, count);
    var buffers: [max_streams]c.WGPUBuffer = .{ null, null };
    errdefer for (buffers) |buffer| {
        if (buffer != null) c.wgpuBufferRelease(buffer);
    };
    for (0..rec.stream_count) |s| {
        buffers[s] = try createPageBuffer(
            self.gpu_context,
            @as(u64, capacity) * rec.strides[s],
            .{ .vertex = true, .copy_dst = true },
            "vertex page",
        );
    }
    _ = try rec.pool.addPage(allocator, buffers, capacity);
    return rec.pool.allocSpan(count).?;
}

fn allocIndices(self: *Self, allocator: std.mem.Allocator, count: u32) !Placement {
    if (self.index_pool.allocSpan(count)) |placement| return placement;
    const capacity = @max(self.index_pool.page_capacity, count);
    const buffer = try createPageBuffer(
        self.gpu_context,
        @as(u64, capacity) * @sizeOf(u32),
        .{ .index = true, .copy_dst = true },
        "index page",
    );
    errdefer c.wgpuBufferRelease(buffer);
    _ = try self.index_pool.addPage(allocator, .{ buffer, null }, capacity);
    return self.index_pool.allocSpan(count).?;
}

fn createPageBuffer(ctx: gpu.GPUContext, bytes: u64, usage: gpu.BufferUsage, label: []const u8) !c.WGPUBuffer {
    if (bytes > max_page_bytes) return error.PageTooLarge;
    return gpu.createBuffer(ctx, @intCast(bytes), usage, .{ .label = label });
}

// ---------------------------------------------------------------------------
// Materials, modules, shaders
// ---------------------------------------------------------------------------

pub const MaterialRecord = struct {
    shaderID: ShaderID,
    render_state: RenderStateID,
    // bind group 1
    bind_group: c.WGPUBindGroup,

    uniforms: []const gpu.BindGroupEntry.BufferEntry,

    const UniformSlot = struct {
        chunk: usize,
        size: u32,
        offset: u32,
    };
};

pub const VsEntry = struct {
    fn_name: []const u8,
    params: []const gpu.VertexInputMeta,
};

pub const ModuleRecord = struct {
    name: []const u8,
    module: c.WGPUShaderModule,
    group_layouts: []const ?c.WGPUBindGroupLayout,
    vs_entries: []const VsEntry,
    fs_entries: []const []const u8,
};

pub const ShaderRecord = struct {
    module: ModuleID,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
};

/// Each generated shader module declares its own anonymous struct type for
/// `VS`, so the entries are copied into the shared `VsEntry` shape at comptime.
fn vsEntriesOf(comptime Reflected: type) []const VsEntry {
    const vs = Reflected.VS orelse return &.{};
    var entries: [vs.len]VsEntry = undefined;
    for (vs, &entries) |v, *e| e.* = .{ .fn_name = v.fn_name, .params = v.params };
    const final = entries;
    return &final;
}

pub fn getOrCreateModule(self: *Self, allocator: std.mem.Allocator, comptime Reflected: type) !ModuleID {
    for (self.modules.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, Reflected.NAME)) {
            return @enumFromInt(i);
        }
    }
    const shader = try gpu.Shader(Reflected).init(allocator, self.gpu_context);
    try self.modules.append(allocator, .{
        .name = Reflected.NAME,
        .module = shader.module,
        .group_layouts = try allocator.dupe(?c.WGPUBindGroupLayout, &shader.group_layouts),
        .vs_entries = comptime vsEntriesOf(Reflected),
        .fs_entries = if (Reflected.FS) |fs| fs else &.{},
    });
    return @enumFromInt(self.modules.items.len - 1);
}

pub fn getOrCreateShader(self: *Self, allocator: std.mem.Allocator, comptime Reflected: type, vertex_entry: []const u8, fragment_entry: []const u8) !ShaderID {
    const module_id = try self.getOrCreateModule(allocator, Reflected);
    for (self.shaders.items, 0..) |s, i| {
        if (s.module == module_id and
            std.mem.eql(u8, s.vertex_entry, vertex_entry) and
            std.mem.eql(u8, s.fragment_entry, fragment_entry))
        {
            return @enumFromInt(i);
        }
    }
    try self.shaders.append(allocator, .{
        .module = module_id,
        .vertex_entry = vertex_entry,
        .fragment_entry = fragment_entry,
    });
    return @enumFromInt(self.shaders.items.len - 1);
}

pub fn getOrCreateRenderState(self: *Self, allocator: std.mem.Allocator, state: gpu.MaterialRenderState) !RenderStateID {
    for (self.render_states.items, 0..) |s, i| {
        if (std.meta.eql(s, state)) return @enumFromInt(i);
    }
    try self.render_states.append(allocator, state);
    return @enumFromInt(self.render_states.items.len - 1);
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

pub fn init(io: std.Io, allocator: std.mem.Allocator, instance: gpu.GPUInstance, surface: c.WGPUSurface) !Self {
    const gpu_context = try gpu.GPUContext.initSync(io, instance.webgpu_instance, surface);
    const target_surface = gpu.Surface.init(gpu_context, surface);
    var self: Self = .{
        .gpu_context = gpu_context,
        .target_surface = target_surface,
        .draw_commands = try .initCapacity(allocator, 512),
        .instance_buffer = try .initCapacity(allocator, 524_288),
        .index_pool = .{ .page_capacity = default_index_page_capacity },
        .builtin_layouts = undefined,
    };
    self.builtin_layouts = .{
        .static = try self.declareLayout(allocator, static_layout),
    };
    return self;
}

/// Releases everything the renderer owns on the CPU and GPU side.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.pipelines.items) |pipeline| c.wgpuRenderPipelineRelease(pipeline);
    self.pipelines.deinit(allocator);
    self.pipeline_ids.deinit(allocator);
    for (self.layouts.items) |*layout| {
        layout.pool.deinit(allocator);
        for (layout.attributes) |attr| allocator.free(attr.name);
        allocator.free(layout.attributes);
    }
    self.layouts.deinit(allocator);
    self.index_pool.deinit(allocator);
    self.meshes.deinit(allocator);
    self.free_mesh_slots.deinit(allocator);
    for (self.modules.items) |module| {
        c.wgpuShaderModuleRelease(module.module);
        for (module.group_layouts) |layout| {
            if (layout) |l| c.wgpuBindGroupLayoutRelease(l);
        }
        allocator.free(module.group_layouts);
    }
    self.modules.deinit(allocator);
    self.shaders.deinit(allocator);
    self.render_states.deinit(allocator);
    self.materials.deinit(allocator);
    self.material_uniforms.deinit(allocator);
    self.draw_commands.deinit(allocator);
    self.instance_buffer.deinit(allocator);
    self.* = undefined;
}

pub const SurfaceTargets = struct {
    sample_count: u32 = 1,
    depth: ?gpu.Texture = null,
    depth_view: c.WGPUTextureView = null,
    msaa_color: ?gpu.Texture = null,
    msaa_color_view: c.WGPUTextureView = null,

    fn recreate(self: *SurfaceTargets, ctx: gpu.GPUContext, color_format: gpu.TextureFormat, width: u32, height: u32) void {
        if (self.depth) |*t| {
            c.wgpuTextureViewRelease(self.depth_view);
            t.deinit();
        }
        self.depth = gpu.Texture.init(
            ctx,
            "surface depth",
            width,
            height,
            .@"2d",
            surface_depth_format,
            .{ .sample_count = self.sample_count },
            .{ .render_attachment = true },
        );
        self.depth_view = self.depth.?.createView(.{ .label = "surface depth view" });

        if (self.msaa_color) |*t| {
            c.wgpuTextureViewRelease(self.msaa_color_view);
            t.deinit();
            self.msaa_color = null;
            self.msaa_color_view = null;
        }
        if (self.sample_count > 1) {
            self.msaa_color = gpu.Texture.init(
                ctx,
                "surface msaa color",
                width,
                height,
                .@"2d",
                color_format,
                .{ .sample_count = self.sample_count },
                .{ .render_attachment = true },
            );
            self.msaa_color_view = self.msaa_color.?.createView(.{ .label = "surface msaa view" });
        }
    }
};

pub fn configureTarget(self: *Self, width: u32, height: u32) void {
    self.target_surface.configure(self.gpu_context, width, height);
    self.surface_targets.recreate(self.gpu_context, self.target_surface.format, width, height);
}

pub fn setSampleCount(self: *Self, sample_count: u32) void {
    if (sample_count == self.surface_targets.sample_count) return;
    self.surface_targets.sample_count = sample_count;
    if (self.surface_targets.depth) |t| {
        self.surface_targets.recreate(self.gpu_context, self.target_surface.format, t.width, t.height);
    }
}

pub fn beginFrame(self: *Self) Frame {
    return .{
        .renderer = self,
        .encoder = self.gpu_context.getEncoder(),
        .surface_view = null,
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

pub fn material(self: *Self, allocator: std.mem.Allocator, Reflected: type, params: MaterialParams(Reflected), render_state: gpu.MaterialRenderState) !Material(Reflected) {
    const Shader = gpu.Shader(Reflected);
    const shader_id = try self.getOrCreateShader(allocator, Reflected, "vs", "fs");
    const render_state_id = try self.getOrCreateRenderState(allocator, render_state);
    const resources: Shader.Resources(1) = undefined;
    const uniform_count = if (Reflected.Uniforms[1]) |bg| bg.len else 0;
    // TODO: no need for one buffer per binding
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
        self.modules.items[@intFromEnum(self.shaders.items[@intFromEnum(shader_id)].module)].group_layouts,
        resources,
    );
    const material_record: MaterialRecord = .{
        .shaderID = shader_id,
        .render_state = render_state_id,
        .bind_group = bind_group,
        .uniforms = uniforms,
    };
    try self.materials.append(allocator, material_record);
    const material_id = self.materials.items.len - 1;
    return .{
        .material_id = @intFromEnum(material_id),
        .shader_id = @intFromEnum(shader_id),
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
        shader_id: ShaderID,

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
        if (a.pipeline != b.pipeline) return @intFromEnum(a.pipeline) < @intFromEnum(b.pipeline);
        if (a.material != b.material) return @intFromEnum(a.material) < @intFromEnum(b.material);
        return @as(u32, @bitCast(a.mesh)) < @as(u32, @bitCast(b.mesh));
    }
};

pub const Frame = struct {
    renderer: *Self,
    encoder: c.WGPUCommandEncoder,
    surface_view: c.WGPUTextureView,
    world_buffer_cursor: u32 = 0,

    pub fn beginPass(self: *@This()) RenderPass {
        return .{ .draw_commands = &self.renderer.draw_commands };
    }

    pub fn endPass(self: *@This(), pass: RenderPass) void {
        _ = pass;
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
        mesh_id: MeshID,
        mat: anytype,
        params: DrawParams(@TypeOf(mat).InstanceType),
    ) !void {
        _ = params;
        try self.draw_commands.append(allocator, .{
            .material = mat.material_id,
            .mesh = mesh_id,
            .transparent = false,
            .pipeline = @enumFromInt(0),
            .depth = 0,
            .instance_offset = 0,
            .instance_size = 0,
        });
    }
};

pub const surface_depth_format: gpu.TextureFormat = .depth32_float;

pub const ColorTarget = union(enum) {
    // renderer managed
    surface,
    // app managed
    offline_target: struct {
        color: gpu.Texture,
        resolve_to: ?gpu.Texture = null,
    },
};

pub const DepthTarget = union(enum) {
    // renderer managed
    surface_depth,
    // app managed
    texture: gpu.Texture,
};

pub const ColorAttachment = struct {
    target: ColorTarget,
    clear_value: gpu.Color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
    load_op: gpu.LoadOp = .clear,
    store_op: gpu.StoreOp = .store,
};

pub const DepthStencilAttachment = struct {
    target: DepthTarget,
    depth_clear_value: f32 = 1.0,
    depth_load_op: gpu.LoadOp = .clear,
    depth_store_op: gpu.StoreOp = .store,
};

pub const PassDescriptor = struct {
    color_attachment: ?ColorAttachment = null,
    depth_stencil_attachment: ?DepthStencilAttachment = null,
    label: []const u8 = "render pass",
};

pub const PassPipelineState = struct {
    color_format: ?gpu.TextureFormat = null,
    depth_format: ?gpu.TextureFormat = null,
    sample_count: u32 = 1,
};

pub fn resolvePassState(self: *const Self, desc: PassDescriptor) PassPipelineState {
    var state = PassPipelineState{};
    if (desc.color_attachment) |ca| switch (ca.target) {
        .surface => {
            state.color_format = self.target_surface.format;
            state.sample_count = self.surface_targets.sample_count;
        },
        .offline_target => |t| {
            state.color_format = t.color.format;
            state.sample_count = t.color.sample_count;
            if (t.resolve_to) |r| {
                std.debug.assert(t.color.sample_count > 1);
                std.debug.assert(r.sample_count == 1);
                std.debug.assert(r.format == t.color.format);
                std.debug.assert(r.width == t.color.width and r.height == t.color.height);
            } else {
                std.debug.assert(t.color.sample_count == 1);
            }
        },
    };
    if (desc.depth_stencil_attachment) |da| {
        const depth_samples = switch (da.target) {
            .surface_depth => blk: {
                state.depth_format = surface_depth_format;
                break :blk self.surface_targets.sample_count;
            },
            .texture => |t| blk: {
                state.depth_format = t.format;
                break :blk t.sample_count;
            },
        };
        if (desc.color_attachment == null) {
            state.sample_count = depth_samples;
        } else {
            std.debug.assert(depth_samples == state.sample_count);
        }
    }
    return state;
}

// ---------------------------------------------------------------------------
// Pipelines
//
// Key = layout × shader × render state × pass targets. The layout selects
// classic vertex state (one buffer layout per stream); shader inputs are
// matched to layout attributes by name.
// ---------------------------------------------------------------------------

pub const PipelineKey = struct {
    layout: VertexLayoutID,
    shader_id: ShaderID,
    render_state_id: RenderStateID,
    pass_state: PassPipelineState,
};

pub fn getOrCreatePipeline(self: *Self, allocator: std.mem.Allocator, key: PipelineKey) !PipelineID {
    if (self.pipeline_ids.get(key)) |id| return id;
    const shader = self.shaders.items[@intFromEnum(key.shader_id)];
    const module = self.modules.items[@intFromEnum(shader.module)];
    const render_state = self.render_states.items[@intFromEnum(key.render_state_id)];
    const layout = &self.layouts.items[@intFromEnum(key.layout)];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    const params = blk: {
        for (module.vs_entries) |entry| {
            if (std.mem.eql(u8, entry.fn_name, shader.vertex_entry)) break :blk entry.params;
        }
        return error.VertexEntryNotFound;
    };
    const vertex_layouts = try buildVertexLayouts(temp, module.name, layout, params);

    // TODO fill gaps with empty bind group layouts (fixed slots, optional occupancy)
    const group_layouts = try temp.alloc(c.WGPUBindGroupLayout, module.group_layouts.len);
    for (group_layouts, module.group_layouts) |*dst, src| {
        dst.* = src orelse return error.UndefinedBindGroup;
    }

    const pipeline = try gpu.createPipeline(
        allocator,
        self.gpu_context,
        "render pipeline",
        .{
            .shader_module = module.module,
            .vertex_layouts = vertex_layouts,
            .blend = render_state.blend_state,
            .cull_mode = render_state.cull_mode,
            .depth_stencil = render_state.depth_stencil_state,
            .depth_format = key.pass_state.depth_format,
            .color_format = key.pass_state.color_format,
            .sample_count = key.pass_state.sample_count,
            .primitive_topology = .triangle_list,
        },
        shader.vertex_entry,
        shader.fragment_entry,
        group_layouts,
    );
    try self.pipelines.append(allocator, pipeline);
    const id: PipelineID = @enumFromInt(self.pipelines.items.len - 1);
    try self.pipeline_ids.put(allocator, key, id);
    return id;
}

/// One `VertexBufferLayout` per stream (slot = stream index). A stream may end
/// up with no attributes for a shader that reads only `position`; it is still
/// declared so the draw path can bind every stream unconditionally.
fn buildVertexLayouts(
    temp: std.mem.Allocator,
    shader_name: []const u8,
    layout: *const VertexLayoutRecord,
    params: []const gpu.VertexInputMeta,
) ![]gpu.VertexBufferLayout {
    const supplied = try temp.alloc(bool, params.len);
    @memset(supplied, false);
    const layouts = try temp.alloc(gpu.VertexBufferLayout, layout.stream_count);
    for (layouts, 0..) |*vertex_layout, s| {
        var attributes: std.ArrayList(gpu.VertexBufferLayout.VertexAttribute) = .empty;
        for (layout.attributes) |attr| {
            if (attr.stream != s) continue;
            const pi = gpu.indexOfVertexInput(params, attr.name) orelse continue;
            supplied[pi] = true;
            try attributes.append(temp, .{
                .format = attr.format,
                .offset = attr.offset,
                .shader_location = params[pi].location,
            });
        }
        vertex_layout.* = .{
            .step_mode = .vertex,
            .array_stride = layout.strides[s],
            .attributes = attributes.items,
        };
    }
    for (supplied, params) |ok, p| {
        if (!ok) {
            std.log.err(
                "{s} reads vertex input '{s}' at location {d}, which the mesh layout does not supply",
                .{ shader_name, p.name, p.location },
            );
            return error.MissingVertexInput;
        }
    }
    return layouts;
}

/// Compiles every material × declared layout × pass state up front, so no
/// pipeline is compiled when a mesh streams in. Layouts that don't feed a
/// material's shader are skipped, not errors.
pub fn precompilePipelines(self: *Self, allocator: std.mem.Allocator, pass_states: []const PassPipelineState) !void {
    var created: usize = 0;
    var skipped: usize = 0;
    for (self.materials.items) |mat| {
        for (0..self.layouts.items.len) |li| {
            for (pass_states) |pass_state| {
                const key: PipelineKey = .{
                    .layout = @enumFromInt(li),
                    .shader_id = mat.shaderID,
                    .render_state_id = mat.render_state,
                    .pass_state = pass_state,
                };
                if (self.pipeline_ids.contains(key)) continue;
                _ = self.getOrCreatePipeline(allocator, key) catch |err| switch (err) {
                    error.MissingVertexInput => {
                        skipped += 1;
                        continue;
                    },
                    else => return err,
                };
                created += 1;
            }
        }
    }
    std.log.info(
        "precompiled {d} pipelines over {d} layouts ({d} material/layout pairs incompatible)",
        .{ created, self.layouts.items.len, skipped },
    );
}

// ---------------------------------------------------------------------------
// Tests (GPU-free)
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

/// A renderer with no device: enough for layouts, pools and packing.
fn testRenderer() Self {
    return .{
        .gpu_context = undefined,
        .target_surface = undefined,
        .index_pool = .{ .page_capacity = 8 },
        .vertex_page_capacity = 8,
        .builtin_layouts = undefined,
    };
}

test "FreeList first-fit, exact fit, coalescing" {
    const allocator = std.testing.allocator;
    var list = try FreeList.init(allocator, 100);
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0), list.alloc(10));
    try std.testing.expectEqual(@as(?u32, 10), list.alloc(20));
    try std.testing.expectEqual(@as(?u32, 30), list.alloc(10));
    try std.testing.expectEqual(@as(?u32, null), list.alloc(61));

    // free the middle: a hole that fits 20 but not 21
    try list.free(allocator, 10, 20);
    try std.testing.expectEqual(@as(usize, 2), list.spans.items.len);
    try std.testing.expectEqual(@as(?u32, 10), list.alloc(20)); // exact fit removes the span
    try std.testing.expectEqual(@as(usize, 1), list.spans.items.len);

    // free in an order that exercises join-prev, join-next and join-both
    try list.free(allocator, 0, 10); // no neighbours → new span
    try list.free(allocator, 30, 10); // joins next (the tail [40,100))
    try list.free(allocator, 10, 20); // joins both
    try std.testing.expect(list.isEmpty(100));
}

test "Pool picks the first page that fits and never resizes one" {
    const allocator = std.testing.allocator;
    var pool: Pool = .{ .page_capacity = 8 };
    defer pool.deinit(allocator);

    _ = try pool.addPage(allocator, .{ null, null }, 8);
    try std.testing.expectEqual(Placement{ .page = 0, .base = 0 }, pool.allocSpan(6).?);
    try std.testing.expectEqual(@as(?Placement, null), pool.allocSpan(3));
    _ = try pool.addPage(allocator, .{ null, null }, 8);
    try std.testing.expectEqual(Placement{ .page = 1, .base = 0 }, pool.allocSpan(3).?);
    try std.testing.expectEqual(Placement{ .page = 0, .base = 6 }, pool.allocSpan(2).?);
    try pool.freeSpan(allocator, .{ .page = 0, .base = 0 }, 6);
    try pool.freeSpan(allocator, .{ .page = 0, .base = 6 }, 2);
    try std.testing.expect(pool.pages.items[0].free.isEmpty(8));
}

test "declareLayout packs the static layout, dedups, validates" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer();
    defer renderer.deinit(allocator);

    const a = try renderer.declareLayout(allocator, static_layout);
    const b = try renderer.declareLayout(allocator, static_layout);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), renderer.layouts.items.len);

    const rec = renderer.layouts.items[@intFromEnum(a)];
    try std.testing.expectEqual(@as(u8, 2), rec.stream_count);
    try std.testing.expectEqual([max_streams]u32{ 12, 20 }, rec.strides);
    try std.testing.expectEqualStrings("position", rec.attributes[0].name);
    try std.testing.expectEqual(@as(u8, 0), rec.attributes[0].stream);
    try std.testing.expectEqual(@as(u32, 0), rec.attributes[0].offset);
    try std.testing.expectEqual(@as(u8, 1), rec.attributes[1].stream); // normal
    try std.testing.expectEqual(@as(u32, 0), rec.attributes[1].offset);
    try std.testing.expectEqual(@as(u32, 8), rec.attributes[2].offset); // uv
    try std.testing.expectEqual(@as(u32, 16), rec.attributes[3].offset); // color

    // position only → one stream
    const p = try renderer.declareLayout(allocator, .{ .attributes = &.{.{ .name = "position", .format = .f32x3 }} });
    try std.testing.expect(p != a);
    try std.testing.expectEqual(@as(u8, 1), renderer.layouts.items[@intFromEnum(p)].stream_count);

    // a 2-byte attribute followed by a 4-byte one gets padded to 4
    const padded = try renderer.declareLayout(allocator, .{ .attributes = &.{
        .{ .name = "position", .format = .f32x3 },
        .{ .name = "w", .format = .f16 },
        .{ .name = "uv", .format = .f32x2 },
    } });
    const padded_rec = renderer.layouts.items[@intFromEnum(padded)];
    try std.testing.expectEqual(@as(u32, 4), padded_rec.attributes[2].offset);
    try std.testing.expectEqual(@as(u32, 12), padded_rec.strides[1]);

    try std.testing.expectError(error.MissingPosition, renderer.declareLayout(allocator, .{ .attributes = &.{.{ .name = "uv", .format = .f32x2 }} }));
    try std.testing.expectError(error.DuplicateAttribute, renderer.declareLayout(allocator, .{ .attributes = &.{
        .{ .name = "position", .format = .f32x3 },
        .{ .name = "position", .format = .f32x3 },
    } }));
}

test "packStream copies, converts and defaults" {
    const allocator = std.testing.allocator;
    var renderer = testRenderer();
    defer renderer.deinit(allocator);
    const id = try renderer.declareLayout(allocator, static_layout);
    const rec = &renderer.layouts.items[@intFromEnum(id)];

    // the app's vertex: f32 position, uv, normal — no color
    const Vertex = extern struct { position: [3]f32, uv: [2]f32, normal: [3]f32 };
    const vertices = [_]Vertex{
        .{ .position = .{ 1, 2, 3 }, .uv = .{ 0.5, 0.25 }, .normal = .{ 0, 0, 1 } },
        .{ .position = .{ 4, 5, 6 }, .uv = .{ 1, 1 }, .normal = .{ 0, -1, 0 } },
    };
    const streams = [_]MeshData.Stream{.{
        .layout = .{ .stride = @sizeOf(Vertex), .attributes = &.{
            .{ .name = "position", .format = .f32x3, .offset = 0 },
            .{ .name = "uv", .format = .f32x2, .offset = 12 },
            .{ .name = "normal", .format = .f32x3, .offset = 20 },
        } },
        .data = std.mem.sliceAsBytes(&vertices),
    }};

    var positions: [24]u8 = undefined;
    packStream(rec, 0, &streams, 2, &positions);
    const expected_positions = [_]f32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected_positions), &positions);

    var attributes: [40]u8 = undefined;
    packStream(rec, 1, &streams, 2, &attributes);
    // vertex 0: normal (0,0,1,w=1) as snorm16x4, uv copied, color defaulted to (0,0,0,1)
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xff, 0x7f, 0xff, 0x7f }, attributes[0..8]);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]f32{ 0.5, 0.25 }), attributes[8..16]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xff }, attributes[16..20]);
    // vertex 1: normal (0,-1,0,1)
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x01, 0x80, 0, 0, 0xff, 0x7f }, attributes[20..28]);
}
