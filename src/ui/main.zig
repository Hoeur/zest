//! Native desktop entry point: owns the window, the back buffer and the
//! message loop, hands each repaint to `app.frame`, and runs the actions the
//! pages ask for, such as menus, dialogs and starting runs.

const std = @import("std");
const Io = std.Io;
const win = @import("win32.zig");
const app = @import("app.zig");
const Canvas = @import("canvas.zig").Canvas;
const State = @import("state.zig").State;
const theme = @import("theme.zig");
const api = @import("api_request.zig");
const api_controls = @import("api_controls.zig");
const Controls = api_controls.Controls;
const Rect = @import("layout.zig").Rect;
const Model = @import("model.zig").Model;
const fields_mod = @import("fields.zig");
const Fields = fields_mod.Fields;
const native = @import("native.zig");
const dark_combo = @import("dark_combo.zig");
const rows_model = @import("assertion_rows.zig");
const load_run = @import("load_run.zig");
const timefmt = @import("timefmt.zig");
const history = @import("../core/history.zig");
const report = @import("../core/report/report.zig");
const environment = @import("../core/environment.zig");
const parser = @import("../core/parser/parser.zig");
const writer = @import("../core/parser/writer.zig");
const ast = @import("../core/parser/ast.zig");
const version = @import("build_options").version;
const draft = api.draft;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

/// Posted after a paint that asked for an action, with the action in wparam,
/// so that menus and dialogs never run inside WM_PAINT.
const WM_RUN_ACTION = win.WM_APP + 1;

const min_width = 1100;
const min_height = 700;
const wheel_step = 60;
const timer_ms = 50;

var canvas: Canvas = undefined;
var state: State = .{};
var input: app.Input = .{};
var scale: f32 = 1;
var cursor_arrow: win.Handle = null;
var cursor_hand: win.Handle = null;
var want_hand = false;
/// Set by a press in the window, so a release only clicks after one.
var mouse_down = false;
/// Whether the window has asked to hear when the pointer leaves it.
var tracking_leave = false;
/// Wheel movement toward the next Assertions row; touchpads send small steps.
var assert_wheel: i32 = 0;
var gpa: std.mem.Allocator = undefined;
var io: Io = undefined;
var model: Model = undefined;
var controls: Controls = .{};
var fields: Fields = .{};
var ready = false;

/// The action posted by the last paint, with its subject and menu point.
var pending_arg: usize = 0;
var pending_x: f32 = 0;
var pending_y: f32 = 0;
/// A search box clicked last frame, focused once its field is shown.
var focus_request: ?fields_mod.Id = null;

var toast_buffer: [200]u8 = undefined;
/// The request as typed when it was sent, for its history entry.
var sent_name_buffer: [256]u8 = undefined;
var sent_name: []const u8 = "";
var sent_method: []const u8 = "GET";
/// Variables for a suite run, which keeps pointing at them while it runs.
var suite_variables: std.heap.ArenaAllocator = undefined;
/// What a load test sends, which must outlive its start.
var load_input: std.heap.ArenaAllocator = undefined;
/// A request handed over from API Tests, with its headers, body and auth,
/// used while the Load Tests URL and method still match it.
var load_template_arena: std.heap.ArenaAllocator = undefined;
var load_template: ?draft.Draft = null;
var load_problem_buffer: [200]u8 = undefined;
/// The last process CPU reading, for the load test's CPU chart.
var cpu_last_busy: u64 = 0;
var cpu_last_wall: i96 = 0;
var ticks: usize = 0;
var seen_cases: usize = 0;
var gutter_seen: [2]usize = .{ 0, 0 };

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

fn nowUnix() i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

fn mainArea(client: win.Rect) Rect {
    return .{
        .x = theme.sidebar_width,
        .y = theme.topbar_height,
        .w = @as(f32, @floatFromInt(client.right)) / scale - theme.sidebar_width,
        .h = @as(f32, @floatFromInt(client.bottom)) / scale - theme.topbar_height,
    };
}

fn paint(hwnd: win.Handle) void {
    var ps: win.PaintStruct = .{};
    const hdc = win.BeginPaint(hwnd, &ps);
    defer _ = win.EndPaint(hwnd, &ps);

    var client: win.Rect = .{};
    _ = win.GetClientRect(hwnd, &client);
    if (client.right == 0 or client.bottom == 0) return;
    ensureBackBuffer(hdc, client.right, client.bottom);

    model.now = nowUnix();
    if (state.screen == .test_suites and model.catalog.suites.len > 0) {
        model.selectSuite(@min(state.suite, model.catalog.suites.len - 1));
    }
    if (ready and state.screen == .api_tests) {
        controls.gutter(.body, &model.body_gutter);
        controls.gutter(.response, &model.response_gutter);
    }

    canvas.begin(back_dc, scale, theme.background) catch return;
    const rendered_screen = state.screen;
    const result = app.frame(
        &canvas,
        &state,
        &model,
        input,
        @as(f32, @floatFromInt(client.right)) / scale,
        @as(f32, @floatFromInt(client.bottom)) / scale,
    );
    canvas.end();
    input.clicked = false;

    if (ready) {
        const area = mainArea(client);
        const same = rendered_screen == state.screen;
        controls.sync(hwnd, same and state.screen == .api_tests, area, scale, &state, model.response_expanded);
        controls.refresh(&model.api, selectedView(), model.pretty);
        if (same) {
            fields.sync(hwnd, result.placements[0..result.placement_count], area, scale);
        } else {
            fields.hideAll(hwnd);
        }
        if (focus_request) |field| {
            focus_request = null;
            _ = win.SetFocus(fields.get(field));
        }
    }

    _ = win.BitBlt(hdc, 0, 0, client.right, client.bottom, back_dc, 0, 0, win.SRCCOPY);
    want_hand = result.hand;
    _ = win.SetCursor(if (want_hand) cursor_hand else cursor_arrow);
    if (result.changed) _ = win.InvalidateRect(hwnd, null, 0);
    if (result.action != .none) {
        pending_arg = result.arg;
        pending_x = result.point_x;
        pending_y = result.point_y;
        _ = win.PostMessageW(hwnd, WM_RUN_ACTION, @backingInt(result.action), 0);
    }
}

