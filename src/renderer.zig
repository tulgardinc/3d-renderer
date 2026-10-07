const std = @import("std");
const gpu = @import("gpu");
const c = gpu.c;
const l = @import("lena.zig");

pub const StreamLayout = struct {
    stride: u32,
    attributes: []const Attribute,

    const Self = @This();

    pub const Attribute = struct {
        name: []const u8,
        format: gpu.VertexFormat,
        offset: u32,
    };

    pub fn fromAttributes(attrs: []const Attribute) Self {
        const stride = blk: {
            var sum = 0;
            for (attrs) |attr| {
                sum += attr.format.byteSize();
            }
            break :blk sum;
        };
        return .{
            .stride = stride,
            .attributes = attrs,
        };
    }
};

pub const default_layout: []const StreamLayout = &.{
    .{
        .stride = 12,
        .attributes = &.{
            .{
                .name = "position",
                .format = .f32x3,
                .offset = 0,
            },
        },
    },
    .{
        .stride = 20,
        .attributes = &.{
            .{
                .name = "normal",
                .format = .snorm16x4,
                .offset = 0,
            },
            .{
                .name = "uv",
                .format = .f32x2,
                .offset = 8,
            },
            .{
                .name = "color",
                .format = .unorm8x4,
                .offset = 16,
            },
        },
    },
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn pluginsType(S: type) ?type {
    if (S.Uniforms.len == 0) return null;
    const group = S.Uniforms[0] orelse return null;
    for (group) |u| {
        if (std.mem.eql(u8, u.name, "plugins")) return u.Type;
    }
    return null;
}

pub fn nameHash(comptime name: []const u8) u64 {
    return comptime std.hash.Fnv1a_64.hash(name);
}

pub fn layoutFingerprint(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var hasher = std.hash.Fnv1a_64.init();
        hashLayout(&hasher, T);
        break :blk hasher.final();
    };
}

fn hashLayout(hasher: *std.hash.Fnv1a_64, comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            hasher.update(if (info.signedness == .signed) "i" else "u");
            hashInt(hasher, info.bits);
        },
        .float => |info| {
            hasher.update("f");
            hashInt(hasher, info.bits);
        },
        .array => |info| {
            hasher.update("[");
            hashInt(hasher, info.len);
            hashInt(hasher, @sizeOf(info.child));
            hashLayout(hasher, info.child);
        },
        .@"struct" => |info| {
            if (info.layout != .@"extern") @compileError(@typeName(T) ++ " must be an extern struct to have a fixed layout");
            hasher.update("{");
            inline for (info.fields) |f| {
                if (comptime std.mem.startsWith(u8, f.name, "pad_")) continue;
                hasher.update(f.name);
                hashInt(hasher, @offsetOf(T, f.name));
                hashLayout(hasher, f.type);
            }
            hasher.update("}");
        },
        else => @compileError(@typeName(T) ++ " cannot be used as a pass uniform value"),
    }
}

