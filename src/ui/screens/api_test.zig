//! Live API builder in the layout of ui's API Test mockup.
const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

pub const Controls = struct { method: Rect, url: Rect, send: Rect, headers: Rect, body_kind: Rect, body: Rect, response: Rect };
pub const Layout = struct { request: Rect, content: Rect, editor: Rect, variables: Rect, response: Rect, assertions: Rect };
pub const request_tab_labels = .{ "Params", "Headers", "Auth", "Body", "Tests" };
pub const response_tab_labels = .{ "Body", "Headers", "Cookies", "Raw" };
pub const body_mode_labels = .{ "none", "raw" };

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

/// The painted panels and real controls share exactly the same geometry.
pub fn controls(area: Rect) Controls {
    const l = layout(area);
    const method: Rect = .{ .x = l.request.x + 18, .y = l.request.y + 48, .w = 116, .h = 40 };
    const send: Rect = .{ .x = l.request.right() - 124, .y = method.y, .w = 106, .h = method.h };
    return .{
        .method = .{ .x = method.x + 7, .y = method.y + 7, .w = method.w - 14, .h = 26 },
        .url = .{ .x = method.right() + 12, .y = method.y + 7, .w = send.x - method.right() - 26, .h = 26 },
        .send = send,
        .headers = .{ .x = l.content.x + 8, .y = l.content.y + 28, .w = l.content.w - 16, .h = l.content.h - 28 },
        .body_kind = .{ .x = l.editor.x, .y = l.content.y, .w = 110, .h = 30 },
        .body = l.editor.inset(8),
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
    c.text(.small, "API Tests", .{ .x = x, .y = y, .w = 200, .h = 20 }, .left, theme.muted);
    c.text(.title, "Untitled - API Test", .{ .x = x, .y = y + 20, .w = w - 260, .h = 44 }, .left, theme.text);
    c.text(.body, "Build a request and inspect its response.", .{ .x = x, .y = y + 66, .w = w, .h = 22 }, .left, theme.muted);
    widgets.disabledButton(c, .{ .x = x + w - 230, .y = y + 24, .w = 90, .h = 38 }, "Save", false);
    widgets.disabledButton(c, .{ .x = x + w - 130, .y = y + 24, .w = 130, .h = 38 }, "Run Test", true);

    widgets.panel(c, l.request);
    c.text(.heading, "Request", .{ .x = x + 18, .y = l.request.y + 10, .w = 150, .h = 28 }, .left, theme.text);
    widgets.disabledButton(c, .{ .x = x + w - 330, .y = l.request.y + 9, .w = 145, .h = 28 }, "Code Snippets", false);
    widgets.disabledButton(c, .{ .x = x + w - 174, .y = l.request.y + 9, .w = 156, .h = 28 }, "Save as Test", false);
    const method_frame: Rect = .{ .x = boxes.method.x - 7, .y = boxes.method.y - 7, .w = boxes.method.w + 14, .h = 40 };
    c.fillRound(method_frame, 8, theme.background);
    c.strokeRound(method_frame, 8, theme.border);
    const url_frame: Rect = .{ .x = boxes.url.x - 7, .y = method_frame.y, .w = boxes.url.w + 14, .h = 40 };
    c.fillRound(url_frame, 8, theme.background);
    c.strokeRound(url_frame, 8, theme.border);
    c.line(x + 18, l.request.y + 134, x + w - 18, l.request.y + 134, theme.border, 1);
    switch (ui.state.request_tab) {
        0 => note(ui, l.content, "Query Parameters", "Add query parameters directly to the URL above."),
        1 => c.text(.small, "One Name: value per line. Duplicate headers are preserved.", .{ .x = l.content.x + 8, .y = l.content.y, .w = l.content.w - 16, .h = 22 }, .left, theme.muted),
        2 => note(ui, l.content, "Authentication", "Use the Headers tab to supply authentication headers."),
        3 => drawBody(ui, l),
        else => note(ui, l.content, "Assertions", "Assertion editing is planned. Responses are shown below."),
    }
    drawResponse(ui, l.response);
    drawAssertions(ui, l.assertions);
    return area.h;
}

fn note(ui: *Ui, r: Rect, heading: []const u8, text: []const u8) void {
    ui.c.text(.strong, heading, .{ .x = r.x + 10, .y = r.y + 12, .w = r.w - 20, .h = 28 }, .left, theme.text);
    ui.c.text(.body, text, .{ .x = r.x + 10, .y = r.y + 48, .w = r.w - 20, .h = 26 }, .left, theme.muted);
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
    const vars = l.variables;
    c.text(.strong, "Environment Variables", .{ .x = vars.x + 8, .y = vars.y, .w = vars.w - 8, .h = 28 }, .left, theme.text);
    const row_h = @min(42, (vars.h - 36) / 3);
    for ([_][]const u8{ "{{baseUrl}}", "{{apiKey}}", "{{env}}" }, 0..) |label, i| {
        const row: Rect = .{ .x = vars.x + 8, .y = vars.y + 34 + @as(f32, @floatFromInt(i)) * row_h, .w = vars.w - 8, .h = row_h - 6 };
        c.fillRound(row, 8, theme.raised);
        c.text(.mono, label, .{ .x = row.x + 8, .y = row.y, .w = row.w * 0.52, .h = row.h }, .left, theme.key);
        c.text(.small, "Not set", .{ .x = row.x + row.w * 0.55, .y = row.y, .w = row.w * 0.4, .h = row.h }, .left, theme.muted);
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
    const row_h = @min(88, (r.h - 90) / 3);
    for ([_]struct { label: []const u8, value: []const u8 }{ .{ .label = "Status code", .value = "equals  200" }, .{ .label = "Response time", .value = "less than  500 ms" }, .{ .label = "Body property", .value = "exists  body.token" } }, 0..) |item, i| {
        const row: Rect = .{ .x = r.x + 14, .y = r.y + 46 + @as(f32, @floatFromInt(i)) * row_h, .w = r.w - 28, .h = row_h - 6 };
        c.strokeRound(row, 8, theme.border);
        c.circle(row.x + 16, row.y + row.h / 2, 6, theme.border);
        c.text(.small, item.label, .{ .x = row.x + 32, .y = row.y, .w = row.w * 0.43, .h = row.h }, .left, theme.text);
        c.text(.small, item.value, .{ .x = row.x + row.w * 0.53, .y = row.y, .w = row.w * 0.44, .h = row.h }, .left, theme.muted);
    }
    widgets.disabledButton(c, .{ .x = r.x + 14, .y = r.bottom() - 38, .w = r.w - 28, .h = 26 }, "Add Assertion (planned)", true);
}
