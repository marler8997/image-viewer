const builtin = @import("builtin");
const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
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

var global = struct {
    opt_image: ?Image = undefined,
    opt_image_rgb32: ?[]u8 = null,
}{};

pub fn fatal(hWnd: ?win32.HWND, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    // TODO: detect if there is a console or not, only show message box
    //       if there is not a console
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
    const result = win32.MessageBoxA(hWnd, msg.ptr, null, win32.MB_OK);
    std.log.info("MessageBox result is {}", .{result});
    std.os.exit(0xff);
}

pub fn go(
    allocator: std.mem.Allocator,
    opt_image: ?Image,
    hInstance: HINSTANCE,
    nCmdShow: u32,
) !void {
    global.opt_image = opt_image;

    if (opt_image) |image| {
        global.opt_image_rgb32 = try allocator.alloc(u8, 4 * image.width * image.height);
        convert.toRgb32(global.opt_image_rgb32.?, image);
    }
    defer if (global.opt_image_rgb32) |r| {
        allocator.free(r);
        global.opt_image_rgb32 = null;
    };

    const CLASS_NAME = L("ImageViewer");
    const wc = win32.WNDCLASS{
        .style = @enumFromInt(0),
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
    };
    const class_id = win32.RegisterClass(&wc);
    if (class_id == 0) {
        std.log.err("RegisterClass failed, error={}", .{win32.GetLastError()});
        std.os.exit(0xff);
    }

    const window_style = win32.WS_OVERLAPPEDWINDOW;
    const size: XY(i32) = blk: {
        const default = XY(i32){ .x = CW_USEDEFAULT, .y = CW_USEDEFAULT };
        const image = opt_image orelse break :blk default;
        var client_rect: win32.RECT = undefined;
        client_rect = .{
            .left = 0, .top = 0,
            .right  = std.math.cast(i32, image.width) orelse break :blk default,
            .bottom = std.math.cast(i32, image.height) orelse break :blk default,
        };
        std.debug.assert(0 != win32.AdjustWindowRect(&client_rect, window_style, 0));
        break :blk .{
            .x = client_rect.right - client_rect.left,
            .y = client_rect.bottom - client_rect.top,
        };
    };

    const hwnd = win32.CreateWindowEx(
        @enumFromInt(0), // Optional window styles.
        CLASS_NAME, // Window class
        // TODO: use the image name in the title if we have one
        L("Image Viewer"),
        window_style,
        // position
        CW_USEDEFAULT, CW_USEDEFAULT,
        size.x, size.y,
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.os.exit(0xff);
    };
    _ = win32.ShowWindow(hwnd, @enumFromInt(nCmdShow));

    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
}

fn WindowProc(
    hWnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
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

fn paint(hWnd: HWND) void {
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hWnd, &ps);

    if (global.opt_image) |image| {
        var client_rect: win32.RECT = undefined;
        std.debug.assert(0 != win32.GetClientRect(hWnd, &client_rect));
        std.debug.assert(0 == client_rect.left);
        std.debug.assert(0 == client_rect.top);
        std.log.info("PAINT! client rect {}x{} image {}x{}", .{
            client_rect.right, client_rect.bottom,
            image.width, image.height,
        });
        const bitmap_info = win32.BITMAPINFO{
            .bmiHeader = .{
                .biSize = @sizeOf(win32.BITMAPINFOHEADER),
                .biWidth = @intCast(image.width),
                .biHeight = -@as(i32, @intCast(image.height)),
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
            0, 0, client_rect.right, client_rect.bottom,
            0, 0, @intCast(image.width), @intCast(image.height),
            global.opt_image_rgb32.?.ptr,
            &bitmap_info,
            win32.DIB_RGB_COLORS,
            win32.SRCCOPY,
        );
        if (result == 0)
            std.debug.panic("StretchDIBits failed with {}", .{win32.GetLastError()});
        //std.debug.assert(result == client_rect.bottom);
        std.log.info("result is {}", .{result});
        std.debug.assert(result != 0);
    } else {
        // TODO: paint a message to open a file
        _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_WINDOW)) + 1));
    }

    _ = win32.EndPaint(hWnd, &ps);
}
