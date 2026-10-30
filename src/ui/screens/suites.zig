//! Test suites, as drawn in `ui/`'s third mockup. Only the first sample suite
//! has run details; nothing can be run until the test runner exists.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const sample = @import("../sample.zig");
const state = @import("../state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const list_width = 270;
const suite_tabs = [_][]const u8{ "Execution Results", "Test Cases (42)", "Configuration", "History", "Artifacts" };
const detail_tabs = [_][]const u8{ "Request", "Response", "Logs", "Assertions" };

const totals = [_]struct { value: []const u8, label: []const u8, note: []const u8, color: u32, tint: u32, icon: []const u8 }{
    .{ .value = "42", .label = "Total Tests", .note = "", .color = theme.text, .tint = theme.raised, .icon = theme.icon.file },
    .{ .value = "38", .label = "Passed", .note = "90.5%", .color = theme.green, .tint = theme.green_dim, .icon = theme.icon.check },
    .{ .value = "3", .label = "Failed", .note = "7.1%", .color = theme.red, .tint = theme.red_dim, .icon = theme.icon.cross },
    .{ .value = "1", .label = "Skipped", .note = "2.4%", .color = theme.amber, .tint = theme.amber_dim, .icon = theme.icon.minus },
    .{ .value = "4m 32s", .label = "Total Duration", .note = "Avg. 6.5s / test", .color = theme.text, .tint = theme.raised, .icon = theme.icon.clock },
};

pub fn draw(ui: *Ui, area: Rect) f32 {
    const top = area.y + 16 - ui.state.scroll;
    const list: Rect = .{ .x = area.x + 20, .y = top, .w = list_width, .h = 0 };
    const detail: Rect = .{ .x = list.right() + 20, .y = top, .w = area.right() - list.right() - 40, .h = 0 };
    const list_end = drawList(ui, list);
    const detail_end = drawDetail(ui, detail);
    return @max(list_end, detail_end) - area.y + ui.state.scroll + theme.page_margin;
}

fn healthColor(health: state.SuiteHealth) u32 {
    return switch (health) {
        .active => theme.green,
        .failing => theme.red,
        .scheduled => theme.muted,
    };
}

fn count(filter: state.SuiteFilter) usize {
    var n: usize = 0;
    for (sample.suites) |suite| {
        if (filter.allows(suite.health)) n += 1;
    }
    return n;
}

fn drawList(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    c.text(.heading, "Test Suites", .{ .x = r.x, .y = r.y, .w = 140, .h = 36 }, .left, theme.text);
    widgets.disabledButton(c, .{ .x = r.right() - 104, .y = r.y, .w = 104, .h = 36 }, "New Suite", true);

    const filters = [_]state.SuiteFilter{ .all, .active, .scheduled };
    const names = [_][]const u8{ "All", "Active", "Scheduled" };
    const bar: Rect = .{ .x = r.x, .y = r.y + 48, .w = r.w, .h = 34 };
    for (filters, names, 0..) |filter, name, i| {
        var buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{s}  {d}", .{ name, count(filter) }) catch name;
        if (widgets.chip(ui, bar.column(i, filters.len, 8), label, null, ui.state.suite_filter == filter)) {
            ui.state.suite_filter = filter;
        }
    }

    var y = bar.bottom() + 10;
    for (sample.suites, 0..) |suite, i| {
        if (!ui.state.suite_filter.allows(suite.health)) continue;
        const row: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 58 };
        if (ui.pressed(row)) ui.state.suite = i;
        const selected = ui.state.suite == i;
        if (selected) {
            c.fillRound(row, 8, theme.amber_dim);
            c.strokeRound(row, 8, theme.amber);
        } else if (ui.hovered(row)) {
            c.fillRound(row, 8, theme.raised);
        }
        const badge: Rect = .{ .x = row.x + 10, .y = row.y + 12, .w = 34, .h = 34 };
        c.fillRound(badge, 8, theme.raised);
        c.text(.icon, theme.icon.layers, badge, .center, theme.text);
        c.text(.strong, suite.name, .{ .x = badge.right() + 12, .y = row.y + 9, .w = row.w - 90, .h = 20 }, .left, theme.text);
        var buffer: [48]u8 = undefined;
        const meta = std.fmt.bufPrint(&buffer, "{d} tests \u{00B7} Last run: {s}", .{ suite.tests, suite.last_run }) catch "";
        c.text(.small, meta, .{ .x = badge.right() + 12, .y = row.y + 30, .w = row.w - 90, .h = 18 }, .left, theme.muted);
        c.circle(row.right() - 16, row.y + 29, 4, healthColor(suite.health));
        y += 62;
    }
    return y;
}

