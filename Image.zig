const Image = @This();

const std = @import("std");
const XY = @import("xy.zig").XY;
const img = @import("img");

pub const Format = enum {
    rgb24,
    rgb32,
};

size: XY(u32),
bytes: []const u8,
format: Format,

pub fn init(image: img.Image) Image {
    return .{
        .size = .{
            .x = @intCast(u32, image.width),
            .y = @intCast(u32, image.height),
        },
        .bytes = image.rawBytes(),
        .format = switch (image.pixelFormat()) {
            .rgb24 => .rgb24,
            .rgba32 => .rgb32,
            else => std.debug.panic("TODO: support pixel format {s}", .{@tagName(image.pixelFormat())}),
        },
    };
}
