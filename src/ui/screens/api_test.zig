//! Live API builder, laid out as `ui/`'s API Test mockup.
const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");
const timefmt = @import("../timefmt.zig");
const native = @import("../native.zig");
const rows_model = @import("../assertion_rows.zig");
const draft = @import("../../core/http/draft.zig");
const Gutter = @import("../model.zig").Gutter;

pub const Controls = struct {
    method: Rect,
    url: Rect,
    send: Rect,
    params: Rect,
    headers: Rect,
    auth_kind: Rect,
    auth_name: Rect,
    auth_value: Rect,
    body_kind: Rect,
    body: Rect,
    tests: Rect,
    response: Rect,
};
pub const Layout = struct { request: Rect, content: Rect, editor: Rect, variables: Rect, response: Rect, assertions: Rect };
pub const request_tab_labels = .{ "Params", "Headers", "Auth", "Body", "Tests" };
pub const response_tab_labels = .{ "Body", "Headers", "Cookies", "Raw" };
pub const body_mode_labels = .{ "none", "raw" };
pub const auth_kinds = std.enums.values(draft.AuthKind);
/// Room left of a code editor for its line numbers.
pub const gutter_width = 40;
const send_arrow = 40;

/// Native tab buttons use the same positions as the painted tab underline.
pub fn requestTabs(area: Rect) [5]Rect {
    const r = layout(area).request;
    return tabBoxes(&.{ 100, 112, 64, 84, 64 }, .{ .x = r.x + 18, .y = r.y + 96, .w = r.w - 36, .h = 38 });
}

pub fn responseTabs(area: Rect) [4]Rect {
    return responseTabsFor(area, false);
}

pub fn responseTabsFor(area: Rect, expanded: bool) [4]Rect {
    const r = layoutFor(area, expanded).response;
    return tabBoxes(&.{ 64, 122, 116, 60 }, .{ .x = r.x + 12, .y = r.y + 80, .w = r.w - 24, .h = 32 });
}

pub fn bodyModes(area: Rect) [2]Rect {
    const r = layout(area).content;
    const step = @min(34, r.h / 6);
    return .{
        .{ .x = r.x, .y = r.y, .w = 160, .h = step - 2 },
        .{ .x = r.x, .y = r.y + 3 * step, .w = 160, .h = step - 2 },
    };
}

fn tabBoxes(comptime widths: []const f32, r: Rect) [widths.len]Rect {
    var boxes: [widths.len]Rect = undefined;
    var x = r.x;
    for (&boxes, widths) |*box, w| {
        box.* = .{ .x = x, .y = r.y, .w = w, .h = r.h };
        x += w + 8;
    }
    return boxes;
}

pub fn layout(area: Rect) Layout {
    return layoutFor(area, false);
}

/// `expanded` gives the response the whole width, as its expand button does.
pub fn layoutFor(area: Rect, expanded: bool) Layout {
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    const request: Rect = .{ .x = x, .y = area.y + 114, .w = w, .h = @min(374, @max(260, area.h * 0.42)) };
    const content: Rect = .{ .x = x + 18, .y = request.y + 146, .w = w - 36, .h = request.h - 164 };
    const vars_w = @min(320, content.w * 0.3);
    const editor: Rect = .{ .x = content.x + 172, .y = content.y + 38, .w = content.w - 172 - vars_w - 12, .h = content.h - 38 };
    const lower_y = request.bottom() + theme.gap;
    const lower_h = @max(150, @min(400, area.bottom() - lower_y - theme.page_margin));
    const left_w = if (expanded) w else (w - theme.gap) * 0.54;
    return .{
        .request = request,
        .content = content,
        .editor = editor,
        .variables = .{ .x = content.right() - vars_w, .y = content.y, .w = vars_w, .h = content.h },
        .response = .{ .x = x, .y = lower_y, .w = left_w, .h = lower_h },
        .assertions = .{ .x = x + left_w + theme.gap, .y = lower_y, .w = if (expanded) 0 else w - left_w - theme.gap, .h = lower_h },
    };
}