fn handleOf(lparam: isize) win.Handle {
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

fn command(hwnd: win.Handle, wparam: usize, lparam: isize) void {
    const code = wparam >> 16;
    const id = wparam & 0xFFFF;
    const sender = handleOf(lparam);
    if (fields.idOf(sender)) |field| {
        fieldChanged(field, code);
        _ = win.InvalidateRect(hwnd, null, 0);
        return;
    }
    switch (code) {
        win.EN_CHANGE => {
            controls.changed(sender);
            _ = win.InvalidateRect(hwnd, null, 0);
            return;
        },
        win.EN_SETFOCUS => {
            controls.noteFocus(sender);
            return;
        },
        win.EN_VSCROLL => {
            _ = win.InvalidateRect(hwnd, null, 0);
            return;
        },
        else => {},
    }
    if (code == 0 and controls.activate(sender, &state, model.api.busy())) {
        controls.refresh(&model.api, selectedView(), model.pretty);
        _ = win.InvalidateRect(hwnd, null, 0);
        return;
    }
    if (code == win.CBN_SELCHANGE) {
        // The painted labels read the state, so it changes before the repaint.
        if (id == api_controls.auth_kind_id) state.auth_kind = controls.authIndex();
        if (id == api_controls.body_kind_id) {
            controls.recolorBody();
            controls.refresh(&model.api, selectedView(), model.pretty);
        }
        controls.selectionChanged();
        _ = win.InvalidateRect(hwnd, null, 0);
        return;
    }
    if (id == api_controls.send_id and code == 0 and sender == controls.send) sendOrCancel(hwnd);
}

/// Keeps the search text the pages filter by in step with its field.
fn fieldChanged(field: fields_mod.Id, code: usize) void {
    if (code == win.EN_SETFOCUS) model.focused_field = field;
    if (code == win.EN_KILLFOCUS and model.focused_field == field) model.focused_field = null;
    if (code != win.EN_CHANGE) return;
    switch (field) {
        .suite_search => model.suite_search_text = readField(field, &model.suite_search_buffer),
        .result_search => model.search_text = readField(field, &model.search_buffer),
        .load_url, .load_method => {},
        else => {},
    }
}

fn readField(field: fields_mod.Id, buffer: []u8) []const u8 {
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    var scratch: [2048]u8 = undefined;
    var scratch_alloc: std.heap.FixedBufferAllocator = .init(&scratch);
    const text = fields.text(scratch_alloc.allocator(), field) catch return "";
    return fixed.allocator().dupe(u8, text) catch "";
}

fn windowProc(hwnd: win.Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        win.WM_DRAWITEM => {
            const item: *const win.DrawItemStruct = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (ready and fields.owns(item.hwndItem)) {
                dark_combo.drawItem(item);
                return 1;
            }
            if (ready and controls.drawButton(&canvas, item, &state)) return 1;
            return win.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win.WM_COMMAND => {
            if (ready) command(hwnd, wparam, lparam);
            return 0;
        },
        WM_RUN_ACTION => {
            if (ready) runAction(hwnd, @fromBackingInt(@intCast(wparam)), pending_arg);
            return 0;
        },
        win.WM_TIMER => {
            if (ready) tick(hwnd);
            return 0;
        },
        win.WM_CTLCOLOREDIT, win.WM_CTLCOLORSTATIC, win.WM_CTLCOLORLISTBOX => {
            if (ready) return controls.color(@ptrFromInt(wparam));
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
        win.WM_CAPTURECHANGED => {
            mouse_down = false;
            return 0;
        },
        win.WM_MOUSELEAVE => {
            tracking_leave = false;
            input.mouse_x = -1;
            input.mouse_y = -1;
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_MOUSEMOVE, win.WM_LBUTTONDOWN, win.WM_LBUTTONUP => {
            const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
            const x: i16 = @bitCast(@as(u16, @truncate(bits)));
            const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
            input.mouse_x = @as(f32, @floatFromInt(x)) / scale;
            input.mouse_y = @as(f32, @floatFromInt(y)) / scale;
            if (!tracking_leave) {
                // Hover highlights would otherwise stay lit after the pointer leaves.
                var track: win.TrackMouseEventInfo = .{ .cbSize = @sizeOf(win.TrackMouseEventInfo), .dwFlags = win.TME_LEAVE, .hwndTrack = hwnd };
                tracking_leave = win.TrackMouseEvent(&track) != 0;
            }
            if (msg == win.WM_LBUTTONDOWN) {
                _ = win.SetCapture(hwnd);
                mouse_down = true;
                input.press_x = input.mouse_x;
                input.press_y = input.mouse_y;
            } else if (msg == win.WM_LBUTTONUP) {
                if (mouse_down) {
                    input.clicked = true;
                    input.click_x = input.mouse_x;
                    input.click_y = input.mouse_y;
                    mouse_down = false;
                    _ = win.ReleaseCapture();
                }
            }
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            // The wheel gives the pointer's place on the screen. The last move
            // may be stale: fields and selectors take the pointer from the window.
            const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
            var point: win.Point = .{
                .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
                .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
            };
            _ = win.ScreenToClient(hwnd, &point);
            input.mouse_x = @as(f32, @floatFromInt(point.x)) / scale;
            input.mouse_y = @as(f32, @floatFromInt(point.y)) / scale;
            if (state.screen == .api_tests) {
                // Only the Assertions panel scrolls; the editors scroll themselves.
                var client: win.Rect = .{};
                _ = win.GetClientRect(hwnd, &client);
                const panel = @import("screens/api_test.zig").layoutFor(mainArea(client), model.response_expanded).assertions;
                if (model.response_expanded or !panel.contains(input.mouse_x, input.mouse_y)) {
                    assert_wheel = 0;
                    return 0;
                }
                // One row per notch, however finely the wheel or touchpad reports it.
                assert_wheel += delta;
                while (assert_wheel >= 120) : (assert_wheel -= 120) state.assert_offset -|= 1;
                while (assert_wheel <= -120) : (assert_wheel += 120) state.assert_offset += 1;
            } else {
                state.scrollBy(-@as(f32, @floatFromInt(delta)) / 120 * wheel_step);
            }
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

/// Finishes requests and runs, takes load samples and keeps live pages fresh.
fn tick(hwnd: win.Handle) void {
    ticks +%= 1;
    var changed = false;
    if (model.api.poll()) {
        changed = true;
        requestFinished();
    }
    const cases = model.suites.finishedCases().len;
    if (cases != seen_cases) {
        seen_cases = cases;
        changed = true;
    }
    if (model.suites.poll()) {
        changed = true;
        suiteFinished();
    }
    if (model.load.busy()) {
        const sampled = model.load.tick() catch true;
        if (sampled) {
            changed = true;
            sampleProcess();
            if (model.load.phase == .done) loadFinished();
        }
    }
    const busy = model.api.busy() or model.suites.busy() or model.load.busy();
    // Elapsed times and progress move on even without new results.
    if (busy and ticks % 5 == 0) changed = true;
    if (model.toast.len > 0 and nowUnix() >= model.toast_until) {
        model.toast = "";
        changed = true;
    }
    if (state.screen == .api_tests) {
        // Editors scroll by wheel without telling the parent; follow them.
        var g: @import("model.zig").Gutter = .{};
        controls.gutter(.body, &g);
        const body = g.first;
        controls.gutter(.response, &g);
        if (body != gutter_seen[0] or g.first != gutter_seen[1]) {
            gutter_seen = .{ body, g.first };
            changed = true;
        }
    }
    if (changed) _ = win.InvalidateRect(hwnd, null, 0);
}

fn notify(comptime fmt: []const u8, args: anytype) void {
    model.now = nowUnix();
    model.notify(std.fmt.bufPrint(&toast_buffer, fmt, args) catch "Done");
}

fn requestFinished() void {
    const s = &model.api;
    model.response_unix = nowUnix();
    if (s.phase == .canceled) return;
    const counts = s.assertionCounts();
    const outcome: history.Outcome = if (s.phase != .completed)
        .failed
    else if (counts != null and counts.?.failed > 0)
        .failed
    else
        .passed;
    const took: u64 = if (s.response) |r| r.duration_ns / std.time.ns_per_ms else 0;
    model.record(&.{.{
        .kind = .request,
        .unix = model.response_unix,
        .outcome = outcome,
        .name = sent_name,
        .suite = model.workspace.fileName() orelse "",
        .environment = model.workspace.selectedName() orelse "",
        .method = sent_method,
        .duration_ms = took,
        .passed = if (counts) |c| @intCast(c.passed) else 0,
        .failed = if (counts) |c| @intCast(c.failed) else 0,
    }});
}

fn suiteFinished() void {
    const run = &model.suites;
    if (run.phase != .done) {
        if (run.problem.len > 0) notify("{s}", .{run.problem});
        run_all_queue.clearRetainingCapacity();
        model.run_all_left = 0;
        model.run_all_total = 0;
        return;
    }
    defer {
        // Run All goes on with the next suite, unless this one was stopped.
        if (run.summary.interrupted) run_all_queue.clearRetainingCapacity();
        if (run_all_queue.items.len > 0) runNextQueued() else model.run_all_total = 0;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const entries = run.historyEntries(arena.allocator()) catch return;
    model.record(entries);
    const s = run.summary;
    if (s.interrupted) {
        notify("{s} stopped: {d} passed, {d} failed", .{ run.suite.name, s.passed, s.failed });
    } else {
        notify("{s} finished: {d} passed, {d} failed, {d} skipped", .{ run.suite.name, s.passed, s.failed, s.skipped });
    }
}

fn loadFinished() void {
    if (model.load.historyEntry()) |entry| model.record(&.{entry});
    const t = model.load.totals();
    notify("Load test finished: {d} requests, {d} failed", .{ t.requests, t.failed });
}

/// The app's own CPU and memory for each load sample, so the charts show
/// what ZTest costs the machine while it generates load.
fn sampleProcess() void {
    while (model.cpu.items.len < model.load.samples.items.len) {
        const now = Io.Timestamp.now(io, .awake).toNanoseconds();
        const busy = processBusy();
        const cores: f32 = @floatFromInt(std.Thread.getCpuCount() catch 1);
        const wall: f32 = @floatFromInt(@max(1, now - cpu_last_wall));
        const used: f32 = @floatFromInt(busy -| cpu_last_busy);
        // Process times count in 100 ns ticks.
        const percent = if (cpu_last_wall == 0) 0 else @min(100, used * 100 * 100 / wall / cores);
        cpu_last_busy = busy;
        cpu_last_wall = now;
        var counters: win.ProcessMemoryCounters = .{};
        const memory: f32 = if (win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, @sizeOf(win.ProcessMemoryCounters)) != 0)
            @as(f32, @floatFromInt(counters.WorkingSetSize)) / (1024 * 1024)
        else
            0;
        model.cpu.append(gpa, percent) catch return;
        model.memory_mb.append(gpa, memory) catch return;
    }
}

fn processBusy() u64 {
    var creation: win.FileTime = .{};
    var exit: win.FileTime = .{};
    var kernel: win.FileTime = .{};
    var user: win.FileTime = .{};
    if (win.GetProcessTimes(win.GetCurrentProcess(), &creation, &exit, &kernel, &user) == 0) return cpu_last_busy;
    return ticksOf(kernel) + ticksOf(user);
}

fn ticksOf(t: win.FileTime) u64 {
    return (@as(u64, t.high) << 32) | t.low;
}

fn sendOrCancel(hwnd: win.Handle) void {
    if (!model.api.busy()) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (controls.readDraft(arena.allocator())) |d| {
            const url = std.mem.trim(u8, d.url, " \t\r\n");
            sent_name = std.fmt.bufPrint(&sent_name_buffer, "{s}", .{url[0..@min(url.len, sent_name_buffer.len)]}) catch "";
            sent_method = @tagName(d.method);
        } else |_| {}
    }
    controls.sendOrCancel(&model.api, &model.workspace);
    if (model.api.busy()) _ = win.SetFocus(controls.send);
    controls.refresh(&model.api, selectedView(), model.pretty);
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn menuAt(hwnd: win.Handle, items: []const native.Item) ?usize {
    return native.pick(hwnd, @intFromFloat(pending_x * scale), @intFromFloat(pending_y * scale), items);
}

fn copyText(hwnd: win.Handle, text: []const u8, what: []const u8) void {
    if (native.copy(hwnd, gpa, text)) {
        notify("Copied {s}", .{what});
    } else {
        notify("Could not copy to the clipboard", .{});
    }
}

fn runAction(hwnd: win.Handle, action: app.Action, arg: usize) void {
    defer _ = win.InvalidateRect(hwnd, null, 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (action) {
        .none, .suite_select => {},
        .send => sendOrCancel(hwnd),
        .open => openFile(hwnd),
        .save => saveFile(hwnd, false),
        .save_as => saveFile(hwnd, true),
        .new => newRequest(),
        .edit_tests => controls.focusTests(&state),
        .previous_test, .next_test => {
            if (model.api.busy() or model.workspace.testCount() < 2) return;
            const current = controls.readDraft(arena) catch return;
            const shown = model.workspace.nextTest(current, if (action == .next_test) 1 else -1) catch return;
            controls.loadDraft(shown, &state);
        },
        .more_menu => {
            const has_file = model.workspace.file != null;
            const choice = menuAt(hwnd, &.{
                .{ .label = "New Request\tCtrl+N" },
                .{ .label = "Open...\tCtrl+O" },
                .{ .label = "Save As...\tCtrl+Shift+S" },
                .{ .label = "", .separator = true },
                .{ .label = "Copy as cURL" },
                .{ .label = "Reload ztest.json" },
                .{ .label = "", .separator = true },
                .{ .label = "Show in Test Suites", .enabled = has_file },
            }) orelse return;
            switch (choice) {
                0 => newRequest(),
                1 => openFile(hwnd),
                2 => saveFile(hwnd, true),
                4 => copyCurl(hwnd),
                5 => reload(),
                7 => showInSuites(),
                else => {},
            }
        },
        .run_menu, .send_menu => {
            const busy = model.api.busy();
            const choice = menuAt(hwnd, &.{
                .{ .label = if (busy) "Cancel Request" else "Send Request\tCtrl+Enter" },
                .{ .label = "Send and Save", .enabled = !busy },
                .{ .label = "Run All Tests in This File", .enabled = model.workspace.file != null and !model.suites.busy() },
                .{ .label = "", .separator = true },
                .{ .label = "Copy as cURL" },
                .{ .label = "Load Test This Request", .enabled = !model.load.busy() },
            }) orelse return;
            switch (choice) {
                0 => sendOrCancel(hwnd),
                1 => {
                    saveFile(hwnd, false);
                    sendOrCancel(hwnd);
                },
                2 => runOpenFile(),
                4 => copyCurl(hwnd),
                5 => loadTestRequest(),
                else => {},
            }
        },
        .snippets_menu => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "Copy as cURL" },
                .{ .label = "Copy as ZTest Test" },
                .{ .label = "Copy URL" },
            }) orelse return;
            const d = controls.readDraft(arena) catch return;
            switch (choice) {
                0 => copyCurl(hwnd),
                1 => {
                    var diagnostic: draft.Diagnostic = .{};
                    const case = draft.toCase(arena, d, model.workspace.title(), &diagnostic) catch |err| {
                        notify("Cannot copy: {s}", .{draft.message(arena, err, diagnostic) catch draft.describe(err)});
                        return;
                    };
                    const text = suiteText(arena, .{ .name = model.workspace.title(), .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }) orelse return;
                    copyText(hwnd, text, "the test");
                },
                else => copyText(hwnd, std.mem.trim(u8, d.url, " \t\r\n"), "the URL"),
            }
        },
        .save_as_menu => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "Save\tCtrl+S" },
                .{ .label = "Save As New File...\tCtrl+Shift+S" },
                .{ .label = "Add to a Suite..." },
            }) orelse return;
            switch (choice) {
                0 => saveFile(hwnd, false),
                1 => saveFile(hwnd, true),
                else => addToSuite(hwnd),
            }
        },
        .insert_variable => {
            const shown = model.workspace.shownVariables(arena) catch return;
            var items: std.ArrayList(native.Item) = .empty;
            for (shown) |item| {
                items.append(arena, .{ .label = std.fmt.allocPrint(arena, "{{{{{s}}}}}\t{s}", .{ item.name, item.source }) catch continue }) catch return;
            }
            if (items.items.len == 0) items.append(arena, .{ .label = "No variables in ztest.json", .enabled = false }) catch return;
            const choice = menuAt(hwnd, items.items) orelse return;
            if (choice >= shown.len) return;
            const text = std.fmt.allocPrint(arena, "{{{{{s}}}}}", .{shown[choice].name}) catch return;
            if (!controls.insert(&state, text)) notify("Choose an editor to insert into first", .{});
        },
        .variable_filter => {
            const labels = [_][]const u8{ "All Variables", "Environment", "File", "Secrets" };
            var items: [4]native.Item = undefined;
            for (&items, labels, 0..) |*item, label, i| item.* = .{ .label = label, .checked = model.variable_filter == i };
            if (menuAt(hwnd, &items)) |choice| model.variable_filter = @intCast(choice);
        },
        .copy_variable => {
            const shown = model.workspace.shownVariables(arena) catch return;
            if (arg >= shown.len) return;
            const item = shown[arg];
            const revealed = arg < 64 and model.revealed & (@as(u64, 1) << @intCast(arg)) != 0;
            if (item.secret and !revealed) {
                // A hidden secret is copied as its reference, never its value.
                copyText(hwnd, std.fmt.allocPrint(arena, "{{{{{s}}}}}", .{item.name}) catch return, "the variable reference");
            } else {
                copyText(hwnd, if (item.secret) item.raw else item.value, "the value");
            }
        },
        .reveal_variable => {
            if (arg < 64) model.revealed ^= @as(u64, 1) << @intCast(arg);
        },
        .response_format => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "JSON (formatted)", .checked = model.pretty },
                .{ .label = "Text (as received)", .checked = !model.pretty },
            }) orelse return;
            model.pretty = choice == 0;
            controls.refresh(&model.api, selectedView(), model.pretty);
        },
        .response_copy => {
            if (model.api.phase != .completed) {
                notify("Send a request first", .{});
                return;
            }
            const text = model.api.previewFormatted(arena, selectedView(), model.pretty) catch return;
            copyText(hwnd, text, "the response");
        },
        .response_expand => model.response_expanded = !model.response_expanded,
        .assert_templates => {
            var items: [rows_model.templates.len]native.Item = undefined;
            for (&items, rows_model.templates) |*item, t| item.* = .{ .label = t.label };
            const choice = menuAt(hwnd, &items) orelse return;
            controls.setTests(rows_model.appendLine(arena, model.tests_text.items, rows_model.templates[choice].text) catch return);
            model.dirty = true;
        },
        .assert_add => {
            const rows = rows_model.parse(arena, model.tests_text.items) catch return;
            controls.setTests(rows_model.appendLine(arena, model.tests_text.items, rows_model.suggested(rows)) catch return);
            model.dirty = true;
        },
        .assert_operator => {
            const rows = rows_model.parse(arena, model.tests_text.items) catch return;
            const row = for (rows) |r| {
                if (r.line == arg) break r;
            } else return;
            const parsed = row.parsed orelse {
                controls.selectTestsLine(&state, arg);
                return;
            };
            const ops = rows_model.operatorsFor(parsed.target);
            var items: [16]native.Item = undefined;
            for (items[0..ops.len], ops) |*item, op| item.* = .{ .label = rows_model.word(op), .checked = op == parsed.op };
            const choice = menuAt(hwnd, items[0..ops.len]) orelse return;
            const line = rows_model.withOperator(arena, row, ops[choice]) catch return;
            controls.setTests(rows_model.replaceLine(arena, model.tests_text.items, arg, line) catch return);
            model.dirty = true;
        },
        .assert_delete => {
            controls.setTests(rows_model.replaceLine(arena, model.tests_text.items, arg, null) catch return);
            model.dirty = true;
        },
        .assert_edit => controls.selectTestsLine(&state, arg),
        .load_start => startLoad(),
        .load_stop => model.load.stop(),
        .load_configs => loadConfigs(hwnd),
        .suite_new => newSuite(hwnd),
        .suite_run => runSuite(model.fail_fast),
        .suite_run_menu => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "Run Suite" },
                .{ .label = "Run, Stopping at the First Failure" },
                .{ .label = "", .separator = true },
                .{ .label = "Always Stop at the First Failure", .checked = model.fail_fast },
            }) orelse return;
            switch (choice) {
                0 => runSuite(model.fail_fast),
                1 => runSuite(true),
                3 => model.fail_fast = !model.fail_fast,
                else => {},
            }
        },
        .suite_stop => model.suites.stop(),
        .suite_export => exportReport(hwnd),
        .suite_open_test => openTest(hwnd, arg),
        .suite_more => {
            const has_suite = model.catalog.suites.len > 0;
            const choice = menuAt(hwnd, &.{
                .{ .label = "Open in API Tests", .enabled = has_suite },
                .{ .label = "Copy File Path", .enabled = has_suite },
                .{ .label = "", .separator = true },
                .{ .label = "Reload Suites" },
            }) orelse return;
            switch (choice) {
                0 => openTest(hwnd, std.math.maxInt(usize)),
                1 => {
                    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
                    const path = model.catalog.fullPath(&buffer, selectedSuite() orelse return) catch return;
                    copyText(hwnd, path, "the path");
                },
                3 => reload(),
                else => {},
            }
        },
        .copy_text => copyText(hwnd, model.copy_request, "the details"),
        .run_all => runAll(false),
        .run_all_menu => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "Run All Suites" },
                .{ .label = "Run Failing Suites Only" },
                .{ .label = "", .separator = true },
                .{ .label = "Stop Each Suite at Its First Failure", .checked = model.fail_fast },
            }) orelse return;
            switch (choice) {
                0 => runAll(false),
                1 => runAll(true),
                3 => model.fail_fast = !model.fail_fast,
                else => {},
            }
        },
        .new_test => {
            newRequest();
            state.navigate(.api_tests);
        },
        .new_test_menu => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "New Request" },
                .{ .label = "New Suite..." },
                .{ .label = "New Load Test" },
            }) orelse return;
            switch (choice) {
                0 => {
                    newRequest();
                    state.navigate(.api_tests);
                },
                1 => {
                    newSuite(hwnd);
                    state.navigate(.test_suites);
                },
                else => state.navigate(.load_tests),
            }
        },
        .trend_range => {
            const choice = menuAt(hwnd, &.{
                .{ .label = "Last 7 days", .checked = state.trend_days == 7 },
                .{ .label = "Last 14 days", .checked = state.trend_days == 14 },
            }) orelse return;
            state.trend_days = if (choice == 0) 7 else 14;
        },
        .runs_suite_filter => {
            // Every suite that has test runs, once, in the order first seen.
            var names: std.ArrayList([]const u8) = .empty;
            for (model.history.entries.items) |e| {
                if (e.kind != .@"test" or e.suite.len == 0) continue;
                const known = for (names.items) |n| {
                    if (std.mem.eql(u8, n, e.suite)) break true;
                } else false;
                if (!known) names.append(arena, e.suite) catch return;
            }
            var items: std.ArrayList(native.Item) = .empty;
            items.append(arena, .{ .label = "All Suites", .checked = model.runs_suite.len == 0 }) catch return;
            for (names.items) |n| items.append(arena, .{ .label = n, .checked = std.mem.eql(u8, n, model.runs_suite) }) catch return;
            const choice = menuAt(hwnd, items.items) orelse return;
            model.runs_suite = if (choice == 0) "" else std.fmt.bufPrint(&model.runs_suite_buffer, "{s}", .{names.items[choice - 1][0..@min(names.items[choice - 1].len, model.runs_suite_buffer.len)]}) catch "";
            state.runs_page = 0;
        },
        .run_row_menu => {
            const entries = model.history.entries.items;
            if (arg >= entries.len) return;
            const e = entries[arg];
            const index = suiteIndex(e.suite);
            const choice = menuAt(hwnd, &.{
                .{ .label = "Open in API Tests", .enabled = index != null },
                .{ .label = "Show Suite", .enabled = index != null },
                .{ .label = "Copy Test Name" },
            }) orelse return;
            switch (choice) {
                0, 1 => {
                    state.suite = index.?;
                    state.open_test = null;
                    if (choice == 1) return state.navigate(.test_suites);
                    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
                    const path = arena.dupe(u8, model.catalog.fullPath(&buffer, model.catalog.suites[index.?]) catch return) catch return;
                    openInApi(path, arena.dupe(u8, e.name) catch return);
                },
                else => copyText(hwnd, e.name, "the name"),
            }
        },
        .environment_menu => {
            const w = &model.workspace;
            var items: std.ArrayList(native.Item) = .empty;
            items.append(arena, .{ .label = "Global only", .checked = w.selected == null }) catch return;
            for (w.settings.environments.items, 0..) |env, i| {
                items.append(arena, .{ .label = env.name, .checked = w.selected == i }) catch return;
            }
            items.append(arena, .{ .label = "", .separator = true }) catch return;
            items.append(arena, .{ .label = "Manage Environments..." }) catch return;
            const choice = menuAt(hwnd, items.items) orelse return;
            if (choice == items.items.len - 1) return state.navigate(.environments);
            if (choice > w.settings.environments.items.len) return;
            w.selected = if (choice == 0) null else choice - 1;
            model.revealed = 0;
        },
        .notifications_menu => {
            var recent: [8]history.Entry = undefined;
            const entries = model.history.recent(&.{ .suite, .load, .request }, &recent);
            var items: std.ArrayList(native.Item) = .empty;
            for (entries) |e| {
                var age: [24]u8 = undefined;
                const verb = switch (e.outcome) {
                    .passed => "passed",
                    .failed => "failed",
                    .skipped => "skipped",
                    .not_run => "stopped",
                };
                const label = switch (e.kind) {
                    .suite => std.fmt.allocPrint(arena, "{s} suite {s}: {d} passed, {d} failed\t{s}", .{ e.name, verb, e.passed, e.failed, timefmt.ago(&age, model.now - e.unix) }),
                    .load => std.fmt.allocPrint(arena, "Load test of {s}: {d:.0} rps\t{s}", .{ e.name, e.rps, timefmt.ago(&age, model.now - e.unix) }),
                    else => std.fmt.allocPrint(arena, "{s} {s} {s}\t{s}", .{ e.method, e.name, verb, timefmt.ago(&age, model.now - e.unix) }),
                } catch continue;
                items.append(arena, .{ .label = label }) catch return;
            }
            if (entries.len == 0) items.append(arena, .{ .label = "Nothing yet", .enabled = false }) catch return;
            items.append(arena, .{ .label = "", .separator = true }) catch return;
            items.append(arena, .{ .label = "View All in Reports" }) catch return;
            const choice = menuAt(hwnd, items.items) orelse return;
            if (choice == items.items.len - 1 or choice < entries.len) {
                const e = if (choice < entries.len) entries[choice] else return state.navigate(.reports);
                switch (e.kind) {
                    .suite => {
                        if (suiteIndex(e.name)) |i| state.suite = i;
                        state.navigate(.test_suites);
                    },
                    .load => state.navigate(.load_tests),
                    else => state.navigate(.reports),
                }
            }
        },
        .focus_field => {
            const field: fields_mod.Id = @fromBackingInt(@intCast(arg));
            model.focused_field = field;
            focus_request = field;
        },
        .reload => reload(),
        .open_suite_file => showInSuites(),
    }
}

