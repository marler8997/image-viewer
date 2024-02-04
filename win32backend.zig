const builtin = @import("builtin");
const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.hi_dpi;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};
const win32fix = struct {
    pub extern "user32" fn LoadImageW(
        hInst: ?win32.HINSTANCE,
        name: ?[*:0]const align(1) u16,
        type: win32.GDI_IMAGE_TYPE,
        cx: i32,
        cy: i32,
        flags: win32.IMAGE_FLAGS,
    ) callconv(@import("std").os.windows.WINAPI) ?win32.HANDLE;
};
const L = win32.L;
const HINSTANCE = win32.HINSTANCE;
const CW_USEDEFAULT = win32.CW_USEDEFAULT;
const MSG = win32.MSG;
const HWND = win32.HWND;

const img = @import("img");
const convert = @import("convert.zig");
const XY = @import("xy.zig").XY;
const Image = img.Image;

pub const UNICODE = true;

const window_style = win32.WS_OVERLAPPEDWINDOW;
const window_menu: win32.BOOL = 0;
const window_style_ex = win32.WINDOW_EX_STYLE.initFlags(.{});

pub const State = union(enum) {
    no_file: void,
    err: struct {
        msg: []const u8,
        filename: []const u8,
    },
    loaded: struct {
        filename: []const u8,
        size: XY(i32),
        rgb32: []u8,
    },

    pub fn close(self: *State) void {
        switch (self.*) {
            .no_file => {},
            .err => |e| {
                global.gpa.free(e.msg);
                global.gpa.free(e.filename);
                self.* = .no_file;
            },
            .loaded => |s| {
                global.gpa.free(s.filename);
                global.gpa.free(s.rgb32);
                self.* = .no_file;
            },
        }
    }

    pub fn setError(
        self: *State,
        filename: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.close();
        const msg = std.fmt.allocPrint(global.gpa, fmt, args) catch |e| oom(e);
        errdefer global.gpa.free(msg);
        self.* = .{
            .err = .{
                .msg = msg,
                .filename = global.gpa.dupe(u8, filename) catch |e| oom(e),
            },
        };
    }

    pub fn loadImage(self: *State, filename: []const u8) void {
        self.close();
        const content = blk: {
            var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
                self.setError(
                    filename,
                    "Open image failed with {s}:",
                    .{@errorName(err)},
                );
                return;
            };
            defer file.close();
            break :blk file.readToEndAlloc(
                global.gpa,
                std.math.maxInt(usize),
            ) catch |err| {
                self.setError(
                    filename,
                    "Read image failed with {s}:",
                    .{@errorName(err)},
                );
                return;
            };
        };
        defer global.gpa.free(content);

        var image = img.Image.fromMemory(
            global.gpa,
            content,
        ) catch |err| {
            self.setError(
                filename,
                "Parse image failed with {s}:",
                .{@errorName(err)},
            );
            return;
        };
        defer image.deinit();

        const rgb32 = global.gpa.alloc(u8, 4 * image.width * image.height) catch |e| oom(e);
        errdefer global.gpa.free(rgb32);
        convert.toRgb32(rgb32, image);
        self.* = .{
            .loaded = .{
                .filename = global.gpa.dupe(u8, filename) catch |e| oom(e),
                .size = .{ .x = @intCast(image.width), .y = @intCast(image.height) },
                .rgb32 = rgb32,
            },
        };
    }
};

const global = struct {
    pub var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){ };
    pub const gpa = gpa_instance.allocator();
    pub var state: State = .no_file;
};

fn oom(e: error{OutOfMemory}) noreturn {
    std.log.err("{s}", .{@errorName(e)});
    _ = win32.MessageBoxA(null, "Out of memory", "Med Error", win32.MB_OK);
    std.os.exit(0xff);
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    // TODO: detect if there is a console or not, only show message box
    //       if there is not a console
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
    const result = win32.MessageBoxA(null, msg.ptr, null, win32.MB_OK);
    std.log.info("MessageBox result is {}", .{result});
    std.os.exit(0xff);
}

const ID_ICON_IMAGE_VIEWER = 1;

