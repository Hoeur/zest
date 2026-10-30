//! Load testing analytics, as drawn in `ui/`'s fourth mockup. Shows one sample
//! run; nothing can be started until the load engine exists.

const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const sample = @import("../sample.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const stats = [_]sample.Stat{
    .{ .label = "Total Requests", .value = "1,245,320", .delta = "+22%", .note = "vs. last run", .trend = .up_good, .icon = theme.icon.layers, .color = theme.amber, .tint = theme.raised, .bars = .{ 3, 4, 3, 5, 4, 6, 5, 7, 6, 8, 7, 9 } },
    .{ .label = "Throughput", .value = "2,076", .unit = "rps", .delta = "+18%", .note = "vs. last run", .trend = .up_good, .icon = theme.icon.bolt, .color = theme.amber, .tint = theme.amber_dim, .bars = .{ 2, 3, 4, 3, 5, 4, 6, 7, 6, 8, 8, 9 } },
    .{ .label = "Avg. Latency", .value = "285", .unit = "ms", .delta = "-32%", .note = "vs. last run", .trend = .down_good, .icon = theme.icon.stopwatch, .color = theme.amber, .tint = theme.raised, .bars = .{ 4, 3, 4, 5, 4, 5, 6, 5, 6, 5, 5, 4 } },
    .{ .label = "Peak Users", .value = "500", .delta = "0%", .note = "vs. configured", .trend = .up_good, .icon = theme.icon.users, .color = theme.muted, .tint = theme.raised, .bars = .{ 2, 3, 4, 4, 5, 6, 6, 7, 7, 8, 8, 9 } },
    .{ .label = "Failure Rate", .value = "0.8%", .delta = "-76%", .note = "vs. last run", .trend = .down_good, .icon = theme.icon.cross, .color = theme.red, .tint = theme.red_dim, .bars = .{ 3, 2, 4, 3, 6, 4, 8, 5, 3, 4, 2, 3 } },
};

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    var y = widgets.pageHeader(ui, area, "Load Testing Analytics", ui.state.screen.subtitle());
    widgets.disabledButton(c, .{ .x = x + w - 160, .y = y - 72, .w = 160, .h = 38 }, "Start Load Test", true);
    widgets.sampleTag(c, x + w - 290, y - 66);

    const config: Rect = .{ .x = x, .y = y, .w = w, .h = 88 };
    drawConfig(c, config);
    y += config.h + theme.gap;

    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 170 };
    for (stats, 0..) |stat, i| widgets.statCard(c, row.column(i, stats.len, theme.gap), stat);
    y += row.h + theme.gap;

    const top: Rect = .{ .x = x, .y = y, .w = w, .h = 200 };
    widgets.lineChart(c, top.column(0, 3, theme.gap), "Requests Per Second", "Avg: 2,076 rps", &.{ "0", "500", "1,000", "1,500", "2,000", "2,500" }, 2500, &.{
        .{ .values = &sample.rps, .color = theme.amber, .area = true },
    });
    widgets.lineChart(c, top.column(1, 3, theme.gap), "Latency Percentiles", "p50 \u{00B7} p95 \u{00B7} p99", &.{ "0", "500 ms", "1.0 s", "1.5 s", "2.0 s" }, 2000, &.{
        .{ .values = &sample.p99, .color = theme.red },
        .{ .values = &sample.p95, .color = theme.amber },
        .{ .values = &sample.p50, .color = theme.green },
    });
    widgets.lineChart(c, top.column(2, 3, theme.gap), "Error Rate", "Avg: 0.8%", &.{ "0%", "2%", "4%", "6%", "8%", "10%" }, 10, &.{
        .{ .values = &sample.error_rate, .color = theme.red },
    });
    y += top.h + theme.gap;

    const bottom: Rect = .{ .x = x, .y = y, .w = w, .h = 180 };
    widgets.lineChart(c, bottom.column(0, 3, theme.gap), "CPU Usage (Server)", "Avg: 68%", &.{ "0%", "25%", "50%", "75%", "100%" }, 100, &.{
        .{ .values = &sample.cpu, .color = theme.blue, .area = true },
    });
    widgets.lineChart(c, bottom.column(1, 3, theme.gap), "Memory Usage (Server)", "Avg: 2.1 GB", &.{ "0", "1 GB", "2 GB", "3 GB", "4 GB" }, 4, &.{
        .{ .values = &sample.memory, .color = theme.purple, .area = true },
    });
    widgets.lineChart(c, bottom.column(2, 3, theme.gap), "Active Virtual Users", "Peak: 500", &.{ "0", "150", "300", "450", "600" }, 600, &.{
        .{ .values = &sample.users, .color = theme.green, .area = true },
    });
    y += bottom.h + theme.gap;

    const table: Rect = .{ .x = x, .y = y, .w = w, .h = 290 };
    drawEndpoints(c, table);
    return table.bottom() - area.y + ui.state.scroll + theme.page_margin;
}