fn selectedSuite() ?@import("suite_run.zig").SuiteFile {
    if (model.catalog.suites.len == 0) return null;
    return model.catalog.suites[@min(state.suite, model.catalog.suites.len - 1)];
}

fn suiteText(arena: std.mem.Allocator, suite: ast.Suite) ?[]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var diagnostic: writer.Diagnostic = .{};
    writer.write(&out.writer, suite, &diagnostic) catch |err| {
        if (err == error.Unrepresentable) notify("Cannot write it as a test: {f}", .{diagnostic}) else notify("Out of memory", .{});
        return null;
    };
    return out.written();
}

fn copyCurl(hwnd: win.Handle) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const d = controls.readDraft(arena.allocator()) catch return;
    copyText(hwnd, draft.toCurl(arena.allocator(), d) catch return, "the cURL command");
}

fn newRequest() void {
    if (model.api.busy()) return;
    model.workspace.close();
    controls.clear(&state);
    model.saved_unix = null;
    model.dirty = false;
}

fn reload() void {
    model.workspace.loadConfig(model.workspace.root);
    model.refresh();
    notify("Reloaded ztest.json and the suites under {s}", .{model.workspace.root});
}

/// Selects the open file's suite on Test Suites.
fn showInSuites() void {
    const file = model.workspace.file orelse {
        state.navigate(.test_suites);
        return;
    };
    model.refresh();
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.mem.endsWith(u8, file.path, suite.path)) {
            state.suite = i;
            state.open_test = null;
            break;
        }
    }
    state.navigate(.test_suites);
}

