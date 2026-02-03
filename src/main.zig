const std = @import("std");
const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("SDL3/SDL.h");
});

pub fn main() void {
    // If this compiles + links, your include path + lib are wired.
    _ = c.WGPUInstanceDescriptor{};
    std.debug.print("webgpu header imported OK\n", .{});

    const v = c.SDL_GetVersion();
    const major = c.SDL_VERSIONNUM_MAJOR(v);
    const minor = c.SDL_VERSIONNUM_MINOR(v);
    const patch = c.SDL_VERSIONNUM_MICRO(v);

    std.debug.print("SDL version: {d}.{d}.{d}\n", .{ major, minor, patch });
}
