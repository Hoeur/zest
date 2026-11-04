//! Small Win32 services the pages share: popup menus, the clipboard and local
//! time.

const std = @import("std");
const win = @import("win32.zig");
const timefmt = @import("timefmt.zig");

pub const Item = struct {
    label: []const u8,
    enabled: bool = true,
    checked: bool = false,
    /// Draws a separator instead of an item.
    separator: bool = false,
};

/// Shows a menu at `x`, `y` in the window's client pixels and returns the
/// chosen index, or null when the menu is dismissed.
pub fn pick(hwnd: win.Handle, x: i32, y: i32, items: []const Item) ?usize {
    const menu = win.CreatePopupMenu() orelse return null;
    defer _ = win.DestroyMenu(menu);
    var buffer: [128]u16 = undefined;
    for (items, 1..) |item, id| {
        if (item.separator) {
            _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
            continue;
        }
        const len = std.unicode.wtf8ToWtf16Le(buffer[0 .. buffer.len - 1], clip(item.label)) catch continue;
        buffer[len] = 0;
        var flags: u32 = win.MF_STRING;
        if (!item.enabled) flags |= win.MF_GRAYED;
        if (item.checked) flags |= win.MF_CHECKED;
        _ = win.AppendMenuW(menu, flags, id, @ptrCast(&buffer));
    }
    var point: win.Point = .{ .x = x, .y = y };
    _ = win.ClientToScreen(hwnd, &point);
    const chosen = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, point.x, point.y, 0, hwnd, null);
    if (chosen <= 0) return null;
    return @intCast(chosen - 1);
}

fn clip(text: []const u8) []const u8 {
    if (text.len <= 120) return text;
    var end: usize = 120;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// Asks Windows 10 1809 and later to draw popup menus dark, as the rest of
/// the app is. Uses uxtheme's unnamed exports (135 SetPreferredAppMode, 136
/// FlushMenuThemes); without them menus stay light.
pub fn darkMenus() void {
    const windows = std.os.windows;
    var info: windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    if (windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return;
    // The exports have these meanings from build 17763 on.
    if (info.dwMajorVersion < 10 or info.dwBuildNumber < 17763) return;
    const module = win.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll")) orelse return;
    const set_mode: *const fn (i32) callconv(.winapi) i32 = @ptrCast(@alignCast(win.GetProcAddress(module, @ptrFromInt(135)) orelse return));
    _ = set_mode(2); // Force dark.
    const flush: *const fn () callconv(.winapi) void = @ptrCast(@alignCast(win.GetProcAddress(module, @ptrFromInt(136)) orelse return));
    flush();
}

/// Puts `text` on the clipboard. False when Windows refuses.
pub fn copy(hwnd: win.Handle, allocator: std.mem.Allocator, text: []const u8) bool {
    const utf16 = std.unicode.wtf8ToWtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);
    const bytes = (utf16.len + 1) * 2;
    const memory = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes) orelse return false;
    const target: [*]u16 = @ptrCast(@alignCast(win.GlobalLock(memory) orelse {
        _ = win.GlobalFree(memory);
        return false;
    }));
    @memcpy(target[0 .. utf16.len + 1], utf16.ptr[0 .. utf16.len + 1]);
    _ = win.GlobalUnlock(memory);
    if (win.OpenClipboard(hwnd) == 0) {
        _ = win.GlobalFree(memory);
        return false;
    }
    defer _ = win.CloseClipboard();
    _ = win.EmptyClipboard();
    // The clipboard owns the memory once this succeeds.
    if (win.SetClipboardData(win.CF_UNICODETEXT, memory) == null) {
        _ = win.GlobalFree(memory);
        return false;
    }
    return true;
}

/// The local time zone's offset from UTC at `unix`, in seconds.
pub fn utcOffset(unix: i64) i64 {
    const utc = fileTime(unix);
    var here: win.FileTime = .{};
    if (win.FileTimeToLocalFileTime(&utc, &here) == 0) return 0;
    const a = (@as(i64, utc.high) << 32) | utc.low;
    const b = (@as(i64, here.high) << 32) | here.low;
    return @divTrunc(b - a, 10_000_000);
}

/// `unix` as local date parts.
pub fn local(unix: i64) timefmt.Parts {
    return timefmt.partsOf(unix + utcOffset(unix));
}

fn fileTime(unix: i64) win.FileTime {
    const ticks: u64 = @intCast(@max(0, (unix + 11_644_473_600) * 10_000_000));
    return .{ .low = @truncate(ticks), .high = @truncate(ticks >> 32) };
}