fn hashInt(hasher: *std.hash.Fnv1a_64, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

pub const RendererConfig = struct {
    comptime geometry_pool: GeometryPoolConfig = .{},
    comptime max_pass_count: usize = 16,

    pub const GeometryPoolConfig = struct {
        layouts: []const StreamLayout = default_layout,
        page_capacity: u32 = 524_288,
        index_chunk_capacity: u32 = 4_194_304,
    };
};

pub fn Renderer(config: RendererConfig) type {
    return struct {
        gpu_context: gpu.GPUContext,
        surface_targets: SurfaceTargets,

        draw_commands: std.ArrayList(DrawCmd),
        instances_cpu: std.ArrayList(u8),
        sorted_instances_cpu: std.ArrayList(u8),
        draw_batches: std.ArrayList(DrawBatch),

        pass_values: std.ArrayList(u8),
        pass_value_entries: std.ArrayList(PassValueEntry),
        pass_snapshots: std.ArrayList(PassSnapshot),
        pass_blocks: std.AutoHashMapUnmanaged(PassBlockKey, u32),
        pass_states: [config.max_pass_count]PassState = undefined,

        materials: std.ArrayList(MaterialRecord),
        render_states: std.ArrayList(gpu.MaterialRenderState),
        modules: std.ArrayList(ModuleRecord),
        shaders: std.ArrayList(ShaderProgramRecord),
        pipelines: std.AutoHashMapUnmanaged(PipelineKey, c.WGPURenderPipeline),

        geometry_pool: GeometryPool,

        world_uniforms_gpu: c.WGPUBuffer,
        world_uniforms_gpu_capacity: u32 = world_uniforms_gpu_initial_capacity,
        world_uniforms_cpu: std.ArrayList(u8),
        instances_gpu: c.WGPUBuffer,
        instances_gpu_capacity: u32 = instances_gpu_initial_capacity,
        instances_layout: c.WGPUBindGroupLayout,
        instances_bind_group: c.WGPUBindGroup,
        material_unfiorms: std.ArrayList(c.WGPUBuffer),

        const Self = @This();

        pub const RenderStateID = enum(u32) { _ };
        pub const MaterialID = enum(u32) { _ };
        pub const MeshID = packed struct { gen: u8, index: u24 };
        pub const ModuleID = enum(u32) { _ };
        pub const ShaderProgramID = enum(u32) { _ };

        pub const world_uniforms_gpu_initial_capacity: u32 = 256 * config.max_pass_count;
        pub const instances_gpu_initial_capacity: u32 = 524_288;

        pub const PassValueEntry = struct {
            name_hash: u64,
            fingerprint: u64,
            offset: u32,
            size: u32,
        };

        pub const PassSnapshot = struct {
            first_entry: u32,
            entry_count: u32,
        };

        pub const PassBlockKey = struct {
            snapshot_index: u32,
            module_id: ModuleID,
        };

        pub const PassState = struct {
            snapshot_index: u32,
            world_offset: ?u32,
            last_module_id: ?ModuleID,
            last_snapshot_index: u32,
            last_block_offset: u32,
        };

        pub const PassUniform = struct {
            binding: u32,
            size: u32,
        };

        fn createWorldBindGroup(
            self: *const Self,
            allocator: std.mem.Allocator,
            layout: c.WGPUBindGroupLayout,
            pass_uniforms: []const PassUniform,
        ) !c.WGPUBindGroup {
            const entries = try allocator.alloc(gpu.BindGroupEntry, pass_uniforms.len);
            defer allocator.free(entries);
            for (pass_uniforms, entries) |u, *entry| {
                entry.* = .{
                    .binding = u.binding,
                    .resource = .{ .buffer = .{ .buffer = self.world_uniforms_gpu, .size = u.size } },
                };
            }
            return gpu.createBindGroup(allocator, self.gpu_context, .{
                .layout = layout,
                .entries = entries,
            });
        }

        pub const WorldUniformsSlot = struct {
            offset: u32,
            bytes: []u8,
        };

        pub fn stageWorldUniforms(self: *Self, allocator: std.mem.Allocator, size: u32) !WorldUniformsSlot {
            const offset: u32 = @intCast(self.world_uniforms_cpu.items.len);
            const bytes = try self.world_uniforms_cpu.addManyAsSlice(allocator, std.mem.alignForward(u32, size, 256));
            return .{ .offset = offset, .bytes = bytes[0..size] };
        }

        fn growWorldUniformsGpu(self: *Self, allocator: std.mem.Allocator, min_capacity: u32) !void {
            var new_capacity = self.world_uniforms_gpu_capacity;
            while (new_capacity < min_capacity) new_capacity *= 2;
            const new_buffer = try gpu.createBuffer(
                self.gpu_context,
                new_capacity,
                .{ .uniform = true, .copy_dst = true },
                .{ .label = "world uniforms" },
            );
            c.wgpuBufferRelease(self.world_uniforms_gpu);
            self.world_uniforms_gpu = new_buffer;
            self.world_uniforms_gpu_capacity = new_capacity;
            for (self.modules.items) |*module| {
                const new_bind_group = try self.createWorldBindGroup(allocator, module.group_layouts[0], module.pass_uniforms);
                c.wgpuBindGroupRelease(module.world_bind_group);
                module.world_bind_group = new_bind_group;
            }
        }

        fn growInstancesGpu(self: *Self, allocator: std.mem.Allocator, min_capacity: u32) !void {
            var new_capacity = self.instances_gpu_capacity;
            while (new_capacity < min_capacity) new_capacity *= 2;
            const new_buffer = try gpu.createBuffer(
                self.gpu_context,
                new_capacity,
                .{ .storage = true, .copy_dst = true },
                .{ .label = "world instances" },
            );
            errdefer c.wgpuBufferRelease(new_buffer);
            const new_bind_group = try gpu.createBindGroup(allocator, self.gpu_context, .{
                .layout = self.instances_layout,
                .entries = &.{.{
                    .binding = 0,
                    .resource = .{ .buffer = .{ .buffer = new_buffer, .size = new_capacity } },
                }},
            });
            c.wgpuBindGroupRelease(self.instances_bind_group);
            c.wgpuBufferRelease(self.instances_gpu);
            self.instances_gpu = new_buffer;
            self.instances_gpu_capacity = new_capacity;
            self.instances_bind_group = new_bind_group;
        }

        pub const MeshLocation = struct {
            page_index: u32,
            base_vertex: u32,
            vertex_count: u32,
            indices: ?struct {
                chunk_index: u32,
                base_index: u32,
                index_count: u32,
            },
        };

        pub const GeometryPool = struct {
            pages: std.ArrayList(Page),
            gpu_context: gpu.GPUContext,
            mesh_table: std.ArrayList(MeshRecord),
            mesh_table_next_free: ?usize,
            index_chunks: std.ArrayList(IndexChunk),
            index_count: usize,

            pub const MeshRecord = struct {
                gen: u8,
                data: union(enum) {
                    location: MeshLocation,
                    next_free: usize,
                },
            };

            // TODO freeing

            pub fn meshTableAppend(self: *@This(), allocator: std.mem.Allocator, location: MeshLocation) !MeshID {
                if (self.mesh_table_next_free) |free_index| {
                    var free_slot = &self.mesh_table.items[free_index];
                    self.mesh_table_next_free = free_slot.data.next_free;
                    free_slot.data = .{ .location = location };
                    return .{ .gen = free_slot.gen, .index = @intCast(free_index) };
                }
                try self.mesh_table.append(allocator, .{ .gen = 0, .data = .{ .location = location } });
                return .{ .gen = 0, .index = @intCast(self.mesh_table.items.len - 1) };
            }

            pub fn append(self: *@This(), allocator: std.mem.Allocator, mesh_data: MeshData) !MeshID {
                std.debug.assert(mesh_data.vertex_count <= config.geometry_pool.page_capacity);

                if (self.pages.items.len == 0) {
                    var new_page: Page = undefined;
                    inline for (config.geometry_pool.layouts, 0..) |layout, i| {
                        new_page.data[i] = try gpu.createBuffer(self.gpu_context, layout.stride * config.geometry_pool.page_capacity, .{ .vertex = true, .copy_dst = true }, .{ .label = "vertex buffer" });
                    }
                    new_page.size = 0;
                    try self.pages.append(allocator, new_page);
                }

                // TODO some system for onerror deallocating
                var mesh_location: MeshLocation = undefined;

                if (mesh_data.indices) |ind| {
                    if (self.index_chunks.items.len == 0) {
                        const new_buffer = try gpu.createBuffer(self.gpu_context, config.geometry_pool.index_chunk_capacity * @sizeOf(u32), .{ .index = true, .copy_dst = true }, .{ .label = "index buffer" });
                        try self.index_chunks.append(allocator, .{ .buffer = new_buffer, .size = 0 });
                    }

                    var index_chunk = &self.index_chunks.items[self.index_chunks.items.len - 1];
                    const chunk_remaining_capacity = config.geometry_pool.index_chunk_capacity - index_chunk.size;
                    if (chunk_remaining_capacity >= ind.len) {
                        gpu.writeBuffer(self.gpu_context, index_chunk.buffer, index_chunk.size * @sizeOf(u32), std.mem.sliceAsBytes(ind));
                        mesh_location.indices = .{
                            .base_index = index_chunk.size,
                            .chunk_index = @intCast(self.index_chunks.items.len - 1),
                            .index_count = @intCast(ind.len),
                        };
                        index_chunk.size += @intCast(ind.len);
                    } else {
                        const new_buffer = try gpu.createBuffer(self.gpu_context, config.geometry_pool.index_chunk_capacity * @sizeOf(u32), .{ .index = true, .copy_dst = true }, .{ .label = "index buffer" });
                        gpu.writeBuffer(self.gpu_context, new_buffer, 0, std.mem.sliceAsBytes(ind));
                        try self.index_chunks.append(allocator, .{ .buffer = new_buffer, .size = @intCast(ind.len) });
                        mesh_location.indices = .{
                            .base_index = 0,
                            .chunk_index = @intCast(self.index_chunks.items.len - 1),
                            .index_count = @intCast(ind.len),
                        };
                    }
                } else {
                    mesh_location.indices = null;
                }

                var last_page = &self.pages.items[self.pages.items.len - 1];
                const page_remaining_capacity = config.geometry_pool.page_capacity - last_page.size;
                if (page_remaining_capacity >= mesh_data.vertex_count) {
                    // append to page
                    inline for (config.geometry_pool.layouts, 0..) |layout, i| {
                        gpu.writeBuffer(self.gpu_context, last_page.data[i], last_page.size * layout.stride, mesh_data.streams[i].data);
                    }

                    mesh_location.base_vertex = last_page.size;
                    mesh_location.page_index = @intCast(self.pages.items.len - 1);
                    mesh_location.vertex_count = mesh_data.vertex_count;

                    last_page.size += mesh_data.vertex_count;

                    return try self.meshTableAppend(allocator, mesh_location);
                }
                // new page
                var new_page: Page = undefined;
                inline for (config.geometry_pool.layouts, 0..) |layout, i| {
                    new_page.data[i] = try gpu.createBuffer(self.gpu_context, layout.stride * config.geometry_pool.page_capacity, .{ .vertex = true, .copy_dst = true }, .{ .label = "vertex buffer" });
                    gpu.writeBuffer(self.gpu_context, new_page.data[i], 0, mesh_data.streams[i].data);
                }
                new_page.size = mesh_data.vertex_count;
                try self.pages.append(allocator, new_page);

                mesh_location.base_vertex = 0;
                mesh_location.page_index = @intCast(self.pages.items.len - 1);
                mesh_location.vertex_count = mesh_data.vertex_count;

                return try self.meshTableAppend(allocator, mesh_location);
            }

            pub fn get(self: @This(), mesh_id: MeshID) ?MeshLocation {
                const slot = self.mesh_table.items[@intCast(mesh_id.index)];
                if (slot.gen != mesh_id.gen) return null;
                return slot.data.location;
            }

            pub const Page = struct {
                // TODO handle tails in pages
                data: [config.geometry_pool.layouts.len]c.WGPUBuffer,
                /// in vertex count
                size: u32,
            };

            pub const IndexChunk = struct {
                buffer: c.WGPUBuffer,
                // in index count
                size: u32,
            };
        };

        pub const MaterialRecord = struct {
            shader_id: ShaderProgramID,
            render_state_id: RenderStateID,
            // bind group 1
            bind_group: c.WGPUBindGroup,

            uniforms: []const gpu.BindGroupEntry.BufferEntry,

            const UniformSlot = struct {
                chunk: usize,
                size: u32,
                offset: u32,
            };
        };

        pub const ModuleRecord = struct {
            name: []const u8,
            module: c.WGPUShaderModule,
            group_layouts: []const c.WGPUBindGroupLayout,
            pass_uniforms: []const PassUniform,
            world_bind_group: c.WGPUBindGroup,
            vs: []const gpu.VertexEntryMeta,
            fs: []const []const u8,
        };

        pub const ShaderProgramRecord = struct {
            module_id: ModuleID,
            vertex_entry: []const u8,
            fragment_entry: ?[]const u8,
        };

        pub fn getOrCreateModule(self: *Self, allocator: std.mem.Allocator, S: type) !ModuleID {
            for (self.modules.items, 0..) |m, i| {
                if (std.mem.eql(u8, m.name, S.NAME)) {
                    return @enumFromInt(i);
                }
            }
            var shader = try gpu.Shader(S).init(allocator, self.gpu_context);
            if (comptime S.layouts.len > 0 and S.layouts[0] != null) {
                var world_entries = S.layouts[0].?[0..S.layouts[0].?.len].*;
                for (&world_entries) |*entry| switch (entry.type) {
                    .buffer => |*buffer| if (buffer.type == .uniform) {
                        buffer.has_dynamic_offset = true;
                    },
                    else => {},
                };
                c.wgpuBindGroupLayoutRelease(shader.group_layouts[0]);
                shader.group_layouts[0] = try gpu.createBindGroupLayout(allocator, self.gpu_context, &world_entries);
            }
            if (comptime S.layouts.len > 2 and S.layouts[2] != null) {
                c.wgpuBindGroupLayoutRelease(shader.group_layouts[2]);
                c.wgpuBindGroupLayoutAddRef(self.instances_layout);
                shader.group_layouts[2] = self.instances_layout;
            }
            const pass_uniforms: []const PassUniform = comptime blk: {
                if (S.Uniforms.len == 0 or S.Uniforms[0] == null) break :blk &.{};
                var list: [S.Uniforms[0].?.len]PassUniform = undefined;
                for (S.Uniforms[0].?, &list) |u, *entry| {
                    entry.* = .{ .binding = u.binding, .size = @sizeOf(u.Type) };
                }
                const final = list;
                break :blk &final;
            };
            const world_bind_group = try self.createWorldBindGroup(allocator, shader.group_layouts[0], pass_uniforms);
            try self.modules.append(allocator, .{
                .name = S.NAME,
                .group_layouts = try allocator.dupe(c.WGPUBindGroupLayout, &shader.group_layouts),
                .pass_uniforms = pass_uniforms,
                .world_bind_group = world_bind_group,
                .module = shader.module,
                .vs = S.VS orelse &.{},
                .fs = S.FS orelse &.{},
            });
            return @enumFromInt(self.modules.items.len - 1);
        }

        pub fn getOrCreateShader(self: *Self, allocator: std.mem.Allocator, S: type, vertex_entry: []const u8, fragment_entry: ?[]const u8) !ShaderProgramID {
            const module_id = try self.getOrCreateModule(allocator, S);
            for (self.shaders.items, 0..) |s, i| {
                if (s.module_id == module_id and
                    std.mem.eql(u8, s.vertex_entry, vertex_entry) and
                    optionalStringEql(s.fragment_entry, fragment_entry))
                {
                    return @enumFromInt(i);
                }
            }
            try self.shaders.append(allocator, .{
                .module_id = module_id,
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
                field_attrs[count] = .{
                    .default_value_ptr = f.default_value_ptr,
                };
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

        pub fn init(allocator: std.mem.Allocator, io: std.Io, instance: c.WGPUInstance, surface: c.WGPUSurface) !Self {
            const gpu_context = try gpu.GPUContext.initSync(io, instance, surface);
            const world_uniforms_gpu = try gpu.createBuffer(
                gpu_context,
                world_uniforms_gpu_initial_capacity,
                .{ .uniform = true, .copy_dst = true },
                .{ .label = "world uniforms" },
            );
            const world_instances = try gpu.createBuffer(
                gpu_context,
                instances_gpu_initial_capacity,
                .{ .storage = true, .copy_dst = true },
                .{ .label = "world instances" },
            );
            const instances_layout = try gpu.createBindGroupLayout(allocator, gpu_context, &.{.{
                .binding = 0,
                .type = .{ .buffer = .{
                    .type = .read_only_storage,
                    .has_dynamic_offset = false,
                    .min_binding_size = 0,
                } },
            }});
            const instances_bind_group = try gpu.createBindGroup(allocator, gpu_context, .{
                .layout = instances_layout,
                .entries = &.{.{
                    .binding = 0,
                    .resource = .{ .buffer = .{ .buffer = world_instances, .size = instances_gpu_initial_capacity } },
                }},
            });
            var pass_blocks: std.AutoHashMapUnmanaged(PassBlockKey, u32) = .empty;
            try pass_blocks.ensureTotalCapacity(allocator, 256);
            return .{
                .gpu_context = gpu_context,
                .surface_targets = .{ .surface = gpu.Surface.init(gpu_context, surface) },
                .draw_commands = try .initCapacity(allocator, 512),
                .instances_cpu = try .initCapacity(allocator, 524_288),
                .sorted_instances_cpu = try .initCapacity(allocator, 524_288),
                .draw_batches = try .initCapacity(allocator, 512),
                .pass_values = try .initCapacity(allocator, 16_384),
                .pass_value_entries = try .initCapacity(allocator, 256),
                .pass_snapshots = try .initCapacity(allocator, 256),
                .pass_blocks = pass_blocks,
                .materials = .empty,
                .render_states = .empty,
                .modules = .empty,
                .shaders = .empty,
                .pipelines = .empty,
                .geometry_pool = .{
                    .pages = .empty,
                    .gpu_context = gpu_context,
                    .mesh_table = .empty,
                    .mesh_table_next_free = null,
                    .index_chunks = .empty,
                    .index_count = 0,
                },
                .material_unfiorms = .empty,
                .world_uniforms_gpu = world_uniforms_gpu,
                .world_uniforms_cpu = try .initCapacity(allocator, world_uniforms_gpu_initial_capacity),
                .instances_gpu = world_instances,
                .instances_layout = instances_layout,
                .instances_bind_group = instances_bind_group,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var pipeline_iter = self.pipelines.valueIterator();
            while (pipeline_iter.next()) |pipeline| c.wgpuRenderPipelineRelease(pipeline.*);
            self.pipelines.deinit(allocator);

            for (self.materials.items) |record| {
                c.wgpuBindGroupRelease(record.bind_group);
                for (record.uniforms) |entry| c.wgpuBufferRelease(entry.buffer);
                allocator.free(record.uniforms);
            }
            self.materials.deinit(allocator);

            for (self.modules.items) |record| {
                c.wgpuBindGroupRelease(record.world_bind_group);
                for (record.group_layouts) |group_layout| {
                    if (group_layout) |gl| c.wgpuBindGroupLayoutRelease(gl);
                }
                allocator.free(record.group_layouts);
                c.wgpuShaderModuleRelease(record.module);
            }
            self.modules.deinit(allocator);

            self.shaders.deinit(allocator);
            self.render_states.deinit(allocator);

            for (self.material_unfiorms.items) |buffer| c.wgpuBufferRelease(buffer);
            self.material_unfiorms.deinit(allocator);

            for (self.geometry_pool.pages.items) |page| {
                for (page.data) |buffer| c.wgpuBufferRelease(buffer);
            }
            self.geometry_pool.pages.deinit(allocator);
            for (self.geometry_pool.index_chunks.items) |chunk| c.wgpuBufferRelease(chunk.buffer);
            self.geometry_pool.index_chunks.deinit(allocator);
            self.geometry_pool.mesh_table.deinit(allocator);

            c.wgpuBindGroupRelease(self.instances_bind_group);
            c.wgpuBindGroupLayoutRelease(self.instances_layout);
            c.wgpuBufferRelease(self.instances_gpu);
            c.wgpuBufferRelease(self.world_uniforms_gpu);

            self.draw_commands.deinit(allocator);
            self.instances_cpu.deinit(allocator);
            self.sorted_instances_cpu.deinit(allocator);
            self.draw_batches.deinit(allocator);
            self.pass_values.deinit(allocator);
            self.pass_value_entries.deinit(allocator);
            self.pass_snapshots.deinit(allocator);
            self.pass_blocks.deinit(allocator);
            self.world_uniforms_cpu.deinit(allocator);

            if (self.surface_targets.depth) |*t| {
                c.wgpuTextureViewRelease(self.surface_targets.depth_view);
                t.deinit();
            }
            if (self.surface_targets.msaa_color) |*t| {
                c.wgpuTextureViewRelease(self.surface_targets.msaa_color_view);
                t.deinit();
            }
            self.surface_targets.surface.deinit();

            self.gpu_context.deinit();
        }

        pub const SurfaceTargets = struct {
            surface: gpu.Surface,
            sample_count: u32 = 1,
            depth: ?gpu.Texture = null,
            depth_view: c.WGPUTextureView = null,
            msaa_color: ?gpu.Texture = null,
            msaa_color_view: c.WGPUTextureView = null,

            fn recreate(self: *SurfaceTargets, ctx: gpu.GPUContext) void {
                if (self.depth) |*t| {
                    c.wgpuTextureViewRelease(self.depth_view);
                    t.deinit();
                }
                self.depth = gpu.Texture.init(
                    ctx,
                    "surface depth",
                    self.surface.width,
                    self.surface.height,
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
                        self.surface.width,
                        self.surface.height,
                        .@"2d",
                        self.surface.format,
                        .{ .sample_count = self.sample_count },
                        .{ .render_attachment = true },
                    );
                    self.msaa_color_view = self.msaa_color.?.createView(.{ .label = "surface msaa view" });
                }
            }
        };

        pub fn configureTarget(self: *Self, width: u32, height: u32) void {
            self.surface_targets.surface.configure(self.gpu_context, width, height);
            self.surface_targets.recreate(self.gpu_context);
        }

        pub fn setSampleCount(self: *Self, sample_count: u32) void {
            if (sample_count == self.surface_targets.sample_count) return;
            self.surface_targets.sample_count = sample_count;
            if (self.surface_targets.depth != null) self.surface_targets.recreate(self.gpu_context);
        }

        pub fn beginFrame(self: *Self) !Frame {
            const surface_texture = try self.surface_targets.surface.getTexture();
            self.world_uniforms_cpu.clearRetainingCapacity();
            self.draw_commands.clearRetainingCapacity();
            self.instances_cpu.clearRetainingCapacity();
            self.sorted_instances_cpu.clearRetainingCapacity();
            self.draw_batches.clearRetainingCapacity();
            self.pass_values.clearRetainingCapacity();
            self.pass_value_entries.clearRetainingCapacity();
            self.pass_snapshots.clearRetainingCapacity();
            self.pass_blocks.clearRetainingCapacity();
            return .{
                .renderer = self,
                .encoder = self.gpu_context.getEncoder(),
                .surface_texture = surface_texture,
                .passes = undefined,
            };
        }

        pub fn MaterialParams(Reflected: type) type {
            const uniforms: []const gpu.BindGroupUniformEntryMeta = if (Reflected.Uniforms.len > 1) Reflected.Uniforms[1] orelse &.{} else &.{};
            const resources: []const gpu.BindGroupResourceEntryMeta = if (Reflected.Resources.len > 1) Reflected.Resources[1] orelse &.{} else &.{};
            const uniform_count = uniforms.len;
            const resource_count = resources.len;
            const field_count = uniform_count + resource_count;
            if (field_count == 0) return void;

            var field_names: [field_count][]const u8 = undefined;
            var field_types: [field_count]type = undefined;
            var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;

            for (uniforms, 0..) |u, i| {
                field_names[i] = u.name;
                field_types[i] = u.Type;
                field_attrs[i] = .{};
            }

            for (resources, 0..) |res, i| {
                field_names[uniform_count + i] = res.name;
                field_types[uniform_count + i] = switch (res.resource_type) {
                    .texture => MaterialTexture,
                    .sampler => gpu.SamplerConfig,
                    .storage => gpu.BindGroupEntry.BufferEntry,
                };
                field_attrs[uniform_count + i] = switch (res.resource_type) {
                    .sampler => .{ .default_value_ptr = &gpu.SamplerConfig{} },
                    else => .{},
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

        pub fn MaterialConfig(Reflected: type) type {
            const vertex_entries: []const gpu.VertexEntryMeta = Reflected.VS orelse &.{};
            const fragment_entries: []const []const u8 = Reflected.FS orelse &.{};
            if (vertex_entries.len == 0) @compileError(Reflected.NAME ++ ": shader has no vertex entry point");

            var vertex_names: [vertex_entries.len][]const u8 = undefined;
            var vertex_values: [vertex_entries.len]u32 = undefined;
            for (vertex_entries, &vertex_names, &vertex_values, 0..) |entry, *name, *value, i| {
                name.* = entry.fn_name;
                value.* = i;
            }
            var fragment_values: [fragment_entries.len]u32 = undefined;
            for (&fragment_values, 0..) |*value, i| value.* = i;

            const VertexEntry = @Enum(u32, .exhaustive, &vertex_names, &vertex_values);
            const FragmentEntry = @Enum(u32, .exhaustive, fragment_entries, &fragment_values);

            const vertex_attrs: std.builtin.Type.StructField.Attributes = if (vertex_entries.len == 1)
                .{ .default_value_ptr = @ptrCast(&@as(VertexEntry, @enumFromInt(0))) }
            else
                .{};
            const fragment_attrs: std.builtin.Type.StructField.Attributes = switch (fragment_entries.len) {
                0 => .{ .default_value_ptr = @ptrCast(&@as(?FragmentEntry, null)) },
                1 => .{ .default_value_ptr = @ptrCast(&@as(?FragmentEntry, @enumFromInt(0))) },
                else => .{},
            };

            return @Struct(
                .auto,
                null,
                &.{ "render_state", "vertex", "fragment" },
                &.{ gpu.MaterialRenderState, VertexEntry, ?FragmentEntry },
                &.{
                    .{ .default_value_ptr = @ptrCast(&gpu.MaterialRenderState{}) },
                    vertex_attrs,
                    fragment_attrs,
                },
            );
        }

        pub const MaterialTexture = struct {
            tex: gpu.Texture,
            view_config: gpu.Texture.ViewConfig = .{},
        };

        pub const MeshData = struct {
            streams: []const Stream,
            indices: ?[]const u32 = null,
            vertex_count: u32,

            pub const Stream = struct {
                layout: StreamLayout,
                data: []const u8,
            };
        };

        pub fn mesh(self: *Self, allocator: std.mem.Allocator, mesh_data: MeshData) !MeshID {
            const canon_layouts = config.geometry_pool.layouts;

            for (mesh_data.streams) |stream| {
                std.debug.assert(stream.data.len >= stream.layout.stride * mesh_data.vertex_count);
            }

            var canon_bytes: [canon_layouts.len][]u8 = undefined;
            var allocated_count: usize = 0;
            defer for (canon_bytes[0..allocated_count]) |bytes| allocator.free(bytes);
            var canon_streams: [canon_layouts.len]MeshData.Stream = undefined;
            inline for (canon_layouts, 0..) |layout, i| {
                canon_bytes[i] = try allocator.alloc(u8, layout.stride * mesh_data.vertex_count);
                allocated_count += 1;
                canon_streams[i] = .{ .layout = layout, .data = canon_bytes[i] };
            }

            const canon_mesh_data: MeshData = .{
                .streams = &canon_streams,
                .indices = mesh_data.indices,
                .vertex_count = mesh_data.vertex_count,
            };

            var source_info: std.ArrayList(?struct {
                src_stream_index: usize,
                src_offset: u32,
                src_format: gpu.VertexFormat,
            }) = .empty;
            defer source_info.deinit(allocator);

            inline for (canon_layouts) |can_layout| {
                for (can_layout.attributes) |can_attr| {
                    var missing = true;
                    for (mesh_data.streams, 0..) |src_stream, i| {
                        for (src_stream.layout.attributes) |src_attr| {
                            if (std.mem.eql(u8, can_attr.name, src_attr.name)) {
                                std.debug.assert(missing);
                                missing = false;
                                try source_info.append(allocator, .{
                                    .src_stream_index = i,
                                    .src_offset = src_attr.offset,
                                    .src_format = src_attr.format,
                                });
                            }
                        }
                    }
                    if (missing) {
                        std.debug.panic("No defaults in the current version", .{});
                    }
                }
            }

            var info_index: usize = 0;
            inline for (canon_layouts, 0..) |can_layout, i| {
                const can_bytes = canon_bytes[i];
                for (can_layout.attributes) |can_attr| {
                    const src_attr_info = source_info.items[info_index].?;
                    const should_transform = src_attr_info.src_format != can_attr.format;
                    var src_base: usize = 0;
                    var can_base: usize = 0;
                    const src_stream = mesh_data.streams[src_attr_info.src_stream_index];
                    const src_stride = src_stream.layout.stride;
                    const can_stride = can_layout.stride;
                    const src_attr_size: usize = @intCast(src_attr_info.src_format.byteSize());
                    const can_attr_size: usize = @intCast(can_attr.format.byteSize());
                    for (0..mesh_data.vertex_count) |_| {
                        if (should_transform) {
                            can_attr.format.encode(
                                src_attr_info.src_format.decode(src_stream.data[src_base + src_attr_info.src_offset ..][0..src_attr_size]),
                                can_bytes[can_base + can_attr.offset ..][0..can_attr_size],
                            );
                        } else {
                            @memcpy(
                                can_bytes[can_base + can_attr.offset ..][0..can_attr_size],
                                src_stream.data[src_base + src_attr_info.src_offset ..][0..src_attr_size],
                            );
                        }
                        can_base += can_stride;
                        src_base += src_stride;
                    }
                    info_index += 1;
                }
            }

            return try self.geometry_pool.append(allocator, canon_mesh_data);
        }

        pub fn material(self: *Self, allocator: std.mem.Allocator, Reflected: type, params: MaterialParams(Reflected), material_config: MaterialConfig(Reflected)) !Material(Reflected) {
            const Shader = gpu.Shader(Reflected);
            const FragmentEntry = @typeInfo(@FieldType(MaterialConfig(Reflected), "fragment")).optional.child;
            const fragment_entry: ?[]const u8 = if (comptime @typeInfo(FragmentEntry).@"enum".fields.len == 0)
                null
            else if (material_config.fragment) |entry|
                @tagName(entry)
            else
                null;
            const shader_id = try self.getOrCreateShader(allocator, Reflected, @tagName(material_config.vertex), fragment_entry);
            const render_state_id = try self.getOrCreateRenderState(allocator, material_config.render_state);
            var resources: Shader.Resources(1) = undefined;
            const uniform_count = if (Reflected.Uniforms[1]) |bg| bg.len else 0;
            // TODO: no need for one buffer per binding
            var uniforms = try allocator.alloc(gpu.BindGroupEntry.BufferEntry, uniform_count);
            if (Reflected.Uniforms[1]) |elements| {
                inline for (elements, 0..) |el, i| {
                    const data = @field(params, el.name);
                    const size = @sizeOf(@TypeOf(data));
                    const buffer = try gpu.createBuffer(
                        self.gpu_context,
                        size,
                        .{ .copy_dst = true, .uniform = true },
                        .{ .label = el.name },
                    );
                    gpu.writeBuffer(self.gpu_context, buffer, 0, std.mem.asBytes(&data));
                    const buffer_entry = gpu.BindGroupEntry.BufferEntry{ .buffer = buffer, .size = size };
                    @field(resources, el.name) = buffer_entry;
                    uniforms[i] = buffer_entry;
                }
            }
            if (Reflected.Resources[1]) |elements| {
                inline for (elements) |el| {
                    const data = @field(params, el.name);
                    switch (el.resource_type) {
                        .texture => @field(resources, el.name) = data.tex.createView(data.view_config),
                        .sampler => @field(resources, el.name) = gpu.createSampler(self.gpu_context, data),
                        .storage => @field(resources, el.name) = data,
                    }
                }
            }
            defer if (Reflected.Resources[1]) |elements| {
                inline for (elements) |el| {
                    switch (el.resource_type) {
                        .texture => c.wgpuTextureViewRelease(@field(resources, el.name)),
                        .sampler => c.wgpuSamplerRelease(@field(resources, el.name)),
                        .storage => {},
                    }
                }
            };
            const bind_group = try gpu.ShaderBindGroup(Reflected, 1).create(
                allocator,
                self.gpu_context,
                self.modules.items[@intFromEnum(self.shaders.items[@intFromEnum(shader_id)].module_id)].group_layouts[1],
                resources,
            );
            const material_record: MaterialRecord = .{
                .shader_id = shader_id,
                .render_state_id = render_state_id,
                .bind_group = bind_group,
                .uniforms = uniforms,
            };
            try self.materials.append(allocator, material_record);
            const material_id = self.materials.items.len - 1;
            return .{
                .material_id = @enumFromInt(material_id),
                .shader_program_id = shader_id,
            };
        }

        pub fn Material(S: type) type {
            const IT: type = comptime blk: {
                for (S.Resources, 0..) |group, group_index| {
                    if (group == null) continue;
                    for (group.?) |r| {
                        if (std.mem.eql(u8, r.name, "instances")) {
                            if (group_index != 2) @compileError("instances must be declared in group 2");
                            if (r.binding != 0) @compileError("instances must be declared at binding 0");
                            if (r.resource_type != .storage) @compileError("instances must be defined as a storage array");
                            if (r.resource_type.storage != .array) @compileError("instances must be defined as a storage array");
                            break :blk r.resource_type.storage.array;
                        }
                    }
                }
                @compileError("Shader has no instances array which is required");
            };

            comptime {
                var found_world = false;
                for (S.Uniforms, 0..) |group, group_index| {
                    if (group == null) continue;
                    for (group.?) |u| {
                        if (std.mem.eql(u8, u.name, "plugins")) {
                            if (group_index != 0) @compileError("plugins must be declared in group 0");
                            if (u.binding != 1) @compileError("plugins must be declared at binding 1");
                            if (@typeInfo(u.Type) != .@"struct") @compileError("plugins must be defined as a struct");
                            continue;
                        }
                        if (!std.mem.eql(u8, u.name, "world")) continue;
                        if (group_index != 0) @compileError("world must be declared in group 0");
                        if (u.binding != 0) @compileError("world must be declared at binding 0");
                        if (@typeInfo(u.Type) != .@"struct") @compileError("world must be defined as a struct");
                        if (!@hasField(u.Type, "vp_matrix")) @compileError("world must have a vp_matrix field");
                        if (@FieldType(u.Type, "vp_matrix") != [4][4]f32) @compileError("world.vp_matrix must be defined as mat4x4<f32>");
                        found_world = true;
                    }
                }
                if (S.Resources.len > 0 and S.Resources[0] != null) @compileError("group 0 may only contain uniforms");
                if (S.Resources[2].?.len != 1 or (S.Uniforms.len > 2 and S.Uniforms[2] != null)) @compileError("group 2 may only contain instances");
                if (!found_world) @compileError("Shader has no world uniform which is required");
                for (S.Uniforms[0].?) |u| {
                    if (!std.mem.eql(u8, u.name, "world") and !std.mem.eql(u8, u.name, "plugins")) @compileError("group 0 may only contain world and plugins");
                }
            }

            return struct {
                material_id: MaterialID,
                shader_program_id: ShaderProgramID,

                pub const InstanceType: type = IT;
                pub const Shader = S;
            };
        }

        pub const DrawCmd = struct {
            pass: u8,
            world_offset: u32,
            transparent: bool,
            pipeline: c.WGPURenderPipeline,
            material_id: MaterialID,
            mesh_id: MeshID,
            depth: f32 = 0,
            block_offset: ?u32,

            instance_offset: u32,
            instance_size: u32,

            pub fn lessThan(_: void, a: DrawCmd, b: DrawCmd) bool {
                if (a.pass != b.pass) return a.pass < b.pass;
                if (a.transparent != b.transparent) return !a.transparent;
                if (a.transparent) return a.depth > b.depth;
                if (a.pipeline != b.pipeline) return @as(usize, @intFromPtr(a.pipeline)) < @as(usize, @intFromPtr(b.pipeline));
                if (a.material_id != b.material_id) return @intFromEnum(a.material_id) < @intFromEnum(b.material_id);
                if (a.mesh_id != b.mesh_id) return @as(u32, @bitCast(a.mesh_id)) < @as(u32, @bitCast(b.mesh_id));
                if (a.world_offset != b.world_offset) return a.world_offset < b.world_offset;
                return (a.block_offset orelse 0) < (b.block_offset orelse 0);
            }
        };

        pub const DrawBatch = struct {
            pass: u8,
            pipeline: c.WGPURenderPipeline,
            material_id: MaterialID,
            mesh_id: MeshID,
            first_instance: u32,
            instance_count: u32,
            world_offset: u32,
            block_offset: ?u32,
        };

        pub const Frame = struct {
            renderer: *Self,
            encoder: c.WGPUCommandEncoder,
            surface_texture: gpu.Texture,
            passes: [config.max_pass_count]PassDescriptor,
            pass_count: usize = 0,

            pub fn pass(self: *@This(), allocator: std.mem.Allocator, descriptor: PassDescriptor) !RenderPass {
                const index = self.pass_count;
                const snapshot: u32 = @intCast(self.renderer.pass_snapshots.items.len);
                try self.renderer.pass_snapshots.append(allocator, .{
                    .first_entry = @intCast(self.renderer.pass_value_entries.items.len),
                    .entry_count = 0,
                });
                self.renderer.pass_states[index] = .{
                    .snapshot_index = snapshot,
                    .world_offset = null,
                    .last_module_id = null,
                    .last_snapshot_index = snapshot,
                    .last_block_offset = 0,
                };
                self.passes[index] = descriptor;
                self.pass_count += 1;
                return .{
                    .renderer = self.renderer,
                    .index = @intCast(index),
                    .desc = descriptor,
                };
            }

            pub fn submit(self: @This(), allocator: std.mem.Allocator) !void {
                if (self.renderer.world_uniforms_gpu_capacity < self.renderer.world_uniforms_cpu.items.len) {
                    try self.renderer.growWorldUniformsGpu(allocator, @intCast(self.renderer.world_uniforms_cpu.items.len));
                }
                gpu.writeBuffer(self.renderer.gpu_context, self.renderer.world_uniforms_gpu, 0, self.renderer.world_uniforms_cpu.items);
                std.mem.sort(DrawCmd, self.renderer.draw_commands.items, {}, DrawCmd.lessThan);
                var active_batch: *DrawBatch = undefined;
                for (self.renderer.draw_commands.items) |cmd| {
                    if (self.renderer.draw_batches.items.len == 0 or
                        active_batch.pass != cmd.pass or
                        active_batch.material_id != cmd.material_id or
                        @intFromPtr(active_batch.pipeline) != @intFromPtr(cmd.pipeline) or
                        active_batch.mesh_id != cmd.mesh_id or
                        active_batch.world_offset != cmd.world_offset or
                        active_batch.block_offset != cmd.block_offset)
                    {
                        const first_instance = try std.math.divCeil(u32, @intCast(self.renderer.sorted_instances_cpu.items.len), cmd.instance_size);
                        try self.renderer.draw_batches.append(allocator, .{
                            .first_instance = first_instance,
                            .instance_count = 0,
                            .pipeline = cmd.pipeline,
                            .material_id = cmd.material_id,
                            .mesh_id = cmd.mesh_id,
                            .pass = cmd.pass,
                            .world_offset = cmd.world_offset,
                            .block_offset = cmd.block_offset,
                        });
                        active_batch = &self.renderer.draw_batches.items[self.renderer.draw_batches.items.len - 1];
                        const diff = first_instance * cmd.instance_size - self.renderer.sorted_instances_cpu.items.len;
                        try self.renderer.sorted_instances_cpu.appendNTimes(allocator, 0, diff);
                    }
                    active_batch.instance_count += 1;
                    try self.renderer.sorted_instances_cpu.appendSlice(allocator, self.renderer.instances_cpu.items[cmd.instance_offset..][0..cmd.instance_size]);
                }
                if (self.renderer.instances_gpu_capacity < self.renderer.sorted_instances_cpu.items.len) {
                    try self.renderer.growInstancesGpu(allocator, @intCast(self.renderer.sorted_instances_cpu.items.len));
                }
                gpu.writeBuffer(self.renderer.gpu_context, self.renderer.instances_gpu, 0, self.renderer.sorted_instances_cpu.items);
                var dynamic_offsets = [2]u32{ 0, 0 };
                const surface_view = self.surface_texture.createView(.{ .label = "surface view" });
                defer c.wgpuTextureViewRelease(surface_view);
                var batch_index: usize = 0;
                for (self.passes[0..self.pass_count], 0..) |pass_desc, pass_index| {
                    var offline_color_view: c.WGPUTextureView = null;
                    var offline_resolve_view: c.WGPUTextureView = null;
                    var offline_depth_view: c.WGPUTextureView = null;
                    defer if (offline_color_view) |v| c.wgpuTextureViewRelease(v);
                    defer if (offline_resolve_view) |v| c.wgpuTextureViewRelease(v);
                    defer if (offline_depth_view) |v| c.wgpuTextureViewRelease(v);

                    var desc = gpu.z_WGPU_RENDER_PASS_DESCRIPTOR_INIT();
                    desc.label = gpu.toWGPUString(pass_desc.label);

                    var color_attachment = gpu.z_WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT();
                    if (pass_desc.color_attachment) |ca| {
                        switch (ca.target) {
                            .surface => {
                                if (self.renderer.surface_targets.msaa_color_view) |msaa_view| {
                                    color_attachment.view = msaa_view;
                                    color_attachment.resolveTarget = surface_view;
                                } else {
                                    color_attachment.view = surface_view;
                                }
                            },
                            .offline_target => |t| {
                                offline_color_view = t.color.createView(.{ .label = "offline color view" });
                                color_attachment.view = offline_color_view;
                                if (t.resolve_to) |r| {
                                    offline_resolve_view = r.createView(.{ .label = "offline resolve view" });
                                    color_attachment.resolveTarget = offline_resolve_view;
                                }
                            },
                        }
                        color_attachment.loadOp = @intFromEnum(ca.load_op);
                        color_attachment.storeOp = @intFromEnum(ca.store_op);
                        color_attachment.clearValue = .{
                            .r = ca.clear_value.r,
                            .g = ca.clear_value.g,
                            .b = ca.clear_value.b,
                            .a = ca.clear_value.a,
                        };
                        desc.colorAttachmentCount = 1;
                        desc.colorAttachments = &color_attachment;
                    }

                    var depth_attachment = gpu.z_WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT();
                    if (pass_desc.depth_stencil_attachment) |da| {
                        depth_attachment.view = switch (da.target) {
                            .surface_depth => self.renderer.surface_targets.depth_view,
                            .texture => |t| blk: {
                                offline_depth_view = t.createView(.{ .label = "offline depth view" });
                                break :blk offline_depth_view;
                            },
                        };
                        depth_attachment.depthLoadOp = @intFromEnum(da.depth_load_op);
                        depth_attachment.depthStoreOp = @intFromEnum(da.depth_store_op);
                        depth_attachment.depthClearValue = da.depth_clear_value;
                        desc.depthStencilAttachment = &depth_attachment;
                    }

                    const render_pass = c.wgpuCommandEncoderBeginRenderPass(self.encoder, &desc);
                    defer c.wgpuRenderPassEncoderRelease(render_pass);
                    c.wgpuRenderPassEncoderSetBindGroup(render_pass, 2, self.renderer.instances_bind_group, 0, null);

                    while (batch_index < self.renderer.draw_batches.items.len and
                        self.renderer.draw_batches.items[batch_index].pass == pass_index) : (batch_index += 1)
                    {
                        const batch = self.renderer.draw_batches.items[batch_index];
                        const mat = self.renderer.materials.items[@intFromEnum(batch.material_id)];
                        const shader = self.renderer.shaders.items[@intFromEnum(mat.shader_id)];
                        const module = self.renderer.modules.items[@intFromEnum(shader.module_id)];
                        dynamic_offsets[0] = batch.world_offset;
                        if (batch.block_offset) |bo| dynamic_offsets[1] = bo;
                        c.wgpuRenderPassEncoderSetPipeline(render_pass, batch.pipeline);
                        c.wgpuRenderPassEncoderSetBindGroup(render_pass, 0, module.world_bind_group, if (batch.block_offset == null) 1 else 2, &dynamic_offsets);
                        c.wgpuRenderPassEncoderSetBindGroup(render_pass, 1, mat.bind_group, 0, null);
                        const location = self.renderer.geometry_pool.get(batch.mesh_id).?;
                        const page = self.renderer.geometry_pool.pages.items[location.page_index];
                        inline for (config.geometry_pool.layouts, 0..) |layout, slot| {
                            c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, slot, page.data[slot], 0, layout.stride * config.geometry_pool.page_capacity);
                        }
                        if (location.indices) |ind| {
                            const chunk = self.renderer.geometry_pool.index_chunks.items[ind.chunk_index];
                            c.wgpuRenderPassEncoderSetIndexBuffer(render_pass, chunk.buffer, c.WGPUIndexFormat_Uint32, 0, config.geometry_pool.index_chunk_capacity * @sizeOf(u32));
                            c.wgpuRenderPassEncoderDrawIndexed(render_pass, ind.index_count, batch.instance_count, ind.base_index, @intCast(location.base_vertex), batch.first_instance);
                        } else {
                            c.wgpuRenderPassEncoderDraw(render_pass, location.vertex_count, batch.instance_count, location.base_vertex, batch.first_instance);
                        }
                    }

                    c.wgpuRenderPassEncoderEnd(render_pass);
                }

                const command_buffer = gpu.finishEncoder(self.encoder);
                self.renderer.gpu_context.submitCommands(&.{command_buffer});
                try self.renderer.surface_targets.surface.present();
            }

            pub fn deinit(self: *@This()) void {
                c.wgpuCommandEncoderRelease(self.encoder);
                self.surface_texture.deinit();
                self.* = undefined;
            }
        };

        const RenderPass = struct {
            renderer: *Self,
            index: u8,
            desc: PassDescriptor,

            pub fn setCamera(self: @This(), allocator: std.mem.Allocator, camera: Camera) !void {
                const slot = try self.renderer.stageWorldUniforms(allocator, @sizeOf(World));
                const width, const height = blk: {
                    if (self.desc.color_attachment) |ca| {
                        break :blk switch (ca.target) {
                            .offline_target => |t| .{ t.color.width, t.color.height },
                            .surface => .{ self.renderer.surface_targets.surface.width, self.renderer.surface_targets.surface.height },
                        };
                    }
                    break :blk switch (self.desc.depth_stencil_attachment.?.target) {
                        .surface_depth => .{ self.renderer.surface_targets.depth.?.width, self.renderer.surface_targets.depth.?.height },
                        .texture => |t| .{ t.width, t.height },
                    };
                };
                const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                const vp_matrix = camera.toVP(aspect);
                @memcpy(slot.bytes, std.mem.asBytes(&World{ .vp_matrix = vp_matrix.toArray() }));
                self.renderer.pass_states[self.index].world_offset = slot.offset;
            }

            pub fn set(self: *@This(), allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
                const name_hash = nameHash(name);
                const state = self.renderer.pass_states[self.index];
                const snapshot = self.renderer.pass_snapshots.items[state];
                const pass_values_old_size = self.renderer.pass_values.items.len;
                const pass_value_entries_old_size = self.renderer.pass_value_entries.items.len;
                try self.renderer.pass_value_entries.ensureUnusedCapacity(allocator, snapshot.entry_count + 1);
                try self.renderer.pass_values.appendSlice(allocator, std.mem.asBytes(&value));
                const fingerprint = layoutFingerprint(@TypeOf(value));
                try self.renderer.pass_value_entries.appendSlice(allocator, self.renderer.pass_value_entries.items[snapshot.first_entry..][0..snapshot.entry_count]);
                for (self.renderer.pass_value_entries.items[snapshot.first_entry..][0..snapshot.entry_count], 0..) |entry, i| {
                    if (entry.name_hash == name_hash) {
                        std.debug.assert(entry.fingerprint == fingerprint);
                        self.renderer.pass_value_entries.items[pass_value_entries_old_size + i].offset = pass_values_old_size;
                        try self.renderer.pass_snapshots.append(allocator, .{
                            .first_entry = pass_value_entries_old_size,
                            .entry_coutn = snapshot.entry_count,
                        });
                        self.renderer.pass_states[self.index].snapshot_index = self.renderer.pass_snapshots.items.len - 1;
                        return;
                    }
                }
                try self.renderer.pass_value_entries.append(allocator, .{
                    .fingerprint = fingerprint,
                    .name_hash = name_hash,
                    .size = @sizeOf(value),
                    .offset = pass_values_old_size,
                });
                try self.renderer.pass_snapshots.append(allocator, .{
                    .first_entry = pass_value_entries_old_size,
                    .entry_coutn = snapshot.entry_count + 1,
                });
                self.renderer.pass_states[self.index].snapshot_index = self.renderer.pass_snapshots.items.len - 1;
            }

            pub fn draw(
                self: @This(),
                allocator: std.mem.Allocator,
                mesh_id: MeshID,
                mat: anytype,
                params: DrawParams(@TypeOf(mat).InstanceType),
            ) !void {
                const material_record = self.renderer.materials.items[@intFromEnum(mat.material_id)];
                const module_id = self.renderer.shaders.items[@intFromEnum(material_record.shader_id)].module_id;
                const render_state = self.renderer.render_states.items[@intFromEnum(material_record.render_state_id)];
                const pipeline = try self.renderer.getOrCreatePipeline(allocator, .{
                    .pipeline_pass_state = self.renderer.resolvePipelinePassState(self.desc),
                    .shader_program_id = mat.shader_program_id,
                    .render_state_id = material_record.render_state_id,
                });
                const state = &self.renderer.pass_states[self.index];
                const world_offset = state.world_offset orelse return error.MissingCamera;
                const depth = blk: {
                    if (comptime @hasField(@TypeOf(params), "position")) {
                        const world: World = @bitCast(self.renderer.world_uniforms_cpu.items[world_offset..][0..@sizeOf(World)].*);
                        const view_proj: l.Mat4x4(f32) = @bitCast(world.vp_matrix);
                        break :blk view_proj.mulVec(.init(params.position[0], params.position[1], params.position[2], 1)).z;
                    }
                    break :blk 0;
                };
                const block_offset: ?u32 = blk: {
                    const Plugins = comptime pluginsType(@TypeOf(mat).Shader) orelse break :blk null;
                    if (state.last_module_id != null and state.last_module_id.? == module_id and state.last_snapshot_index == state.snapshot_index) {
                        break :blk state.last_block_offset;
                    }
                    if (self.renderer.pass_blocks.get(.{ .module_id = module_id, .snapshot_index = state.snapshot_index })) |block_offset| {
                        break :blk block_offset;
                    }
                    const block_fields = std.meta.fields(Plugins);
                    var group0_size = 0;
                    inline for (block_fields) |field| {
                        group0_size += @sizeOf(field.type);
                    }
                    const slots = try self.renderer.stageWorldUniforms(allocator, group0_size);
                    var slot_offset = 0;
                    const snapshot = self.renderer.pass_snapshots.items[state.snapshot_index];
                    inline for (block_fields) |field| {
                        comptime if (std.mem.startsWith(u8, field.name, "pad_")) continue;
                        var found = false;
                        for (self.renderer.pass_value_entries.items[snapshot.first_entry..][0..snapshot.entry_count]) |entry| {
                            if (nameHash(field.name) == entry.name_hash) {
                                std.debug.assert(layoutFingerprint(field.type) == entry.fingerprint);
                                @memcpy(slots.bytes[slot_offset..][0..entry.size], self.renderer.pass_values.items[entry.offset..][0..entry.size]);
                                slot_offset += @sizeOf(field.type);
                                found = true;
                                break;
                            }
                        }
                        if (!found) return error.MissingBlockValue;
                    }
                    try self.renderer.pass_blocks.put(
                        allocator,
                        .{ .module_id = module_id, .snapshot_index = state.snapshot_index },
                        slots.offset,
                    );
                    break :blk slots.offset;
                };
                if (block_offset) |bo| {
                    state.last_block_offset = bo;
                    state.last_module_id = module_id;
                    state.last_snapshot_index = state.snapshot_index;
                }
                const InstanceType: type = @TypeOf(mat).InstanceType;
                try self.renderer.draw_commands.append(allocator, .{
                    .block_offset = block_offset,
                    .pass = self.index,
                    .world_offset = world_offset,
                    .material_id = mat.material_id,
                    .mesh_id = mesh_id,
                    .transparent = render_state.blend_state != null,
                    .pipeline = pipeline,
                    .depth = depth,
                    .instance_offset = @intCast(self.renderer.instances_cpu.items.len),
                    .instance_size = @sizeOf(InstanceType),
                });
                var instances: InstanceType = undefined;
                inline for (std.meta.fields(InstanceType)) |field| {
                    if (comptime std.mem.eql(u8, field.name, "model")) {
                        const pos = l.Vec3(f32).fromArray(@field(params, "position"));
                        const scale = l.Vec3(f32).fromArray(@field(params, "scale"));
                        const rot = l.Vec3(f32).fromArray(@field(params, "rotation"));
                        const model_mat = l.Mat4x4(f32).translation(pos).mul(.euler(rot)).mul(.scale(scale));
                        @field(instances, "model") = model_mat.toArray();
                        continue;
                    }
                    @field(instances, field.name) = @field(params, field.name);
                }
                try self.renderer.instances_cpu.appendSlice(allocator, std.mem.asBytes(&instances));
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

        pub fn resolvePipelinePassState(self: *const Self, desc: PassDescriptor) PassPipelineState {
            var state = PassPipelineState{};
            if (desc.color_attachment) |ca| switch (ca.target) {
                .surface => {
                    state.color_format = self.surface_targets.surface.format;
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

        pub const PipelineKey = struct {
            shader_program_id: ShaderProgramID,
            render_state_id: RenderStateID,
            pipeline_pass_state: PassPipelineState,
        };

        pub fn getOrCreatePipeline(self: *Self, allocator: std.mem.Allocator, key: PipelineKey) !c.WGPURenderPipeline {
            if (self.pipelines.get(key)) |pipeline| return pipeline;
            const program = self.shaders.items[@intFromEnum(key.shader_program_id)];
            const module = self.modules.items[@intFromEnum(program.module_id)];
            const render_state = self.render_states.items[@intFromEnum(key.render_state_id)];
            var vertex_layouts: [config.geometry_pool.layouts.len]gpu.VertexBufferLayout = undefined;
            const total_attribute_count = comptime blk: {
                var total = 0;
                for (config.geometry_pool.layouts) |layout| {
                    total += layout.attributes.len;
                }
                break :blk total;
            };
            var attributes: [total_attribute_count]gpu.VertexBufferLayout.VertexAttribute = undefined;
            var attr_index: usize = 0;
            var match_count: usize = 0;
            const vs = blk: {
                for (module.vs) |vs| {
                    if (std.mem.eql(u8, vs.fn_name, program.vertex_entry)) break :blk vs;
                }
                return error.UnknownVertexShaderEntry;
            };
            for (config.geometry_pool.layouts, 0..) |layout, i| {
                const attr_start = attr_index;
                for (layout.attributes) |attr| {
                    for (vs.params) |par| {
                        if (std.mem.eql(u8, par.name, attr.name)) {
                            attributes[attr_index] = .{
                                .format = attr.format,
                                .offset = attr.offset,
                                .shader_location = par.location,
                            };
                            attr_index += 1;
                            match_count += 1;
                            break;
                        }
                    }
                }
                vertex_layouts[i] = .{
                    .step_mode = .vertex,
                    .array_stride = layout.stride,
                    .attributes = attributes[attr_start..attr_index],
                };
            }
            if (match_count != vs.params.len) return error.MissingVertexParameter;
            const pipeline = try gpu.createPipeline(
                allocator,
                self.gpu_context,
                "render pipeline",
                .{
                    .shader_module = module.module,
                    .vertex_layouts = &vertex_layouts,
                    .blend = render_state.blend_state,
                    .cull_mode = render_state.cull_mode,
                    .depth_stencil = render_state.depth_stencil_state,
                    .depth_format = key.pipeline_pass_state.depth_format,
                    .color_format = key.pipeline_pass_state.color_format,
                    .sample_count = key.pipeline_pass_state.sample_count,
                    .primitive_topology = .triangle_list,
                },
                program.vertex_entry,
                program.fragment_entry,
                module.group_layouts,
            );
            try self.pipelines.put(allocator, key, pipeline);
            return pipeline;
        }
    };
}

pub const Camera = struct {
    pos: l.Vec3(f32) = .splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    projection: Projection = .{ .perspective = .{} },
    near: f32 = 0.01,
    far: f32 = 100,

    pub const Projection = union(enum) {
        perspective: struct { fov_y: f32 = std.math.degreesToRadians(90) },
        orthographic: struct { height: f32 = 10 },
    };

    pub fn forward(self: Camera) l.Vec3(f32) {
        return .init(@cos(self.pitch) * @sin(self.yaw), -@sin(self.pitch), -@cos(self.pitch) * @cos(self.yaw));
    }

    pub fn right(self: Camera) l.Vec3(f32) {
        return .init(@cos(self.yaw), 0, @sin(self.yaw));
    }

    pub fn toVP(self: Camera, aspect: f32) l.Mat4x4(f32) {
        const f = self.forward();
        const view = l.Mat4x4(f32).lookAt(self.pos, self.pos.add(f), self.right().cross(f));
        const proj = switch (self.projection) {
            .perspective => |p| l.Mat4x4(f32).perspective(p.fov_y, aspect, self.near, self.far),
            .orthographic => |o| blk: {
                const half_h = o.height / 2;
                const half_w = half_h * aspect;
                break :blk l.Mat4x4(f32).orthographic(-half_w, half_w, half_h, -half_h, self.near, self.far);
            },
        };
        return proj.mul(view);
    }
};

pub const World = extern struct {
    vp_matrix: [4][4]f32,
};