fn drawConfig(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    const inner = r.inset(16);
    const widths = [_]f32{ 0.40, 0.18, 0.21, 0.21 };
    const labels = [_][]const u8{ "Target Endpoint", "Virtual Users", "Duration", "Ramp-up Time" };
    const values = [_][]const u8{ "https://api.yourapp.com/v1", "500", "10 min", "2 min" };
    var x = inner.x;
    for (widths, labels, values) |share, label, value| {
        const w = inner.w * share - 12;
        c.text(.small, label, .{ .x = x, .y = inner.y - 4, .w = w, .h = 18 }, .left, theme.muted);
        widgets.field(c, .{ .x = x, .y = inner.y + 18, .w = w, .h = 36 }, value, false);
        x += w + 16;
    }
}

const columns = [_]struct { title: []const u8, at: f32 }{
    .{ .title = "Endpoint", .at = 0 },
    .{ .title = "Method", .at = 0.22 },
    .{ .title = "Total Requests", .at = 0.32 },
    .{ .title = "Throughput (rps)", .at = 0.45 },
    .{ .title = "Avg. Latency", .at = 0.59 },
    .{ .title = "p95 Latency", .at = 0.71 },
    .{ .title = "p99 Latency", .at = 0.82 },
    .{ .title = "Error Rate", .at = 0.92 },
};

fn cell(table: Rect, index: usize, y: f32, h: f32) Rect {
    const end = if (index + 1 < columns.len) columns[index + 1].at else 1;
    return .{ .x = table.x + table.w * columns[index].at, .y = y, .w = table.w * (end - columns[index].at) - 6, .h = h };
}

fn drawEndpoints(c: *Canvas, r: Rect) void {
    widgets.panel(c, r);
    c.text(.heading, "Endpoint Results", .{ .x = r.x + 20, .y = r.y + 12, .w = r.w - 40, .h = 26 }, .left, theme.text);
    c.text(.small, "Performance breakdown by endpoint during this test.", .{ .x = r.x + 20, .y = r.y + 38, .w = r.w - 40, .h = 18 }, .left, theme.muted);

    const table: Rect = .{ .x = r.x + 20, .y = r.y + 62, .w = r.w - 40, .h = r.h - 70 };
    const row_h = 37;
    for (columns, 0..) |column, i| c.text(.small, column.title, cell(table, i, table.y, row_h), .left, theme.muted);

    var y = table.y + row_h;
    for (sample.endpoints) |endpoint| {
        c.line(table.x, y, table.right(), y, theme.grid, 1);
        c.text(.body, endpoint.path, cell(table, 0, y, row_h), .left, theme.text);
        const method = cell(table, 1, y, row_h);
        const post = endpoint.method[0] == 'P';
        widgets.pill(c, .{ .x = method.x, .y = y + 7, .w = 54, .h = 23 }, endpoint.method, if (post) theme.blue else theme.green, if (post) theme.blue_dim else theme.green_dim);
        c.text(.body, endpoint.requests, cell(table, 2, y, row_h), .left, theme.text);
        c.text(.body, endpoint.throughput, cell(table, 3, y, row_h), .left, theme.text);
        c.text(.body, endpoint.average, cell(table, 4, y, row_h), .left, theme.text);
        c.text(.body, endpoint.p95, cell(table, 5, y, row_h), .left, theme.text);
        c.text(.body, endpoint.p99, cell(table, 6, y, row_h), .left, theme.text);
        c.text(.body, endpoint.error_rate, cell(table, 7, y, row_h), .left, if (endpoint.failing) theme.red else theme.green);
        y += row_h;
    }
}
