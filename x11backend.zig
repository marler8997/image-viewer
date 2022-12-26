const builtin = @import("builtin");
const std = @import("std");
const img = @import("img");
const convert = @import("convert.zig");
const x = @import("x");
const common = @import("x11common.zig");
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const XY = @import("xy.zig").XY;
const Image = img.Image;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn bg_gc(self: Ids) u32 { return self.base + 1; }
    pub fn fg_gc(self: Ids) u32 { return self.base + 2; }
};

pub fn go(allocator: std.mem.Allocator, opt_image: ?Image) !void {
    const image = opt_image orelse {
        std.log.err("x11backend requires an image right now", .{});
        std.os.exit(0xff);
    };

    try x.wsaStartup();

    const conn = try common.connect(allocator);
    defer {
        std.os.shutdown(conn.sock, .both) catch {};
        conn.setup.deinit(allocator);
    }

    const fixed = conn.setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
        std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
    }
    std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
    const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
    for (formats) |format, i| {
        std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
    }
    var screen = conn.setup.getFirstScreenPtr(format_list_limit);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
    }
    const max_request_len = @intCast(u18, conn.setup.fixed().max_request_len) * 4;

    // TODO: maybe need to call conn.setup.verify or something?
    const ids = Ids{ .base = conn.setup.fixed().resource_id_base };

    // TODO: if image is too big, create a window that's smaller than the image
    const image_size_u16 = XY(u16){
        .x = std.math.cast(u16, image.width) orelse @panic("image larger than 0xffff not implemented"),
        .y = std.math.cast(u16, image.height) orelse @panic("image larger than 0xffff not implemented"),
    };
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0, .y = 0,
            .width = image_size_u16.x,
            .height = image_size_u16.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
            }, .{
            //            .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xaabbccdd,
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            .event_mask =
                x.event.key_press
                | x.event.key_release
                | x.event.button_press
                | x.event.button_release
                | x.event.enter_window
                | x.event.leave_window
                | x.event.pointer_motion
                //                | x.event.pointer_motion_hint WHAT THIS DO?
                //                | x.event.button1_motion  WHAT THIS DO?
                //                | x.event.button2_motion  WHAT THIS DO?
                //                | x.event.button3_motion  WHAT THIS DO?
                //                | x.event.button4_motion  WHAT THIS DO?
                //                | x.event.button5_motion  WHAT THIS DO?
                //                | x.event.button_motion  WHAT THIS DO?
                | x.event.keymap_state
                | x.event.exposure
                ,
            //            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    // TODO: we probably only need 1 graphics context??
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg_gc(),
            .drawable_id = screen.root,
            }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = screen.root,
            }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try conn.send(msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, ids.fg_gc(), text);
        try conn.send(&msg);
    }

    const double_buf = try x.DoubleBuffer.init(
        std.mem.alignForward(1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit();
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return error.X11UnexpectedReply;
            },
        }
    };
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window());
        try conn.send(&msg);
    }

    const image_rgb32 = try allocator.alloc(u8, 4 * image.width * image.height);
    defer allocator.free(image_rgb32);
    convert.toRgb32(image_rgb32, image);

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return error.X11BufferTooSmall;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            const msg_len = x.parseMsgLen(@alignCast(4, data));
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return error.X11Error;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(
                        .{ .x = image.width, .y = image.height},
                        conn.sock,
                        max_request_len,
                        ids,
                        font_dims,
                        image_rgb32,
                    );
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
            }
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    size: XY(usize),
    sock: std.os.socket_t,
    max_request_len: u18,
    ids: Ids,
    font_dims: FontDims,
    image_rgb32: []const u8,
) !void {
    _ = font_dims;
    const stride = 4 * size.x;
    try sendImage(
        sock,
        max_request_len,
        ids.window(),
        ids.fg_gc(),
        0, 0,
        size,
        stride,
        image_rgb32,
    );
}

fn sendImage(
    sock: std.os.socket_t,
    max_request_len: u18,
    drawable_id: u32,
    gc_id: u32,
    x_loc: i16,
    y: i16,
    size: XY(usize),
    stride: usize,
    data: []const u8,
) !void {
    // NOTE: for now we only support sending images whose width can fit in a u16
    const width_u16 = std.math.cast(u16, size.x) orelse return error.ImageTooWide;

    std.debug.assert(size.y > 0);
    const max_image_len = max_request_len - x.put_image.data_offset;

    // TODO: is this division going to hurt performance?
    const max_lines_per_msg = @divTrunc(max_image_len, stride);
    if (max_lines_per_msg == 0) {
        // in this case we would have to split up each line of the image as well, but
        // this is *unlikely* to ever happen right?
        std.debug.panic("TODO: 1 line is to long!?! max_image_len={}, stride={}", .{max_image_len, stride});
    }

    var lines_sent: usize = 0;
    var data_offset: usize = 0;
    while (true) {
        const lines_remaining = size.y - lines_sent;
        var next_msg_line_count = std.math.min(lines_remaining, max_lines_per_msg);
        var data_len = stride * next_msg_line_count;
        try sendPutImage(
            sock,
            drawable_id,
            gc_id,
            x_loc,
            // TODO: is this cast ok?
            y + @intCast(i16, lines_sent),
            width_u16,
            @intCast(u16, next_msg_line_count),
            x.Slice(u18, [*]const u8) {
                .ptr = data.ptr + data_offset,
                .len = @intCast(u18, data_len),
            },
        );
        lines_sent += next_msg_line_count;
        if (lines_sent == size.y) break;
        data_offset += data_len;
    }
}

fn sendPutImage(
    sock: std.os.socket_t,
    drawable_id: u32,
    gc_id: u32,
    x_loc: i16,
    y: i16,
    width: u16,
    height: u16,
    data: x.Slice(u18, [*]const u8),
) !void {
    var msg: [x.put_image.data_offset]u8 = undefined;
    const expected_msg_len = x.put_image.data_offset + data.len;
    std.debug.assert(expected_msg_len == x.put_image.getLen(data.len));
    x.put_image.serializeNoDataCopy(&msg, data.len, .{
        .format = .z_pixmap,
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .width = width,
        .height = height,
        .x = x_loc,
        .y = y,
        .left_pad = 0,
        // hardcoded to my machine with:
        //     depth= 24 bpp= 32 scanpad= 32
        .depth = 24,
    });
    if (builtin.os.tag == .windows) {
        {
            const sent = try x.writeSock(sock, &msg, 0);
            std.debug.assert(sent == msg.len);
        }
        {
            const sent = try x.writeSock(sock, data.nativeSlice(), 0);
            std.debug.assert(sent == data.len);
        }
    } else {
        std.log.info("message len is {}", .{msg.len + data.len});
        const len = try std.os.writev(sock, &[_]std.os.iovec_const {
            .{ .iov_base = &msg, .iov_len = msg.len },
            .{ .iov_base = data.ptr, .iov_len = data.len },
        });
        if (len != expected_msg_len) {
            // TODO: need to call write multiple times
            std.debug.panic("TODO: writev {} only wrote {}", .{expected_msg_len, len});
        }
    }
}
