const builtin = @import("builtin");
const std = @import("std");

const XY = @import("xy.zig").XY;
const Image = @import("Image.zig");
const x11backend = @import("x11backend.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
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

pub fn main() !u8 {
    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        for (all_args) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };
    if (args.len == 0) {
        try std.io.getStdErr().writer().writeAll("Usage: image-viewer FILE\n");
        return 0xff;
    }
    if (args.len != 1)
        fatal("expected 1 cmdline argument but got {}", .{args.len});
    const filename = std.mem.span(args[0]);
    const content = blk: {
        var file = std.fs.cwd().openFile(filename, .{}) catch |err|
            // TODO: maybe display an error in the GUI?
            fatal("failed to open '{s}' with {s}", .{filename, @errorName(err)});
        defer file.close();
        break :blk try file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
    };

    const img = Image.initPpm(content) catch |err|
        fatal("failed to parse {s} as a ppm file with {s}", .{filename, @errorName(err)});
    
    // TODO: select the right backend
    var x11_state = try x11backend.State.init(
        arena.allocator(),
        img,
    );
    defer x11_state.deinit();

    //const 
    //std.log.info("maximum request length is {} bytes", .{max_request_len});
    
    try x11_state.windowLoop();
    return 0;
}