/// Rows of the Auth tab: the type selector, then the two fields.
pub fn authRows(content: Rect) [3]Rect {
    const step = @min(40, content.h / 3);
    const h = @min(28, step - 4);
    const x = content.x + 140;
    const w = @min(420, content.w - 150);
    return .{
        .{ .x = x, .y = content.y, .w = @min(220, w), .h = h },
        .{ .x = x, .y = content.y + step, .w = w, .h = h },
        .{ .x = x, .y = content.y + 2 * step, .w = w, .h = h },
    };
}

pub fn controls(area: Rect) Controls {
    return controlsFor(area, false);
}

/// The painted panels and real controls share exactly the same geometry.
pub fn controlsFor(area: Rect, expanded: bool) Controls {
    const l = layoutFor(area, expanded);
    const method: Rect = .{ .x = l.request.x + 18, .y = l.request.y + 48, .w = 130, .h = 40 };
    const send: Rect = .{ .x = l.request.right() - 18 - 150, .y = method.y, .w = 150 - send_arrow, .h = method.h };
    // Params, Headers and Tests share one editor area below a hint line.
    const text_editor: Rect = .{ .x = l.content.x + 8, .y = l.content.y + 28, .w = l.content.w - 16, .h = l.content.h - 28 };
    const auth = authRows(l.content);
    return .{
        .method = .{ .x = method.x + 7, .y = method.y + 7, .w = method.w - 14, .h = 26 },
        .url = .{ .x = method.right() + 19, .y = method.y + 9, .w = send.x - method.right() - 38, .h = 22 },
        .send = send,
        .params = text_editor,
        .headers = text_editor,
        .auth_kind = auth[0],
        .auth_name = auth[1],
        .auth_value = auth[2],
        .body_kind = .{ .x = l.editor.x, .y = l.content.y, .w = 110, .h = 30 },
        .body = .{ .x = l.editor.x + gutter_width, .y = l.editor.y + 6, .w = l.editor.w - gutter_width - 8, .h = l.editor.h - 12 },
        .tests = text_editor,
        .response = .{ .x = l.response.x + 18 + gutter_width, .y = l.response.y + 120, .w = l.response.w - 36 - gutter_width, .h = @max(30, l.response.h - 136) },
    };
}

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const m = ui.m;
    const l = layoutFor(area, m.response_expanded);
    const boxes = controlsFor(area, m.response_expanded);
    const x = l.request.x;
    const w = l.request.w;
    const y = area.y + 14;

    drawHeader(ui, x, y, w);

    widgets.panel(c, l.request);
    c.text(.heading, "Request", .{ .x = x + 18, .y = l.request.y + 10, .w = 150, .h = 28 }, .left, theme.text);
    const save_menu: Rect = .{ .x = x + w - 18 - 150, .y = l.request.y + 8, .w = 150, .h = 32 };
    const snippets: Rect = .{ .x = save_menu.x - 12 - 170, .y = save_menu.y, .w = 170, .h = 32 };
    if (widgets.menuButton(ui, snippets, theme.icon.code, "Code Snippets")) ui.act(.snippets_menu, 0, snippets);
    if (widgets.menuButton(ui, save_menu, theme.icon.save, "Save as Test")) ui.act(.save_as_menu, 0, save_menu);

    const method_frame: Rect = .{ .x = boxes.method.x - 7, .y = boxes.method.y - 7, .w = boxes.method.w + 14, .h = 40 };
    c.fillRound(method_frame, 8, theme.background);
    c.strokeRound(method_frame, 8, theme.border);
    const url_frame: Rect = .{ .x = boxes.url.x - 9, .y = method_frame.y, .w = boxes.url.w + 18, .h = 40 };
    c.fillRound(url_frame, 8, theme.background);
    c.strokeRound(url_frame, 8, theme.border);
    // The native Send button covers the left part; the arrow is painted.
    const arrow: Rect = .{ .x = boxes.send.right(), .y = boxes.send.y, .w = send_arrow, .h = boxes.send.h };
    c.fillRound(.{ .x = boxes.send.x, .y = arrow.y, .w = boxes.send.w + send_arrow, .h = arrow.h }, 8, if (ui.api.phase == .canceling) theme.amber_dim else theme.amber);
    if (ui.hovered(arrow)) c.fillRound(arrow, 8, theme.key);
    c.line(arrow.x, arrow.y + 8, arrow.x, arrow.bottom() - 8, 0x60000000, 1);
    c.text(.icon, theme.icon.chevron_down, arrow, .center, theme.on_amber);
    if (ui.pressed(arrow)) ui.act(.send_menu, 0, arrow);

    c.line(x + 18, l.request.y + 134, x + w - 18, l.request.y + 134, theme.border, 1);
    switch (ui.state.request_tab) {
        0 => hint(ui, l.content, "One name=value per line, added to the URL encoded. Start a line with # to switch it off."),
        1 => hint(ui, l.content, "One Name: value per line. Duplicates are kept. Start a line with # to switch it off."),
        2 => drawAuth(ui, l.content),
        3 => drawBody(ui, l),
        else => hint(ui, l.content, "One assertion per line, such as status == 200, body.id exists or response_time < 500ms."),
    }
    drawResponse(ui, l.response, boxes.response);
    if (!m.response_expanded) drawAssertions(ui, l.assertions);
    return area.h;
}

