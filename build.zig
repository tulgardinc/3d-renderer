const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tint_path = b.path("./lib/macos/tint_info").getPath(b);
    const shaders_dir = b.path("./src/shaders/").getPath(b);
    var options = b.addOptions();
    options.addOption([]const u8, "tint_path", tint_path);
    options.addOption([]const u8, "shaders_dir", shaders_dir);

    const tree_sitter = b.addLibrary(.{
        .name = "tree_sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    tree_sitter.root_module.addCSourceFiles(.{
        .files = &.{
            "third_party/tree-sitter/lib/src/lib.c",
            "third_party/tree-sitter-wgsl/parser.c",
            "third_party/tree-sitter-wgsl/scanner.c",
        },
    });
    tree_sitter.root_module.addIncludePath(b.path("third_party/tree-sitter/lib/src"));
    tree_sitter.root_module.addIncludePath(b.path("third_party/tree-sitter/lib/include"));
    tree_sitter.root_module.addIncludePath(b.path("include/"));

    const shader_tool = b.addExecutable(.{
        .name = "shader_tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shader-tool.zig"),

            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    shader_tool.root_module.linkLibrary(tree_sitter);
    shader_tool.root_module.addIncludePath(b.path("third_party/tree-sitter/lib/include"));

    // -Ddebug makes the shader tool dump its reflection output to stderr.
    // Off by default so normal builds stay quiet.
    const debug_shaders = b.option(bool, "debug", "Print shader-tool reflection debug output") orelse false;
    const tool_options = b.addOptions();
    tool_options.addOption(bool, "debug", debug_shaders);
    shader_tool.root_module.addOptions("build_options", tool_options);

    b.installArtifact(shader_tool);

    const exe = b.addExecutable(.{
        .name = "renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    exe.root_module.addIncludePath(b.path("include/"));
    exe.root_module.addObjectFile(b.path("lib/macos/libwebgpu_dawn.a"));

    exe.root_module.addFrameworkPath(b.path("lib/sdl3/"));
    exe.root_module.linkFramework("SDL3", .{});

    exe.root_module.addRPath(b.path("zig-out/bin/"));

    exe.root_module.addCSourceFile(.{ .file = b.path("c/sdl3webgpu.m") });
    exe.root_module.addCSourceFile(.{ .file = b.path("c/wgpu_init_shim.c") });

    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("IOSurface", .{});
    exe.root_module.linkFramework("IOKit", .{});

    b.installArtifact(exe);

    // gpu.zig is a shared module so that main.zig AND every generated shader
    // module resolve the SAME `gpu` instance — otherwise gpu.* types from a
    // generated file wouldn't match the ones main.zig uses. It needs its own
    // include/framework paths because gpu.zig @cImports SDL/webgpu headers.
    const gpu_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gpu_mod.addIncludePath(b.path("include/"));
    gpu_mod.addFrameworkPath(b.path("lib/sdl3/"));
    exe.root_module.addImport("gpu", gpu_mod);

    const run_tool_step = b.step("tool", "Run the shader tool");

    const run_tool_cmd = b.addRunArtifact(shader_tool);
    run_tool_step.dependOn(&run_tool_cmd.step);

    if (b.args) |args| {
        run_tool_cmd.addArgs(args);
    }

    const install_fw = b.addInstallDirectory(.{
        .source_dir = b.path("lib/sdl3/SDL3.framework/"),
        .install_dir = .bin,
        .install_subdir = "SDL3.framework",
    });

    const run_step = b.step("run", "Run the app");

    const io = b.graph.io;
    var shaders_handle = b.build_root.handle.openDir(
        io,
        "src/shaders",
        .{ .iterate = true },
    ) catch |err|
        std.debug.panic("failed to open src/shaders: {s}", .{@errorName(err)});
    defer shaders_handle.close(io);

    var shader_it = shaders_handle.iterate();
    while (shader_it.next(io) catch |err|
        std.debug.panic("failed to iterate src/shaders: {s}", .{@errorName(err)})) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wgsl")) continue;

        // dupe now: entry.name is invalidated by the next iteration.
        const stem = b.dupe(entry.name[0 .. entry.name.len - ".wgsl".len]);

        const gen_cmd = b.addRunArtifact(shader_tool);
        gen_cmd.addFileArg(b.path(b.fmt("src/shaders/{s}", .{entry.name})));
        // Tier 1: the tool writes into a cache file Zig manages (not the source
        // tree), which is what makes this Run step cacheable / skippable.
        const out = gen_cmd.addOutputFileArg(b.fmt("{s}.zig", .{stem}));

        // Wrap the generated file in a module that imports the shared gpu, and
        // expose it to the exe under the shader's name: @import("<stem>").
        const shader_mod = b.createModule(.{
            .root_source_file = out,
            .target = target,
            .optimize = optimize,
        });
        shader_mod.addImport("gpu", gpu_mod);
        exe.root_module.addImport(stem, shader_mod);

        // Guarantee every shader is generated even if the exe never imports it
        // (an unused module import wouldn't force the Run on its own).
        exe.step.dependOn(&gen_cmd.step);
    }

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
