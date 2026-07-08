const gpu = @import("../gpu.zig");

pub const layouts: ?[]const []const gpu.BindGroupLayoutEntry = &.{
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 80 } } },
    },
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 32 } } },
        .{ .binding = 1, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .texture = .{ .sample_type = .float, .view_dimension = .@"2d", .multi_sampled = false } } },
        .{ .binding = 2, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .sampler = .filtering } },
    },
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .read_only_storage, .has_dynamic_offset = false, .min_binding_size = 0 } } },
    },
};

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
