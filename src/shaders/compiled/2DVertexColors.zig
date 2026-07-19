const gpu = @import("../../gpu.zig");

pub const VS: []const u8 = "vs";
pub const FS: []const u8 = "fs";

pub const vertex_meta: []const gpu.VertexInputMeta = &.{
    .{ .sem_meaning = .position, .location = 0 },
    .{ .sem_meaning = .color, .location = 1 },
};

pub const Uniforms: []const ?[]const gpu.BindGroupEntryMeta = &.{
    &.{
        .{ .binding = 0, .Type = f32, .name = "time" },
    },
};

pub const Resources: []const ?[]const gpu.BindGroupEntryMeta = &.{
    null,
};

pub const layouts: []const ?[]const gpu.BindGroupLayoutEntry = &.{
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 0 } } },
    },
};

pub const NAME: []const u8 = "2DVertexColors";
pub const SOURCE: []const u8 = @embedFile("../2DVertexColors.wgsl");
