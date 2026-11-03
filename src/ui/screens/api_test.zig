//! Live API builder in the layout of ui's API Test mockup.
const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");
const draft = @import("../../core/http/draft.zig");

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

/// Native tab buttons use the same positions as the painted tab underline.
pub fn requestTabs(area: Rect) [5]Rect {
    const r = layout(area).request;
    return tabBoxes(&.{ 76, 84, 64, 64, 64 }, .{ .x = r.x + 18, .y = r.y + 96, .w = r.w - 36, .h = 38 });
}

pub fn responseTabs(area: Rect) [4]Rect {
    const r = layout(area).response;
    return tabBoxes(&.{ 64, 84, 80, 60 }, .{ .x = r.x + 12, .y = r.y + 80, .w = r.w - 24, .h = 32 });
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
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    const request: Rect = .{ .x = x, .y = area.y + 114, .w = w, .h = @min(374, @max(260, area.h * 0.42)) };
    const content: Rect = .{ .x = x + 18, .y = request.y + 146, .w = w - 36, .h = request.h - 164 };
    const vars_w = @min(300, content.w * 0.28);
    const editor: Rect = .{ .x = content.x + 172, .y = content.y + 38, .w = content.w - 172 - vars_w - 12, .h = content.h - 38 };
    const lower_y = request.bottom() + theme.gap;
    const lower_h = @max(150, @min(386, area.bottom() - lower_y - theme.page_margin));
    const left_w = (w - theme.gap) * 0.54;
    return .{
        .request = request,
        .content = content,
        .editor = editor,
        .variables = .{ .x = content.right() - vars_w, .y = content.y, .w = vars_w, .h = content.h },
        .response = .{ .x = x, .y = lower_y, .w = left_w, .h = lower_h },
        .assertions = .{ .x = x + left_w + theme.gap, .y = lower_y, .w = w - left_w - theme.gap, .h = lower_h },
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

/// The painted panels and real controls share exactly the same geometry.
pub fn controls(area: Rect) Controls {
    const l = layout(area);
    const method: Rect = .{ .x = l.request.x + 18, .y = l.request.y + 48, .w = 116, .h = 40 };
    const send: Rect = .{ .x = l.request.right() - 124, .y = method.y, .w = 106, .h = method.h };
    // Params, Headers and Tests share one editor area below a hint line.
    const text_editor: Rect = .{ .x = l.content.x + 8, .y = l.content.y + 28, .w = l.content.w - 16, .h = l.content.h - 28 };
    const auth = authRows(l.content);
    return .{
        .method = .{ .x = method.x + 7, .y = method.y + 7, .w = method.w - 14, .h = 26 },
        .url = .{ .x = method.right() + 12, .y = method.y + 7, .w = send.x - method.right() - 26, .h = 26 },
        .send = send,
        .params = text_editor,
        .headers = text_editor,
        .auth_kind = auth[0],
        .auth_name = auth[1],
        .auth_value = auth[2],
        .body_kind = .{ .x = l.editor.x, .y = l.content.y, .w = 110, .h = 30 },
        .body = l.editor.inset(8),
        .tests = text_editor,
        .response = .{ .x = l.response.x + 18, .y = l.response.y + 120, .w = l.response.w - 36, .h = @max(30, l.response.h - 136) },
    };
}

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const l = layout(area);
    const boxes = controls(area);
    const x = l.request.x;
    const w = l.request.w;
    const y = area.y + 14;
    var title_buffer: [160]u8 = undefined;
    const file_name = ui.workspace.fileName();
    c.text(.small, if (file_name) |name| name else "API Tests", .{ .x = x, .y = y, .w = w - 360, .h = 20 }, .left, theme.muted);
    const title = std.fmt.bufPrint(&title_buffer, "{s} - API Test", .{ui.workspace.title()}) catch "API Test";
    const count = ui.workspace.testCount();
    const switcher_w: f32 = if (count > 1) 150 else 0;
    c.text(.title, title, .{ .x = x, .y = y + 20, .w = w - 360 - switcher_w, .h = 44 }, .left, theme.text);
    if (count > 1) {
        // A suite holds several tests; these step through them.
        const box: Rect = .{ .x = x + w - 360 - switcher_w, .y = y + 26, .w = switcher_w - 12, .h = 34 };
        const index = if (ui.workspace.file) |file| file.test_index + 1 else 1;
        const label = std.fmt.bufPrint(title_buffer[100..], "{d} of {d}", .{ index, count }) catch "";
        if (widgets.button(ui, .{ .x = box.x, .y = box.y, .w = 32, .h = box.h }, "<", false) and !ui.api.busy()) ui.action = .previous_test;
        c.text(.small, label, .{ .x = box.x + 34, .y = box.y, .w = box.w - 68, .h = box.h }, .center, theme.text);
        if (widgets.button(ui, .{ .x = box.right() - 32, .y = box.y, .w = 32, .h = box.h }, ">", false) and !ui.api.busy()) ui.action = .next_test;
    }
    const status = if (ui.workspace.message.len > 0) ui.workspace.message else "Build a request and inspect its response. Ctrl+S saves, Ctrl+O opens.";
    const status_color = if (std.mem.startsWith(u8, status, "Not saved") or std.mem.startsWith(u8, status, "Cannot")) theme.red else theme.muted;
    c.text(.body, status, .{ .x = x, .y = y + 66, .w = w, .h = 22 }, .left, status_color);
    if (widgets.button(ui, .{ .x = x + w - 340, .y = y + 24, .w = 90, .h = 38 }, "Open", false)) ui.action = .open;
    if (widgets.button(ui, .{ .x = x + w - 240, .y = y + 24, .w = 90, .h = 38 }, "Save", false)) ui.action = .save;
    if (widgets.button(ui, .{ .x = x + w - 140, .y = y + 24, .w = 140, .h = 38 }, if (ui.api.busy()) "Cancel" else "Run Test", true)) ui.action = .send;

    widgets.panel(c, l.request);
    c.text(.heading, "Request", .{ .x = x + 18, .y = l.request.y + 10, .w = 150, .h = 28 }, .left, theme.text);
    if (widgets.button(ui, .{ .x = x + w - 284, .y = l.request.y + 9, .w = 110, .h = 28 }, "New", false)) ui.action = .new;
    if (widgets.button(ui, .{ .x = x + w - 164, .y = l.request.y + 9, .w = 146, .h = 28 }, "Save as Test...", false)) ui.action = .save_as;
    const method_frame: Rect = .{ .x = boxes.method.x - 7, .y = boxes.method.y - 7, .w = boxes.method.w + 14, .h = 40 };
    c.fillRound(method_frame, 8, theme.background);
    c.strokeRound(method_frame, 8, theme.border);
    const url_frame: Rect = .{ .x = boxes.url.x - 7, .y = method_frame.y, .w = boxes.url.w + 14, .h = 40 };
    c.fillRound(url_frame, 8, theme.background);
    c.strokeRound(url_frame, 8, theme.border);
    c.line(x + 18, l.request.y + 134, x + w - 18, l.request.y + 134, theme.border, 1);
    switch (ui.state.request_tab) {
        0 => hint(ui, l.content, "One name=value per line, added to the URL encoded. Start a line with # to switch it off."),
        1 => hint(ui, l.content, "One Name: value per line. Duplicates are kept. Start a line with # to switch it off."),
        2 => drawAuth(ui, l.content),
        3 => drawBody(ui, l),
        else => hint(ui, l.content, "One assertion per line, such as status == 200, body.id exists or response_time < 500ms."),
    }
    drawResponse(ui, l.response);
    drawAssertions(ui, l.assertions);
    return area.h;
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
        const selected = ui.state.body_type == i;
        if (selected) c.fillRound(row, 6, theme.amber_dim);
        c.circle(row.x + 14, row.y + row.h / 2, 7, if (selected) theme.amber else theme.border);
        if (selected) c.circle(row.x + 14, row.y + row.h / 2, 3, theme.on_amber);
        c.text(.small, label, .{ .x = row.x + 30, .y = row.y, .w = row.w - 32, .h = row.h }, .left, if (supported) theme.text else theme.muted);
    }
    c.fillRound(l.editor, 8, theme.background);
    c.strokeRound(l.editor, 8, theme.border);
    drawVariables(ui, l.variables);
}