const ztest_filter = wide("ZTest files (*.ztest)\x00*.ztest\x00All files (*.*)\x00*.*\x00");

const Dialog = struct {
    saving: bool,
    filter: [*]const u16 = ztest_filter,
    extension: [*:0]const u16 = wide("ztest"),
    /// The file name offered when saving.
    name: []const u8 = "",
    title: ?[*:0]const u16 = null,
};

/// Null when the user cancels. The path is WTF-8, owned by `allocator`.
fn askPath(hwnd: win.Handle, allocator: std.mem.Allocator, dialog: Dialog) ?[]const u8 {
    var buffer: [1024:0]u16 = @splat(0);
    if (dialog.name.len > 0) {
        const n = std.unicode.wtf8ToWtf16Le(buffer[0 .. buffer.len - 1], dialog.name) catch 0;
        buffer[n] = 0;
    }
    // Start in the workspace, where the suites are.
    var folder: [1024:0]u16 = @splat(0);
    const folder_len = std.unicode.wtf8ToWtf16Le(folder[0 .. folder.len - 1], model.workspace.root) catch 0;
    folder[folder_len] = 0;
    var info: win.OpenFileName = .{
        .hwndOwner = hwnd,
        .lpstrFilter = dialog.filter,
        .nFilterIndex = 1,
        .lpstrFile = &buffer,
        .nMaxFile = buffer.len,
        .lpstrInitialDir = &folder,
        .lpstrTitle = dialog.title,
        .lpstrDefExt = dialog.extension,
        .Flags = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_NOCHANGEDIR |
            (if (dialog.saving) @as(u32, win.OFN_OVERWRITEPROMPT) else win.OFN_FILEMUSTEXIST),
    };
    const ok = if (dialog.saving) win.GetSaveFileNameW(&info) else win.GetOpenFileNameW(&info);
    if (ok == 0) return null;
    const len = std.mem.findScalar(u16, &buffer, 0) orelse buffer.len;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..len]) catch null;
}

