const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const img = @import("img");
const convert = @import("convert.zig");
const x = @import("x");
const common = @import("x11common.zig");
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const XY = @import("xy.zig").XY;
const Image = img.Image;

const Endian = std.builtin.Endian;

fn oom(e: error{OutOfMemory}) noreturn {
    std.log.err("{s}", .{@errorName(e)});
    @panic("OutOfMemory");
}

const ImageState = union(enum) {
    no_file: void,
    err: struct {
        msg: []const u8,
        filename: []const u8,
    },
    loaded: struct {
        filename: []const u8,
        size: XY(u16),
    },
};
const State = struct {
    pixmap: struct {
        pending_create: bool = false,
        pending_frees: u16 = 0,
    },
    window_size: XY(u16),
    image: ImageState,

    pub fn close(
        self: *State,
        allocator: Allocator,
        sock: std.os.socket_t,
        ids: Ids,
    ) !void {
        if (self.pixmap.pending_create) {
            var msg: [x.free_pixmap.len]u8 = undefined;
            x.free_pixmap.serialize(&msg, ids.pixmap());
            try common.send(sock, &msg);
            self.pixmap.pending_create = false;
            self.pixmap.pending_frees += 1;
        }

        switch (self.image) {
            .no_file => {},
            .err => |e| {
                allocator.free(e.msg);
                allocator.free(e.filename);
                self.image = .no_file;
            },
            .loaded => |s| {
                allocator.free(s.filename);
                self.image = .no_file;
            },
        }
    }

    pub fn setError(
        self: *State,
        allocator: Allocator,
        sock: std.os.socket_t,
        ids: Ids,
        filename: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.close(allocator, sock, ids);
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch |e| oom(e);
        errdefer allocator.free(msg);
        self.image = .{
            .err = .{
                .msg = msg,
                .filename = allocator.dupe(u8, filename) catch |e| oom(e),
            },
        };
    }

    pub fn loadImage(
        self: *State,
        allocator: Allocator,
        sock: std.os.socket_t,
        screen_root: u32,
        ids: Ids,
        image_format: XImageFormat,
        filename: []const u8,
    ) !void {
        try self.close(allocator, sock, ids);
        const content = blk: {
            var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
                try self.setError(
                    allocator, sock, ids, filename,
                    "Open image failed with {s}:",
                    .{@errorName(err)},
                );
                return;
            };
            defer file.close();
            break :blk file.readToEndAlloc(
                allocator,
                std.math.maxInt(usize),
            ) catch |err| {
                try self.setError(
                    allocator, sock, ids, filename,
                    "Read image failed with {s}:",
                    .{@errorName(err)},
                );
                return;
            };
        };
        defer allocator.free(content);

        var image = img.Image.fromMemory(
            allocator,
            content,
        ) catch |err| {
            try self.setError(
                allocator, sock, ids, filename,
                "Parse image failed with {s}:",
                .{@errorName(err)},
            );
            return;
        };
        defer image.deinit();

        const image_size_u16 = XY(u16){
            .x = std.math.cast(u16, image.width) orelse {
                try self.setError(
                    allocator, sock, ids, filename,
                    "todo: support image width {}",
                    .{image.width},
                );
                return;
            },
            .y = std.math.cast(u16, image.height) orelse {
                try self.setError(
                    allocator, sock, ids, filename,
                    "todo: support image height {}",
                    .{image.height},
                );
                return;
            },
        };

        const rgb32 = allocator.alloc(u8, 4 * image.width * image.height) catch |e| oom(e);
        defer allocator.free(rgb32);
        convert.toRgb32(rgb32, image);

        {
            var msg: [x.create_pixmap.len]u8 = undefined;
            x.create_pixmap.serialize(&msg, .{
                .id = ids.pixmap(),
                .drawable_id = screen_root,
                .depth = image_format.depth,
                .width = image_size_u16.x,
                .height = image_size_u16.y,
            });
            try common.send(sock, &msg);
        }

        {
            const image_bytes_per_pixel = image_format.bits_per_pixel / 8;
            const image_stride = std.mem.alignForward(
                usize,
                image_bytes_per_pixel * image.width,
                image_format.scanline_pad / 8,
            );
            const put_image_line_msg = try allocator.alloc(u8, x.put_image.data_offset + image_stride);
            defer allocator.free(put_image_line_msg);

            var it = image.iterator();
            var line_index: usize = 0;
            while (line_index < image_size_u16.y) : (line_index += 1) {
                try sendLine(
                    sock,
                    image_format,
                    ids.pixmap(),
                    ids.fg_gc(),
                    0,
                    // TODO: is this cast ok?
                    @intCast(line_index),
                    image_size_u16.x,
                    &it,
                    put_image_line_msg,
                );
            }
        }

        self.image = .{
            .loaded = .{
                .filename = allocator.dupe(u8, filename) catch |e| oom(e),
                .size = .{ .x = @intCast(image.width), .y = @intCast(image.height) },
            },
        };
    }
};

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn fg_gc(self: Ids) u32 { return self.base + 1; }
    pub fn pixmap(self: Ids) u32 { return self.base + 2; }
};

