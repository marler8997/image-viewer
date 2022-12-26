const std = @import("std");
const img = @import("img");

pub fn toRgb32(dst_rgb32: []u8, image: img.Image) void {
    const bytes = image.rawBytes();
    switch (image.pixelFormat()) {
        .rgb24 => {
            var src_off: usize = 0;
            var dst_off: usize = 0;
            var y: usize = 0;
            while (y < image.height) : (y += 1) {
                var col: usize = 0;
                while (col < image.width) : (col += 1) {
                    dst_rgb32[dst_off + 0] = bytes[src_off + 2];
                    dst_rgb32[dst_off + 1] = bytes[src_off + 1];
                    dst_rgb32[dst_off + 2] = bytes[src_off + 0];
                    dst_rgb32[dst_off + 3] = 0;
                    dst_off += 4;
                    src_off += 3;
                }
            }
        },
        .rgba32 => {
            var src_off: usize = 0;
            var dst_off: usize = 0;
            var y: usize = 0;
            while (y < image.height) : (y += 1) {
                var col: usize = 0;
                while (col < image.width) : (col += 1) {
                    dst_rgb32[dst_off + 0] = bytes[src_off + 2];
                    dst_rgb32[dst_off + 1] = bytes[src_off + 1];
                    dst_rgb32[dst_off + 2] = bytes[src_off + 0];
                    dst_rgb32[dst_off + 3] = 0;
                    dst_off += 4;
                    src_off += 4;
                }
            }
        },
        else => std.debug.panic(
            "x11 does not yet support pixel format {s}",
            .{@tagName(image.pixelFormat())},
        ),
    }
}
