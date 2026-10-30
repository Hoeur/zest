//! Dashboard, as drawn in `ui/`'s first mockup. All figures come from `sample.zig`.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const sample = @import("../sample.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const stats = [_]sample.Stat{
    .{ .label = "Total Test Suites", .value = "12", .delta = "+2", .trend = .up_good, .icon = theme.icon.layers, .color = theme.amber, .tint = theme.raised, .bars = .{ 3, 4, 3, 5, 4, 6, 5, 7, 5, 8, 6, 9 } },
    .{ .label = "Passing Tests", .value = "342", .delta = "+12%", .trend = .up_good, .icon = theme.icon.check, .color = theme.green, .tint = theme.green_dim, .bars = .{ 4, 5, 4, 6, 5, 6, 7, 5, 8, 6, 8, 9 } },
    .{ .label = "Failing Tests", .value = "18", .delta = "-28%", .trend = .down_bad, .icon = theme.icon.cross, .color = theme.red, .tint = theme.red_dim, .bars = .{ 3, 5, 4, 6, 4, 8, 5, 9, 6, 5, 3, 2 } },
    .{ .label = "Avg. Response Time", .value = "285", .unit = "ms", .delta = "-16%", .trend = .down_good, .icon = theme.icon.stopwatch, .color = theme.amber, .tint = theme.raised, .bars = .{ 4, 3, 4, 5, 4, 5, 6, 5, 6, 5, 5, 4 } },
    .{ .label = "Throughput", .value = "1,240", .unit = "rps", .delta = "+22%", .trend = .up_good, .icon = theme.icon.bolt, .color = theme.amber, .tint = theme.amber_dim, .bars = .{ 3, 4, 3, 5, 4, 6, 5, 7, 6, 8, 7, 9 } },
};

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    var y = widgets.pageHeader(ui, area, "Dashboard", ui.state.screen.subtitle());

    widgets.sampleTag(c, x + w - 120, y - 58);

    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 170 };
    for (stats, 0..) |stat, i| widgets.statCard(c, row.column(i, stats.len, theme.gap), stat);
    y += row.h + theme.gap;

    const trend_width = (w - theme.gap) * 0.66;
    const trend: Rect = .{ .x = x, .y = y, .w = trend_width, .h = 300 };
    const recent: Rect = .{ .x = trend.right() + theme.gap, .y = y, .w = w - trend_width - theme.gap, .h = 300 };
    drawTrend(c, trend);
    drawActivity(c, recent);
    y += trend.h + theme.gap;

    const table: Rect = .{ .x = x, .y = y, .w = w, .h = 324 };
    drawRuns(c, table);
    return table.bottom() - area.y + ui.state.scroll + theme.page_margin;
}

fn legend(c: *Canvas, x: f32, y: f32, color: u32, label: []const u8) void {
    c.circle(x, y + 10, 5, color);
    c.text(.small, label, .{ .x = x + 11, .y = y, .w = 50, .h = 20 }, .left, theme.muted);
}

fn drawTrend(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    c.text(.heading, "Test Results Trend", .{ .x = r.x + 20, .y = r.y + 14, .w = r.w - 200, .h = 26 }, .left, theme.text);
    c.text(.small, "Total test results over time", .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 200, .h = 18 }, .left, theme.muted);
    legend(c, r.right() - 140, r.y + 18, theme.green, "Passed");
    legend(c, r.right() - 70, r.y + 18, theme.red, "Failed");

    const chart: Rect = .{ .x = r.x + 52, .y = r.y + 76, .w = r.w - 76, .h = r.h - 118 };
    const max = 600.0;
    for (0..4) |i| {
        const step: f32 = @floatFromInt(i);
        const y = chart.bottom() - chart.h * step / 3;
        c.line(chart.x, y, chart.right(), y, theme.grid, 1);
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{i * 200}) catch "";
        c.text(.small, label, .{ .x = r.x + 10, .y = y - 9, .w = 34, .h = 18 }, .right, theme.muted);
    }

    const slot = chart.w / sample.days.len;
    for (sample.days, 0..) |day, i| {
        const left = chart.x + slot * @as(f32, @floatFromInt(i));
        const passed = chart.h * day.passed / max;
        const failed = chart.h * day.failed / max;
        const x = left + slot * 0.25;
        const w = slot * 0.5;
        c.fill(.{ .x = x, .y = chart.bottom() - passed, .w = w, .h = passed }, theme.green);
        c.fill(.{ .x = x, .y = chart.bottom() - passed - failed, .w = w, .h = failed }, theme.red);
        c.text(.small, day.label, .{ .x = left, .y = chart.bottom() + 8, .w = slot, .h = 18 }, .center, theme.muted);
    }
}

