const gpu = @import("../../gpu.zig");

pub const SIMULATE: []const u8 = "simulate";

pub const layouts: ?[]const []const gpu.BindGroupLayoutEntry = &.{
    &.{
        .{ .binding = 0, .visibility = gpu.ShaderStage.compute, .type = .{ .buffer = .{ .type = .read_only_storage, .has_dynamic_offset = false, .min_binding_size = 0 } } },
        .{ .binding = 1, .visibility = gpu.ShaderStage.compute, .type = .{ .buffer = .{ .type = .storage, .has_dynamic_offset = false, .min_binding_size = 0 } } },
        .{ .binding = 2, .visibility = gpu.ShaderStage.compute, .type = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = false, .min_binding_size = 64 } } },
    },
};

pub const PARTICLES_IN_STRIDE: u32 = 48;

pub const Particle = extern struct {
    position: [3]f32,
    pad_0: [4]u8 = @splat(0),
    velocity: [3]f32,
    mass: f32,
    color: [4]f32,
};

pub const ParticleBuffer = extern struct {
    count: u32,
    pad_0: [12]u8 = @splat(0),

    pub const PARTICLES_STRIDE: u32 = 48;
    pub const PARTICLES_OFFSET: u32 = 16;
};

pub const SimParams = extern struct {
    delta_time: f32,
    particle_count: u32,
    pad_0: [8]u8 = @splat(0),
    gravity: [3]f32,
    pad_1: [4]u8 = @splat(0),
    bounds_min: [3]f32,
    pad_2: [4]u8 = @splat(0),
    bounds_max: [3]f32,
    pad_3: [4]u8 = @splat(0),
};
