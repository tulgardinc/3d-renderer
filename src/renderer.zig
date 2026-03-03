const std = @import("std");
const gpu = @import("gpu.zig");
const c = gpu.c;
const sys = @import("gpu-system.zig");

gpu_instance: gpu.GPUInstance,
gpu_context: gpu.GPUContext,
pipleine_cache: sys.PipelineCache,
bind_group_cache: sys.BindGroupCache,
bind_group_layout_cache: sys.BindGroupLayoutCache,
resource_manager: sys.ResourceManager,
shader_manager: sys.ShaderManager,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, instance: gpu.GPUInstance, surface: gpu.Surface) Self {
    const gpu_context = try gpu.GPUContext.initSync(instance.webgpu_instance, surface.surface);
    const resources = try sys.ResourceManager.init(allocator, gpu_context.device, gpu_context.queue);
    const shaders = try sys.ShaderManager.init(allocator, gpu_context.device);
    const bind_group_layout_cache = sys.BindGroupLayoutCache.init(gpu_context.device);
    const bind_group_cache = sys.BindGroupCache.init(gpu_context.device);
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
        .resource_manager = resources,
        .shader_manager = shaders,
    };
}
