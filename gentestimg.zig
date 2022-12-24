const std = @import("std");

pub fn main() !void {
    const width = 256;
    const height = 256;
    var file = try std.fs.cwd().createFile("testimg.ppm", .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    try bw.writer().print("P6\n{} {}\n255\n", .{width, height});
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const mod = y % 100;
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        if (mod < 20) r = 0xff
        else if (mod < 40) g = 0xff
        else if (mod < 60) b = 0xff
        else if (mod < 80) {}
        else { r = 0xff; g = 0xff; b = 0xff; }
        
        var x: usize = 0;
        while (x < width) : (x += 1) {
            try bw.writer().writeAll(&[3]u8{r, b, g});
        }
    }
    try bw.flush();
}