/// The values `{{name}}` takes with the chosen environment, secrets masked.
fn drawVariables(ui: *Ui, vars: Rect) void {
    const c = ui.c;
    c.text(.strong, "Environment Variables", .{ .x = vars.x + 8, .y = vars.y, .w = vars.w - 8, .h = 28 }, .left, theme.text);
    if (ui.workspace.config_problem) |problem| {
        c.text(.small, problem, .{ .x = vars.x + 8, .y = vars.y + 34, .w = vars.w - 8, .h = 40 }, .left, theme.red);
        return;
    }
    var buffer: [16 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const shown = ui.workspace.shownVariables(fixed.allocator()) catch &.{};
    if (shown.len == 0) {
        c.text(.small, "None. Add variables to ztest.json", .{ .x = vars.x + 8, .y = vars.y + 34, .w = vars.w - 8, .h = 24 }, .left, theme.muted);
        c.text(.small, "beside your .ztest file.", .{ .x = vars.x + 8, .y = vars.y + 56, .w = vars.w - 8, .h = 24 }, .left, theme.muted);
        return;
    }
    const row_h: f32 = 30;
    const capacity: usize = @intFromFloat(@max(1, @floor((vars.h - 34) / row_h)));
    var name_buffer: [80]u8 = undefined;
    for (shown, 0..) |item, i| {
        if (i + 1 == capacity and shown.len > capacity) {
            const more = std.fmt.bufPrint(&name_buffer, "+{d} more", .{shown.len - i}) catch "";
            c.text(.small, more, .{ .x = vars.x + 8, .y = vars.y + 34 + @as(f32, @floatFromInt(i)) * row_h, .w = vars.w - 8, .h = row_h - 4 }, .left, theme.muted);
            break;
        }
        const row: Rect = .{ .x = vars.x + 8, .y = vars.y + 34 + @as(f32, @floatFromInt(i)) * row_h, .w = vars.w - 8, .h = row_h - 4 };
        c.fillRound(row, 6, theme.raised);
        const name = std.fmt.bufPrint(&name_buffer, "{{{{{s}}}}}", .{item.name}) catch item.name;
        c.text(.mono, name, .{ .x = row.x + 8, .y = row.y, .w = row.w * 0.48, .h = row.h }, .left, theme.key);
        c.text(.small, item.value, .{ .x = row.x + row.w * 0.5, .y = row.y, .w = row.w * 0.48, .h = row.h }, .left, theme.muted);
    }
}

fn drawResponse(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    c.text(.heading, "Response", .{ .x = r.x + 18, .y = r.y + 10, .w = r.w - 36, .h = 28 }, .left, theme.text);
    var buffer: [100]u8 = undefined;
    if (ui.api.phase == .completed) {
        const response = ui.api.response.?;
        const status = std.fmt.bufPrint(&buffer, "{d}", .{response.status}) catch "";
        widgets.pill(c, .{ .x = r.x + 18, .y = r.y + 46, .w = 70, .h = 26 }, status, if (response.status < 400) theme.green else theme.amber, if (response.status < 400) theme.green_dim else theme.amber_dim);
        const summary = std.fmt.bufPrint(&buffer, "{d} ms     {d} bytes", .{ response.duration_ns / std.time.ns_per_ms, response.size() }) catch "";
        c.text(.small, summary, .{ .x = r.x + 100, .y = r.y + 46, .w = r.w - 116, .h = 26 }, .left, theme.text);
    } else {
        c.text(.small, ui.api.message(), .{ .x = r.x + 18, .y = r.y + 46, .w = r.w - 36, .h = 26 }, .left, if (ui.api.phase == .failed) theme.red else theme.muted);
    }
    c.line(r.x + 12, r.y + 112, r.right() - 12, r.y + 112, theme.border, 1);
}

fn drawAssertions(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    c.text(.heading, "Assertions", .{ .x = r.x + 18, .y = r.y + 10, .w = r.w - 36, .h = 28 }, .left, theme.text);
    var buffer: [96]u8 = undefined;
    const add: Rect = .{ .x = r.x + 14, .y = r.bottom() - 38, .w = r.w - 28, .h = 26 };
    defer if (widgets.button(ui, add, if (ui.state.request_tab == 4) "Edit assertions above" else "Edit Assertions", false)) {
        ui.action = .edit_tests;
    };

    const counts = ui.api.assertionCounts() orelse {
        const text: []const u8 = if (ui.api.phase == .completed)
            "No assertions ran. Add them in the Tests tab."
        else
            "Assertions in the Tests tab run on every response.";
        c.text(.small, text, .{ .x = r.x + 18, .y = r.y + 46, .w = r.w - 36, .h = 26 }, .left, theme.muted);
        return;
    };
    const summary = std.fmt.bufPrint(&buffer, "{d} passed, {d} failed", .{ counts.passed, counts.failed }) catch "";
    widgets.pill(c, .{ .x = r.right() - 150, .y = r.y + 12, .w = 132, .h = 24 }, summary, if (counts.failed == 0) theme.green else theme.red, if (counts.failed == 0) theme.green_dim else theme.red_dim);

    const results = ui.api.results;
    const top = r.y + 46;
    const bottom = add.y - 8;
    const capacity: usize = @intFromFloat(@max(1, @floor((bottom - top) / 42)));
    // Failures first, because they are what the user needs to read.
    var shown: usize = 0;
    for ([_]bool{ false, true }) |want| {
        for (results) |result| {
            if (result.passed != want) continue;
            if (shown == capacity) break;
            const row: Rect = .{ .x = r.x + 14, .y = top + @as(f32, @floatFromInt(shown)) * 42, .w = r.w - 28, .h = 38 };
            c.strokeRound(row, 8, theme.border);
            widgets.outcomeBadge(c, row.x + 16, row.y + row.h / 2, 8, if (result.passed) .passed else .failed);
            const text_x = row.x + 32;
            const text_w = row.w - 40;
            if (result.passed) {
                c.text(.mono, result.assertion.text, .{ .x = text_x, .y = row.y, .w = text_w, .h = row.h }, .left, theme.text);
            } else {
                c.text(.mono, result.assertion.text, .{ .x = text_x, .y = row.y + 2, .w = text_w, .h = 18 }, .left, theme.text);
                const actual = std.fmt.bufPrint(&buffer, "Actual: {s}", .{result.actual}) catch result.actual;
                c.text(.small, actual, .{ .x = text_x, .y = row.y + 19, .w = text_w, .h = 17 }, .left, theme.red);
            }
            shown += 1;
        }
    }
    if (shown < results.len) {
        const more = std.fmt.bufPrint(&buffer, "+{d} more", .{results.len - shown}) catch "";
        c.text(.small, more, .{ .x = r.x + 18, .y = bottom - 20, .w = r.w - 36, .h = 20 }, .left, theme.muted);
    }
}
