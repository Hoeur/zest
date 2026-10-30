//! API test builder, as drawn in `ui/`'s second mockup. Shows a sample request;
//! nothing can be sent until the HTTP engine exists.

const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const sample = @import("../sample.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const request_tabs = [_][]const u8{ "Params (2)", "Headers (3)", "Auth", "Body", "Tests" };
const response_tabs = [_][]const u8{ "Body", "Headers (3)", "Cookies (2)", "Raw" };

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    var y = area.y + 14 - ui.state.scroll;

    c.text(.small, "API Tests", .{ .x = x, .y = y, .w = 200, .h = 20 }, .left, theme.muted);
    c.text(.title, "Create User - API Test", .{ .x = x, .y = y + 20, .w = w - 300, .h = 44 }, .left, theme.text);
    c.text(.body, "Create a new user account and verify the response contains a valid token.", .{ .x = x, .y = y + 64, .w = w - 130, .h = 22 }, .left, theme.muted);
    widgets.sampleTag(c, x + w - 120, y + 64);
    widgets.disabledButton(c, .{ .x = x + w - 230, .y = y + 22, .w = 90, .h = 38 }, "Save", false);
    widgets.disabledButton(c, .{ .x = x + w - 130, .y = y + 22, .w = 130, .h = 38 }, "Run Test", true);
    y += 100;

    const request: Rect = .{ .x = x, .y = y, .w = w, .h = 374 };
    drawRequest(ui, request);
    y += request.h + theme.gap;

    const left_width = (w - theme.gap) * 0.54;
    const lower: f32 = 386;
    drawResponse(ui, .{ .x = x, .y = y, .w = left_width, .h = lower });
    drawAssertions(c, .{ .x = x + left_width + theme.gap, .y = y, .w = w - left_width - theme.gap, .h = lower });
    return y + lower - area.y + ui.state.scroll + theme.page_margin;
}

fn drawRequest(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    c.text(.heading, "Request", .{ .x = r.x + 18, .y = r.y + 12, .w = 200, .h = 26 }, .left, theme.text);

    const method: Rect = .{ .x = r.x + 18, .y = r.y + 48, .w = 116, .h = 40 };
    c.fillRound(method, 8, theme.background);
    c.strokeRound(method, 8, theme.border);
    c.text(.strong, "POST", .{ .x = method.x + 14, .y = method.y, .w = 60, .h = method.h }, .left, theme.amber);
    c.text(.icon, theme.icon.chevron_down, .{ .x = method.right() - 28, .y = method.y, .w = 18, .h = method.h }, .left, theme.muted);

    const send: Rect = .{ .x = r.right() - 124, .y = method.y, .w = 106, .h = method.h };
    const url: Rect = .{ .x = method.right() + 10, .y = method.y, .w = send.x - method.right() - 20, .h = method.h };
    c.fillRound(url, 8, theme.background);
    c.strokeRound(url, 8, theme.border);
    const variable = "{{baseUrl}}";
    c.text(.mono, variable, .{ .x = url.x + 14, .y = url.y, .w = 100, .h = url.h }, .left, theme.blue);
    const after = c.measure(.mono, variable);
    c.text(.mono, "/api/v1/users", .{ .x = url.x + 14 + after, .y = url.y, .w = 200, .h = url.h }, .left, theme.text);
    widgets.disabledButton(c, send, "Send", true);

    const bar: Rect = .{ .x = r.x + 18, .y = r.y + 96, .w = r.w - 36, .h = 38 };
    if (widgets.tabs(ui, bar, &request_tabs, ui.state.request_tab)) |tab| ui.state.request_tab = tab;

    const content: Rect = .{ .x = r.x + 18, .y = bar.bottom() + 12, .w = r.w - 36, .h = r.bottom() - bar.bottom() - 24 };
    switch (ui.state.request_tab) {
        0 => drawPairs(c, content, &sample.params),
        1 => drawPairs(c, content, &sample.request_headers),
        2 => drawPairs(c, content, &sample.auth),
        3 => drawBody(ui, content),
        else => drawAssertionSummary(c, content),
    }
}

fn drawPairs(c: *Canvas, r: Rect, pairs: []const sample.Pair) void {
    var y = r.y;
    for (pairs) |pair| {
        c.text(.mono, pair.key, .{ .x = r.x + 8, .y = y, .w = r.w * 0.35, .h = 34 }, .left, theme.key);
        c.text(.mono, pair.value, .{ .x = r.x + r.w * 0.35 + 16, .y = y, .w = r.w * 0.6, .h = 34 }, .left, theme.text);
        y += 34;
        c.line(r.x, y, r.right(), y, theme.grid, 1);
    }
}

fn drawAssertionSummary(c: *Canvas, r: Rect) void {
    var y = r.y;
    for (sample.assertions) |item| {
        c.text(.body, item.note, .{ .x = r.x + 8, .y = y, .w = r.w - 16, .h = 34 }, .left, theme.text);
        y += 34;
        c.line(r.x, y, r.right(), y, theme.grid, 1);
    }
}

