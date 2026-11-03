//! Native inputs for the pages other than API Tests. A page places a field
//! while it paints, with `Ui.place`; after the frame, `sync` shows the placed
//! fields where they were drawn, follows scrolling, and hides the rest.

const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;
const dark_combo = @import("dark_combo.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Id = enum {
    load_url,
    load_users,
    load_duration,
    load_duration_unit,
    load_ramp,
    load_ramp_unit,
    load_method,
    load_rps,
    load_assert,
    suite_search,
    result_search,
    global_search,
};

pub const Placement = struct { id: Id, rect: Rect };

pub const units = [_][]const u8{ "sec", "min", "hr" };
pub const unit_ms = [_]u64{ std.time.ms_per_s, std.time.ms_per_min, std.time.ms_per_hour };
pub const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

const first_id = 1300;
const count = std.enums.values(Id).len;

fn isCombo(id: Id) bool {
    return switch (id) {
        .load_duration_unit, .load_ramp_unit, .load_method => true,
        else => false,
    };
}

fn initial(id: Id) []const u8 {
    return switch (id) {
        .load_url => "{{baseUrl}}/",
        .load_users => "10",
        .load_duration => "1",
        .load_ramp => "0",
        .load_assert => "status == 200",
        else => "",
    };
}

pub const Fields = struct {
    handles: [count]win.Handle = @splat(null),
    shown: [count]bool = @splat(false),
    placed: [count]?Rect = @splat(null),
    scale: f32 = 0,
    font: win.Handle = null,

    pub fn init(parent: win.Handle) !Fields {
        var f: Fields = .{};
        errdefer f.deinit();
        for (std.enums.values(Id), 0..) |id, i| {
            const style: u32 = if (isCombo(id)) win.CBS_DROPDOWNLIST | win.WS_VSCROLL | 0x0210 else win.ES_AUTOHSCROLL;
            const class = if (isCombo(id)) wide("COMBOBOX") else wide("EDIT");
            var label: [64]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(label[0..63], initial(id)) catch 0;
            label[len] = 0;
            f.handles[i] = win.CreateWindowExW(0, class, @ptrCast(&label), win.WS_CHILD | win.WS_TABSTOP | style, 0, 0, 1, 1, parent, @ptrFromInt(first_id + i), win.GetModuleHandleW(null), null) orelse return error.CreateControlFailed;
            if (isCombo(id)) try dark_combo.install(f.handles[i]);
        }
        for ([_]Id{ .load_duration_unit, .load_ramp_unit }) |id| {
            inline for (units) |label| _ = win.SendMessageW(f.get(id), win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(label))));
        }
        inline for (methods) |label| _ = win.SendMessageW(f.get(.load_method), win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(label))));
        f.select(.load_duration_unit, 1);
        f.select(.load_ramp_unit, 0);
        f.select(.load_method, 0);
        for (f.handles) |handle| _ = win.SendMessageW(handle, win.EM_SETLIMITTEXT, 4096, 0);
        return f;
    }

    pub fn deinit(f: *Fields) void {
        for (f.handles) |handle| {
            if (handle != null) _ = win.DestroyWindow(handle);
        }
        if (f.font != null) _ = win.DeleteObject(f.font);
    }

    pub fn get(f: *const Fields, id: Id) win.Handle {
        return f.handles[@backingInt(id)];
    }

    pub fn owns(f: *const Fields, handle: win.Handle) bool {
        return f.idOf(handle) != null;
    }

    pub fn idOf(f: *const Fields, handle: win.Handle) ?Id {
        if (handle == null) return null;
        for (f.handles, 0..) |h, i| {
            if (h == handle) return @fromBackingInt(@intCast(i));
        }
        return null;
    }

    /// Shows each placed field inside `clip`, and hides the others.
    pub fn sync(f: *Fields, parent: win.Handle, placements: []const Placement, clip: Rect, scale: f32) void {
        if (scale != f.scale) f.setFont(scale);
        var wanted: [count]?Rect = @splat(null);
        for (placements) |p| {
            const r = p.rect;
            // With room for the painted frame around it, which the bars cover.
            // The top bar's search is outside the page and never scrolls.
            const fixed = p.id == .global_search;
            if (fixed or (r.y - 12 >= clip.y and r.bottom() + 12 <= clip.bottom())) wanted[@backingInt(p.id)] = r;
        }
        for (f.handles, wanted, 0..) |handle, rect, i| {
            const show = rect != null;
            if (rect) |r| {
                const same = if (f.placed[i]) |old| old.x == r.x and old.y == r.y and old.w == r.w and old.h == r.h else false;
                if (!same or !f.shown[i]) {
                    const combo = isCombo(@fromBackingInt(@intCast(i)));
                    _ = win.SetWindowPos(handle, null, @intFromFloat(r.x * scale), @intFromFloat(r.y * scale), @intFromFloat(r.w * scale), @intFromFloat((if (combo) 220 else r.h) * scale), win.SWP_NOZORDER | win.SWP_NOACTIVATE);
                    f.placed[i] = r;
                }
            }
            if (show == f.shown[i]) continue;
            if (!show and win.GetFocus() == handle) _ = win.SetFocus(parent);
            _ = win.ShowWindow(handle, if (show) win.SW_SHOW else win.SW_HIDE);
            f.shown[i] = show;
        }
    }

    pub fn hideAll(f: *Fields, parent: win.Handle) void {
        f.sync(parent, &.{}, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, f.scale);
    }

    /// Owned by `allocator`.
    pub fn text(f: *const Fields, allocator: std.mem.Allocator, id: Id) ![]const u8 {
        const handle = f.get(id);
        const length = win.GetWindowTextLengthW(handle);
        const buffer = try allocator.alloc(u16, @intCast(length + 1));
        defer allocator.free(buffer);
        const n = win.GetWindowTextW(handle, buffer.ptr, @intCast(buffer.len));
        return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..@intCast(n)]);
    }

    pub fn setText(f: *Fields, id: Id, value: []const u8) void {
        var buffer: [1024]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(buffer[0 .. buffer.len - 1], value[0..@min(value.len, 1000)]) catch return;
        buffer[len] = 0;
        _ = win.SetWindowTextW(f.get(id), @ptrCast(&buffer));
    }

    pub fn selected(f: *const Fields, id: Id) usize {
        const index = win.SendMessageW(f.get(id), win.CB_GETCURSEL, 0, 0);
        return if (index < 0) 0 else @intCast(index);
    }

    pub fn select(f: *Fields, id: Id, index: usize) void {
        _ = win.SendMessageW(f.get(id), win.CB_SETCURSEL, index, 0);
    }

    pub fn enable(f: *Fields, ids: []const Id, enabled: bool) void {
        for (ids) |id| _ = win.EnableWindow(f.get(id), @intFromBool(enabled));
    }

    fn setFont(f: *Fields, scale: f32) void {
        const font = win.CreateFontW(-@as(i32, @intFromFloat(14 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI"));
        if (font == null) return;
        for (f.handles, 0..) |handle, i| {
            _ = win.SendMessageW(handle, win.WM_SETFONT, @intFromPtr(font), 1);
            if (isCombo(@fromBackingInt(@intCast(i)))) {
                _ = win.SendMessageW(handle, 0x0153, ~@as(usize, 0), @intFromFloat(26 * scale)); // CB_SETITEMHEIGHT
                _ = win.SendMessageW(handle, 0x0153, 0, @intFromFloat(26 * scale));
            }
        }
        if (f.font != null) _ = win.DeleteObject(f.font);
        f.font = font;
        f.scale = scale;
        f.placed = @splat(null);
    }
};

/// A number typed in a field, or null when it is not one.
pub fn number(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

const testing = std.testing;

test "numbers are read from field text" {
    try testing.expectEqual(@as(?u64, 500), number(" 500 "));
    try testing.expectEqual(@as(?u64, null), number("5x"));
    try testing.expectEqual(@as(?u64, null), number(""));
}
