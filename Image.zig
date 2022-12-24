const Image = @This();

const std = @import("std");
const XY = @import("xy.zig").XY;

pub const Format = enum {
    rgb24,
};

size: XY(u32),
bytes: []const u8,
format: Format,

pub fn initPpm(file_content: []const u8) !Image {
    if (!std.mem.startsWith(u8, file_content, "P6"))
        return error.InvalidPpmBadMagic;
    const after_magic = file_content[2..];
    var it = std.mem.tokenize(u8, after_magic, " \t\r\n");
    const width_str = it.next() orelse return error.InvalidPpmTooSmall;
    const width = std.fmt.parseInt(u32, width_str, 10) catch
        return error.InvalidPpmBadWidth;
    const height_str = it.next() orelse return error.InvalidPpmTooSmall;
    const height = std.fmt.parseInt(u32, height_str, 10) catch
        return error.InvalidPpmBadHeight;
    const maxcolor_str = it.next() orelse return error.InvalidPpmTooSmall;
    const maxcolor = std.fmt.parseInt(u32, maxcolor_str, 10) catch
        return error.InvalidPpmBadMaxcolor;
    if (maxcolor != 255) return error.UnsupportePpmMaxColor;
    return .{
        .size = .{ .x = width, .y = height },
        .bytes = after_magic[it.index + 1..],
        .format = .rgb24,
    };
}
