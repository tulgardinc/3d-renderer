const std = @import("std");
const gpu = @import("gpu.zig");
const c = gpu.c;
const sys = @import("gpu-system.zig");

gpu_instance: gpu.GPUInstance,
gpu_context: gpu.GPUContext,
pipleine_cache: sys.PipelineCache,
bind_group_cache: sys.BindGroupCache,
bind_group_layout_cache: sys.BindGroupLayoutCache,
asset_manager: sys.AssetManager,
shader_manager: sys.ShaderManager,
meshes: std.ArrayList(Mesh),
surface: gpu.Surface,

const Self = @This();

// TODO: AUTOMATIC SHADER CODEGEN

pub fn initOwning(allocator: std.mem.Allocator, instance: gpu.GPUInstance, surface: c.WGPUSurface) !Self {
    const gpu_context = try gpu.GPUContext.initSync(instance.webgpu_instance, surface);
    const target_surface = gpu.Surface.init(surface, gpu_context.adapter);
    const resources = try sys.ResourceManager.init(allocator, gpu_context.device, gpu_context.queue);
    const shaders = try sys.ShaderManager.init(allocator, gpu_context.device);
    const bind_group_layout_cache = sys.BindGroupLayoutCache.init(gpu_context.device);
    const bind_group_cache = sys.BindGroupCache.init(gpu_context.device);
    const meshes = std.ArrayList(Mesh).empty;
    const pipelines = sys.PipelineCache.init(
        gpu_context.device,
        surface.format,
        .depth24_plus,
    );

    const renderer: Self = .{
        .gpu_instance = instance,
        .gpu_context = gpu_context,
        .pipleine_cache = pipelines,
        .bind_group_cache = bind_group_cache,
        .bind_group_layout_cache = bind_group_layout_cache,
        .asset_manager = resources,
        .shader_manager = shaders,
        .surface = target_surface,
        .meshes = meshes,
    };

    try renderer.initPrimitiveMeshes(gpu_context.device, gpu_context.queue, allocator);
}

pub fn deinit(self: *Self) void {
    self.gpu_instance.deinit();
    self.gpu_context.deinit();
    self.pipleine_cache.deinit();
    self.bind_group_cache.deinit();
    self.bind_group_layout_cache.deinit();
    self.asset_manager.deinit();
    self.shader_manager.deinit();
    self.surface.deinit();
}

pub const Mesh = struct {
    vertex_buffers: []const sys.VertexBuffer,
    index_buffer: ?c.WGPUBuffer = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.vertex_buffers) |vb| {
            allocator.free(vb.attributes);
            c.wgpuBufferRelease(vb.buffer);
        }
        allocator.free(self.vertex_buffers);
        if (self.index_buffer) |ib| {
            c.wgpuBufferRelease(ib);
        }
    }
};

// Bind group 0, the entire pass
// Bind group 1, material uniforms,
// Bind group 2, object overrides,
pub const Material = struct {
    shader: sys.ShaderHandle,
    uniforms: c.WGPUBuffer,
    bind_group: c.WGPUBindGroup,

    pub fn deinit(self: *@This()) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.uniforms);
    }
};

pub const DrawObject = struct {
    mesh: Mesh,
    material: Material,
    instance_data: c.WGPUBuffer,
};

pub const Primitives = enum {
    square,
};

pub fn initPrimitiveMeshes(
    self: *Self,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    allocator: std.mem.Allocator,
) !void {
    inline for (std.meta.fields(Primitives)) |field| {
        const primitive: Primitives = @enumFromInt(field.vlaue);
        comptime switch (primitive) {
            .square => {
                if (self.meshes.items.getMesh(@intFromEnum(Primitives.square))) |mesh| {
                    return mesh;
                }

                const vertices = [_]f32{
                    -0.5, 0.5,
                    -0.5, -0.5,
                    0.5,  -0.5,
                    0.5,  0.5,
                };
                const vb = try gpu.createBuffer(
                    device,
                    queue,
                    std.mem.sliceAsBytes(&vertices),
                    "cube vertices",
                    gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
                );
                const indices = [_]u32{
                    0, 1, 2,
                    2, 3, 0,
                };
                const ib = try gpu.createBuffer(
                    device,
                    queue,
                    std.mem.sliceAsBytes(&indices),
                    "cube indices",
                    gpu.BufferUsage.copy_dst | gpu.BufferUsage.index,
                );

                const vertex_buffers: []const sys.VertexBuffer = &.{
                    .buffer = vb,
                    .info = .{
                        .array_stride = 0,
                        .attibute_info = .{
                            .format = .f32x2,
                            .offset = @sizeOf(f32) * 2,
                            .attribute_type = .POSITION,
                        },
                    },
                };

                try self.meshes.createMeshOwning(
                    allocator,
                    vertex_buffers,
                    ib,
                );
            },
        };
    }
}
