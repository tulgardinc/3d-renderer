const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A web build is a different shape end to end: Zig emits a static library
    // instead of an executable, emcc links it against the SDL3 + emdawnwebgpu
    // ports, and the WebGPU headers come from the port rather than include/.
    // Everything native is untouched.
    const is_web = target.result.os.tag == .emscripten;

    // iOS is a third shape: linked like native (static SDL3 + Dawn on Metal)
    // but cross-compiled against the iPhone SDK and installed as a flat
    // Renderer.app bundle instead of a bare executable. `-Dtarget=aarch64-ios`
    // is a device build, `-Dtarget=aarch64-ios-simulator` a simulator one.
    const is_ios = target.result.os.tag == .ios;
    const is_ios_sim = is_ios and target.result.abi == .simulator;

    // The vendored Dawn slices are built with a 14.0 floor; if the target
    // query didn't pin a version, pin it to match so the linker doesn't warn
    // about objects newer than the executable.
    if (is_ios and target.query.os_version_min == null) {
        var query = target.query;
        query.os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(query);
    }

    // The shader tool and its tree-sitter parser are *build-time* tools. They
    // have to run on the machine doing the build, so they follow the host, not
    // the target -- otherwise `-Dtarget=wasm32-emscripten` would compile the
    // codegen step to wasm and the build could never invoke it.
    const host = b.graph.host;

    const tint_path = b.path("./lib/macos/tint_info").getPath(b);
    const shaders_dir = b.path("./src/shaders/").getPath(b);
    var options = b.addOptions();
    options.addOption([]const u8, "tint_path", tint_path);
    options.addOption([]const u8, "shaders_dir", shaders_dir);

    // Emscripten SDK layout. The ports must have been fetched once (any emcc
    // invocation with --use-port does it) so their headers exist on disk before
    // Zig compiles anything that @cImports them.
    const emsdk = b.option([]const u8, "emsdk", "Path to the emsdk checkout (web builds only)") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", "emsdk" });
    // em++, not emcc: emdawnwebgpu's bindings layer is C++ and the driver
    // refuses to link it from the C front end.
    const emcc_path = b.pathJoin(&.{ emsdk, "upstream", "emscripten", "em++" });
    const em_cache = b.pathJoin(&.{ emsdk, "upstream", "emscripten", "cache" });
    const em_sysroot_inc = b.pathJoin(&.{ em_cache, "sysroot", "include" });
    const em_webgpu_inc = b.pathJoin(&.{
        em_cache, "ports", "emdawnwebgpu", "emdawnwebgpu_pkg", "webgpu", "include",
    });

    if (is_web) {
        std.Io.Dir.accessAbsolute(b.graph.io, em_webgpu_inc, .{}) catch {
            std.debug.panic(
                \\emdawnwebgpu port headers not found at:
                \\  {s}
                \\Fetch the ports once with:
                \\  emcc --use-port=sdl3 --use-port=emdawnwebgpu -c <any.c> -o /dev/null
                \\or point the build at a different SDK with -Demsdk=<path>.
            , .{em_webgpu_inc});
        };
    }

    // iOS: the SDK comes from Xcode (queried at configure time -- there is one
    // per device/simulator), and the static libs are provisioned into lib/
    // like lib/macos/ is. Simulator and device are distinct architectures to
    // the linker even though both are arm64, hence two lib directories.
    const ios_lib_dir = if (is_ios_sim) "lib/ios-simulator" else "lib/ios";
    const ios_sdk = if (is_ios)
        std.mem.trimEnd(u8, b.run(&.{
            "xcrun",
            "--sdk",
            if (is_ios_sim) "iphonesimulator" else "iphoneos",
            "--show-sdk-path",
        }), "\n")
    else
        "";

    if (is_ios) {
        for ([_][]const u8{ "libwebgpu_dawn.a", "libSDL3.a" }) |lib_name| {
            const lib_path = b.pathJoin(&.{ b.path(ios_lib_dir).getPath(b), lib_name });
            std.Io.Dir.accessAbsolute(b.graph.io, lib_path, .{}) catch {
                std.debug.panic(
                    \\iOS prebuilt library not found at:
                    \\  {s}
                    \\Provision it (full instructions in lib/ios/README.md):
                    \\  libwebgpu_dawn.a -- the {s} slice of google/dawn release
                    \\    v20260828.215121's dawn-apple-<sha>.xcframework.tar.gz
                    \\  libSDL3.a -- SDL3 3.4.14 built static via CMake with
                    \\    -DCMAKE_SYSTEM_NAME=iOS{s}
                , .{
                    lib_path,
                    if (is_ios_sim) "ios-arm64_x86_64-simulator (lipo -thin arm64)" else "ios-arm64",
                    if (is_ios_sim) " -DCMAKE_OSX_SYSROOT=iphonesimulator" else "",
                });
            };
        }
    }

    const tree_sitter = b.addLibrary(.{
        .name = "tree_sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = host,
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

            .target = host,
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

    // The app itself. Native links it into an executable; web wraps it in a
    // static library that emcc links, so the module is created up front and the
    // artifact chosen below.
    const app_mod = b.createModule(.{
        // On iOS the entry point must go through SDL_RunApp/UIApplicationMain,
        // so the root is a thin wrapper whose callconv(.c) main trampolines
        // into SDL_RunApp instead of std.start's usual machinery.
        .root_source_file = b.path(if (is_ios) "src/main_ios.zig" else "src/main.zig"),

        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Dawn is C++; the emdawnwebgpu port brings its own runtime. On iOS
        // Zig's bundled libcxx doesn't compile (mbstate_t detection), so the
        // SDK's libc++.tbd is linked below instead -- the right runtime for
        // the platform anyway.
        .link_libcpp = !is_web and !is_ios,
        // std.debug's Mach-O self-inspection calls a dyld API the iOS SDK
        // doesn't export (__dyld_get_image_header_containing_address), which
        // fails the link. Stripping debug info drops that code path -- at the
        // cost of Zig stack traces on iOS.
        .strip = if (is_ios) true else null,
        // Debug builds sanitize C with a UBSan runtime that only Zig's own
        // linker bundles; Apple clang does the iOS link, so it must be off.
        .sanitize_c = if (is_ios) .off else null,
    });
    app_mod.addOptions("build_options", options);

    // gpu.zig is a shared module so that main.zig AND every generated shader
    // module resolve the SAME `gpu` instance — otherwise gpu.* types from a
    // generated file wouldn't match the ones main.zig uses. It needs its own
    // include/framework paths because gpu.zig @cImports SDL/webgpu headers.
    const gpu_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_ios) true else null,
    });
    app_mod.addImport("gpu", gpu_mod);

    // Both modules @cImport SDL + webgpu, so they must see the identical set of
    // headers -- a disagreement here would mean Zig and the C shims compile
    // against different struct layouts.
    for ([_]*std.Build.Module{ app_mod, gpu_mod }) |mod| {
        if (is_web) {
            // Port headers FIRST. include/ carries a native Dawn header of a
            // different vintage, and whichever -I comes first wins.
            mod.addIncludePath(.{ .cwd_relative = em_webgpu_inc });
            mod.addIncludePath(.{ .cwd_relative = em_sysroot_inc });
        }
        if (is_ios) {
            // The iPhone SDK, spelled out as explicit paths rather than
            // --sysroot: b.sysroot is global to the build graph and would
            // poison the host-targeted shader_tool compile with iOS libc.
            // usr/include carries the ObjC runtime headers, the framework dir
            // serves both #include <UIKit/...> resolution and the linker's
            // .tbd stubs (libSystem comes from usr/lib the same way).
            mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ios_sdk, "usr", "include" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ios_sdk, "usr", "lib" }) });
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ ios_sdk, "System", "Library", "Frameworks" }) });
        }
        // Native: SDL3 + Dawn + sdl3webgpu.h. Web: only sdl3webgpu.h is taken
        // from here, the rest is shadowed by the port paths above.
        mod.addIncludePath(b.path("include/"));
        if (!is_web and !is_ios) mod.addFrameworkPath(b.path("lib/sdl3/"));
    }

    if (is_web) {
        // sdl3webgpu.m is Objective-C for the Metal path only; its emscripten
        // branch is plain C, and emscripten has no Objective-C runtime -- so
        // force the language rather than keeping a second copy of the file.
        app_mod.addCSourceFile(.{
            .file = b.path("c/sdl3webgpu.m"),
            .flags = &.{ "-x", "c" },
        });
        app_mod.addCSourceFile(.{ .file = b.path("c/wgpu_init_shim.c") });
        app_mod.addCSourceFile(.{ .file = b.path("c/web_frame.c") });
    } else if (is_ios) {
        // Compile inputs only. The final link is Apple clang's job (see the
        // iOS branch at the bottom), so the Dawn/SDL archives, frameworks,
        // and libc++ all live on that command line, not on the module.
        //
        // sdl3webgpu.m's iOS branch is real Objective-C (SDL_Metal_CreateView
        // + CAMetalLayer), unlike the plain-C emscripten branch.
        app_mod.addCSourceFile(.{ .file = b.path("c/sdl3webgpu.m") });
        app_mod.addCSourceFile(.{ .file = b.path("c/wgpu_init_shim.c") });
    } else {
        app_mod.addObjectFile(b.path("lib/macos/libwebgpu_dawn.a"));
        app_mod.linkFramework("SDL3", .{});
        app_mod.addRPath(b.path("zig-out/bin/"));

        app_mod.addCSourceFile(.{ .file = b.path("c/sdl3webgpu.m") });
        app_mod.addCSourceFile(.{ .file = b.path("c/wgpu_init_shim.c") });

        app_mod.linkFramework("Metal", .{});
        app_mod.linkFramework("QuartzCore", .{});
        app_mod.linkFramework("Foundation", .{});
        app_mod.linkFramework("AppKit", .{});
        app_mod.linkFramework("CoreGraphics", .{});
        app_mod.linkFramework("IOSurface", .{});
        app_mod.linkFramework("IOKit", .{});
    }

    // The one artifact the shader codegen steps hang off, whichever it is.
    // Web AND iOS produce a static library for an external linker (emcc and
    // Apple clang respectively) -- iOS because Zig's self-hosted Mach-O
    // linker overflows relocations on the 20MB Dawn archive.
    const app_step: *std.Build.Step = blk: {
        if (is_web or is_ios) {
            const lib = b.addLibrary(.{
                .name = "renderer",
                .linkage = .static,
                .root_module = app_mod,
            });
            break :blk &lib.step;
        }
        const exe = b.addExecutable(.{
            .name = "renderer",
            .root_module = app_mod,
        });
        b.installArtifact(exe);
        break :blk &exe.step;
    };

    const run_tool_step = b.step("tool", "Compile all shaders with no args, or one: zig build tool -- <ShaderName>");

    if (b.args) |tool_args| {
        const run_tool_cmd = b.addRunArtifact(shader_tool);
        if (tool_args.len == 1) {
            // Convenience form: resolve src/shaders/<Name>.wgsl, run codegen,
            // then compile the generated module against `gpu` (same as the
            // exe's per-shader step) so this catches Zig-side errors too —
            // not just wgsl parse/reflection errors — without linking the
            // full app (SDL/Dawn/frameworks).
            const stem = std.fs.path.stem(std.fs.path.basename(tool_args[0]));
            run_tool_cmd.addFileArg(b.path(b.fmt("src/shaders/{s}.wgsl", .{stem})));
            const out = run_tool_cmd.addOutputFileArg(b.fmt("{s}.zig", .{stem}));

            const shader_mod = b.createModule(.{
                .root_source_file = out,
                .target = target,
                .optimize = optimize,
            });
            shader_mod.addImport("gpu", gpu_mod);

            const shader_obj = b.addObject(.{
                .name = stem,
                .root_module = shader_mod,
            });
            run_tool_step.dependOn(&shader_obj.step);
        } else {
            // Raw passthrough: zig build tool -- <src> <out>
            run_tool_cmd.addArgs(tool_args);
        }
        run_tool_step.dependOn(&run_tool_cmd.step);
    } else {
        // No args: compile every shader in src/shaders/ so `zig build tool`
        // alone is a full shader-compile check, without touching the app exe.
        const io = b.graph.io;
        var tool_shaders_handle = b.build_root.handle.openDir(
            io,
            "src/shaders",
            .{ .iterate = true },
        ) catch |err|
            std.debug.panic("failed to open src/shaders: {s}", .{@errorName(err)});
        defer tool_shaders_handle.close(io);

        var tool_shader_it = tool_shaders_handle.iterate();
        while (tool_shader_it.next(io) catch |err|
            std.debug.panic("failed to iterate src/shaders: {s}", .{@errorName(err)})) |entry|
        {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wgsl")) continue;

            const stem = entry.name[0 .. entry.name.len - ".wgsl".len];

            const run_tool_cmd = b.addRunArtifact(shader_tool);
            run_tool_cmd.addFileArg(b.path(b.fmt("src/shaders/{s}", .{entry.name})));
            _ = run_tool_cmd.addOutputFileArg(b.fmt("{s}.zig", .{stem}));
            run_tool_step.dependOn(&run_tool_cmd.step);
        }
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

    // Mirrors every generated shader .zig (normally buried in the Zig cache)
    // into src/shaders/compiled-copy/ so the codegen output is readable in-tree.
    // addUpdateSourceFiles is Zig's sanctioned way to write generated files back
    // into the source dir. Note: this dirties git — gitignore compiled-copy/.
    const copy_shaders = b.addUpdateSourceFiles();

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
        // expose it to the app under the shader's name: @import("<stem>").
        const shader_mod = b.createModule(.{
            .root_source_file = out,
            .target = target,
            .optimize = optimize,
        });
        shader_mod.addImport("gpu", gpu_mod);
        app_mod.addImport(stem, shader_mod);

        // Guarantee every shader is generated even if the app never imports it
        // (an unused module import wouldn't force the Run on its own).
        app_step.dependOn(&gen_cmd.step);

        // Drop a readable copy of the generated file into the source tree.
        copy_shaders.addCopyFileToSource(
            out,
            b.fmt("src/shaders/compiled-copy/{s}.zig", .{stem}),
        );
    }

    // `zig build copy-shaders` on its own, and also on every normal build so the
    // in-tree copies never go stale.
    const copy_shaders_step = b.step("copy-shaders", "Copy generated shader .zig into src/shaders/compiled-copy/");
    copy_shaders_step.dependOn(&copy_shaders.step);
    app_step.dependOn(&copy_shaders.step);

    if (is_web) {
        // emcc does the linking: it supplies emscripten's libc, the SDL3 port,
        // and emdawnwebgpu's JS bindings, then runs Binaryen's asyncify pass
        // over the whole module -- which is what makes the blocking spin-waits
        // in gpu.zig legal in a browser.
        const web_out_dir = b.pathJoin(&.{ b.install_path, "web" });
        const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", web_out_dir });

        const emcc = b.addSystemCommand(&.{emcc_path});
        emcc.step.dependOn(&mkdir.step);
        emcc.addArtifactArg(@fieldParentPtr("step", app_step));
        emcc.addArgs(&.{
            "--use-port=sdl3",
            "--use-port=emdawnwebgpu",
            // Asyncify rewrites the wasm so emscripten_sleep can unwind the
            // stack and resume later. The default asyncify stack is 4KB, which
            // is not enough for a call chain this deep.
            "-sASYNCIFY",
            "-sASYNCIFY_STACK_SIZE=65536",
            "-sSTACK_SIZE=4194304",
            "-sALLOW_MEMORY_GROWTH=1",
            // main() never returns while the loop runs; don't tear down after.
            "-sEXIT_RUNTIME=0",
            "-sASSERTIONS=1",
        });
        // Replace emcc's stock demo page (logo, checkboxes, output box) with a
        // bare full-viewport canvas.
        emcc.addArg("--shell-file");
        emcc.addFileArg(b.path("web/shell.html"));
        emcc.addArg("-o");
        emcc.addArg(b.pathJoin(&.{ web_out_dir, "index.html" }));
        // The .js/.wasm siblings emcc emits aren't tracked as step outputs, so
        // this can't be cached on their absence.
        emcc.has_side_effects = true;

        b.getInstallStep().dependOn(&emcc.step);

        // `zig build run -Dtarget=wasm32-emscripten` serves the build: WebGPU
        // and wasm both need a real http origin, file:// won't do.
        const serve = b.addSystemCommand(&.{
            "python3", "-m", "http.server", "8000", "--directory", web_out_dir,
        });
        serve.step.dependOn(&emcc.step);
        run_step.dependOn(&serve.step);
    } else if (is_ios) {
        const lib: *std.Build.Step.Compile = @fieldParentPtr("step", app_step);

        // Apple clang links: it drives ld64, which handles the Dawn archive's
        // relocation ranges, pulls _main out of our static lib, and ad-hoc
        // signs the arm64 output (enough for the simulator).
        const link = b.addSystemCommand(&.{
            "xcrun",
            "--sdk",
            if (is_ios_sim) "iphonesimulator" else "iphoneos",
            "clang",
            "-target",
            if (is_ios_sim) "arm64-apple-ios14.0-simulator" else "arm64-apple-ios14.0",
        });
        link.addArtifactArg(lib);
        link.addFileArg(b.path(b.fmt("{s}/libSDL3.a", .{ios_lib_dir})));
        link.addFileArg(b.path(b.fmt("{s}/libwebgpu_dawn.a", .{ios_lib_dir})));
        // Dawn is C++; Apple's runtime, not Zig's bundled libcxx (which
        // doesn't compile for iOS -- see link_libcpp at the module).
        link.addArg("-lc++");
        // Static SDL3 doesn't carry its dependencies the way the macOS
        // framework does; this list is the Libs line of the iOS build's
        // generated sdl3.pc, verbatim -- plus IOSurface, which Dawn's Metal
        // backend uses for texture sharing.
        for ([_][]const u8{
            "CoreMedia",    "CoreVideo",      "CoreAudio",    "AudioToolbox",
            "AVFoundation", "CoreBluetooth",  "CoreGraphics", "CoreMotion",
            "Foundation",   "GameController", "Metal",        "OpenGLES",
            "QuartzCore",   "UIKit",          "IOSurface",
        }) |framework| {
            link.addArgs(&.{ "-framework", framework });
        }
        link.addArgs(&.{ "-weak_framework", "CoreHaptics" });
        link.addArg("-o");
        const linked_exe = link.addOutputFileArg("renderer");

        // iOS bundles are flat -- no Contents/MacOS, the binary and the plist
        // sit next to each other. UILaunchScreen (even empty) is what opts a
        // storyboard-less app into edge-to-edge fullscreen instead of the
        // legacy letterboxed compatibility mode.
        const plist = b.addWriteFiles().add("Info.plist",
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
            \\  <key>CFBundleExecutable</key><string>renderer</string>
            \\  <key>CFBundleIdentifier</key><string>com.tulgardinc.renderer</string>
            \\  <key>CFBundleName</key><string>Renderer</string>
            \\  <key>CFBundleDisplayName</key><string>Renderer</string>
            \\  <key>CFBundlePackageType</key><string>APPL</string>
            \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            \\  <key>CFBundleVersion</key><string>1</string>
            \\  <key>CFBundleShortVersionString</key><string>0.0.0</string>
            \\  <key>MinimumOSVersion</key><string>14.0</string>
            \\  <key>LSRequiresIPhoneOS</key><true/>
            \\  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
            \\  <key>UILaunchScreen</key><dict/>
            \\  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
            \\  <key>UISupportedInterfaceOrientations</key><array>
            \\    <string>UIInterfaceOrientationPortrait</string>
            \\    <string>UIInterfaceOrientationLandscapeLeft</string>
            \\    <string>UIInterfaceOrientationLandscapeRight</string>
            \\  </array>
            \\</dict>
            \\</plist>
            \\
        );

        const install_exe = b.addInstallFile(linked_exe, "Renderer.app/renderer");
        const install_plist = b.addInstallFile(plist, "Renderer.app/Info.plist");
        b.getInstallStep().dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&install_plist.step);

        // `zig build run -Dtarget=aarch64-ios-simulator` boots a simulator,
        // installs the bundle, and launches it with the console attached.
        // Device installs need a signing identity, so no run step there --
        // see lib/ios/README.md.
        if (is_ios_sim) {
            // Resolve a concrete device UDID at configure time: prefer one
            // that is already booted, else the first available iPhone.
            const device_list = b.run(&.{ "xcrun", "simctl", "list", "devices", "available" });
            const udid = pickSimulatorUdid(device_list) orelse
                std.debug.panic("no available iPhone simulator found in `xcrun simctl list devices available`", .{});

            // bootstatus -b boots the device if needed and blocks until it
            // finishes; open -a Simulator just attaches the UI to it.
            const boot = b.addSystemCommand(&.{ "xcrun", "simctl", "bootstatus", udid, "-b" });
            boot.has_side_effects = true;

            const open_ui = b.addSystemCommand(&.{ "open", "-a", "Simulator" });
            open_ui.has_side_effects = true;
            open_ui.step.dependOn(&boot.step);

            const install_cmd = b.addSystemCommand(&.{ "xcrun", "simctl", "install", udid });
            install_cmd.addArg(b.pathJoin(&.{ b.install_path, "Renderer.app" }));
            install_cmd.has_side_effects = true;
            install_cmd.step.dependOn(b.getInstallStep());
            install_cmd.step.dependOn(&open_ui.step);

            const launch_cmd = b.addSystemCommand(&.{
                "xcrun", "simctl", "launch", "--console", udid, "com.tulgardinc.renderer",
            });
            launch_cmd.has_side_effects = true;
            launch_cmd.step.dependOn(&install_cmd.step);

            run_step.dependOn(&launch_cmd.step);
        }
    } else {
        const exe: *std.Build.Step.Compile = @fieldParentPtr("step", app_step);
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        b.getInstallStep().dependOn(&install_fw.step);
        run_cmd.step.dependOn(&install_fw.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const exe_tests = b.addTest(.{
            .root_module = app_mod,
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_exe_tests.step);
    }
}

/// Picks a simulator UDID from `simctl list devices available` output: a
/// booted device if there is one (any type -- respect what the user has
/// open), else the first available iPhone. Lines look like
///   iPhone 17 Pro (81F738D1-9F2F-4DCB-88B3-957187ABC9B1) (Shutdown)
fn pickSimulatorUdid(list: []const u8) ?[]const u8 {
    var first_iphone: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const open = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, line, open, ')') orelse continue;
        const udid = line[open + 1 .. close];
        // UDIDs are 36-char UUIDs; anything else in parens is a device
        // variant like "(4th generation)".
        if (udid.len != 36) continue;
        if (std.mem.indexOf(u8, line[close..], "(Booted)") != null) return udid;
        if (first_iphone == null and std.mem.indexOf(u8, line, "iPhone") != null)
            first_iphone = udid;
    }
    return first_iphone;
}