fn openFile(hwnd: win.Handle) void {
    if (model.api.busy()) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = askPath(hwnd, arena.allocator(), .{ .saving = false }) orelse return;
    const opened = model.workspace.open(path) catch return;
    controls.loadDraft(opened, &state);
    model.saved_unix = null;
    model.refresh();
}

/// Saves over the open file, or asks for a path when there is none or
/// `choose` is set.
fn saveFile(hwnd: win.Handle, choose: bool) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = if (!choose and model.workspace.file != null)
        allocator.dupe(u8, model.workspace.file.?.path) catch return
    else
        askPath(hwnd, allocator, .{ .saving = true, .name = model.workspace.fileName() orelse "" }) orelse return;
    const source = controls.readDraft(allocator) catch return;
    model.workspace.save(path, source) catch return;
    model.dirty = false;
    model.saved_unix = nowUnix();
    model.refresh();
}

/// Adds the request as a new test at the end of a suite the user picks.
fn addToSuite(hwnd: win.Handle) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = askPath(hwnd, arena, .{ .saving = false, .title = wide("Add to a Suite") }) orelse return;
    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        notify("Cannot read {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    var parse_diagnostic: parser.Diagnostic = .{};
    var suite = parser.parse(arena, source, &parse_diagnostic) catch {
        notify("{s}:{d}: {s}", .{ std.fs.path.basename(path), parse_diagnostic.line, parse_diagnostic.message });
        return;
    };
    const d = controls.readDraft(arena) catch return;
    const base = if (model.workspace.file != null) model.workspace.title() else "Request";
    var name = base;
    var n: usize = 2;
    while (for (suite.tests) |t| {
        if (std.mem.eql(u8, t.name, name)) break true;
    } else false) : (n += 1) {
        name = std.fmt.allocPrint(arena, "{s} {d}", .{ base, n }) catch return;
    }
    var diagnostic: draft.Diagnostic = .{};
    const case = draft.toCase(arena, d, name, &diagnostic) catch |err| {
        notify("Not added. {s}", .{draft.message(arena, err, diagnostic) catch draft.describe(err)});
        return;
    };
    const tests = arena.alloc(ast.Case, suite.tests.len + 1) catch return;
    @memcpy(tests[0..suite.tests.len], suite.tests);
    tests[suite.tests.len] = case;
    suite.tests = tests;
    const text = suiteText(arena, suite) orelse return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
        notify("Cannot write {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    model.refresh();
    notify("Added \"{s}\" to {s}", .{ name, std.fs.path.basename(path) });
}

/// Opens a suite's test in API Tests. `arg` is the selected suite's file for
/// `maxInt`, its test `i` for `maxInt - 1 - i`, or else a finished case of the
/// run, which gets a menu first.
fn openTest(hwnd: win.Handle, arg: usize) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const max = std.math.maxInt(usize);
    var path: []const u8 = "";
    var name: []const u8 = "";
    if (arg >= max - 4096) {
        const suite = selectedSuite() orelse return;
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        path = arena.dupe(u8, model.catalog.fullPath(&buffer, suite) catch return) catch return;
        if (arg != max) {
            const tests = if (model.selected_suite) |s| s.tests else return;
            const index = max - 1 - arg;
            if (index >= tests.len) return;
            name = tests[index].name;
        }
    } else {
        const cases = model.suites.finishedCases();
        if (arg >= cases.len) return;
        const case = cases[arg];
        const choice = menuAt(hwnd, &.{
            .{ .label = "Open in API Tests", .enabled = case.kind == .@"test" },
            .{ .label = "", .separator = true },
            .{ .label = "Copy Request" },
            .{ .label = "Copy Response" },
            .{ .label = "Copy Log" },
        }) orelse return;
        switch (choice) {
            0 => {},
            2 => return copyText(hwnd, case.request_text, "the request"),
            3 => return copyText(hwnd, case.response_text, "the response"),
            4 => return copyText(hwnd, case.log_text, "the log"),
            else => return,
        }
        path = model.suites.path;
        name = case.name;
    }
    openInApi(path, name);
}

