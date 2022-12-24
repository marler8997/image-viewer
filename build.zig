const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "e7572d24ac22e0d00128649791196d3c25d0d6f1",
        .fetch_enabled = true,
    });
    
    const exe = b.addExecutable("image-viewer", "main.zig");
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
