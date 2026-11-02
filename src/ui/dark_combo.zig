//! Paint the closed native combo while retaining its dropdown and keyboard logic.
const std = @import("std");
const win = @import("win32.zig");
const theme = @import("theme.zig");
const Callback = *const fn (win.Handle, u32, usize, isize, usize, usize) callconv(.winapi) isize;
extern "comctl32" fn SetWindowSubclass(win.Handle, Callback, usize, usize) callconv(.winapi) i32;
extern "comctl32" fn DefSubclassProc(win.Handle, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn FillRect(win.Handle, *const win.Rect, win.Handle) callconv(.winapi) i32;
extern "user32" fn FrameRect(win.Handle, *const win.Rect, win.Handle) callconv(.winapi) i32;
extern "user32" fn DrawTextW(win.Handle, [*:0]const u16, i32, *win.Rect, u32) callconv(.winapi) i32;
extern "gdi32" fn SetBkMode(win.Handle, i32) callconv(.winapi) i32;

pub fn install(handle: win.Handle) !void {
    if (SetWindowSubclass(handle, procedure, 1, 0) == 0) return error.SubclassFailed;
}

pub fn drawItem(item: *const win.DrawItemStruct) void {
    const brush = win.CreateSolidBrush(rgb(if (item.itemState & 1 != 0) theme.amber_dim else theme.background));
    defer _ = win.DeleteObject(brush);
    _ = FillRect(item.hDC, &item.rcItem, brush);
    if (item.itemID == 0xFFFFFFFF) return;
    const font = win.SendMessageW(item.hwndItem, 0x0031, 0, 0);
    const old_font = win.SelectObject(item.hDC, @ptrFromInt(@as(usize, @bitCast(font))));
    defer _ = win.SelectObject(item.hDC, old_font);
    _ = SetBkMode(item.hDC, 1);
    _ = win.SetTextColor(item.hDC, rgb(theme.text));
    var label: [64:0]u16 = @splat(0);
    const count = win.SendMessageW(item.hwndItem, 0x0148, item.itemID, @bitCast(@intFromPtr(&label))); // CB_GETLBTEXT
    var box = item.rcItem;
    box.left += 6;
    _ = DrawTextW(item.hDC, &label, @intCast(@max(0, count)), &box, 0x824);
}

fn procedure(handle: win.Handle, message: u32, wparam: usize, lparam: isize, _: usize, _: usize) callconv(.winapi) isize {
    if (message == win.WM_PAINT or message == 0x0318) { // WM_PRINTCLIENT
        var ps: win.PaintStruct = .{};
        const dc = if (message == win.WM_PAINT) win.BeginPaint(handle, &ps) else @as(win.Handle, @ptrFromInt(wparam));
        defer if (message == win.WM_PAINT) {
            _ = win.EndPaint(handle, &ps);
        };
        var box: win.Rect = .{};
        _ = win.GetClientRect(handle, &box);
        const background = win.CreateSolidBrush(rgb(theme.background));
        defer _ = win.DeleteObject(background);
        _ = FillRect(dc, &box, background);
        const border = win.CreateSolidBrush(rgb(if (win.GetFocus() == handle) theme.amber else theme.border));
        defer _ = win.DeleteObject(border);
        _ = FrameRect(dc, &box, border);
        const font = win.SendMessageW(handle, 0x0031, 0, 0); // WM_GETFONT
        const old_font = win.SelectObject(dc, @ptrFromInt(@as(usize, @bitCast(font))));
        defer _ = win.SelectObject(dc, old_font);
        _ = SetBkMode(dc, 1);
        _ = win.SetTextColor(dc, rgb(if (win.IsWindowEnabled(handle) != 0) theme.text else theme.muted));
        const padding = @max(4, @divTrunc(box.bottom, 5));
        var label: [64:0]u16 = @splat(0);
        const count = win.GetWindowTextW(handle, &label, label.len);
        var text_box = box;
        text_box.left += padding;
        text_box.right -= box.bottom;
        _ = DrawTextW(dc, &label, count, &text_box, 0x24 | 0x800); // VCENTER | SINGLELINE | NOPREFIX
        var arrow_box = box;
        arrow_box.left = box.right - box.bottom;
        _ = DrawTextW(dc, std.unicode.utf8ToUtf16LeStringLiteral("▾"), -1, &arrow_box, 0x25);
        return 0;
    }
    const result = DefSubclassProc(handle, message, wparam, lparam);
    if (message == win.WM_SETFONT or message == win.CB_SETCURSEL or message == 0x0007 or message == 0x0008 or message == 0x000A) _ = win.InvalidateRect(handle, null, 0);
    return result;
}

fn rgb(argb: u32) u32 {
    return ((argb & 0xFF) << 16) | (argb & 0xFF00) | ((argb >> 16) & 0xFF);
}
