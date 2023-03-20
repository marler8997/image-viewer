const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_windows = target.getOs().tag == .windows;
    const enable_x11_backend = blk: {
        if (b.option(bool, "x11", "enable the x11 backend")) |opt| break :blk opt;
        break :blk true;
    };

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_x11_backend", enable_x11_backend);

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    //const exe = b.addExecutable("image-viewer", if (is_windows) "win32main.zig" else "main.zig");
    const exe = b.addExecutable(.{
        .name = "image-viewer",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addOptions("build_options", build_options);

    exe.addModule("img", zigimg_dep.module("zigimg"));
    if (enable_x11_backend) {
        const zigx_dep = b.dependency("zigx", .{});
        exe.addModule("x", zigx_dep.module("zigx"));
    }
    if (is_windows) {
        const zigwin32_dep = b.dependency("zigwin32", .{});
        exe.addModule("win32", zigx_dep.module("zigwin32"));
        exe.subsystem = .Windows;
    }

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
