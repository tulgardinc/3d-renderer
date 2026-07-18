const gpu = @import("../../gpu.zig");

pub const VS: []const u8 = "vs";
pub const FS: []const u8 = "fs";

pub const Camera = extern struct {
    view_proj: [4][4]f32,
    camera_pos: [3]f32,
    pad_0: [4]u8 = @splat(0),
};

pub const Material = extern struct {
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    pad_0: [8]u8 = @splat(0),
};

pub const Light = extern struct {
    position: [3]f32,
    pad_0: [4]u8 = @splat(0),
    color: [3]f32,
    pad_1: [4]u8 = @splat(0),
};

pub const LightBuffer = extern struct {
    count: u32,
    pad_0: [12]u8 = @splat(0),

    pub const LIGHTS_STRIDE: u32 = 32;
    pub const LIGHTS_OFFSET: u32 = 16;
};

pub const Uniforms: []const ?[]const gpu.BindGroupEntryMeta = &.{
    &.{
        .{ .binding = 0, .Type = Camera, .name = "camera" },
    },
    &.{
        .{ .binding = 0, .Type = Material, .name = "material" },
    },
};

pub const Resources: []const ?[]const gpu.BindGroupEntryMeta = &.{
    null,
    &.{
        .{ .name = "albedo_tex", .binding = 1, .Type = gpu.c.WGPUTextureView },
        .{ .name = "albedo_sampler", .binding = 2, .Type = gpu.c.WGPUSampler },
    },
};

pub const layouts: []const ?[]const gpu.BindingGroupLayoutEntry = &.{
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 80 } } },
    },
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 32 } } },
        .{ .binding = 1, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .texture = .{ .sample_type = .float, .view_dimension = .@"2d", .multi_sampled = false } } },
        .{ .binding = 2, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .sampler = .filtering } },
    },
};
