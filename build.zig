const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_windows = target.getOs().tag == .windows;
    const enable_x11_backend = blk: {
        if (b.option(bool, "x11", "enable the x11 backend")) |opt| break :blk opt;
        break :blk true;
    };

    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "15.0.2-preview",
        .sha = "007649ade45ffb544de3aafbb112de25064d3d92",
        .fetch_enabled = true,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_x11_backend", enable_x11_backend);

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const zigwin32 = b.addModule("win32", .{
        .source_file = .{ .path = b.pathJoin(&.{zigwin32_repo.path, "win32.zig"}), },
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
        exe.subsystem = .Windows;
        exe.step.dependOn(&zigwin32_repo.step);
        exe.addModule("win32", zigwin32);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
