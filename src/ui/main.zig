//! Native desktop entry point: owns the window, the back buffer and the
//! message loop, and hands each repaint to `app.frame`.

const std = @import("std");
const win = @import("win32.zig");
const app = @import("app.zig");
const Canvas = @import("canvas.zig").Canvas;
const State = @import("state.zig").State;
const theme = @import("theme.zig");
const Session = @import("api_request.zig").Session;
const api_controls = @import("api_controls.zig");
const Controls = api_controls.Controls;
const Rect = @import("layout.zig").Rect;
const Workspace = @import("workspace.zig").Workspace;

/// Posted after a paint that asked for an action, with the action in wparam,
/// so that modal dialogs never run inside WM_PAINT.
const WM_RUN_ACTION = win.WM_APP + 1;

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
var api: Session = undefined;
var workspace: Workspace = undefined;
var gpa: std.mem.Allocator = undefined;
var controls: Controls = .{};
var controls_ready = false;

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
    const rendered_screen = state.screen;
    const result = app.frame(
        &canvas,
        &state,
        &api,
        &workspace,
        input,
        @as(f32, @floatFromInt(client.right)) / scale,
        @as(f32, @floatFromInt(client.bottom)) / scale,
    );
    canvas.end();
    input.clicked = false;

    if (controls_ready) {
        const area: Rect = .{
            .x = theme.sidebar_width,
            .y = theme.topbar_height,
            .w = @as(f32, @floatFromInt(client.right)) / scale - theme.sidebar_width,
            .h = @as(f32, @floatFromInt(client.bottom)) / scale - theme.topbar_height,
        };
        controls.sync(hwnd, rendered_screen == .api_tests and state.screen == .api_tests, area, scale, &state);
        controls.refresh(&api, selectedView());
    }

    _ = win.BitBlt(hdc, 0, 0, client.right, client.bottom, back_dc, 0, 0, win.SRCCOPY);
    want_hand = result.hand;
    _ = win.SetCursor(if (want_hand) cursor_hand else cursor_arrow);
    if (result.changed) _ = win.InvalidateRect(hwnd, null, 0);
    if (result.action != .none) _ = win.PostMessageW(hwnd, WM_RUN_ACTION, @backingInt(result.action), 0);
}