fn drawDetail(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const suite = sample.suites[ui.state.suite];
    c.text(.subtitle, suite.name, .{ .x = r.x, .y = r.y, .w = r.w - 260, .h = 36 }, .left, theme.text);
    widgets.disabledButton(c, .{ .x = r.right() - 120, .y = r.y, .w = 120, .h = 36 }, "Run Suite", true);
    widgets.sampleTag(c, r.right() - 250, r.y + 5);

    var y = r.y + 54;
    if (ui.state.suite != 0) {
        const box: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 160 };
        widgets.panel(c, box);
        c.text(.body, "No run details for this suite in the sample data.", box, .center, theme.muted);
        return box.bottom();
    }

    c.text(.body, "End-to-end tests for the checkout flow: cart, payment, order creation, and confirmation.", .{ .x = r.x, .y = y - 8, .w = r.w, .h = 22 }, .left, theme.muted);
    y += 24;

    const row: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 84 };
    for (totals, 0..) |total, i| {
        const card = row.column(i, totals.len, 10);
        widgets.panel(c, card);
        const badge: Rect = .{ .x = card.right() - 34, .y = card.y + 10, .w = 24, .h = 24 };
        c.fillRound(badge, 6, total.tint);
        c.text(.icon, total.icon, badge, .center, total.color);
        const text_x = card.x + 12;
        const text_w = card.w - 18;
        c.text(.heading, total.value, .{ .x = text_x, .y = card.y + 10, .w = text_w - 26, .h = 24 }, .left, theme.text);
        c.text(.tiny, total.label, .{ .x = text_x, .y = card.y + 34, .w = text_w, .h = 18 }, .left, theme.muted);
        c.text(.tiny, total.note, .{ .x = text_x, .y = card.y + 52, .w = text_w, .h = 18 }, .left, total.color);
    }
    y += row.h + 12;

    const bar: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 40 };
    if (widgets.tabs(ui, bar, &suite_tabs, ui.state.suite_tab)) |tab| ui.state.suite_tab = tab;
    y = bar.bottom() + 12;

    if (ui.state.suite_tab != 0) {
        const box: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 160 };
        widgets.panel(c, box);
        c.text(.body, "Nothing to show in the sample data.", box, .center, theme.muted);
        return box.bottom();
    }
    return drawResults(ui, .{ .x = r.x, .y = y, .w = r.w, .h = 0 });
}

fn drawProgress(c: *Canvas, r: Rect) void {
    const parts = [_]struct { share: f32, color: u32 }{
        .{ .share = 38.0 / 42.0, .color = theme.green },
        .{ .share = 3.0 / 42.0, .color = theme.red },
        .{ .share = 1.0 / 42.0, .color = theme.amber },
    };
    var x = r.x;
    for (parts) |part| {
        c.fill(.{ .x = x, .y = r.y, .w = r.w * part.share, .h = r.h }, part.color);
        x += r.w * part.share;
    }
}

fn drawResults(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const inner_x = r.x + 16;
    const inner_w = r.w - 32;
    var y = r.y + 14;

    widgets.outcomeBadge(c, inner_x + 16, y + 18, 16, .passed);
    c.text(.strong, "Test Suite Execution Completed", .{ .x = inner_x + 44, .y = y, .w = inner_w - 44, .h = 20 }, .left, theme.text);
    c.text(.small, "Started Mar 16, 2024, 10:24 AM \u{00B7} Duration: 4m 32s \u{00B7} Environment: Production", .{ .x = inner_x + 44, .y = y + 20, .w = inner_w - 44, .h = 18 }, .left, theme.muted);
    y += 48;
    drawProgress(c, .{ .x = inner_x, .y = y, .w = inner_w, .h = 8 });
    y += 20;

    const filters = [_]state.ResultFilter{ .all, .passed, .failed, .skipped };
    const labels = [_][]const u8{ "All  42", "Passed  38", "Failed  3", "Skipped  1" };
    const dots = [_]?u32{ null, theme.green, theme.red, theme.amber };
    for (filters, labels, dots, 0..) |filter, label, dot, i| {
        const chip_rect: Rect = .{ .x = inner_x + @as(f32, @floatFromInt(i)) * 118, .y = y, .w = 110, .h = 32 };
        if (widgets.chip(ui, chip_rect, label, dot, ui.state.result_filter == filter)) {
            ui.state.result_filter = filter;
        }
    }
    y += 44;

    for (sample.groups, 0..) |group, index| {
        if (!groupVisible(ui.state.result_filter, group)) continue;
        y = drawGroup(ui, group, index, inner_x, inner_w, y);
    }

    const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = y + 8 - r.y };
    c.strokeRound(box, 12, theme.border);
    return box.bottom();
}

