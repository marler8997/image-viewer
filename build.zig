const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "fc679932c08bd6d957270a9462aec97c8fced01f",
        .fetch_enabled = true,
    });

    const zigimg_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/zigimg/zigimg",
        .branch = null,
        .sha = "5e8e5687ce1edd7dd1040c0580ec0731bcfbd793",
        .fetch_enabled = true,
    });

    const exe = b.addExecutable("image-viewer", "main.zig");
    exe.step.dependOn(&zigimg_repo.step);
    exe.addPackagePath("img", b.pathJoin(&.{zigimg_repo.path, "zigimg.zig"}));
    exe.step.dependOn(&zigx_repo.step);
    exe.addPackagePath("x", b.pathJoin(&.{zigx_repo.path, "x.zig"}));
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
