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
mesh_manager: sys.MeshManager,
surface: gpu.Surface,

const Self = @This();

pub fn initOwning(allocator: std.mem.Allocator, instance: gpu.GPUInstance, surface: c.WGPUSurface) Self {
    const gpu_context = try gpu.GPUContext.initSync(instance.webgpu_instance, surface);
    const target_surface = gpu.Surface.init(surface, gpu_context.adapter);
    const resources = try sys.ResourceManager.init(allocator, gpu_context.device, gpu_context.queue);
    const shaders = try sys.ShaderManager.init(allocator, gpu_context.device);
    const bind_group_layout_cache = sys.BindGroupLayoutCache.init(gpu_context.device);
    const bind_group_cache = sys.BindGroupCache.init(gpu_context.device);
    const mesh_manager = sys.MeshManager.init(gpu_context.device, gpu_context.queue);
    const pipelines = sys.PipelineCache.init(
        gpu_context.device,
        surface.format,
        .depth24_plus,
    );

    return .{
        .gpu_instance = instance,
        .gpu_context = gpu_context,
        .pipleine_cache = pipelines,
        .bind_group_cache = bind_group_cache,
        .bind_group_layout_cache = bind_group_layout_cache,
        .asset_manager = resources,
        .shader_manager = shaders,
        .surface = target_surface,
        .mesh_manager = mesh_manager,
    };
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
    mesh: sys.Mesh,
    material: Material,
    instance_data: c.WGPUBuffer,
};
