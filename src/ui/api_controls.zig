//! Native editing, clipboard, keyboard focus and response scrolling for API Tests.
const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;
const screen = @import("screens/api_test.zig");
const api = @import("api_request.zig");
const theme = @import("theme.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
pub const send_id = 1003;

pub const Controls = struct {
    method: win.Handle = null,
    url: win.Handle = null,
    send: win.Handle = null,
    response: win.Handle = null,
    font: win.Handle = null,
    brush: win.Handle = null,
    scale: f32 = 0,
    visible: bool = false,
    last_view: ?api.View = null,
    last_phase: ?api.Phase = null,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(parent: win.Handle) !Controls {
        var c: Controls = .{};
        errdefer c.deinit();
        c.method = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL, 1001);
        c.url = try child(parent, "EDIT", "http://localhost:3000/", win.ES_AUTOHSCROLL, 1002);
        c.send = try child(parent, "BUTTON", "Send", 0, send_id);
        c.response = try child(parent, "EDIT", "Enter a URL and send a request.", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_READONLY | win.WS_VSCROLL, 1004);
        inline for (api.methods) |method| {
            const label = wide(@tagName(method));
            _ = win.SendMessageW(c.method, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(label)));
        }
        _ = win.SendMessageW(c.method, win.CB_SETCURSEL, 0, 0);
        _ = win.SendMessageW(c.url, win.EM_SETLIMITTEXT, 8192, 0);
        c.brush = win.CreateSolidBrush(rgb(theme.background));
        if (c.brush == null) return error.CreateBrushFailed;
        return c;
    }

    pub fn deinit(c: *Controls) void {
        for ([_]win.Handle{ c.method, c.url, c.send, c.response }) |handle| {
            if (handle != null) _ = win.DestroyWindow(handle);
        }
        if (c.font != null) _ = win.DeleteObject(c.font);
        if (c.brush != null) _ = win.DeleteObject(c.brush);
    }

    pub fn color(c: *Controls, hdc: win.Handle) isize {
        _ = win.SetTextColor(hdc, rgb(theme.text));
        _ = win.SetBkColor(hdc, rgb(theme.background));
        return @bitCast(@intFromPtr(c.brush));
    }

    pub fn sync(c: *Controls, parent: win.Handle, visible: bool, area: Rect, scale: f32) void {
        const revealed = visible and !c.visible;
        if (visible) {
            const resized = c.width != area.w or c.height != area.h or c.scale != scale;
            if (c.scale != scale) c.setFont(scale);
            if (resized or revealed) {
                const boxes = screen.controls(area);
                move(c.method, boxes.method, scale, true);
                move(c.url, boxes.url, scale, false);
                move(c.send, boxes.send, scale, false);
                move(c.response, boxes.response, scale, false);
                c.width = area.w;
                c.height = area.h;
            }
        }
        if (c.visible != visible) {
            if (!visible) {
                const focus = win.GetFocus();
                for ([_]win.Handle{ c.method, c.url, c.send, c.response }) |handle| {
                    if (focus == handle) _ = win.SetFocus(parent);
                }
            }
            for ([_]win.Handle{ c.method, c.url, c.send, c.response }) |handle| {
                _ = win.ShowWindow(handle, if (visible) win.SW_SHOW else win.SW_HIDE);
            }
            c.visible = visible;
            if (revealed) _ = win.SetFocus(c.url);
        }
    }

    pub fn refresh(c: *Controls, session: *const api.Session, view: api.View) void {
        if (c.last_phase == session.phase and c.last_view == view) return;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const text = session.preview(arena.allocator(), view) catch "Could not display the response";
        const utf16 = std.unicode.utf8ToUtf16LeAllocZ(arena.allocator(), text) catch return;
        _ = win.SetWindowTextW(c.response, utf16);
        _ = win.SetWindowTextW(c.send, switch (session.phase) {
            .running => wide("Cancel"),
            .canceling => wide("Canceling..."),
            else => wide("Send"),
        });
        _ = win.EnableWindow(c.send, @intFromBool(session.phase != .canceling));
        _ = win.EnableWindow(c.method, @intFromBool(!session.busy()));
        _ = win.EnableWindow(c.url, @intFromBool(!session.busy()));
        c.last_phase = session.phase;
        c.last_view = view;
    }

    pub fn sendOrCancel(c: *Controls, session: *api.Session) void {
        if (session.busy()) {
            session.cancel();
            return;
        }
        c.last_phase = null;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const length = win.GetWindowTextLengthW(c.url);
        const text = arena.allocator().alloc(u16, @intCast(length + 1)) catch {
            session.phase = .failed;
            session.failure = error.OutOfMemory;
            return;
        };
        const count = win.GetWindowTextW(c.url, text.ptr, @intCast(text.len));
        const url = std.unicode.utf16LeToUtf8Alloc(arena.allocator(), text[0..@intCast(count)]) catch {
            session.phase = .failed;
            session.failure = error.InvalidUrl;
            return;
        };
        const selected = win.SendMessageW(c.method, win.CB_GETCURSEL, 0, 0);
        const index: usize = if (selected >= 0 and selected < api.methods.len) @intCast(selected) else 0;
        session.start(api.methods[index], url, 30_000) catch |err| {
            session.phase = .failed;
            session.failure = if (err == error.OutOfMemory) error.OutOfMemory else error.RequestFailed;
        };
    }

    fn setFont(c: *Controls, scale: f32) void {
        const font = win.CreateFontW(-@as(i32, @intFromFloat(14 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI"));
        if (font == null) return;
        for ([_]win.Handle{ c.method, c.url, c.send, c.response }) |handle| {
            _ = win.SendMessageW(handle, win.WM_SETFONT, @intFromPtr(font), 1);
        }
        if (c.font != null) _ = win.DeleteObject(c.font);
        c.font = font;
        c.scale = scale;
    }
};

fn child(parent: win.Handle, comptime class: []const u8, comptime title: []const u8, style: u32, id: usize) !win.Handle {
    const handle = win.CreateWindowExW(0, wide(class), wide(title), win.WS_CHILD | win.WS_TABSTOP | style, 0, 0, 1, 1, parent, @ptrFromInt(id), win.GetModuleHandleW(null), null);
    return handle orelse error.CreateControlFailed;
}

fn move(handle: win.Handle, r: Rect, scale: f32, combo: bool) void {
    _ = win.SetWindowPos(handle, null, @intFromFloat(r.x * scale), @intFromFloat(r.y * scale), @intFromFloat(r.w * scale), @intFromFloat((if (combo) 240 else r.h) * scale), win.SWP_NOZORDER | win.SWP_NOACTIVATE);
}

fn rgb(argb: u32) u32 {
    return ((argb & 0xFF) << 16) | (argb & 0xFF00) | ((argb >> 16) & 0xFF);
}
