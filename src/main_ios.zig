//! iOS root source file. UIKit apps must start through UIApplicationMain, so
//! main here is only a trampoline into SDL_RunApp, which runs it and calls
//! sdlMain back on the main thread once UIKit has an app to render into.
//!
//! `main` is declared callconv(.c): std.start sees that and emits none of its
//! own entry machinery, exporting this function as the C main directly --
//! which is exactly what SDL_main.h's #define main dance would produce for a
//! C source file.
const std = @import("std");
const app = @import("main.zig");

// From SDL_main.h, which the gpu cImport deliberately doesn't include (its
// main-renaming macro must not fire in normal TUs).
const SdlMainFn = fn (argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int;
extern fn SDL_RunApp(
    argc: c_int,
    argv: ?[*:null]?[*:0]u8,
    mainFunction: *const SdlMainFn,
    reserved: ?*anyopaque,
) c_int;

fn sdlMain(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    app.run() catch |err| {
        std.log.err("fatal: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

// `export` emits the actual _main symbol; `pub` + the C calling convention
// are what std.start checks to know it must stand down.
pub export fn main(argc: c_int, argv: ?[*:null]?[*:0]u8) c_int {
    return SDL_RunApp(argc, argv, &sdlMain, null);
}
