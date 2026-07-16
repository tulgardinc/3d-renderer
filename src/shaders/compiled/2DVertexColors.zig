const gpu = @import("../../gpu.zig");

pub const VS: []const u8 = "vs";
pub const FS: []const u8 = "fs";

pub const Uniforms = extern struct {
    time: f32,
};

pub const layouts: ?[]const []const gpu.BindGroupLayoutEntry = &.{
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 4 } } },
    },
};

pub const binding_descriptors: ?[]const []const gpu.BindingMetadata = &.{
    &.{
        .{ .name = "u", .binding = 0, .Type = Uniforms },
    },
};
