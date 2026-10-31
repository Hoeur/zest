//! Native editing, clipboard, keyboard focus and response scrolling for API Tests.
const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;
const screen = @import("screens/api_test.zig");
const api = @import("api_request.zig");
const theme = @import("theme.zig");
const State = @import("state.zig").State;
const Canvas = @import("canvas.zig").Canvas;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
pub const send_id = 1003;
pub const body_kind_id = 1005;
const request_tab_id = 1100;
const body_mode_id = 1110;
const response_tab_id = 1120;

pub const Controls = struct {
    method: win.Handle = null,
    url: win.Handle = null,
    send: win.Handle = null,
    request_tabs: [5]win.Handle = @splat(null),
    headers: win.Handle = null,
    body_modes: [2]win.Handle = @splat(null),
    body_kind: win.Handle = null,
    body: win.Handle = null,
    response_tabs: [4]win.Handle = @splat(null),
    response: win.Handle = null,
    font: win.Handle = null,
    mono_font: win.Handle = null,
    brush: win.Handle = null,
    scale: f32 = 0,
    visible: bool = false,
    last_view: ?api.View = null,
    last_phase: ?api.Phase = null,
    width: f32 = 0,
    height: f32 = 0,
    body_enabled: bool = false,
    shown: [18]bool = @splat(false),

    pub fn init(parent: win.Handle) !Controls {
        var c: Controls = .{};
        errdefer c.deinit();
        c.method = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL, 1001);
        c.url = try child(parent, "EDIT", "http://localhost:3000/", win.ES_AUTOHSCROLL, 1002);
        c.send = try child(parent, "BUTTON", "Send", win.BS_OWNERDRAW, send_id);
        inline for (screen.request_tab_labels, 0..) |label, i| {
            c.request_tabs[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, request_tab_id + i);
        }
        c.headers = try child(parent, "EDIT", "", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_WANTRETURN | win.WS_VSCROLL, 1006);
        inline for (screen.body_mode_labels, 0..) |label, i| {
            c.body_modes[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, body_mode_id + i);
        }
        c.body_kind = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL, body_kind_id);
        c.body = try child(parent, "EDIT", "", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_WANTRETURN | win.WS_VSCROLL, 1007);
        inline for (screen.response_tab_labels, 0..) |label, i| {
            c.response_tabs[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, response_tab_id + i);
        }
        c.response = try child(parent, "EDIT", "Enter a URL and send a request.", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_READONLY | win.WS_VSCROLL, 1004);
        inline for (api.methods) |method| {
            const label = wide(@tagName(method));
            _ = win.SendMessageW(c.method, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(label)));
        }
        _ = win.SendMessageW(c.method, win.CB_SETCURSEL, 0, 0);
        inline for (.{ "Raw text", "JSON" }) |label| {
            _ = win.SendMessageW(c.body_kind, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(label))));
        }
        _ = win.SendMessageW(c.body_kind, win.CB_SETCURSEL, 1, 0);
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
        if (c.mono_font != null) _ = win.DeleteObject(c.mono_font);
        if (c.brush != null) _ = win.DeleteObject(c.brush);
    }

    pub fn color(c: *Controls, hdc: win.Handle) isize {
        _ = win.SetTextColor(hdc, rgb(theme.text));
        _ = win.SetBkColor(hdc, rgb(theme.background));
        return @bitCast(@intFromPtr(c.brush));
    }

    pub fn sync(c: *Controls, parent: win.Handle, visible: bool, area: Rect, scale: f32, state: *const State) void {
        c.body_enabled = state.body_type == 3;
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
                for (c.request_tabs, screen.requestTabs(area)) |handle, box| move(handle, box, scale, false);
                for (c.body_modes, screen.bodyModes(area)) |handle, box| move(handle, box, scale, false);
                for (c.response_tabs, screen.responseTabs(area)) |handle, box| move(handle, box, scale, false);
                c.width = area.w;
                c.height = area.h;
            }
        }
        for (c.handles(), 0..) |handle, i| {
            const body_control = handle == c.body_kind or handle == c.body or
                handle == c.body_modes[0] or handle == c.body_modes[1];
            const show = visible and (if (handle == c.headers) state.request_tab == 1 else if (body_control) state.request_tab == 3 else true);
            if (show == c.shown[i]) continue;
            if (!show and win.GetFocus() == handle) _ = win.SetFocus(parent);
            _ = win.ShowWindow(handle, if (show) win.SW_SHOW else win.SW_HIDE);
            c.shown[i] = show;
        }
        c.visible = visible;
        if (revealed) _ = win.SetFocus(c.url);
    }

    pub fn refresh(c: *Controls, session: *const api.Session, view: api.View) void {
        for ([_]win.Handle{ c.method, c.url, c.headers }) |handle| {
            _ = win.EnableWindow(handle, @intFromBool(!session.busy()));
        }
        _ = win.EnableWindow(c.body, @intFromBool(!session.busy() and c.bodyKind() != .none));
        _ = win.EnableWindow(c.body_kind, @intFromBool(!session.busy() and c.body_enabled));
        for (c.body_modes) |handle| _ = win.EnableWindow(handle, @intFromBool(!session.busy()));
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
        if (!c.body_enabled) return .none;
        return switch (win.SendMessageW(c.body_kind, win.CB_GETCURSEL, 0, 0)) {
            1 => .json,
            else => .raw,
        };
    }

    /// Native buttons provide Tab/Shift+Tab focus and Space activation for the
    /// custom-painted tabs and body modes, as well as the Send action.
    pub fn drawButton(c: *Controls, canvas: *Canvas, item: *const win.DrawItemStruct, state: *const State) bool {
        const target = c.button(item.hwndItem) orelse return false;
        canvas.begin(item.hDC, c.scale, theme.panel) catch return true;
        defer canvas.end();
        const r: Rect = .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(item.rcItem.right)) / c.scale, .h = @as(f32, @floatFromInt(item.rcItem.bottom)) / c.scale };
        var label: [32]u16 = undefined;
        const count = win.GetWindowTextW(item.hwndItem, &label, label.len);
        var text: [64]u8 = undefined;
        const length = std.unicode.utf16LeToUtf8(&text, label[0..@intCast(count)]) catch 0;
        const disabled = item.itemState & 4 != 0;
        switch (target.kind) {
            .send => {
                canvas.fillRound(r, 8, if (disabled) theme.amber_dim else if (item.itemState & 1 != 0) theme.key else theme.amber);
                canvas.text(.strong, text[0..length], r, .center, if (disabled) theme.muted else theme.on_amber);
            },
            .request_tab, .response_tab => {
                const selected = target.index == if (target.kind == .request_tab) state.request_tab else state.response_tab;
                canvas.text(.body, text[0..length], r, .center, if (selected) theme.amber else theme.muted);
                canvas.line(0, r.h, r.w, r.h, theme.border, 1);
                if (selected) canvas.fill(.{ .x = 0, .y = r.h - 2, .w = r.w, .h = 2 }, theme.amber);
            },
            .body_mode => {
                const selected = state.body_type == (if (target.index == 0) @as(usize, 0) else 3);
                if (selected) canvas.fillRound(r, 6, theme.amber_dim);
                canvas.circle(14, r.h / 2, 7, if (selected) theme.amber else theme.border);
                if (selected) canvas.circle(14, r.h / 2, 3, theme.on_amber);
                canvas.text(.small, text[0..length], .{ .x = 30, .y = 0, .w = r.w - 32, .h = r.h }, .left, if (disabled) theme.muted else theme.text);
            },
        }
        if (item.itemState & 0x10 != 0) canvas.strokeRound(r.inset(3), 5, if (target.kind == .send) theme.on_amber else theme.amber);
        return true;
    }

    /// The same notification handles mouse clicks and keyboard activation.
    pub fn activate(c: *Controls, sender: win.Handle, state: *State, busy: bool) bool {
        const selected = c.button(sender) orelse return false;
        switch (selected.kind) {
            .send => return false,
            .request_tab => state.request_tab = selected.index,
            .response_tab => state.response_tab = selected.index,
            .body_mode => {
                if (busy) return true;
                state.body_type = if (selected.index == 0) 0 else 3;
                c.body_enabled = state.body_type == 3;
            },
        }
        for (c.handles()) |handle| _ = win.InvalidateRect(handle, null, 0);
        return true;
    }

    const Button = struct { kind: enum { send, request_tab, body_mode, response_tab }, index: usize = 0 };

    fn button(c: *const Controls, handle: win.Handle) ?Button {
        if (handle == null) return null;
        if (handle == c.send) return .{ .kind = .send };
        for (c.request_tabs, 0..) |tab, i| if (handle == tab) return .{ .kind = .request_tab, .index = i };
        for (c.body_modes, 0..) |mode, i| if (handle == mode) return .{ .kind = .body_mode, .index = i };
        for (c.response_tabs, 0..) |tab, i| if (handle == tab) return .{ .kind = .response_tab, .index = i };
        return null;
    }

    pub fn isEditor(c: *const Controls, handle: win.Handle) bool {
        return handle == c.url or handle == c.headers or handle == c.body or handle == c.response;
    }

    /// Keep multiline editors and owner-drawn buttons in one predictable tab
    /// order, skipping controls that are hidden or disabled for this request.
    pub fn focusNext(c: *const Controls, reverse: bool) void {
        const all = c.handles();
        const focus = win.GetFocus();
        var index: usize = if (reverse) 0 else all.len - 1;
        for (all, 0..) |handle, i| {
            if (handle == focus) {
                index = i;
                break;
            }
        }
        for (0..all.len) |_| {
            index = (index + if (reverse) all.len - 1 else @as(usize, 1)) % all.len;
            if (c.shown[index] and win.IsWindowEnabled(all[index]) != 0) {
                _ = win.SetFocus(all[index]);
                return;
            }
        }
    }

    fn handles(c: *const Controls) [18]win.Handle {
        return .{ c.method, c.url, c.send } ++ c.request_tabs ++ .{c.headers} ++ c.body_modes ++ .{ c.body_kind, c.body } ++ c.response_tabs ++ .{c.response};
    }

    fn setFont(c: *Controls, scale: f32) void {
        const font = win.CreateFontW(-@as(i32, @intFromFloat(14 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI"));
        if (font == null) return;
        const mono_font = win.CreateFontW(-@as(i32, @intFromFloat(13 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Consolas"));
        for (c.handles()) |handle| {
            const code = handle == c.headers or handle == c.body or handle == c.response;
            _ = win.SendMessageW(handle, win.WM_SETFONT, @intFromPtr(if (code and mono_font != null) mono_font else font), 1);
        }
        if (c.font != null) _ = win.DeleteObject(c.font);
        if (c.mono_font != null) _ = win.DeleteObject(c.mono_font);
        c.font = font;
        c.mono_font = mono_font;
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