fn groupVisible(filter: state.ResultFilter, group: sample.TestGroup) bool {
    if (filter.allows(group.outcome)) return true;
    for (group.tests) |item| {
        if (filter.allows(item.outcome)) return true;
    }
    return false;
}

fn drawGroup(ui: *Ui, group: sample.TestGroup, index: usize, x: f32, w: f32, top: f32) f32 {
    const c = ui.c;
    var y = top;
    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 38 };
    const expandable = group.tests.len > 0;
    const open = expandable and ui.state.open_group == index;
    if (expandable and ui.pressed(row)) ui.state.open_group = state.toggled(ui.state.open_group, index);
    if (expandable) {
        const glyph = if (open) theme.icon.chevron_down else theme.icon.chevron_right;
        c.text(.icon, glyph, .{ .x = x, .y = y, .w = 18, .h = row.h }, .left, theme.muted);
    }
    widgets.outcomeBadge(c, x + 32, y + 19, 10, group.outcome);
    c.text(.strong, group.name, .{ .x = x + 52, .y = y, .w = 160, .h = row.h }, .left, theme.text);
    c.text(.small, group.summary, .{ .x = x + 214, .y = y, .w = w - 370, .h = row.h }, .left, theme.muted);
    widgets.outcomePill(c, .{ .x = row.right() - 136, .y = y + 8, .w = 66, .h = 23 }, group.outcome);
    c.text(.small, group.duration, .{ .x = row.right() - 60, .y = y, .w = 60, .h = row.h }, .right, theme.muted);
    y += row.h;
    if (!open) return y;

    for (group.tests, 0..) |item, i| {
        if (!ui.state.result_filter.allows(item.outcome)) continue;
        const test_row: Rect = .{ .x = x + 20, .y = y, .w = w - 20, .h = 34 };
        // Only the payment failure has sample details.
        const has_details = i == 3;
        if (has_details and ui.pressed(test_row)) ui.state.open_test = state.toggled(ui.state.open_test, i);
        if (has_details and ui.hovered(test_row)) c.fillRound(test_row, 6, theme.raised);
        widgets.outcomeBadge(c, test_row.x + 22, y + 17, 9, item.outcome);
        c.text(.body, item.name, .{ .x = test_row.x + 40, .y = y, .w = 210, .h = test_row.h }, .left, theme.text);
        var buffer: [64]u8 = undefined;
        const route = std.fmt.bufPrint(&buffer, "{s} {s}", .{ item.method, item.path }) catch "";
        c.text(.tiny, route, .{ .x = test_row.x + 256, .y = y, .w = test_row.w - 410, .h = test_row.h }, .left, theme.muted);
        c.text(.small, item.duration, .{ .x = test_row.right() - 142, .y = y, .w = 60, .h = test_row.h }, .right, theme.text);
        widgets.outcomePill(c, .{ .x = test_row.right() - 72, .y = y + 6, .w = 66, .h = 22 }, item.outcome);
        y += test_row.h;

        if (has_details and ui.state.open_test == i) y = drawDetails(ui, x + 40, w - 40, y);
    }
    return y;
}

fn drawDetails(ui: *Ui, x: f32, w: f32, top: f32) f32 {
    const c = ui.c;
    const box: Rect = .{ .x = x, .y = top + 4, .w = w, .h = 150 };
    c.fillRound(box, 8, theme.background);
    c.strokeRound(box, 8, theme.border);
    const bar: Rect = .{ .x = box.x + 10, .y = box.y + 4, .w = box.w - 20, .h = 34 };
    if (widgets.tabs(ui, bar, &detail_tabs, ui.state.detail_tab)) |tab| ui.state.detail_tab = tab;

    var y = bar.bottom() + 8;
    for (sample.test_details[ui.state.detail_tab]) |line| {
        const failing = std.mem.indexOf(u8, line, "ERROR") != null or std.mem.startsWith(u8, line, "  expected");
        c.text(.mono, line, .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, if (failing) theme.red else theme.text);
        y += 21;
    }
    return box.bottom() + 6;
}