fn drawActivity(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    c.text(.heading, "Recent Activity", .{ .x = r.x + 18, .y = r.y + 14, .w = r.w - 36, .h = 26 }, .left, theme.text);

    var y = r.y + 50;
    for (sample.activity) |item| {
        const color, const tint, const icon = switch (item.outcome) {
            .passed => .{ theme.green, theme.green_dim, theme.icon.check },
            .failed => .{ theme.red, theme.red_dim, theme.icon.cross },
            .neutral => .{ theme.text, theme.raised, theme.icon.layers },
        };
        const badge: Rect = .{ .x = r.x + 18, .y = y + 6, .w = 30, .h = 30 };
        c.fillRound(badge, 15, tint);
        c.text(.icon, icon, badge, .center, color);

        const text_x = badge.right() + 12;
        const text_w = r.right() - text_x - 14;
        c.text(.small, item.title, .{ .x = text_x, .y = y + 2, .w = text_w, .h = 20 }, .left, theme.text);
        c.text(.tiny, item.detail, .{ .x = text_x, .y = y + 22, .w = text_w - 52, .h = 18 }, .left, theme.muted);
        c.text(.tiny, item.age, .{ .x = r.right() - 66, .y = y + 22, .w = 52, .h = 18 }, .right, theme.muted);
        y += 48;
    }
}

const columns = [_]struct { title: []const u8, at: f32 }{
    .{ .title = "#", .at = 0 },
    .{ .title = "Test Name", .at = 0.06 },
    .{ .title = "Suite", .at = 0.26 },
    .{ .title = "Environment", .at = 0.42 },
    .{ .title = "Status", .at = 0.58 },
    .{ .title = "Response Time", .at = 0.68 },
    .{ .title = "Started At", .at = 0.82 },
};

fn cell(table: Rect, index: usize, y: f32, h: f32) Rect {
    const end = if (index + 1 < columns.len) columns[index + 1].at else 1;
    return .{ .x = table.x + table.w * columns[index].at, .y = y, .w = table.w * (end - columns[index].at) - 8, .h = h };
}

fn drawRuns(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    c.text(.heading, "Recent Test Runs", .{ .x = r.x + 20, .y = r.y + 14, .w = r.w - 40, .h = 26 }, .left, theme.text);
    c.text(.small, "Latest test executions across all suites.", .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 40, .h = 18 }, .left, theme.muted);

    const table: Rect = .{ .x = r.x + 34, .y = r.y + 72, .w = r.w - 68, .h = r.h - 84 };
    const row_h = 40;
    for (columns, 0..) |column, i| c.text(.small, column.title, cell(table, i, table.y, row_h), .left, theme.muted);

    var y = table.y + row_h;
    for (sample.runs, 1..) |run, number| {
        c.line(r.x + 20, y, r.right() - 20, y, theme.grid, 1);
        var buffer: [4]u8 = undefined;
        const index = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch "";
        c.text(.body, index, cell(table, 0, y, row_h), .left, theme.muted);
        c.text(.body, run.name, cell(table, 1, y, row_h), .left, theme.text);
        c.text(.body, run.suite, cell(table, 2, y, row_h), .left, theme.muted);

        const env = cell(table, 3, y, row_h);
        const dot = if (std.mem.eql(u8, run.environment, "Production")) theme.green else theme.amber;
        c.circle(env.x + 5, y + row_h / 2, 5, dot);
        c.text(.body, run.environment, .{ .x = env.x + 18, .y = y, .w = env.w - 18, .h = row_h }, .left, theme.text);

        const status = cell(table, 4, y, row_h);
        const pill: Rect = .{ .x = status.x, .y = y + 8, .w = 62, .h = 24 };
        if (run.passed) {
            widgets.pill(c, pill, "Passed", theme.green, theme.green_dim);
        } else {
            widgets.pill(c, pill, "Failed", theme.red, theme.red_dim);
        }
        c.text(.body, run.response, cell(table, 5, y, row_h), .left, theme.text);
        c.text(.small, run.started, cell(table, 6, y, row_h), .left, theme.muted);
        y += row_h;
    }
}
