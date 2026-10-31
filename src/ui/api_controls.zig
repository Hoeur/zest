//! Native editing, clipboard, keyboard focus and response scrolling for API Tests.
const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;
const screen = @import("screens/api_test.zig");
const api = @import("api_request.zig");
const theme = @import("theme.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
pub const send_id = 1003;
pub const body_kind_id = 1005;

pub const Controls = struct {
    method: win.Handle = null,
    url: win.Handle = null,
    send: win.Handle = null,
    headers: win.Handle = null,
    body_kind: win.Handle = null,
    body: win.Handle = null,
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
        c.headers = try child(parent, "EDIT", "", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_WANTRETURN | win.WS_VSCROLL, 1006);
        c.body_kind = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL, body_kind_id);
        c.body = try child(parent, "EDIT", "", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_WANTRETURN | win.WS_VSCROLL, 1007);
        c.response = try child(parent, "EDIT", "Enter a URL and send a request.", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_READONLY | win.WS_VSCROLL, 1004);
        inline for (api.methods) |method| {
            const label = wide(@tagName(method));
            _ = win.SendMessageW(c.method, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(label)));
        }
        _ = win.SendMessageW(c.method, win.CB_SETCURSEL, 0, 0);
        inline for (.{ "None", "Raw", "JSON" }) |label| {
            _ = win.SendMessageW(c.body_kind, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(label))));
        }
        _ = win.SendMessageW(c.body_kind, win.CB_SETCURSEL, 0, 0);
        _ = win.SendMessageW(c.url, win.EM_SETLIMITTEXT, 8192, 0);
        _ = win.SendMessageW(c.headers, win.EM_SETLIMITTEXT, 8192, 0);
        _ = win.SendMessageW(c.body, win.EM_SETLIMITTEXT, 65536, 0);
        c.brush = win.CreateSolidBrush(rgb(theme.background));
        if (c.brush == null) return error.CreateBrushFailed;
        return c;
    }

    pub fn deinit(c: *Controls) void {
        for (c.handles()) |handle| {
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
                move(c.headers, boxes.headers, scale, false);
                move(c.body_kind, boxes.body_kind, scale, true);
                move(c.body, boxes.body, scale, false);
                move(c.response, boxes.response, scale, false);
                c.width = area.w;
                c.height = area.h;
            }
        }
        if (c.visible != visible) {
            if (!visible) {
                const focus = win.GetFocus();
                for (c.handles()) |handle| {
                    if (focus == handle) _ = win.SetFocus(parent);
                }
            }
            for (c.handles()) |handle| {
                _ = win.ShowWindow(handle, if (visible) win.SW_SHOW else win.SW_HIDE);
            }
            c.visible = visible;
            if (revealed) _ = win.SetFocus(c.url);
        }
    }

    pub fn refresh(c: *Controls, session: *const api.Session, view: api.View) void {
        for ([_]win.Handle{ c.method, c.url, c.headers, c.body_kind }) |handle| {
            _ = win.EnableWindow(handle, @intFromBool(!session.busy()));
        }
        _ = win.EnableWindow(c.body, @intFromBool(!session.busy() and c.bodyKind() != .none));
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
        c.last_phase = session.phase;
        c.last_view = view;
    }

    pub fn sendOrCancel(c: *Controls, session: *api.Session) void {
        if (session.busy()) {
            session.cancel();
            return;
        }
        c.last_phase = null;
        session.input_message = null;
        session.failure = null;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        c.readAndStart(session, arena.allocator()) catch |err| {
            session.phase = .failed;
            if (session.input_message == null and session.failure == null) {
                session.failure = if (err == error.OutOfMemory) error.OutOfMemory else error.RequestFailed;
            }
        };
    }

    fn readAndStart(c: *Controls, session: *api.Session, allocator: std.mem.Allocator) !void {
        const url = try readText(allocator, c.url);
        const headers = try readText(allocator, c.headers);
        const body = try readText(allocator, c.body);
        const selected = win.SendMessageW(c.method, win.CB_GETCURSEL, 0, 0);
        const index: usize = if (selected >= 0 and selected < api.methods.len) @intCast(selected) else 0;
        try session.startDraft(.{ .method = api.methods[index], .url = url, .headers = headers, .body_kind = c.bodyKind(), .body = body }, 30_000);
    }

    fn bodyKind(c: *const Controls) api.draft.BodyKind {
        return switch (win.SendMessageW(c.body_kind, win.CB_GETCURSEL, 0, 0)) {
            1 => .raw,
            2 => .json,
            else => .none,
        };
    }

    pub fn isEditor(c: *const Controls, handle: win.Handle) bool {
        return handle == c.url or handle == c.headers or handle == c.body or handle == c.response;
    }

    fn handles(c: *const Controls) [7]win.Handle {
        return .{ c.method, c.url, c.send, c.headers, c.body_kind, c.body, c.response };
    }

    fn setFont(c: *Controls, scale: f32) void {
        const font = win.CreateFontW(-@as(i32, @intFromFloat(14 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI"));
        if (font == null) return;
        for (c.handles()) |handle| {
            _ = win.SendMessageW(handle, win.WM_SETFONT, @intFromPtr(font), 1);
        }
        if (c.font != null) _ = win.DeleteObject(c.font);
        c.font = font;
        c.scale = scale;
    }
};

fn readText(allocator: std.mem.Allocator, handle: win.Handle) ![]const u8 {
    const length = win.GetWindowTextLengthW(handle);
    const text = try allocator.alloc(u16, @intCast(length + 1));
    const count = win.GetWindowTextW(handle, text.ptr, @intCast(text.len));
    return std.unicode.utf16LeToUtf8Alloc(allocator, text[0..@intCast(count)]);
}

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