/// Opens test `name` of the suite at `path`, or its first test when `name`
/// is empty, unless that would lose the request being edited.
fn openInApi(path: []const u8, name: []const u8) void {
    if (model.api.busy()) {
        notify("Wait for the request to finish first", .{});
        return;
    }
    if (model.dirty) {
        notify("Save or discard the request in API Tests first", .{});
        state.navigate(.api_tests);
        return;
    }
    const opened = (if (name.len > 0) model.workspace.openAt(path, name) else model.workspace.open(path)) catch {
        notify("{s}", .{model.workspace.message});
        return;
    };
    controls.loadDraft(opened, &state);
    model.saved_unix = null;
    state.navigate(.api_tests);
}

/// The catalog index of a suite named `name`, as history records it.
fn suiteIndex(name: []const u8) ?usize {
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.mem.eql(u8, suite.name, name) or std.mem.endsWith(u8, name, suite.path)) return i;
    }
    return null;
}

/// Suites waiting for Run All, as paths, run one after another.
var run_all_arena: std.heap.ArenaAllocator = undefined;
var run_all_queue: std.ArrayList([]const u8) = .empty;

fn runAll(failing_only: bool) void {
    if (model.suites.busy()) return;
    _ = run_all_arena.reset(.retain_capacity);
    run_all_queue = .empty;
    const arena = run_all_arena.allocator();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    for (model.catalog.suites) |suite| {
        if (suite.problem != null) continue;
        if (failing_only) {
            const last = model.history.last(.suite, suite.name) orelse continue;
            if (last.outcome != .failed) continue;
        }
        const path = arena.dupe(u8, model.catalog.fullPath(&buffer, suite) catch continue) catch return;
        run_all_queue.append(arena, path) catch return;
    }
    if (run_all_queue.items.len == 0) {
        notify("{s}", .{if (failing_only) "No suite failed its last run" else "No suites to run"});
        return;
    }
    model.run_all_total = run_all_queue.items.len;
    runNextQueued();
}

fn runNextQueued() void {
    if (run_all_queue.items.len == 0) {
        model.run_all_left = 0;
        return;
    }
    const path = run_all_queue.orderedRemove(0);
    model.run_all_left = run_all_queue.items.len;
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.mem.endsWith(u8, path, suite.path)) state.suite = i;
    }
    startSuite(path, model.fail_fast);
}

fn runOpenFile() void {
    const file = model.workspace.file orelse return;
    model.refresh();
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.mem.endsWith(u8, file.path, suite.path)) state.suite = i;
    }
    state.navigate(.test_suites);
    startSuite(file.path, model.fail_fast);
}

fn runSuite(fail_fast: bool) void {
    const suite = selectedSuite() orelse return;
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = model.catalog.fullPath(&buffer, suite) catch return;
    startSuite(path, fail_fast);
}

fn startSuite(path: []const u8, fail_fast: bool) void {
    if (model.suites.busy()) return;
    _ = suite_variables.reset(.retain_capacity);
    const arena = suite_variables.allocator();
    const w = &model.workspace;
    if (w.config_problem) |problem| {
        notify("{s}", .{problem});
        return;
    }
    var problem: []const u8 = "";
    const variables = environment.resolve(arena, w.settings, w.environ, w.selectedName(), &problem) catch {
        notify("{s}", .{if (problem.len > 0) problem else "The environment is incomplete"});
        return;
    };
    state.open_test = null;
    seen_cases = 0;
    model.suites.start(path, variables, w.selectedName(), fail_fast) catch {};
}

