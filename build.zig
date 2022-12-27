const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const is_windows = target.getOs().tag == .windows;
    const enable_x11_backend = blk: {
        if (b.option(bool, "x11", "enable the x11 backend")) |opt| break :blk opt;
        break :blk true;
    };

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "a88936ee3125fbfaa85bd4b4983cddfbc32ac4a1",
        .fetch_enabled = true,
    });

    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "15.0.2-preview",
        .sha = "56cf335ddcdb72a6d7059c5b6f131263830b3eca",
        .fetch_enabled = true,
    });

    const zigimg_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/zigimg/zigimg",
        .branch = null,
        .sha = "5e8e5687ce1edd7dd1040c0580ec0731bcfbd793",
        .fetch_enabled = true,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_x11_backend", enable_x11_backend);

    //const exe = b.addExecutable("image-viewer", if (is_windows) "win32main.zig" else "main.zig");
    const exe = b.addExecutable("image-viewer", "main.zig");
    exe.addOptions("build_options", build_options);

    exe.step.dependOn(&zigimg_repo.step);
    exe.addPackagePath("img", b.pathJoin(&.{zigimg_repo.path, "zigimg.zig"}));
    if (enable_x11_backend) {
        exe.step.dependOn(&zigx_repo.step);
        exe.addPackagePath("x", b.pathJoin(&.{zigx_repo.path, "x.zig"}));
    }
    if (is_windows) {
        exe.subsystem = .Windows;
        exe.step.dependOn(&zigwin32_repo.step);
        exe.addPackagePath("win32", b.pathJoin(&.{zigwin32_repo.path, "win32.zig"}));
    }

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
