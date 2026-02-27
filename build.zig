const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tint_path = b.path("./lib/macos/tint_info").getPath(b);
    const shaders_dir = b.path("./src/shaders/").getPath(b);
    var options = b.addOptions();
    options.addOption([]const u8, "tint_path", tint_path);
    options.addOption([]const u8, "shaders_dir", shaders_dir);

    const exe = b.addExecutable(.{
        .name = "renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    exe.linkLibC();
    exe.addIncludePath(b.path("include/"));
    exe.addObjectFile(b.path("lib/macos/libwebgpu_dawn.a"));

    exe.addFrameworkPath(b.path("lib/sdl3/"));
    exe.linkFramework("SDL3");

    exe.addRPath(b.path("zig-out/bin/"));

    exe.addCSourceFile(.{ .file = b.path("c/sdl3webgpu.m") });
    exe.addCSourceFile(.{ .file = b.path("c/wgpu_init_shim.c") });

    exe.linkFramework("Metal");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("Foundation");
    exe.linkFramework("AppKit");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("IOSurface");
    exe.linkFramework("IOKit");

    exe.linkSystemLibrary("c++");

    b.installArtifact(exe);

    const install_fw = b.addInstallDirectory(.{
        .source_dir = b.path("lib/sdl3/SDL3.framework/"),
        .install_dir = .bin,
        .install_subdir = "SDL3.framework",
    });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    b.getInstallStep().dependOn(&install_fw.step);
    run_cmd.step.dependOn(&install_fw.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