fn drawHeader(ui: *Ui, x: f32, y: f32, w: f32) void {
    const c = ui.c;
    const m = ui.m;
    const back: Rect = .{ .x = x - 4, .y = y - 2, .w = 130, .h = 24 };
    if (ui.hovered(back)) c.fillRound(back, 6, theme.raised);
    c.text(.icon, theme.icon.back, .{ .x = x, .y = y, .w = 20, .h = 20 }, .left, theme.text);
    c.text(.body, "API Tests", .{ .x = x + 28, .y = y, .w = 120, .h = 20 }, .left, theme.text);
    if (ui.pressed(back)) {
        if (ui.workspace.file != null) {
            ui.act(.open_suite_file, 0, back);
        } else {
            ui.state.navigate(.dashboard);
        }
    }

    const run: Rect = .{ .x = x + w - 168, .y = y + 22, .w = 168, .h = 44 };
    const save: Rect = .{ .x = run.x - 12 - 90, .y = run.y, .w = 90, .h = 44 };
    const more: Rect = .{ .x = save.x - 12 - 44, .y = run.y, .w = 44, .h = 44 };
    const split = widgets.splitButton(ui, run, theme.icon.play, if (ui.api.busy()) "Cancel" else "Run Test", ui.api.phase != .canceling);
    if (split.main) ui.act(.send, 0, run);
    if (split.menu) ui.act(.run_menu, 0, .{ .x = run.right() - 200, .y = run.y, .w = 200, .h = run.h });
    if (widgets.button(ui, save, "Save", false)) ui.act(.save, 0, save);
    if (widgets.iconButton(ui, more, theme.icon.more)) ui.act(.more_menu, 0, more);

    var ago_buffer: [32]u8 = undefined;
    var status_buffer: [64]u8 = undefined;
    const status: struct { dot: u32, text: []const u8 } = if (m.dirty)
        .{ .dot = theme.amber, .text = "Unsaved changes" }
    else if (ui.workspace.file == null)
        .{ .dot = theme.muted, .text = "Not saved yet" }
    else if (m.saved_unix) |when|
        .{ .dot = theme.green, .text = std.fmt.bufPrint(&status_buffer, "Saved {s}", .{timefmt.ago(&ago_buffer, m.now - when)}) catch "Saved" }
    else
        .{ .dot = theme.green, .text = "Saved" };
    const status_w = c.measure(.small, status.text) + 22;
    const status_x = more.x - 18 - status_w;
    c.circle(status_x + 6, y + 44, 5, status.dot);
    c.text(.small, status.text, .{ .x = status_x + 18, .y = y + 34, .w = status_w, .h = 20 }, .left, theme.text);

    var title_buffer: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buffer, "{s} - API Test", .{ui.workspace.title()}) catch "API Test";
    const count = ui.workspace.testCount();
    const switcher_w: f32 = if (count > 1) 138 else 0;
    const title_w = status_x - x - 16 - switcher_w;
    c.text(.title, title, .{ .x = x, .y = y + 22, .w = title_w, .h = 44 }, .left, theme.text);
    if (count > 1) {
        // A suite holds several tests; these step through them.
        const box: Rect = .{ .x = status_x - 12 - switcher_w, .y = y + 28, .w = switcher_w - 8, .h = 32 };
        const index = if (ui.workspace.file) |file| file.test_index + 1 else 1;
        var label_buffer: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "{d} of {d}", .{ index, count }) catch "";
        if (widgets.button(ui, .{ .x = box.x, .y = box.y, .w = 30, .h = box.h }, "<", false) and !ui.api.busy()) ui.act(.previous_test, 0, box);
        c.text(.small, label, .{ .x = box.x + 32, .y = box.y, .w = box.w - 64, .h = box.h }, .center, theme.text);
        if (widgets.button(ui, .{ .x = box.right() - 30, .y = box.y, .w = 30, .h = box.h }, ">", false) and !ui.api.busy()) ui.act(.next_test, 0, box);
    }

    const note = if (m.toast_until > m.now and m.toast.len > 0)
        m.toast
    else if (ui.workspace.message.len > 0)
        ui.workspace.message
    else if (ui.workspace.file) |file|
        file.path
    else
        "Build a request, check the response, and save it as a .ztest test.";
    const failed = std.mem.startsWith(u8, note, "Not saved") or std.mem.startsWith(u8, note, "Cannot") or std.mem.startsWith(u8, note, "Fix ");
    c.text(.body, note, .{ .x = x, .y = y + 70, .w = w, .h = 22 }, .left, if (failed) theme.red else theme.muted);
}

