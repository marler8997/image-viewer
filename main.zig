const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const img = @import("img");

const XY = @import("xy.zig").XY;
const x11backend = if (build_options.enable_x11_backend) @import("x11backend.zig") else struct {};
const win32backend = @import("win32backend.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    if (builtin.os.tag == .windows) {
        win32backend.fatal(null, fmt, args);
    } else {
        std.log.err(fmt, args);
        std.os.exit(0xff);
    }
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};
pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..]) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

const MainData = if (builtin.os.tag == .windows) struct {
    hInstance: std.os.windows.HINSTANCE,
    nCmdShow: u32,
} else void;
var main_data: MainData = undefined;

pub fn wWinMain(
    hInstance: std.os.windows.HINSTANCE,
    hPrevInstance: ?std.os.windows.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) c_int {
    _ = hPrevInstance;
    _ = pCmdLine;
    main_data = .{
        .hInstance = hInstance,
        .nCmdShow = nCmdShow,
    };
    return std.start.callMain();
}

pub fn main() !u8 {

    var cmdline_opt = struct {
        x11: if (build_options.enable_x11_backend) bool else void =
            if (build_options.enable_x11_backend) false else {},
    }{};

    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        for (all_args) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else if (std.mem.eql(u8, arg, "--x11")) {
                if (build_options.enable_x11_backend) {
                    cmdline_opt.x11 = true;
                } else fatal("the x11 backend was not enabled in this build", .{});
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };

    const opt_image: ?img.Image = image_blk: {
        if (args.len == 0) break :image_blk null;
        if (args.len > 1)
            fatal("expected 0 or 1 cmdline arguments but got {}", .{args.len});
        const filename = std.mem.span(args[0]);
        const content = blk: {
            var file = std.fs.cwd().openFile(filename, .{}) catch |err|
                // TODO: maybe display an error in the GUI?
                fatal("failed to open '{s}' with {s}", .{filename, @errorName(err)});
            defer file.close();
            break :blk try file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
        };
        break :image_blk img.Image.fromMemory(arena.allocator(), content) catch |err|
            fatal("failed load image {s} with {s}", .{filename, @errorName(err)});
    };
    if (builtin.os.tag == .windows) {
        if (build_options.enable_x11_backend) {
            if (cmdline_opt.x11) {
                try x11backend.go(arena.allocator(), opt_image);
                return 0;
            }
        }
        try win32backend.go(arena.allocator(), opt_image, main_data.hInstance, main_data.nCmdShow);
    } else {
        try x11backend.go(arena.allocator(), opt_image);
    }
    return 0;
}