const XImageFormat = struct {
    endian: Endian,
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
};
fn getXImageFormat(
    endian: Endian,
    formats: []const align(4) x.Format,
    root_depth: u8,
) !XImageFormat {
    var opt_match_index: ?usize = null;
    for (formats, 0..) |format, i| {
        if (format.depth == root_depth) {
            if (opt_match_index) |_|
                return error.MultiplePixmapFormatsSameDepth;
            opt_match_index = i;
        }
    }
    const match_index = opt_match_index orelse
        return error.MissingPixmapFormat;
    return XImageFormat{
        .endian = endian,
        .depth = root_depth,
        .bits_per_pixel = formats[match_index].bits_per_pixel,
        .scanline_pad = formats[match_index].scanline_pad,
    };
}

const WindowRect = struct {
    pos: XY(u16),
    size: XY(u16),
};
fn calcStartWindowRect(state: State) WindowRect {
    const desired_size: XY(u16) = switch (state.image) {
        .no_file => .{ .x = 500, .y = 200 },
        .err => .{ .x = 500, .y = 200 },
        .loaded => |s| s.size,
    };

    return .{
        .pos = .{ .x = 0, .y = 0 },
        .size = desired_size,
    };
}

pub fn go(maybe_filename: ?[]const u8) !void {
    try x.wsaStartup();

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){ };
    const gpa = gpa_instance.allocator();
    const conn = try common.connect(gpa);
    defer {
        std.os.shutdown(conn.sock, .both) catch {};
        conn.setup.deinit(gpa);
    }

    const fixed = conn.setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
        std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
    }
    const ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
    const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
    for (formats, 0..) |format, i| {
        std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
    }
    const screen = conn.setup.getFirstScreenPtr(format_list_limit);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
    }
    const image_format = blk: {
        const image_endian: Endian = switch (fixed.image_byte_order) {
            .lsb_first => .Little,
            .msb_first => .Big,
            else => |order| {
                std.log.err("unknown image-byte-order {}", .{order});
                return error.X11UnexpectedReply;
            },
        };
        break :blk try getXImageFormat(image_endian, formats, screen.root_depth);
    };

    // TODO: maybe need to call conn.setup.verify or something?

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = screen.root,
        }, .{
            .background = screen.black_pixel,
            .foreground = x.rgb24To(0xffaadd, screen.root_depth),
            // prevent NoExposure events when we CopyArea
            .graphics_exposures = false,
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
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit();
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return error.X11UnexpectedReply;
            },
        }
    };

    var state: State = .{
        .pixmap = .{},
        .window_size = .{ .x = 0, .y = 0 },
        .image = .no_file,
    };
    if (maybe_filename) |filename| {
        try state.loadImage(gpa, conn.sock, screen.root, ids, image_format, filename);
    }



    {
        const window_rect = calcStartWindowRect(state);
        state.window_size = window_rect.size;

        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = window_rect.pos.x,
            .y = window_rect.pos.y,
            .width = window_rect.size.x,
            .height = window_rect.size.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
            }, .{
            //            .bg_pixmap = .copy_from_parent,
            .bg_pixel = x.rgb24To(0xbbccdd, screen.root_depth),
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

    // render image to pixmap
    // NOTE: if image is too big (width/height can't fit in u16), we will need
    //       mulitple pixmaps
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window());
        try conn.send(&msg);
    }

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
            if (data.len < 32)
                break;
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
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
                    try render(conn.sock, ids, font_dims, state);
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for structure_notify events
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
    sock: std.os.socket_t,
    ids: Ids,
    font_dims: FontDims,
    state: State,
) !void {
    switch (state.image) {
        .no_file => {
            try renderClearBg(sock, ids, state.window_size);
            try renderText(sock, ids, font_dims, state.window_size, "No File Opened", 0);
        },
        .err => |err| {
            try renderClearBg(sock, ids, state.window_size);
            try renderText(sock, ids, font_dims, state.window_size, err.msg, -1);
            try renderText(sock, ids, font_dims, state.window_size, err.filename, 1);
        },
        .loaded => |s| {
            var msg: [x.copy_area.len]u8 = undefined;
            x.copy_area.serialize(&msg, .{
                .src_drawable_id = ids.pixmap(),
                .dst_drawable_id = ids.window(),
                .gc_id = ids.fg_gc(),
                .src_x = 0,
                .src_y = 0,
                .dst_x = 0,
                .dst_y = 0,
                .width = s.size.x,
                .height = s.size.y,
            });
            try common.send(sock, &msg);
        },
    }
}