fn hint(ui: *Ui, r: Rect, text: []const u8) void {
    ui.c.text(.small, text, .{ .x = r.x + 8, .y = r.y, .w = r.w - 16, .h = 22 }, .left, theme.muted);
}

fn drawAuth(ui: *Ui, content: Rect) void {
    const c = ui.c;
    const rows = authRows(content);
    const kind = auth_kinds[@min(ui.state.auth_kind, auth_kinds.len - 1)];
    const labels = kind.fields();
    c.text(.small, "Type", .{ .x = content.x + 8, .y = rows[0].y, .w = 120, .h = rows[0].h }, .left, theme.text);
    for (labels, rows[1..]) |label, row| {
        const text = label orelse continue;
        c.text(.small, text, .{ .x = content.x + 8, .y = row.y, .w = 128, .h = row.h }, .left, theme.text);
        const frame: Rect = .{ .x = row.x - 6, .y = row.y - 2, .w = row.w + 12, .h = row.h + 4 };
        c.fillRound(frame, 6, theme.background);
        c.strokeRound(frame, 6, theme.border);
    }
    const note_x = rows[0].right() + 18;
    const note: []const u8 = if (kind == .none)
        "No credentials are sent."
    else
        "Keys are masked. Use {{variables}} from ztest.json to keep them out of saved files.";
    c.text(.small, note, .{ .x = note_x, .y = rows[0].y, .w = content.right() - note_x, .h = rows[0].h }, .left, theme.muted);
}

fn drawBody(ui: *Ui, l: Layout) void {
    const c = ui.c;
    const step = @min(34, l.content.h / 6);
    for ([_][]const u8{ "none", "form-data", "x-www-form-urlencoded", "raw", "binary", "GraphQL" }, 0..) |label, i| {
        const row: Rect = .{ .x = l.content.x, .y = l.content.y + @as(f32, @floatFromInt(i)) * step, .w = 160, .h = step - 2 };
        const supported = i == 0 or i == 3;
        // Supported modes are native focusable buttons drawn by api_controls.
        if (supported) continue;
        c.circle(row.x + 14, row.y + row.h / 2, 7, theme.border);
        c.text(.small, label, .{ .x = row.x + 30, .y = row.y, .w = row.w - 32, .h = row.h }, .left, theme.muted);
    }
    const insert: Rect = .{ .x = l.editor.right() - 170, .y = l.content.y, .w = 170, .h = 30 };
    if (widgets.menuButton(ui, insert, "{ }", "Insert Variable")) ui.act(.insert_variable, 0, insert);
    c.fillRound(l.editor, 8, theme.background);
    c.strokeRound(l.editor, 8, theme.border);
    drawGutter(c, .{ .x = l.editor.x + 4, .y = l.editor.y + 6, .w = gutter_width - 8, .h = l.editor.h - 12 }, &ui.m.body_gutter);
    drawVariables(ui, l.variables);
}

