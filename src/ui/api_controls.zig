//! Native editing, clipboard, keyboard focus and response scrolling for API Tests.
const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;
const screen = @import("screens/api_test.zig");
const api = @import("api_request.zig");
const theme = @import("theme.zig");
const State = @import("state.zig").State;
const Canvas = @import("canvas.zig").Canvas;
const Workspace = @import("workspace.zig").Workspace;
const rich = @import("rich_edit.zig");
const dark_combo = @import("dark_combo.zig");
const draft = api.draft;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
pub const send_id = 1003;
pub const body_kind_id = 1005;
pub const auth_kind_id = 1008;
pub const auth_value_id = 1010;
const request_tab_id = 1100;
const body_mode_id = 1110;
const response_tab_id = 1120;
const handle_count = 23;
/// The bullet ES_PASSWORD shows in place of each character.
const password_char = 0x25CF;

pub const Controls = struct {
    method: win.Handle = null,
    url: win.Handle = null,
    send: win.Handle = null,
    request_tabs: [5]win.Handle = @splat(null),
    params: win.Handle = null,
    headers: win.Handle = null,
    auth_kind: win.Handle = null,
    auth_name: win.Handle = null,
    auth_value: win.Handle = null,
    body_modes: [2]win.Handle = @splat(null),
    body_kind: win.Handle = null,
    body: win.Handle = null,
    tests: win.Handle = null,
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
    shown: [handle_count]bool = @splat(false),
    rich_library: ?rich.Library = null,
    coloring: bool = false,
    body_editable: bool = false,
    /// Focused at the end of the next `sync`, once it is visible.
    pending_focus: win.Handle = null,
    /// Holds a message the session shows but does not own.
    message_buffer: [320]u8 = undefined,

    pub fn init(parent: win.Handle) !Controls {
        var c: Controls = .{};
        errdefer c.deinit();
        c.rich_library = rich.Library.init();
        const editor_style = win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_WANTRETURN | win.WS_VSCROLL;
        c.method = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL | 0x0210, 1001); // OWNERDRAWFIXED | HASSTRINGS
        c.url = try child(parent, "EDIT", "http://localhost:3000/", win.ES_AUTOHSCROLL, 1002);
        c.send = try child(parent, "BUTTON", "Send", win.BS_OWNERDRAW, send_id);
        inline for (screen.request_tab_labels, 0..) |label, i| {
            c.request_tabs[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, request_tab_id + i);
        }
        c.params = try child(parent, "EDIT", "", editor_style, 1011);
        c.headers = try child(parent, "EDIT", "", editor_style, 1006);
        c.auth_kind = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL | 0x0210, auth_kind_id);
        c.auth_name = try child(parent, "EDIT", "", win.ES_AUTOHSCROLL, 1009);
        c.auth_value = try child(parent, "EDIT", "", win.ES_AUTOHSCROLL | win.ES_PASSWORD, auth_value_id);
        inline for (screen.body_mode_labels, 0..) |label, i| {
            c.body_modes[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, body_mode_id + i);
        }
        c.body_kind = try child(parent, "COMBOBOX", "", win.CBS_DROPDOWNLIST | win.WS_VSCROLL | 0x0210, body_kind_id);
        c.body = if (c.rich_library != null)
            try child(parent, "RICHEDIT50W", "", editor_style, 1007)
        else
            try child(parent, "EDIT", "", editor_style, 1007);
        c.tests = try child(parent, "EDIT", "status == 200\r\n", editor_style, 1012);
        inline for (screen.response_tab_labels, 0..) |label, i| {
            c.response_tabs[i] = try child(parent, "BUTTON", label, win.BS_OWNERDRAW, response_tab_id + i);
        }
        c.response = if (c.rich_library != null)
            try child(parent, "RICHEDIT50W", "Enter a URL and send a request.", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_READONLY | win.WS_VSCROLL, 1004)
        else
            try child(parent, "EDIT", "Enter a URL and send a request.", win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.ES_READONLY | win.WS_VSCROLL, 1004);
        if (c.rich_library != null) {
            rich.configure(c.body, true);
            rich.configure(c.response, false);
        }
        try dark_combo.install(c.method);
        try dark_combo.install(c.body_kind);
        try dark_combo.install(c.auth_kind);
        inline for (api.methods) |method| {
            const label = wide(@tagName(method));
            _ = win.SendMessageW(c.method, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(label)));
        }
        _ = win.SendMessageW(c.method, win.CB_SETCURSEL, 0, 0);
        inline for (.{ "Raw text", "JSON" }) |label| {
            _ = win.SendMessageW(c.body_kind, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(label))));
        }
        _ = win.SendMessageW(c.body_kind, win.CB_SETCURSEL, 1, 0);
        inline for (comptime std.enums.values(draft.AuthKind)) |kind| {
            _ = win.SendMessageW(c.auth_kind, win.CB_ADDSTRING, 0, @bitCast(@intFromPtr(wide(kind.label()))));
        }
        _ = win.SendMessageW(c.auth_kind, win.CB_SETCURSEL, 0, 0);
        _ = win.SendMessageW(c.url, win.EM_SETLIMITTEXT, 8192, 0);
        for ([_]win.Handle{ c.headers, c.params, c.tests }) |editor| _ = win.SendMessageW(editor, win.EM_SETLIMITTEXT, 16384, 0);
        for ([_]win.Handle{ c.auth_name, c.auth_value }) |field| _ = win.SendMessageW(field, win.EM_SETLIMITTEXT, 4096, 0);
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
        if (c.rich_library) |library| library.deinit();
    }

    pub fn recolorBody(c: *Controls) void {
        if (c.rich_library == null or c.coloring) return;
        c.coloring = true;
        defer c.coloring = false;
        rich.highlight(c.body, c.bodyKind() == .json);
    }

    pub fn changed(c: *Controls, sender: win.Handle) void {
        if (sender == c.body) c.recolorBody();
        if (sender == c.auth_value) c.updateMask();
    }

    /// A key written as `{{name}}` is shown, because it is not the secret
    /// itself; anything else stays masked.
    fn updateMask(c: *Controls) void {
        var buffer: [4097]u16 = undefined;
        const count = win.GetWindowTextW(c.auth_value, &buffer, buffer.len);
        const text = buffer[0..@intCast(@max(0, count))];
        const is_variable = text.len >= 4 and text[0] == '{' and text[1] == '{' and text[text.len - 1] == '}' and text[text.len - 2] == '}';
        _ = win.SendMessageW(c.auth_value, win.EM_SETPASSWORDCHAR, if (is_variable) 0 else password_char, 0);
        _ = win.InvalidateRect(c.auth_value, null, 1);
    }

    pub fn color(c: *Controls, hdc: win.Handle) isize {
        _ = win.SetTextColor(hdc, rgb(theme.text));
        _ = win.SetBkColor(hdc, rgb(theme.background));
        return @bitCast(@intFromPtr(c.brush));
    }

    pub fn sync(c: *Controls, parent: win.Handle, visible: bool, area: Rect, scale: f32, state: *State) void {
        c.body_enabled = state.body_type == 3;
        state.auth_kind = c.authIndex();
        const revealed = visible and !c.visible;
        if (visible) {
            const resized = c.width != area.w or c.height != area.h or c.scale != scale;
            if (c.scale != scale) c.setFont(scale);
            if (resized or revealed) {
                const boxes = screen.controls(area);
                move(c.method, boxes.method, scale, true);
                move(c.url, boxes.url, scale, false);
                move(c.send, boxes.send, scale, false);
                move(c.params, boxes.params, scale, false);
                move(c.headers, boxes.headers, scale, false);
                move(c.auth_kind, boxes.auth_kind, scale, true);
                move(c.auth_name, boxes.auth_name, scale, false);
                move(c.auth_value, boxes.auth_value, scale, false);
                move(c.body_kind, boxes.body_kind, scale, true);
                move(c.body, boxes.body, scale, false);
                move(c.tests, boxes.tests, scale, false);
                move(c.response, boxes.response, scale, false);
                for (c.request_tabs, screen.requestTabs(area)) |handle, box| move(handle, box, scale, false);
                for (c.body_modes, screen.bodyModes(area)) |handle, box| move(handle, box, scale, false);
                for (c.response_tabs, screen.responseTabs(area)) |handle, box| move(handle, box, scale, false);
                c.width = area.w;
                c.height = area.h;
            }
        }
        const fields = screen.auth_kinds[state.auth_kind].fields();
        for (c.handles(), 0..) |handle, i| {
            const tab: ?usize = if (handle == c.params)
                0
            else if (handle == c.headers)
                1
            else if (handle == c.auth_kind)
                2
            else if (handle == c.auth_name)
                (if (fields[0] != null) @as(usize, 2) else 99)
            else if (handle == c.auth_value)
                (if (fields[1] != null) @as(usize, 2) else 99)
            else if (handle == c.body_kind or handle == c.body or handle == c.body_modes[0] or handle == c.body_modes[1])
                3
            else if (handle == c.tests)
                4
            else
                null;
            const show = visible and (if (tab) |t| state.request_tab == t else true);
            if (show == c.shown[i]) continue;
            if (!show and win.GetFocus() == handle) _ = win.SetFocus(parent);
            _ = win.ShowWindow(handle, if (show) win.SW_SHOW else win.SW_HIDE);
            c.shown[i] = show;
        }
        c.visible = visible;
        if (revealed) _ = win.SetFocus(c.url);
        if (visible and c.pending_focus != null) {
            _ = win.SetFocus(c.pending_focus);
            _ = win.SendMessageW(c.pending_focus, win.EM_SETSEL, std.math.maxInt(usize), -1);
            c.pending_focus = null;
        }
    }

    pub fn refresh(c: *Controls, session: *const api.Session, view: api.View) void {
        const idle = !session.busy();
        for ([_]win.Handle{ c.method, c.url, c.headers, c.params, c.tests, c.auth_kind, c.auth_name, c.auth_value }) |handle| {
            _ = win.EnableWindow(handle, @intFromBool(idle));
        }
        c.body_editable = idle and c.bodyKind() != .none;
        if (c.rich_library != null) {
            _ = win.SendMessageW(c.body, 0x00CF, @intFromBool(!c.body_editable), 0); // EM_SETREADONLY avoids the system gray disabled background.
        } else _ = win.EnableWindow(c.body, @intFromBool(c.body_editable));
        _ = win.EnableWindow(c.body_kind, @intFromBool(idle and c.body_enabled));
        for (c.body_modes) |handle| _ = win.EnableWindow(handle, @intFromBool(idle));
        if (c.last_phase == session.phase and c.last_view == view) return;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const text = session.preview(arena.allocator(), view) catch "Could not display the response";
        const utf16 = std.unicode.utf8ToUtf16LeAllocZ(arena.allocator(), text) catch return;
        _ = win.SetWindowTextW(c.response, utf16);
        if (c.rich_library != null) {
            const valid_json = if (view == .body) blk: {
                const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{}) catch break :blk false;
                parsed.deinit();
                break :blk true;
            } else false;
            rich.highlight(c.response, valid_json);
        }
        _ = win.SetWindowTextW(c.send, switch (session.phase) {
            .running => wide("Cancel"),
            .canceling => wide("Canceling..."),
            else => wide("Send"),
        });
        _ = win.EnableWindow(c.send, @intFromBool(session.phase != .canceling));
        c.last_phase = session.phase;
        c.last_view = view;
    }

    /// Starts the request with the workspace's variables, or cancels one.
    pub fn sendOrCancel(c: *Controls, session: *api.Session, workspace: *const Workspace) void {
        if (session.busy()) {
            session.cancel();
            return;
        }
        c.last_phase = null;
        session.input_message = null;
        session.failure = null;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        c.readAndStart(session, workspace, arena.allocator()) catch |err| {
            session.phase = .failed;
            if (session.input_message == null and session.failure == null) {
                session.failure = if (err == error.OutOfMemory) error.OutOfMemory else error.RequestFailed;
            }
        };
    }

    fn readAndStart(c: *Controls, session: *api.Session, workspace: *const Workspace, allocator: std.mem.Allocator) !void {
        var source = try c.readDraft(allocator);
        var problem: []const u8 = "";
        source.variables = workspace.variables(allocator, &problem) catch |err| {
            if (err == error.InvalidEnvironment) {
                // `problem` lives in this call's arena, so it is copied.
                session.input_message = std.fmt.bufPrint(&c.message_buffer, "{s}", .{problem}) catch "The environment is incomplete";
                session.phase = .failed;
            }
            return err;
        };
        try session.startDraft(source, 30_000);
    }

    /// Everything in the editors, as typed. Owned by `allocator`.
    pub fn readDraft(c: *const Controls, allocator: std.mem.Allocator) !draft.Draft {
        const selected = win.SendMessageW(c.method, win.CB_GETCURSEL, 0, 0);
        const index: usize = if (selected >= 0 and selected < api.methods.len) @intCast(selected) else 0;
        return .{
            .method = api.methods[index],
            .url = try readText(allocator, c.url),
            .headers = try readText(allocator, c.headers),
            .params = try readText(allocator, c.params),
            .auth = .{
                .kind = screen.auth_kinds[c.authIndex()],
                .name = try readText(allocator, c.auth_name),
                .value = try readText(allocator, c.auth_value),
            },
            .body_kind = c.bodyKind(),
            .body = if (c.rich_library != null) try rich.read(allocator, c.body) else try readText(allocator, c.body),
            .assertions = try readText(allocator, c.tests),
        };
    }

    /// Puts an opened request into the editors.
    pub fn loadDraft(c: *Controls, source: draft.Draft, state: *State) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for (api.methods, 0..) |method, i| {
            if (method == source.method) _ = win.SendMessageW(c.method, win.CB_SETCURSEL, i, 0);
        }
        setText(a, c.url, source.url);
        setText(a, c.headers, source.headers);
        setText(a, c.params, source.params);
        setText(a, c.tests, source.assertions);
        const auth_index = std.mem.findScalar(draft.AuthKind, screen.auth_kinds, source.auth.kind) orelse 0;
        _ = win.SendMessageW(c.auth_kind, win.CB_SETCURSEL, auth_index, 0);
        setText(a, c.auth_name, source.auth.name);
        setText(a, c.auth_value, source.auth.value);
        c.updateMask();
        state.body_type = if (source.body_kind == .none) 0 else 3;
        c.body_enabled = state.body_type == 3;
        if (source.body_kind != .none) _ = win.SendMessageW(c.body_kind, win.CB_SETCURSEL, @intFromBool(source.body_kind == .json), 0);
        setText(a, c.body, source.body);
        c.recolorBody();
        state.auth_kind = auth_index;
        state.request_tab = if (source.body_kind != .none) 3 else if (source.params.len > 0) 0 else 1;
        c.last_phase = null;
        for (c.handles()) |handle| _ = win.InvalidateRect(handle, null, 0);
    }

    /// Empties the editors for a new request.
    pub fn clear(c: *Controls, state: *State) void {
        c.loadDraft(.{ .url = "http://localhost:3000/", .assertions = "status == 200\r\n" }, state);
        state.request_tab = 0;
    }

    pub fn authIndex(c: *const Controls) usize {
        const selected = win.SendMessageW(c.auth_kind, win.CB_GETCURSEL, 0, 0);
        return if (selected >= 0 and selected < screen.auth_kinds.len) @intCast(selected) else 0;
    }

    fn bodyKind(c: *const Controls) draft.BodyKind {
        if (!c.body_enabled) return .none;
        return switch (win.SendMessageW(c.body_kind, win.CB_GETCURSEL, 0, 0)) {
            1 => .json,
            else => .raw,
        };
    }

    /// Native buttons provide Tab/Shift+Tab focus and Space activation for the
    /// custom-painted tabs and body modes, as well as the Send action.
    pub fn drawButton(c: *Controls, canvas: *Canvas, item: *const win.DrawItemStruct, state: *const State) bool {
        if (item.CtlType == 3 and (item.hwndItem == c.method or item.hwndItem == c.body_kind or item.hwndItem == c.auth_kind)) {
            dark_combo.drawItem(item);
            return true;
        }
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
                c.recolorBody();
            },
        }
        for (c.handles()) |handle| _ = win.InvalidateRect(handle, null, 0);
        return true;
    }

    /// Shows the Tests editor and puts the caret at its end.
    pub fn focusTests(c: *Controls, state: *State) void {
        state.request_tab = 4;
        c.pending_focus = c.tests;
        for (c.handles()) |handle| _ = win.InvalidateRect(handle, null, 0);
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
        return handle != null and (handle == c.url or handle == c.headers or handle == c.params or handle == c.tests or
            handle == c.auth_name or handle == c.auth_value or handle == c.body or handle == c.response);
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
            if (c.shown[index] and win.IsWindowEnabled(all[index]) != 0 and (all[index] != c.body or c.body_editable)) {
                _ = win.SetFocus(all[index]);
                return;
            }
        }
    }

    fn handles(c: *const Controls) [handle_count]win.Handle {
        return .{ c.method, c.url, c.send } ++ c.request_tabs ++
            .{ c.params, c.headers, c.auth_kind, c.auth_name, c.auth_value } ++
            c.body_modes ++ .{ c.body_kind, c.body, c.tests } ++ c.response_tabs ++ .{c.response};
    }

    fn setFont(c: *Controls, scale: f32) void {
        const font = win.CreateFontW(-@as(i32, @intFromFloat(14 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI"));
        if (font == null) return;
        const mono_font = win.CreateFontW(-@as(i32, @intFromFloat(13 * scale)), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, wide("Consolas"));
        for (c.handles()) |handle| {
            const code = handle == c.headers or handle == c.params or handle == c.tests or handle == c.body or
                handle == c.response or handle == c.auth_name or handle == c.auth_value;
            _ = win.SendMessageW(handle, win.WM_SETFONT, @intFromPtr(if (code and mono_font != null) mono_font else font), 1);
        }
        if (c.font != null) _ = win.DeleteObject(c.font);
        if (c.mono_font != null) _ = win.DeleteObject(c.mono_font);
        c.font = font;
        c.mono_font = mono_font;
        c.scale = scale;
        if (c.rich_library != null) {
            c.recolorBody();
            c.last_phase = null;
        }
        for ([_]win.Handle{ c.method, c.body_kind, c.auth_kind }) |handle| {
            _ = win.SendMessageW(handle, 0x0153, ~@as(usize, 0), @intFromFloat(24 * scale)); // CB_SETITEMHEIGHT, closed selector
            _ = win.SendMessageW(handle, 0x0153, 0, @intFromFloat(26 * scale));
        }
    }
};

fn readText(allocator: std.mem.Allocator, handle: win.Handle) ![]const u8 {
    const length = win.GetWindowTextLengthW(handle);
    const text = try allocator.alloc(u16, @intCast(length + 1));
    const count = win.GetWindowTextW(handle, text.ptr, @intCast(text.len));
    return std.unicode.utf16LeToUtf8Alloc(allocator, text[0..@intCast(count)]);
}

fn setText(allocator: std.mem.Allocator, handle: win.Handle, text: []const u8) void {
    const utf16 = std.unicode.wtf8ToWtf16LeAllocZ(allocator, text) catch return;
    _ = win.SetWindowTextW(handle, utf16);
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