fn exportReport(hwnd: win.Handle) void {
    const run = &model.suites;
    if (run.phase != .done) return;
    const choice = menuAt(hwnd, &.{
        .{ .label = "HTML Report" },
        .{ .label = "JSON Report" },
        .{ .label = "JUnit XML" },
    }) orelse return;
    const format: report.Format = switch (choice) {
        0 => .html,
        1 => .json,
        else => .junit,
    };
    const dialog: Dialog = switch (format) {
        .html => .{ .saving = true, .filter = wide("HTML files (*.html)\x00*.html\x00"), .extension = wide("html"), .name = format.defaultPath() },
        .json => .{ .saving = true, .filter = wide("JSON files (*.json)\x00*.json\x00"), .extension = wide("json"), .name = format.defaultPath() },
        .junit => .{ .saving = true, .filter = wide("JUnit XML (*.xml)\x00*.xml\x00"), .extension = wide("xml"), .name = format.defaultPath() },
    };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = askPath(hwnd, arena, dialog) orelse return;
    var stamp: [20]u8 = undefined;
    const started_at = report.formatTimestamp(&stamp, run.started_unix);
    const result = run.toReport(arena, version, started_at) catch return;
    var out: Io.Writer.Allocating = .init(arena);
    report.write(&out.writer, format, result) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() }) catch |err| {
        notify("Cannot write {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    model.addArtifact(path);
    notify("Saved {s}", .{std.fs.path.basename(path)});
}

/// Asks where to create a suite and writes a starter test there.
fn newSuite(hwnd: win.Handle) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = askPath(hwnd, arena, .{ .saving = true, .name = "new-suite.ztest", .title = wide("New Suite") }) orelse return;
    const stem = std.fs.path.stem(path);
    const text = std.fmt.allocPrint(arena,
        \\# Created by ZTest. See docs/TEST_FORMAT.md for everything a test can do.
        \\suite "{s}"
        \\
        \\test "Responds"
        \\  GET {{{{baseUrl}}}}/
        \\  expect status == 200
        \\end
        \\
    , .{if (stem.len > 0) stem else "New Suite"}) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
        notify("Cannot write {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        return;
    };
    model.refresh();
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.mem.endsWith(u8, path, suite.path)) state.suite = i;
    }
    if (model.catalog.suites.len == 0) {
        notify("Created {s}, outside {s}, so it is not listed", .{ std.fs.path.basename(path), model.workspace.root });
    } else {
        notify("Created {s}", .{std.fs.path.basename(path)});
    }
}

fn setLoadProblem(comptime fmt: []const u8, args: anytype) void {
    model.load.problem = std.fmt.bufPrint(&load_problem_buffer, fmt, args) catch "Check the load test settings";
    model.load.phase = .failed;
}

/// A field's whole number, or null after showing why it is not one.
fn wholeNumber(arena: std.mem.Allocator, field: fields_mod.Id, label: []const u8, empty: ?u64) ?u64 {
    const text = fields.text(arena, field) catch return null;
    if (std.mem.trim(u8, text, " \t").len == 0) if (empty) |value| return value;
    return fields_mod.number(text) orelse {
        setLoadProblem("{s} must be a whole number", .{label});
        return null;
    };
}

fn startLoad() void {
    if (model.load.busy()) return;
    _ = load_input.reset(.retain_capacity);
    const arena = load_input.allocator();
    const url = std.mem.trim(u8, fields.text(arena, .load_url) catch return, " \t\r\n");
    if (url.len == 0) return setLoadProblem("Enter the endpoint to test", .{});
    const users = wholeNumber(arena, .load_users, "Virtual users", null) orelse return;
    const duration = wholeNumber(arena, .load_duration, "Duration", null) orelse return;
    const ramp = wholeNumber(arena, .load_ramp, "Ramp-up time", 0) orelse return;
    const rps = wholeNumber(arena, .load_rps, "Max requests/s", 0) orelse return;
    const assertions = fields.text(arena, .load_assert) catch return;
    const method = api.methods[@min(fields.selected(.load_method), api.methods.len - 1)];

    var source: draft.Draft = .{ .method = method, .url = url };
    if (load_template) |template| {
        if (template.method == method and std.mem.eql(u8, std.mem.trim(u8, template.url, " \t\r\n"), url)) source = template;
    }
    source.assertions = assertions;
    var problem: []const u8 = "";
    source.variables = model.workspace.variables(arena, &problem) catch {
        return setLoadProblem("{s}", .{if (problem.len > 0) problem else "The environment is incomplete"});
    };
    const unit_ms = fields_mod.unit_ms;
    const settings: load_run.Settings = .{
        .users = @intCast(@min(users, std.math.maxInt(u32))),
        .duration_ms = duration *| unit_ms[@min(fields.selected(.load_duration_unit), unit_ms.len - 1)],
        .ramp_up_ms = ramp *| unit_ms[@min(fields.selected(.load_ramp_unit), unit_ms.len - 1)],
        .rps = @intCast(@min(rps, std.math.maxInt(u32))),
    };
    model.cpu.clearRetainingCapacity();
    model.memory_mb.clearRetainingCapacity();
    cpu_last_wall = 0;
    cpu_last_busy = processBusy();
    model.load.start(source, settings) catch return;
    cpu_last_wall = Io.Timestamp.now(io, .awake).toNanoseconds();
}

/// Hands the request in API Tests, with its headers, body and auth, to Load Tests.
fn loadTestRequest() void {
    if (model.load.busy()) {
        notify("Stop the running load test first", .{});
        return;
    }
    _ = load_template_arena.reset(.retain_capacity);
    load_template = controls.readDraft(load_template_arena.allocator()) catch null;
    const template = load_template orelse return;
    fields.setText(.load_url, std.mem.trim(u8, template.url, " \t\r\n"));
    for (api.methods, 0..) |method, i| {
        if (method == template.method) fields.select(.load_method, i);
    }
    if (template.method != .GET) state.load_advanced = true;
    state.navigate(.load_tests);
    notify("Load Tests will send this request with its headers, body and auth", .{});
}

/// Earlier load tests from history, newest first, to run again.
fn loadConfigs(hwnd: win.Handle) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var found: std.ArrayList(history.Entry) = .empty;
    const entries = model.history.entries.items;
    var i = entries.len;
    while (i > 0 and found.items.len < 8) {
        i -= 1;
        const e = entries[i];
        if (e.kind != .load) continue;
        const duplicate = for (found.items) |f| {
            if (std.mem.eql(u8, f.name, e.name) and std.mem.eql(u8, f.method, e.method) and f.users == e.users and f.duration_ms / 1000 == e.duration_ms / 1000) break true;
        } else false;
        if (!duplicate) found.append(arena, e) catch return;
    }
    var items: std.ArrayList(native.Item) = .empty;
    for (found.items) |e| {
        var took: [24]u8 = undefined;
        const label = std.fmt.allocPrint(arena, "{s} {s}\t{d} users, {s}", .{ e.method, e.name, e.users, timefmt.duration(&took, e.duration_ms) }) catch continue;
        items.append(arena, .{ .label = label }) catch return;
    }
    if (found.items.len == 0) items.append(arena, .{ .label = "Runs are kept here once they finish", .enabled = false }) catch return;
    items.append(arena, .{ .label = "", .separator = true }) catch return;
    items.append(arena, .{ .label = "Use the Request in API Tests" }) catch return;
    const choice = menuAt(hwnd, items.items) orelse return;
    if (choice == items.items.len - 1) return loadTestRequest();
    if (choice >= found.items.len) return;
    const e = found.items[choice];
    load_template = null;
    _ = load_template_arena.reset(.retain_capacity);
    fields.setText(.load_url, e.name);
    for (fields_mod.methods, 0..) |name, m| {
        if (std.mem.eql(u8, name, e.method)) fields.select(.load_method, m);
    }
    var number: [24]u8 = undefined;
    fields.setText(.load_users, std.fmt.bufPrint(&number, "{d}", .{e.users}) catch "10");
    const seconds = @max(1, (e.duration_ms + 500) / 1000);
    if (seconds % 60 == 0) {
        fields.setText(.load_duration, std.fmt.bufPrint(&number, "{d}", .{seconds / 60}) catch "1");
        fields.select(.load_duration_unit, 1);
    } else {
        fields.setText(.load_duration, std.fmt.bufPrint(&number, "{d}", .{seconds}) catch "60");
        fields.select(.load_duration_unit, 0);
    }
}