/// Line numbers beside a native editor, from its visible lines.
fn drawGutter(c: anytype, r: Rect, gutter: *const Gutter) void {
    var buffer: [8]u8 = undefined;
    for (gutter.tops[0..gutter.count], 0..) |top, i| {
        if (top < 0 or top + 16 > r.h) continue;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{gutter.first + i + 1}) catch "";
        c.text(.mono, label, .{ .x = r.x, .y = r.y + top, .w = r.w - 6, .h = 18 }, .right, theme.muted);
    }
}

/// The values `{{name}}` takes with the chosen environment, secrets masked.
fn drawVariables(ui: *Ui, vars: Rect) void {
    const c = ui.c;
    const m = ui.m;
    c.text(.strong, "Environment Variables", .{ .x = vars.x + 8, .y = vars.y, .w = vars.w - 130, .h = 30 }, .left, theme.text);
    const title_w = c.measure(.strong, "Environment Variables");
    if (vars.w > title_w + 160) c.text(.icon, theme.icon.info, .{ .x = vars.x + 14 + title_w, .y = vars.y, .w = 18, .h = 30 }, .left, theme.muted);
    const filters = [_][]const u8{ "All Variables", "Environment", "File", "Secrets" };
    const filter_box: Rect = .{ .x = vars.right() - 118, .y = vars.y, .w = 118, .h = 30 };
    if (widgets.menuButton(ui, filter_box, null, filters[m.variable_filter])) ui.act(.variable_filter, 0, filter_box);

    if (ui.workspace.config_problem) |problem| {
        c.text(.small, problem, .{ .x = vars.x + 8, .y = vars.y + 40, .w = vars.w - 8, .h = 40 }, .left, theme.red);
        return;
    }
    var buffer: [16 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const shown = ui.workspace.shownVariables(fixed.allocator()) catch &.{};
    const row_h: f32 = 44;
    const top = vars.y + 40;
    const capacity: usize = @intFromFloat(@max(1, @floor((vars.bottom() - top + 6) / row_h)));
    var drawn: usize = 0;
    var name_buffer: [80]u8 = undefined;
    for (shown, 0..) |item, index| {
        const keep = switch (m.variable_filter) {
            1 => item.origin == 1,
            2 => item.origin == 2,
            3 => item.secret,
            else => true,
        };
        if (!keep) continue;
        if (drawn + 1 == capacity and drawn + 1 < shown.len) {
            const more = std.fmt.bufPrint(&name_buffer, "+{d} more", .{shown.len - drawn}) catch "";
            c.text(.small, more, .{ .x = vars.x + 8, .y = top + @as(f32, @floatFromInt(drawn)) * row_h, .w = vars.w - 8, .h = row_h - 8 }, .left, theme.muted);
            return;
        }
        const row: Rect = .{ .x = vars.x + 8, .y = top + @as(f32, @floatFromInt(drawn)) * row_h, .w = vars.w - 8, .h = row_h - 8 };
        c.fillRound(row, 8, theme.raised);
        const name = std.fmt.bufPrint(&name_buffer, "{{{{{s}}}}}", .{item.name}) catch item.name;
        c.text(.mono, name, .{ .x = row.x + 12, .y = row.y, .w = row.w * 0.4 - 12, .h = row.h }, .left, theme.amber);
        const revealed = index < 64 and m.revealed & (@as(u64, 1) << @intCast(index)) != 0;
        const value = if (item.secret and revealed) item.raw else item.value;
        const icons_w: f32 = if (item.secret) 60 else 32;
        c.text(.small, value, .{ .x = row.x + row.w * 0.42, .y = row.y, .w = row.w * 0.58 - icons_w - 6, .h = row.h }, .left, theme.text);
        const copy: Rect = .{ .x = row.right() - 30, .y = row.y + 6, .w = 24, .h = row.h - 12 };
        if (ui.hovered(copy)) c.fillRound(copy, 6, theme.border);
        c.text(.icon, theme.icon.copy, copy, .center, theme.muted);
        if (ui.pressed(copy)) ui.act(.copy_variable, index, copy);
        if (item.secret) {
            const eye: Rect = .{ .x = copy.x - 28, .y = copy.y, .w = 24, .h = copy.h };
            if (ui.hovered(eye)) c.fillRound(eye, 6, theme.border);
            c.text(.icon, if (revealed) theme.icon.eye_off else theme.icon.eye, eye, .center, theme.muted);
            if (ui.pressed(eye)) ui.act(.reveal_variable, index, eye);
        }
        drawn += 1;
    }
    if (drawn == 0) {
        c.text(.small, if (shown.len == 0) "None. Add variables to ztest.json beside your suites." else "No variables match this filter.", .{ .x = vars.x + 8, .y = top, .w = vars.w - 8, .h = 24 }, .left, theme.muted);
    }
}

fn drawResponse(ui: *Ui, r: Rect, editor: Rect) void {
    const c = ui.c;
    const m = ui.m;
    widgets.panel(c, r);
    c.text(.heading, "Response", .{ .x = r.x + 18, .y = r.y + 10, .w = r.w - 36, .h = 28 }, .left, theme.text);
    var buffer: [100]u8 = undefined;
    if (ui.api.phase == .completed) {
        const response = ui.api.response.?;
        const status = std.fmt.bufPrint(&buffer, "{d} {s}", .{ response.status, response.status_text }) catch "";
        const good = response.status < 400;
        const pill_w = c.measure(.small, status) + 30;
        widgets.pill(c, .{ .x = r.x + 18, .y = r.y + 44, .w = pill_w, .h = 30 }, status, if (good) theme.green else if (response.status < 500) theme.amber else theme.red, if (good) theme.green_dim else if (response.status < 500) theme.amber_dim else theme.red_dim);
        var x = r.x + 18 + pill_w + 22;
        var part: [48]u8 = undefined;
        const took = timefmt.duration(&part, response.duration_ns / std.time.ns_per_ms);
        c.text(.small, took, .{ .x = x, .y = r.y + 44, .w = 90, .h = 30 }, .left, theme.text);
        x += c.measure(.small, took) + 22;
        const size = timefmt.size(&part, response.size());
        c.text(.small, size, .{ .x = x, .y = r.y + 44, .w = 90, .h = 30 }, .left, theme.text);
        x += c.measure(.small, size) + 22;
        var date: [48]u8 = undefined;
        c.text(.small, timefmt.dateTime(&date, native.local(m.response_unix), true), .{ .x = x, .y = r.y + 44, .w = r.right() - x - 18, .h = 30 }, .left, theme.text);
    } else {
        c.text(.small, ui.api.message(), .{ .x = r.x + 18, .y = r.y + 46, .w = r.w - 36, .h = 26 }, .left, if (ui.api.phase == .failed) theme.red else theme.muted);
    }
    // Format, copy and expand sit at the end of the response tab row.
    const tools_y = r.y + 80;
    const expand: Rect = .{ .x = r.right() - 18 - 34, .y = tools_y, .w = 34, .h = 32 };
    const copy: Rect = .{ .x = expand.x - 8 - 34, .y = tools_y, .w = 34, .h = 32 };
    const format: Rect = .{ .x = copy.x - 8 - 96, .y = tools_y, .w = 96, .h = 32 };
    // Only when there is room after the four response tabs.
    if (format.x > r.x + 400) {
        if (widgets.menuButton(ui, format, null, if (m.pretty) "JSON" else "Text")) ui.act(.response_format, 0, format);
    }
    if (widgets.iconButton(ui, copy, theme.icon.copy)) ui.act(.response_copy, 0, copy);
    if (widgets.iconButton(ui, expand, theme.icon.expand)) ui.act(.response_expand, 0, expand);
    c.line(r.x + 12, r.y + 112, r.right() - 12, r.y + 112, theme.border, 1);
    drawGutter(c, .{ .x = editor.x - gutter_width, .y = editor.y, .w = gutter_width - 4, .h = editor.h }, &m.response_gutter);
}

fn drawAssertions(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const m = ui.m;
    widgets.panel(c, r);
    c.text(.heading, "Assertions", .{ .x = r.x + 18, .y = r.y + 10, .w = r.w - 200, .h = 28 }, .left, theme.text);
    const templates: Rect = .{ .x = r.right() - 18 - 140, .y = r.y + 10, .w = 140, .h = 32 };
    if (widgets.menuButton(ui, templates, theme.icon.swap, "Templates")) ui.act(.assert_templates, 0, templates);

    var scratch: [32 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    const rows = rows_model.parse(fixed.allocator(), m.tests_text.items) catch &.{};

    const add_zone: Rect = .{ .x = r.x + 14, .y = r.bottom() - 60, .w = r.w - 28, .h = 46 };
    const top = r.y + 52;
    const row_h: f32 = 82;
    const capacity: usize = @intFromFloat(@max(1, @floor((add_zone.y - 6 - top) / row_h)));
    const offset = @min(ui.state.assert_offset, rows.len -| capacity);
    ui.state.assert_offset = offset;

    // Each line is matched to the result for the same text, once.
    var used: [64]bool = @splat(false);
    var y = top;
    for (rows[offset..@min(rows.len, offset + capacity)]) |row| {
        var outcome: ?bool = null;
        var actual: []const u8 = "";
        for (ui.api.results, 0..) |result, i| {
            if (i < used.len and !used[i] and std.mem.eql(u8, result.assertion.text, row.text)) {
                used[i] = true;
                outcome = result.passed;
                actual = result.actual;
                break;
            }
        }
        drawAssertionRow(ui, .{ .x = r.x + 14, .y = y, .w = r.w - 28, .h = row_h - 8 }, row, outcome, actual);
        y += row_h;
    }
    if (rows.len == 0) {
        c.text(.small, "No assertions yet. Add one below, or type them in the Tests tab.", .{ .x = r.x + 18, .y = top, .w = r.w - 36, .h = 24 }, .left, theme.muted);
    } else if (rows.len > capacity) {
        var buffer: [48]u8 = undefined;
        const note = std.fmt.bufPrint(&buffer, "{d}-{d} of {d}, scroll for more", .{ offset + 1, @min(rows.len, offset + capacity), rows.len }) catch "";
        c.text(.tiny, note, .{ .x = r.x + 18, .y = add_zone.y - 20, .w = r.w - 36, .h = 16 }, .right, theme.muted);
    }

    // Dashed amber zone with the Add Assertion split button, as drawn.
    dashed(c, add_zone);
    const add: Rect = .{ .x = add_zone.x + add_zone.w / 2 - 88, .y = add_zone.y + 8, .w = 176, .h = 30 };
    const split = widgets.splitButton(ui, add, theme.icon.add, "Add Assertion", true);
    if (split.main) ui.act(.assert_add, 0, add);
    if (split.menu) ui.act(.assert_templates, 0, add);
}

fn dashed(c: anytype, r: Rect) void {
    const color = 0x80FFC83D;
    var x = r.x + 8;
    while (x < r.right() - 8) : (x += 10) {
        const end = @min(x + 5, r.right() - 8);
        c.line(x, r.y, end, r.y, color, 1);
        c.line(x, r.bottom(), end, r.bottom(), color, 1);
    }
    var y = r.y + 8;
    while (y < r.bottom() - 8) : (y += 10) {
        const end = @min(y + 5, r.bottom() - 8);
        c.line(r.x, y, r.x, end, color, 1);
        c.line(r.right(), y, r.right(), end, color, 1);
    }
}

fn drawAssertionRow(ui: *Ui, r: Rect, row: rows_model.Row, outcome: ?bool, actual: []const u8) void {
    const c = ui.c;
    c.strokeRound(r, 10, theme.border);
    const top: Rect = .{ .x = r.x, .y = r.y + 8, .w = r.w, .h = 36 };
    // Grey before a response, then green or red.
    const cx = r.x + 24;
    const cy = top.y + top.h / 2;
    if (outcome) |passed| {
        widgets.outcomeBadge(c, cx, cy, 12, if (passed) .passed else .failed);
    } else {
        c.circle(cx, cy, 12, theme.border);
        c.circle(cx, cy, 10, theme.panel);
    }
    const trash: Rect = .{ .x = r.right() - 38, .y = top.y + 4, .w = 28, .h = 28 };
    if (ui.hovered(trash)) c.fillRound(trash, 6, theme.raised);
    c.text(.icon, theme.icon.trash, trash, .center, theme.muted);
    if (ui.pressed(trash)) ui.act(.assert_delete, row.line, trash);

    const label_x = r.x + 48;
    const label_w: f32 = @min(118, r.w * 0.26);
    c.text(.body, row.label, .{ .x = label_x, .y = top.y, .w = label_w, .h = top.h }, .left, theme.text);
    const fields_x = label_x + label_w + 6;
    const fields_w = trash.x - 8 - fields_x;
    if (row.parsed == null) {
        const box: Rect = .{ .x = fields_x, .y = top.y, .w = fields_w, .h = top.h };
        c.fillRound(box, 8, theme.background);
        c.strokeRound(box, 8, theme.red);
        c.text(.mono, row.text, .{ .x = box.x + 10, .y = box.y, .w = box.w - 20, .h = box.h }, .left, theme.text);
        if (ui.pressed(box)) ui.act(.assert_edit, row.line, box);
    } else {
        const op_w = @min(130, fields_w * 0.4);
        const unit_w: f32 = if (row.unit.len > 0) 70 else 0;
        const op_box: Rect = .{ .x = fields_x, .y = top.y, .w = op_w, .h = top.h };
        if (widgets.dropdown(ui, op_box, row.operator, false)) ui.act(.assert_operator, row.line, op_box);
        const value_box: Rect = .{ .x = op_box.right() + 8, .y = top.y, .w = fields_w - op_w - 8 - (if (unit_w > 0) unit_w + 8 else 0), .h = top.h };
        c.fillRound(value_box, 8, theme.background);
        c.strokeRound(value_box, 8, if (ui.hovered(value_box)) theme.amber else theme.border);
        c.text(.mono, row.value, .{ .x = value_box.x + 10, .y = value_box.y, .w = value_box.w - 20, .h = value_box.h }, .left, theme.text);
        if (ui.pressed(value_box)) ui.act(.assert_edit, row.line, value_box);
        if (unit_w > 0) {
            const unit_box: Rect = .{ .x = value_box.right() + 8, .y = top.y, .w = unit_w, .h = top.h };
            c.fillRound(unit_box, 8, theme.background);
            c.strokeRound(unit_box, 8, theme.border);
            c.text(.small, row.unit, .{ .x = unit_box.x + 12, .y = unit_box.y, .w = unit_box.w - 34, .h = unit_box.h }, .left, theme.text);
            c.text(.icon, theme.icon.chevron_down, .{ .x = unit_box.right() - 24, .y = unit_box.y, .w = 16, .h = unit_box.h }, .left, theme.muted);
        }
    }
    var buffer: [256]u8 = undefined;
    const failed = outcome != null and !outcome.?;
    const text = if (failed) (std.fmt.bufPrint(&buffer, "Actual: {s}", .{actual}) catch actual) else rows_model.sentence(&buffer, row);
    c.text(.small, text, .{ .x = label_x, .y = r.y + 48, .w = r.w - 60, .h = 20 }, .left, if (failed or row.parsed == null) theme.red else theme.muted);
}