fn drawBody(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const list_w = 172;
    const vars_w = @min(300, r.w * 0.3);

    var y = r.y;
    for (sample.body_types, 0..) |name, i| {
        const row: Rect = .{ .x = r.x, .y = y, .w = list_w, .h = 32 };
        if (ui.pressed(row)) ui.state.body_type = i;
        const selected = ui.state.body_type == i;
        if (selected) c.fillRound(row, 6, theme.amber_dim);
        c.circle(row.x + 16, row.y + 16, 7, if (selected) theme.amber else theme.border);
        if (selected) c.circle(row.x + 16, row.y + 16, 3, theme.on_amber);
        c.text(.small, name, .{ .x = row.x + 32, .y = row.y, .w = row.w - 36, .h = row.h }, .left, theme.text);
        y += 34;
    }

    const editor: Rect = .{ .x = r.x + list_w + 12, .y = r.y, .w = r.w - list_w - vars_w - 24, .h = r.h };
    c.fillRound(editor, 8, theme.background);
    c.strokeRound(editor, 8, theme.border);
    if (ui.state.body_type == 3) {
        widgets.code(c, editor.inset(6), &sample.request_body, true);
    } else {
        c.text(.body, "No sample body for this type.", editor, .center, theme.muted);
    }

    const vars: Rect = .{ .x = r.right() - vars_w, .y = r.y, .w = vars_w, .h = r.h };
    c.text(.strong, "Environment Variables", .{ .x = vars.x, .y = vars.y, .w = vars.w, .h = 24 }, .left, theme.text);
    var row_y = vars.y + 30;
    for (sample.variables) |variable| {
        const row: Rect = .{ .x = vars.x, .y = row_y, .w = vars.w, .h = 38 };
        c.fillRound(row, 8, theme.raised);
        c.text(.mono, variable.key, .{ .x = row.x + 10, .y = row.y, .w = 96, .h = row.h }, .left, theme.key);
        c.text(.small, variable.value, .{ .x = row.x + 108, .y = row.y, .w = row.w - 114, .h = row.h }, .left, theme.text);
        row_y += 44;
    }
}

fn drawResponse(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    c.text(.heading, "Response", .{ .x = r.x + 18, .y = r.y + 12, .w = 200, .h = 26 }, .left, theme.text);

    const y = r.y + 46;
    widgets.pill(c, .{ .x = r.x + 18, .y = y, .w = 70, .h = 26 }, "200 OK", theme.green, theme.green_dim);
    c.text(.small, "245 ms", .{ .x = r.x + 100, .y = y, .w = 60, .h = 26 }, .left, theme.text);
    c.text(.small, "1.2 KB", .{ .x = r.x + 160, .y = y, .w = 60, .h = 26 }, .left, theme.text);
    c.text(.small, "Mar 16, 2024, 10:22:41 AM", .{ .x = r.x + 220, .y = y, .w = r.w - 236, .h = 26 }, .left, theme.muted);

    const bar: Rect = .{ .x = r.x + 18, .y = r.y + 80, .w = r.w - 36, .h = 36 };
    if (widgets.tabs(ui, bar, &response_tabs, ui.state.response_tab)) |tab| ui.state.response_tab = tab;

    const content: Rect = .{ .x = r.x + 18, .y = bar.bottom() + 8, .w = r.w - 36, .h = r.bottom() - bar.bottom() - 16 };
    switch (ui.state.response_tab) {
        0 => widgets.code(c, content, &sample.response_body, true),
        1 => drawPairs(c, content, &sample.response_headers),
        2 => drawPairs(c, content, &sample.response_cookies),
        else => widgets.code(c, content, &sample.response_raw, false),
    }
}

fn drawAssertions(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    c.text(.heading, "Assertions", .{ .x = r.x + 18, .y = r.y + 12, .w = 200, .h = 26 }, .left, theme.text);

    var y = r.y + 50;
    for (sample.assertions) |item| {
        const row: Rect = .{ .x = r.x + 14, .y = y, .w = r.w - 28, .h = 88 };
        c.strokeRound(row, 8, theme.border);
        widgets.outcomeBadge(c, row.x + 22, row.y + 26, 12, .passed);
        c.text(.small, item.target, .{ .x = row.x + 42, .y = row.y + 8, .w = 90, .h = 36 }, .left, theme.text);
        const rest = row.w - 146;
        widgets.field(c, .{ .x = row.x + 136, .y = row.y + 8, .w = rest * 0.5, .h = 36 }, item.operator, true);
        widgets.field(c, .{ .x = row.x + 142 + rest * 0.5, .y = row.y + 8, .w = rest * 0.5 - 6, .h = 36 }, item.expected, false);
        c.text(.tiny, item.note, .{ .x = row.x + 42, .y = row.y + 54, .w = row.w - 54, .h = 22 }, .left, theme.muted);
        y += 96;
    }
    widgets.disabledButton(c, .{ .x = r.x + 14, .y = y + 4, .w = r.w - 28, .h = 36 }, "Add Assertion", false);
}
