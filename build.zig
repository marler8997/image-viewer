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

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "d229f93eacdb60316f0350657b0950f113f07e8b",
        .fetch_enabled = true,
    });

    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "15.0.2-preview",
        .sha = "79c0144225dc015a5c0253b5af30356aa6dc6426",
        .fetch_enabled = true,
    });

    const zigimg_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/zigimg/zigimg",
        .branch = null,
        .sha = "6d0f7d71a49b19564cf70f07577670f712cfc353",
        .fetch_enabled = true,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_x11_backend", enable_x11_backend);

    const zigimg = b.addModule("zigimg", .{
        .source_file = .{ .path = b.pathJoin(&.{zigimg_repo.path, "zigimg.zig"}) },
    });
    const zigx = b.addModule("x", .{
        .source_file = .{ .path = b.pathJoin(&.{zigx_repo.path, "x.zig"}), },
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

    exe.step.dependOn(&zigimg_repo.step);
    exe.addModule("img", zigimg);
    if (enable_x11_backend) {
        exe.step.dependOn(&zigx_repo.step);
        exe.addModule("x", zigx);
    }
    if (is_windows) {
        exe.subsystem = .Windows;
        exe.step.dependOn(&zigwin32_repo.step);
        exe.addModule("win32", zigwin32);
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