fn selectedView() api.View {
    return switch (state.response_tab) {
        1 => .headers,
        2 => .cookies,
        3 => .raw,
        else => .body,
    };
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;
    model = .init(init.gpa, init.io, init.environ_map);
    defer model.deinit();
    model.workspace.loadConfig(".");
    model.refresh();
    suite_variables = .init(gpa);
    defer suite_variables.deinit();
    load_input = .init(gpa);
    defer load_input.deinit();
    load_template_arena = .init(gpa);
    defer load_template_arena.deinit();
    run_all_arena = .init(gpa);
    defer run_all_arena.deinit();
    _ = win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    native.darkMenus();

    var token: usize = 0;
    if (win.GdiplusStartup(&token, &.{}, null) != 0) return error.GdiPlusFailed;
    defer win.GdiplusShutdown(token);

    canvas = try .init();
    defer canvas.deinit();

    cursor_arrow = win.LoadCursorW(null, win.IDC_ARROW);
    cursor_hand = win.LoadCursorW(null, win.IDC_HAND);

    const instance = win.GetModuleHandleW(null);
    const class_name = wide("ZTestWindow");
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
        wide("ZTest"),
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
    controls.model = &model;
    fields = try .init(hwnd);
    ready = true;
    defer {
        ready = false;
        fields.deinit();
        controls.deinit();
    }
    controls.clear(&state);
    if (win.SetTimer(hwnd, 1, timer_ms, null) == 0) return error.CreateTimerFailed;
    defer _ = win.KillTimer(hwnd, 1);

    scale = @as(f32, @floatFromInt(win.GetDpiForWindow(hwnd))) / 96;
    const dark: i32 = 1;
    _ = win.DwmSetWindowAttribute(hwnd, win.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(i32));
    _ = win.ShowWindow(hwnd, win.SW_SHOW);

    var msg: win.Msg = .{};
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        if (handleKey(hwnd, &msg)) continue;
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
}

/// Keyboard shortcuts. True when the key was used.
fn handleKey(hwnd: win.Handle, msg: *win.Msg) bool {
    const control = win.GetKeyState(win.VK_CONTROL) < 0 and win.GetKeyState(win.VK_MENU) >= 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    const key_down = msg.message == win.WM_KEYDOWN;
    // Reach every sidebar page without needing a pointer first.
    if (key_down and control and msg.wParam >= '1' and msg.wParam <= '7') {
        state.navigate(@fromBackingInt(@intCast(msg.wParam - '1')));
        _ = win.InvalidateRect(hwnd, null, 0);
        return true;
    }
    const focus = win.GetFocus();
    if (key_down and control and msg.wParam == 'K') {
        model.focused_field = .global_search;
        focus_request = .global_search;
        _ = win.InvalidateRect(hwnd, null, 0);
        return true;
    }
    // Standard Win32 EDIT controls do not implement Ctrl+A themselves.
    if (key_down and control and msg.wParam == 'A' and (controls.isEditor(focus) or fields.owns(focus))) {
        _ = win.SendMessageW(focus, win.EM_SETSEL, 0, -1);
        return true;
    }
    if (focus == fields.get(.global_search)) return fieldKey(hwnd, .global_search, msg);
    if (state.screen == .api_tests) {
        // Ctrl+S saves, Ctrl+Shift+S saves as, Ctrl+O opens, Ctrl+N starts over.
        if (key_down and control) {
            const action: app.Action = switch (msg.wParam) {
                'S' => if (shift) .save_as else .save,
                'O' => .open,
                'N' => .new,
                0x21 => .previous_test, // VK_PRIOR, Page Up
                0x22 => .next_test, // VK_NEXT, Page Down
                else => .none,
            };
            if (action != .none) {
                runAction(hwnd, action, 0);
                return true;
            }
        }
        if (key_down and msg.wParam == win.VK_TAB and win.GetKeyState(win.VK_CONTROL) >= 0 and win.GetKeyState(win.VK_MENU) >= 0) {
            controls.focusNext(shift);
            return true;
        }
        if (key_down and msg.wParam == win.VK_RETURN and
            (focus == controls.url or (control and controls.isEditor(focus))))
        {
            sendOrCancel(hwnd);
            return true;
        }
        return win.IsDialogMessageW(hwnd, msg) != 0;
    }
    if (fields.idOf(focus)) |field| return fieldKey(hwnd, field, msg);
    if (key_down and !control and scrollKey(msg.wParam)) {
        _ = win.InvalidateRect(hwnd, null, 0);
        return true;
    }
    return false;
}

/// Page Up and Down, Home, End and the arrows scroll the page when no field
/// has the keyboard. True when the key was used.
fn scrollKey(key: usize) bool {
    const page = @max(wheel_step, state.view_height - 80);
    switch (key) {
        0x21 => state.scrollBy(-page), // VK_PRIOR, Page Up
        0x22 => state.scrollBy(page), // VK_NEXT, Page Down
        0x24 => state.scrollBy(-state.content_height), // VK_HOME
        0x23 => state.scrollBy(state.content_height), // VK_END
        0x26 => state.scrollBy(-wheel_step), // VK_UP
        0x28 => state.scrollBy(wheel_step), // VK_DOWN
        else => return false,
    }
    return true;
}

/// Enter and Escape in a page's field. True when the key was used.
fn fieldKey(hwnd: win.Handle, field: fields_mod.Id, msg: *win.Msg) bool {
    if (msg.message != win.WM_KEYDOWN) return win.IsDialogMessageW(hwnd, msg) != 0;
    const search = field == .global_search or field == .suite_search or field == .result_search;
    if (msg.wParam == 0x1B and search) { // VK_ESCAPE
        fields.setText(field, "");
        _ = win.SetFocus(hwnd);
        return true;
    }
    if (msg.wParam == win.VK_RETURN) {
        if (field == .global_search) {
            globalSearch(hwnd);
        } else if (!search and state.screen == .load_tests) {
            runAction(hwnd, .load_start, 0);
        }
        return true;
    }
    return win.IsDialogMessageW(hwnd, msg) != 0;
}

/// Finds suites by name or file from the top bar.
fn globalSearch(hwnd: win.Handle) void {
    var buffer: [256]u8 = undefined;
    const query = std.mem.trim(u8, readField(.global_search, &buffer), " \t");
    fields.setText(.global_search, "");
    _ = win.SetFocus(hwnd);
    model.focused_field = null;
    if (query.len == 0) return;
    fields.setText(.suite_search, query);
    model.suite_search_text = readField(.suite_search, &model.suite_search_buffer);
    state.suite_filter = .all;
    for (model.catalog.suites, 0..) |suite, i| {
        if (std.ascii.findIgnoreCase(suite.name, query) != null or std.ascii.findIgnoreCase(suite.path, query) != null) {
            state.suite = i;
            break;
        }
    }
    state.navigate(.test_suites);
}
