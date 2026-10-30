//! Native desktop entry point: owns the window, the back buffer and the
//! message loop, and hands each repaint to `app.frame`.

const std = @import("std");
const win = @import("win32.zig");
const app = @import("app.zig");
const Canvas = @import("canvas.zig").Canvas;
const State = @import("state.zig").State;
const theme = @import("theme.zig");

const min_width = 1100;
const min_height = 700;
const wheel_step = 60;

var canvas: Canvas = undefined;
var state: State = .{};
var input: app.Input = .{};
var scale: f32 = 1;
var cursor_arrow: win.Handle = null;
var cursor_hand: win.Handle = null;
var want_hand = false;

var back_dc: win.Handle = null;
var back_bitmap: win.Handle = null;
var back_width: i32 = 0;
var back_height: i32 = 0;

fn ensureBackBuffer(hdc: win.Handle, width: i32, height: i32) void {
    if (back_dc != null and width == back_width and height == back_height) return;
    if (back_dc == null) back_dc = win.CreateCompatibleDC(hdc);
    const bitmap = win.CreateCompatibleBitmap(hdc, width, height);
    _ = win.SelectObject(back_dc, bitmap);
    if (back_bitmap != null) _ = win.DeleteObject(back_bitmap);
    back_bitmap = bitmap;
    back_width = width;
    back_height = height;
}

fn paint(hwnd: win.Handle) void {
    var ps: win.PaintStruct = .{};
    const hdc = win.BeginPaint(hwnd, &ps);
    defer _ = win.EndPaint(hwnd, &ps);

    var client: win.Rect = .{};
    _ = win.GetClientRect(hwnd, &client);
    if (client.right == 0 or client.bottom == 0) return;
    ensureBackBuffer(hdc, client.right, client.bottom);

    canvas.begin(back_dc, scale, theme.background) catch return;
    const result = app.frame(
        &canvas,
        &state,
        input,
        @as(f32, @floatFromInt(client.right)) / scale,
        @as(f32, @floatFromInt(client.bottom)) / scale,
    );
    canvas.end();
    input.clicked = false;

    _ = win.BitBlt(hdc, 0, 0, client.right, client.bottom, back_dc, 0, 0, win.SRCCOPY);
    want_hand = result.hand;
    _ = win.SetCursor(if (want_hand) cursor_hand else cursor_arrow);
    if (result.changed) _ = win.InvalidateRect(hwnd, null, 0);
}

fn windowProc(hwnd: win.Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        win.WM_DESTROY => {
            win.PostQuitMessage(0);
            return 0;
        },
        win.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_SETCURSOR => {
            _ = win.SetCursor(if (want_hand) cursor_hand else cursor_arrow);
            return 1;
        },
        win.WM_SIZE => {
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_GETMINMAXINFO => {
            const info: *win.MinMaxInfo = @ptrFromInt(@as(usize, @bitCast(lparam)));
            info.ptMinTrackSize = .{
                .x = @intFromFloat(min_width * scale),
                .y = @intFromFloat(min_height * scale),
            };
            return 0;
        },
        win.WM_MOUSEMOVE, win.WM_LBUTTONUP => {
            const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
            const x: i16 = @bitCast(@as(u16, @truncate(bits)));
            const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
            input.mouse_x = @as(f32, @floatFromInt(x)) / scale;
            input.mouse_y = @as(f32, @floatFromInt(y)) / scale;
            if (msg == win.WM_LBUTTONUP) {
                input.clicked = true;
                input.click_x = input.mouse_x;
                input.click_y = input.mouse_y;
            }
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            state.scroll -= @as(f32, @floatFromInt(delta)) / 120 * wheel_step;
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_DPICHANGED => {
            scale = @as(f32, @floatFromInt(wparam & 0xFFFF)) / 96;
            const r: *const win.Rect = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn main() !void {
    _ = win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    var token: usize = 0;
    if (win.GdiplusStartup(&token, &.{}, null) != 0) return error.GdiPlusFailed;
    defer win.GdiplusShutdown(token);

    canvas = try .init();
    defer canvas.deinit();

    cursor_arrow = win.LoadCursorW(null, win.IDC_ARROW);
    cursor_hand = win.LoadCursorW(null, win.IDC_HAND);

    const instance = win.GetModuleHandleW(null);
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZTestWindow");
    const class: win.WndClassEx = .{
        .lpfnWndProc = windowProc,
        .hInstance = instance,
        .hIcon = win.LoadIconW(instance, win.IDI_APP),
        .hCursor = cursor_arrow,
        .lpszClassName = class_name,
    };
    if (win.RegisterClassExW(&class) == 0) return error.RegisterClassFailed;

    const hwnd = win.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("ZTest"),
        win.WS_OVERLAPPEDWINDOW,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        1448,
        1000,
        null,
        null,
        instance,
        null,
    );
    if (hwnd == null) return error.CreateWindowFailed;

    scale = @as(f32, @floatFromInt(win.GetDpiForWindow(hwnd))) / 96;
    const dark: i32 = 1;
    _ = win.DwmSetWindowAttribute(hwnd, win.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(i32));
    _ = win.ShowWindow(hwnd, win.SW_SHOW);

    var msg: win.Msg = .{};
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
}