const Icons = struct {
    small: ?win32.HICON,
    large: ?win32.HICON,
};
fn getIcons() Icons {
    const size_small = XY(i32){
        .x = win32.GetSystemMetrics(win32.SM_CXSMICON),
        .y = win32.GetSystemMetrics(win32.SM_CYSMICON)
    };
    const size_large = XY(i32){
        .x = win32.GetSystemMetrics(win32.SM_CXICON),
        .y = win32.GetSystemMetrics(win32.SM_CYICON)
    };
    const small = win32fix.LoadImageW(
        win32.GetModuleHandle(null),
        @ptrFromInt(ID_ICON_IMAGE_VIEWER),
        .ICON,
        size_small.x,
        size_small.y,
        win32.IMAGE_FLAGS.initFlags(.{ .DEFAULTCOLOR=1, .SHARED=1 }),
    );
    if (small == null) {
        std.log.err("LoadImage for small icon failed, error={}", .{win32.GetLastError()});
        // not a critical error
    }
    const large = win32fix.LoadImageW(
        win32.GetModuleHandle(null),
        @ptrFromInt(ID_ICON_IMAGE_VIEWER),
        .ICON,
        size_large.x,
        size_large.y,
        win32.IMAGE_FLAGS.initFlags(.{ .DEFAULTCOLOR=1, .SHARED=1 }),
    );
    if (large == null) {
        std.log.err("LoadImage for large icon failed, error={}", .{win32.GetLastError()});
        // not a critical error
    }
    return .{
        .small = @ptrCast(small),
        .large = @ptrCast(large),
    };
}

pub fn go(maybe_filename: ?[]const u8) !void {
    if (maybe_filename) |filename| {
        global.state.loadImage(filename);
    }

    // See https://gist.github.com/marler8997/9f39458d26e2d8521d48e36530fbb459
    // for notes about windows DPI scaling.
//    {
//        var dpi_awareness: win32.PROCESS_DPI_AWARENESS = undefined;
//        {
//            const result = win32.GetProcessDpiAwareness(null, &dpi_awareness);
//            if (result != 0)
//                fatal("GetProcessDpiAwareness failed, error={}", .{result});
//        }
//        if (dpi_awareness != win32.PROCESS_PER_MONITOR_DPI_AWARE)
//            // We'll just exit for now until we see if this is possible
//            // it *might* be possible on older versions of windows
//            fatal("unexpected dpi awareness {}", dpi_awareness);
//    }

    const icons = getIcons();

    const CLASS_NAME = L("ImageViewer");
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = @enumFromInt(0),
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandle(null),
        .hIcon = icons.large,
        .hIconSm = icons.small,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
    };
    const class_id = win32.RegisterClassExW(&wc);
    if (class_id == 0) {
        std.log.err("RegisterClass failed, error={}", .{win32.GetLastError()});
        std.os.exit(0xff);
    }

    const hwnd = win32.CreateWindowEx(
        @enumFromInt(0), // Optional window styles.
        CLASS_NAME, // Window class
        // TODO: use the image name in the title if we have one
        L("Image Viewer"),
        window_style,
        0, 0, // position
        0, 0, // size
        null, // Parent window
        null, // Menu
        win32.GetModuleHandle(null),
        null // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.os.exit(0xff);
    };

    {
        const rect = calcStartWindowRect(hwnd);
        if (0 == win32.SetWindowPos(
            hwnd,
            null,
            rect.left, rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            win32.SET_WINDOW_POS_FLAGS.initFlags(.{}),
        ))
            fatal("SetWindowPos failed, error={}", .{win32.GetLastError()});
    }

    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);

    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
}

fn clientToWindowSize(size: XY(i32)) XY(i32) {
    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = size.x,
        .bottom = size.y,
    };
    if (0 == win32.AdjustWindowRectEx(&rect, window_style, window_menu, window_style_ex))
        std.debug.panic("AdjustWindowRectExForDpi failed, error={}", .{win32.GetLastError()});
    return XY(i32){
        .x = rect.right - rect.left,
        .y = rect.bottom - rect.top,
    };
}

fn calcStartWindowRect(hWnd: HWND) win32.RECT {
    const monitor = win32.MonitorFromWindow(
        hWnd, win32.MONITOR_DEFAULTTOPRIMARY
    ) orelse @panic("unexpected");

    var info: win32.MONITORINFO = undefined;
    info.cbSize = @sizeOf(@TypeOf(info));
    if (0 == win32.GetMonitorInfoW(monitor, &info)) @panic("unexpected");

    std.log.info("monitor rect {},{} {},{}", .{
        info.rcWork.left, info.rcWork.top,
        info.rcWork.right, info.rcWork.bottom,
    });
    const desktop_size = XY(i32){
        .x = info.rcWork.right - info.rcWork.left,
        .y = info.rcWork.bottom - info.rcWork.top,
    };

    const desired_client_size: XY(i32) = switch (global.state) {
        .no_file => .{ .x = 500, .y = 200 },
        .err => .{ .x = 500, .y = 200 },
        .loaded => |s| s.size,
    };
    const desired_window_size = clientToWindowSize(desired_client_size);

    var window_size = desired_window_size;
    if (desktop_size.x < desired_window_size.x) {
        std.log.info(
            "clamping window width {} to desktop {}",
            .{desired_window_size.x, desktop_size.x},
        );
        window_size.x = desktop_size.x;
    }
    if (desktop_size.y < desired_window_size.y) {
        std.log.info(
            "clamping window height {} to desktop {}",
            .{desired_window_size.y, desktop_size.y},
        );
        window_size.y = desktop_size.y;
    }
    const adjust = XY(i32){
        .x = @divTrunc(desktop_size.x - window_size.x, 2),
        .y = @divTrunc(desktop_size.y - window_size.y, 2),
    };
    return .{
        .left = info.rcWork.left + adjust.x,
        .top = info.rcWork.top + adjust.y,
        .right = info.rcWork.right - adjust.x,
        .bottom = info.rcWork.bottom - adjust.y,
    };
}