fn renderClearBg(sock: std.os.socket_t, ids: Ids, size: XY(u16)) !void {
    var msg: [x.clear_area.len]u8 = undefined;
    x.clear_area.serialize(&msg, false, ids.window(), .{
        .x = 0, .y = 0, .width = size.x, .height = size.y,
    });
    try common.send(sock, &msg);
}

fn renderText(
    sock: std.os.socket_t,
    ids: Ids,
    font_dims: FontDims,
    window_size: XY(u16),
    text_slice: []const u8,
    y_offset_multiplier: f32,
) !void {
    const text = x.Slice(u8, [*]const u8) {
        .ptr = text_slice.ptr,
        .len = std.math.cast(u8, text_slice.len) orelse
            std.debug.panic("todo: implement render message of length {}", .{text_slice.len}),
    };
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_width = font_dims.width * text_slice.len;

    const y_offset: i16 = @intFromFloat(y_offset_multiplier * @as(f32, @floatFromInt(font_dims.height)));
    x.image_text8.serialize(&msg, text, .{
        .drawable_id = ids.window(),
        .gc_id = ids.fg_gc(),
        .x = @divTrunc((@as(i16, @intCast(window_size.x)) - @as(i16, @intCast(text_width))),  2) + font_dims.font_left,
        .y = @divTrunc((@as(i16, @intCast(window_size.y)) - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent + y_offset,
    });
    try common.send(sock, msg[0 .. x.image_text8.getLen(text.len)]);
}

fn sendLine(
    sock: std.os.socket_t,
    dst_image_format: XImageFormat,
    drawable_id: u32,
    gc_id: u32,
    x_loc: i16,
    y: i16,
    width: u16,
    pixel_it: *img.color.PixelStorageIterator,
    msg: []u8,
) !void {
    const dst_bytes_per_pixel = dst_image_format.bits_per_pixel / 8;
    const dst_stride = std.mem.alignForward(
        u18,
        dst_bytes_per_pixel * width,
        dst_image_format.scanline_pad / 8,
    );
    std.debug.assert(msg.len == x.put_image.getLen(dst_stride));
    x.put_image.serializeNoDataCopy(msg.ptr, dst_stride, .{
        .format = .z_pixmap,
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .width = width,
        .height = 1,
        .x = x_loc,
        .y = y,
        .left_pad = 0,
        .depth = dst_image_format.depth,
    });

    {
        var msg_off: usize = x.put_image.data_offset;
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            const color_f32 = pixel_it.next().?;
            const r: u24 = @as(u24, @intFromFloat(color_f32.r / 1.0 * 0xff)) & 0xff;
            const g: u24 = @as(u24, @intFromFloat(color_f32.g / 1.0 * 0xff)) & 0xff;
            const b: u24 = @as(u24, @intFromFloat(color_f32.b / 1.0 * 0xff)) & 0xff;
            const color = (r << 16) | (g << 8) | (b << 0);

            switch (dst_image_format.depth) {
                16 => std.mem.writeInt(
                    u16,
                    msg[msg_off..][0 .. 2],
                    x.rgb24To16(color),
                    dst_image_format.endian,
                ),
                24 => std.mem.writeInt(
                    u24,
                    msg[msg_off..][0 .. 3],
                    color,
                    dst_image_format.endian,
                ),
                32 => std.mem.writeInt(
                    u32,
                    msg[msg_off..][0 .. 4],
                    color,
                    dst_image_format.endian,
                ),
                else => std.debug.panic("TODO: implement image depth {}", .{dst_image_format.depth}),
            }
            msg_off += dst_bytes_per_pixel;
        }
    }

    try common.send(sock, msg);
}