fn windowProc(hwnd: win.Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        win.WM_DRAWITEM => {
            if (controls_ready and controls.drawButton(&canvas, @ptrFromInt(@as(usize, @bitCast(lparam))), &state)) return 1;
            return win.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win.WM_COMMAND => {
            if (controls_ready and wparam >> 16 == win.EN_CHANGE) {
                controls.changed(@ptrFromInt(@as(usize, @bitCast(lparam))));
                return 0;
            }
            if (controls_ready and wparam >> 16 == 0 and
                controls.activate(@ptrFromInt(@as(usize, @bitCast(lparam))), &state, api.busy()))
            {
                controls.refresh(&api, selectedView());
                _ = win.InvalidateRect(hwnd, null, 0);
                return 0;
            }
            if (controls_ready and wparam & 0xFFFF == api_controls.auth_kind_id and wparam >> 16 == win.CBN_SELCHANGE) {
                // The painted labels read the state, so it changes before the repaint.
                state.auth_kind = controls.authIndex();
                _ = win.InvalidateRect(hwnd, null, 0);
                return 0;
            }
            if (controls_ready and wparam & 0xFFFF == api_controls.body_kind_id and wparam >> 16 == win.CBN_SELCHANGE) {
                controls.recolorBody();
                controls.refresh(&api, selectedView());
                _ = win.InvalidateRect(hwnd, null, 0);
            }
            if (controls_ready and wparam & 0xFFFF == api_controls.send_id and
                wparam >> 16 == 0 and @as(win.Handle, @ptrFromInt(@as(usize, @bitCast(lparam)))) == controls.send)
            {
                sendOrCancel(hwnd);
            }
            return 0;
        },
        WM_RUN_ACTION => {
            if (controls_ready) runAction(hwnd, @fromBackingInt(@intCast(wparam)));
            return 0;
        },
        win.WM_TIMER => {
            if (api.poll()) _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_CTLCOLOREDIT, win.WM_CTLCOLORSTATIC, win.WM_CTLCOLORLISTBOX => {
            if (controls_ready) return controls.color(@ptrFromInt(wparam));
            return win.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
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
            if (state.screen == .api_tests) return 0;
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

fn sendOrCancel(hwnd: win.Handle) void {
    controls.sendOrCancel(&api, &workspace);
    if (api.busy()) _ = win.SetFocus(controls.send);
    controls.refresh(&api, selectedView());
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn runAction(hwnd: win.Handle, action: app.Action) void {
    switch (action) {
        .none => {},
        .send => sendOrCancel(hwnd),
        .open => openFile(hwnd),
        .save => saveFile(hwnd, false),
        .save_as => saveFile(hwnd, true),
        .new => {
            if (api.busy()) return;
            workspace.close();
            controls.clear(&state);
        },
        .edit_tests => controls.focusTests(&state),
        .previous_test, .next_test => {
            if (api.busy() or workspace.testCount() < 2) return;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const current = controls.readDraft(arena.allocator()) catch return;
            const shown = workspace.nextTest(current, if (action == .next_test) 1 else -1) catch {
                _ = win.InvalidateRect(hwnd, null, 0);
                return;
            };
            controls.loadDraft(shown, &state);
        },
    }
    _ = win.InvalidateRect(hwnd, null, 0);
}

const filter = std.unicode.utf8ToUtf16LeStringLiteral("ZTest files (*.ztest)\x00*.ztest\x00All files (*.*)\x00*.*\x00");

/// Null when the user cancels. The path is WTF-8, owned by `allocator`.
fn askPath(hwnd: win.Handle, allocator: std.mem.Allocator, saving: bool) ?[]const u8 {
    var buffer: [1024:0]u16 = @splat(0);
    if (saving) if (workspace.file) |file| {
        const name = std.fs.path.basename(file.path);
        const n = std.unicode.wtf8ToWtf16Le(&buffer, name) catch 0;
        buffer[n] = 0;
    };
    var info: win.OpenFileName = .{
        .hwndOwner = hwnd,
        .lpstrFilter = filter,
        .nFilterIndex = 1,
        .lpstrFile = &buffer,
        .nMaxFile = buffer.len,
        .lpstrDefExt = std.unicode.utf8ToUtf16LeStringLiteral("ztest"),
        .Flags = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR |
            (if (saving) @as(u32, win.OFN_OVERWRITEPROMPT) else win.OFN_FILEMUSTEXIST),
    };
    const ok = if (saving) win.GetSaveFileNameW(&info) else win.GetOpenFileNameW(&info);
    if (ok == 0) return null;
    const len = std.mem.findScalar(u16, &buffer, 0) orelse buffer.len;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..len]) catch null;
}

fn openFile(hwnd: win.Handle) void {
    if (api.busy()) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = askPath(hwnd, arena.allocator(), false) orelse return;
    const opened = workspace.open(path) catch return;
    controls.loadDraft(opened, &state);
}

/// Saves over the open file, or asks for a path when there is none or
/// `choose` is set.
fn saveFile(hwnd: win.Handle, choose: bool) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = if (!choose and workspace.file != null)
        allocator.dupe(u8, workspace.file.?.path) catch return
    else
        askPath(hwnd, allocator, true) orelse return;
    const source = controls.readDraft(allocator) catch return;
    workspace.save(path, source) catch {};
}

fn selectedView() @import("api_request.zig").View {
    return switch (state.response_tab) {
        1 => .headers,
        2 => .cookies,
        3 => .raw,
        else => .body,
    };
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    api = .init(init.gpa, init.io);
    defer api.deinit();
    workspace = .init(init.gpa, init.io, init.environ_map);
    defer workspace.deinit();
    workspace.loadConfig(".");
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
        win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN,
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
    defer _ = win.DestroyWindow(hwnd);

    controls = try .init(hwnd);
    controls_ready = true;
    defer {
        controls_ready = false;
        controls.deinit();
    }
    if (win.SetTimer(hwnd, 1, 50, null) == 0) return error.CreateTimerFailed;
    defer _ = win.KillTimer(hwnd, 1);

    scale = @as(f32, @floatFromInt(win.GetDpiForWindow(hwnd))) / 96;
    const dark: i32 = 1;
    _ = win.DwmSetWindowAttribute(hwnd, win.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(i32));
    _ = win.ShowWindow(hwnd, win.SW_SHOW);

    var msg: win.Msg = .{};
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        // Reach every sidebar page without needing a pointer first.
        if (msg.message == win.WM_KEYDOWN and msg.wParam >= '1' and msg.wParam <= '7' and
            win.GetKeyState(win.VK_CONTROL) < 0 and win.GetKeyState(win.VK_MENU) >= 0)
        {
            state.navigate(@fromBackingInt(@intCast(msg.wParam - '1')));
            _ = win.InvalidateRect(hwnd, null, 0);
            continue;
        }
        if (state.screen == .api_tests) {
            // Ctrl+S saves, Ctrl+Shift+S saves as, Ctrl+O opens, Ctrl+N starts over.
            if (msg.message == win.WM_KEYDOWN and win.GetKeyState(win.VK_CONTROL) < 0 and win.GetKeyState(win.VK_MENU) >= 0) {
                const shift = win.GetKeyState(win.VK_SHIFT) < 0;
                const action: app.Action = switch (msg.wParam) {
                    'S' => if (shift) .save_as else .save,
                    'O' => .open,
                    'N' => .new,
                    0x21 => .previous_test, // VK_PRIOR, Page Up
                    0x22 => .next_test, // VK_NEXT, Page Down
                    else => .none,
                };
                if (action != .none) {
                    runAction(hwnd, action);
                    continue;
                }
            }
            if (msg.message == win.WM_KEYDOWN and msg.wParam == win.VK_TAB and
                win.GetKeyState(win.VK_CONTROL) >= 0 and win.GetKeyState(win.VK_MENU) >= 0)
            {
                controls.focusNext(win.GetKeyState(win.VK_SHIFT) < 0);
                continue;
            }
            // Standard Win32 EDIT controls do not implement Ctrl+A themselves.
            const focus = win.GetFocus();
            if (msg.message == win.WM_KEYDOWN and msg.wParam == 'A' and win.GetKeyState(win.VK_CONTROL) < 0 and
                controls.isEditor(focus))
            {
                _ = win.SendMessageW(focus, win.EM_SETSEL, 0, -1);
                continue;
            }
            if (msg.message == win.WM_KEYDOWN and msg.wParam == win.VK_RETURN and
                (focus == controls.url or (win.GetKeyState(win.VK_CONTROL) < 0 and controls.isEditor(focus))))
            {
                sendOrCancel(hwnd);
                continue;
            }
            if (win.IsDialogMessageW(hwnd, &msg) != 0) continue;
        }
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
}