fn WindowProc(
    hWnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_KEYDOWN => {
            if (wParam == @intFromEnum(win32.VK_F5)) {
                std.log.info("TODO: refresh the file", .{});
            }
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            paint(hWnd);
            return 0;
        },
        win32.WM_SIZE => {
            // since we "stretch" the image accross the full window, we
            // always invalidate the full client area on each window resize
            std.debug.assert(0 != win32.InvalidateRect(hWnd, null, 0));
        },
        else => {},
    }
    return win32.DefWindowProc(hWnd, uMsg, wParam, lParam);
}

fn getClientSize(hWnd: HWND) win32.SIZE {
    var client_rect: win32.RECT = undefined;
    std.debug.assert(0 != win32.GetClientRect(hWnd, &client_rect));
    return .{
        .cx = client_rect.right - client_rect.left,
        .cy = client_rect.bottom - client_rect.top,
    };
}

fn paint(hWnd: HWND) void {
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hWnd, &ps);

    const client_size = getClientSize(hWnd);
    switch (global.state) {
        .no_file => {
            fillBg(hdc, ps.rcPaint);
            paintMsg(hdc, client_size, "No File Opened", 0);
        },
        .err => |err| {
            fillBg(hdc, ps.rcPaint);
            paintMsg(hdc, client_size, err.msg, -1);
            paintMsg(hdc, client_size, err.filename, 1);
        },
        .loaded => |s| {
            std.log.info("PAINT! client rect {}x{} image {}x{}", .{
                client_size.cx, client_size.cy,
                s.size.x, s.size.y,
            });
            const bitmap_info = win32.BITMAPINFO{
                .bmiHeader = .{
                    .biSize = @sizeOf(win32.BITMAPINFOHEADER),
                    .biWidth = @intCast(s.size.x),
                    .biHeight = -@as(i32, @intCast(s.size.y)),
                    .biPlanes = 1,
                    .biBitCount = 32,
                    .biCompression = win32.BI_RGB,
                    .biSizeImage = 0,
                    .biXPelsPerMeter = 0,
                    .biYPelsPerMeter = 0,
                    .biClrUsed = 0,
                    .biClrImportant = 0,
                },
                .bmiColors = undefined,
            };
            const result = win32.StretchDIBits(
                hdc,
                0, 0, client_size.cx, client_size.cy,
                0, 0, @intCast(s.size.x), @intCast(s.size.y),
                s.rgb32.ptr,
                &bitmap_info,
                win32.DIB_RGB_COLORS,
                win32.SRCCOPY,
            );
            if (result == 0)
                std.debug.panic("StretchDIBits failed with {}", .{win32.GetLastError()});
            //std.debug.assert(result == client_size.cx);
            std.log.info("result is {}", .{result});
            std.debug.assert(result != 0);
        },
    }
    _ = win32.EndPaint(hWnd, &ps);
}

fn fillBg(hdc: ?win32.HDC, paint_rect: win32.RECT) void {
    _ = win32.FillRect(
        hdc,
        &paint_rect,
        @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_WINDOW)) + 1),
    );
}

fn paintMsg(
    hdc: ?win32.HDC,
    client_size: win32.SIZE,
    msg: []const u8,
    y_offset_multiplier: f32,
) void {
    var size: win32.SIZE = undefined;
    std.debug.assert(0 != win32.GetTextExtentPoint32A(
        hdc, @ptrCast(msg.ptr), @intCast(msg.len), &size
    ));
    const y_offset: i32 = @intFromFloat(y_offset_multiplier * @as(f32, @floatFromInt(size.cy)));
    const x = @divTrunc(client_size.cx - size.cx, 2);
    const y = @divTrunc(client_size.cy - size.cy, 2) + y_offset;

    _ = win32.TextOutA(hdc, x, y, @ptrCast(msg.ptr), @intCast(msg.len));
}
