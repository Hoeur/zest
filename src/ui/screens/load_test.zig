//! Load testing, laid out as `ui/`'s fourth mockup and driven by the core load
//! engine. Charts fill once a second while a test runs.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");
const timefmt = @import("../timefmt.zig");
const load_run = @import("../load_run.zig");

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const run = &ui.m.load;
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    var y = widgets.pageHeader(ui, area, "Load Testing Analytics", ui.state.screen.subtitle());

    const start: Rect = .{ .x = x + w - 214, .y = y - 76, .w = 214, .h = 44 };
    if (run.busy()) {
        if (widgets.button(ui, start, if (run.phase == .stopping) "Stopping..." else "Stop Load Test", true) and run.phase == .running) ui.act(.load_stop, 0, start);
    } else {
        const split = widgets.splitButton(ui, start, theme.icon.play, "Start Load Test", true);
        if (split.main) ui.act(.load_start, 0, start);
        if (split.menu) ui.act(.load_configs, 0, .{ .x = start.right() - 260, .y = start.y, .w = 260, .h = start.h });
    }
    const configs: Rect = .{ .x = start.x - 14 - 160, .y = start.y, .w = 160, .h = 44 };
    if (widgets.menuButton(ui, configs, null, "Saved Configs")) ui.act(.load_configs, 0, configs);

    const config: Rect = .{ .x = x, .y = y, .w = w, .h = if (ui.state.load_advanced) 150 else 92 };
    drawConfig(ui, config);
    y += config.h + 8;
    // A line for a problem or progress, only while there is one.
    if (run.problem.len > 0) {
        c.text(.small, run.problem, .{ .x = x + 4, .y = y, .w = w, .h = 20 }, .left, theme.red);
        y += 24;
    } else if (run.busy()) {
        var buffer: [96]u8 = undefined;
        const note = std.fmt.bufPrint(&buffer, "Running for {d:.0}s of {d}s...", .{ run.elapsedS(), run.settings.duration_ms / 1000 }) catch "";
        c.text(.small, note, .{ .x = x + 4, .y = y, .w = w, .h = 20 }, .left, theme.amber);
        y += 24;
    } else {
        y += theme.gap - 8;
    }

    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 150 };
    drawStats(ui, row);
    y += row.h + theme.gap;

    drawCharts(ui, .{ .x = x, .y = y, .w = w, .h = 0 });
    y += 2 * (200 + theme.gap);

    const table: Rect = .{ .x = x, .y = y, .w = w, .h = @max(200, 100 + @as(f32, @floatFromInt(@min(run.rows.items.len, 10))) * 36) };
    drawEndpoints(ui, table);
    return table.bottom() - area.y + ui.state.scroll + theme.page_margin;
}

fn frameField(c: *Canvas, r: Rect) void {
    c.fillRound(r, 8, theme.background);
    c.strokeRound(r, 8, theme.border);
}

/// Painted frames with native fields inside, as the mockup's inputs.
fn drawConfig(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    const inner: Rect = .{ .x = r.x + 18, .y = r.y + 14, .w = r.w - 36, .h = 60 };
    const advanced_w: f32 = 170;
    const fields_w = inner.w - advanced_w - 16;
    const shares = [_]f32{ 0.40, 0.18, 0.21, 0.21 };
    const labels = [_][]const u8{ "Target Endpoint", "Virtual Users", "Duration", "Ramp-up Time" };
    const icons = [_][]const u8{ theme.icon.link, theme.icon.users, theme.icon.clock, theme.icon.chart };
    var fx = inner.x;
    for (shares, labels, icons, 0..) |share, label, icon, i| {
        const fw = fields_w * share - 14;
        c.text(.icon, icon, .{ .x = fx, .y = inner.y - 2, .w = 18, .h = 20 }, .left, theme.muted);
        c.text(.small, label, .{ .x = fx + 22, .y = inner.y - 2, .w = fw - 22, .h = 20 }, .left, theme.text);
        const box: Rect = .{ .x = fx, .y = inner.y + 22, .w = fw, .h = 36 };
        frameField(c, box);
        switch (i) {
            0 => ui.place(.load_url, .{ .x = box.x + 12, .y = box.y + 8, .w = box.w - 24, .h = 22 }),
            1 => ui.place(.load_users, .{ .x = box.x + 12, .y = box.y + 8, .w = box.w - 24, .h = 22 }),
            else => {
                const unit_w: f32 = 74;
                c.line(box.right() - unit_w, box.y + 6, box.right() - unit_w, box.bottom() - 6, theme.border, 1);
                const value_id: @import("../fields.zig").Id = if (i == 2) .load_duration else .load_ramp;
                const unit_id: @import("../fields.zig").Id = if (i == 2) .load_duration_unit else .load_ramp_unit;
                ui.place(value_id, .{ .x = box.x + 12, .y = box.y + 8, .w = box.w - unit_w - 24, .h = 22 });
                ui.place(unit_id, .{ .x = box.right() - unit_w + 6, .y = box.y + 5, .w = unit_w - 12, .h = 26 });
            },
        }
        fx += fw + 14;
    }
    const advanced: Rect = .{ .x = inner.right() - advanced_w, .y = inner.y + 22, .w = advanced_w, .h = 36 };
    if (widgets.menuButton(ui, advanced, theme.icon.settings, "Advanced Options")) ui.state.load_advanced = !ui.state.load_advanced;
    if (!ui.state.load_advanced) return;

    // Method, a total rate limit and an assertion, the options the engine has.
    const second: Rect = .{ .x = inner.x, .y = inner.y + 72, .w = inner.w, .h = 58 };
    const parts = [_]struct { label: []const u8, share: f32 }{
        .{ .label = "Method", .share = 0.14 },
        .{ .label = "Max requests/s (empty for no limit)", .share = 0.26 },
        .{ .label = "Each response must pass", .share = 0.60 },
    };
    var sx = second.x;
    for (parts, 0..) |part, i| {
        const fw = second.w * part.share - 14;
        c.text(.small, part.label, .{ .x = sx, .y = second.y - 4, .w = fw, .h = 20 }, .left, theme.text);
        const box: Rect = .{ .x = sx, .y = second.y + 18, .w = fw, .h = 36 };
        frameField(c, box);
        const inside: Rect = .{ .x = box.x + 12, .y = box.y + 8, .w = box.w - 24, .h = 22 };
        switch (i) {
            0 => ui.place(.load_method, .{ .x = box.x + 6, .y = box.y + 5, .w = box.w - 12, .h = 26 }),
            1 => ui.place(.load_rps, inside),
            else => ui.place(.load_assert, inside),
        }
        sx += fw + 14;
    }
}

fn drawStats(ui: *Ui, row: Rect) void {
    const c = ui.c;
    const run = &ui.m.load;
    const rows = run.rows.items;
    const live = run.busy();
    // The current run, or the last finished one.
    const latest: ?load_run.Row = if (!live and rows.len > 0) rows[rows.len - 1] else null;
    const previous: ?load_run.Row = if (live) (if (rows.len > 0) rows[rows.len - 1] else null) else if (rows.len > 1) rows[rows.len - 2] else null;
    const totals = run.totals();
    const samples = run.samples.items;

    var bars: [5][12]f32 = @splat(@splat(0));
    const tail = samples[samples.len -| 12..];
    for (tail, 0..) |s, i| {
        bars[0][i] = s.rps;
        bars[1][i] = s.rps;
        bars[2][i] = s.p50_ms;
        bars[3][i] = s.users;
        bars[4][i] = s.error_pct;
    }
    const has = live or latest != null;
    var b: [5][32]u8 = undefined;
    var d: [5][16]u8 = undefined;
    const rps: f64 = if (latest) |l| l.rps else if (samples.len > 0) samples[samples.len - 1].rps else 0;
    const mean: f64 = if (latest) |l| l.mean_ms else if (samples.len > 0) samples[samples.len - 1].p50_ms else 0;
    const failure: f64 = if (latest) |l| l.error_rate else if (totals.requests > 0) @as(f64, @floatFromInt(totals.failed)) * 100 / @as(f64, @floatFromInt(totals.requests)) else 0;
    const peak = run.peakUsers();

    const stats = [_]widgets.LiveStat{
        .{
            .label = "Total Requests",
            .value = if (has) timefmt.grouped(&b[0], totals.requests) else "-",
            .delta = if (previous) |p| change(&d[0], @floatFromInt(totals.requests), @floatFromInt(p.requests)) else "",
            .good = true,
            .note = if (previous != null) "vs. last run" else if (live) "so far" else "No runs yet",
            .icon = theme.icon.layers,
            .color = theme.amber,
            .tint = theme.raised,
            .bars = &bars[0],
        },
        .{
            .label = "Throughput",
            .value = if (has) std.fmt.bufPrint(&b[1], "{d:.0}", .{rps}) catch "" else "-",
            .unit = if (has) "rps" else "",
            .delta = if (previous) |p| change(&d[1], rps, p.rps) else "",
            .good = previous == null or rps >= previous.?.rps,
            .note = if (previous != null) "vs. last run" else "",
            .icon = theme.icon.bolt,
            .color = theme.amber,
            .tint = theme.amber_dim,
            .bars = &bars[1],
        },
        .{
            // Live samples give the median; a finished run has the mean.
            .label = if (live) "Median Latency" else "Avg. Latency",
            .value = if (has) latencyText(&b[2], mean) else "-",
            .unit = if (has) (if (mean >= 1000) "s" else "ms") else "",
            .delta = if (previous) |p| change(&d[2], mean, p.mean_ms) else "",
            .good = previous == null or mean <= previous.?.mean_ms,
            .note = if (previous != null) "vs. last run" else "",
            .icon = theme.icon.stopwatch,
            .color = theme.amber,
            .tint = theme.raised,
            .bars = &bars[2],
        },
        .{
            .label = "Peak Users",
            .value = if (has) std.fmt.bufPrint(&b[3], "{d}", .{peak}) catch "" else "-",
            .delta = if (has) change(&d[3], @floatFromInt(peak), @floatFromInt(run.settings.users)) else "",
            .good = true,
            .note = if (has) "vs. configured" else "",
            .icon = theme.icon.users,
            .color = theme.muted,
            .tint = theme.raised,
            .bars = &bars[3],
        },
        .{
            .label = "Failure Rate",
            .value = if (has) std.fmt.bufPrint(&b[4], "{d:.1}%", .{failure}) catch "" else "-",
            .delta = if (previous) |p| change(&d[4], failure, p.error_rate) else "",
            .good = previous == null or failure <= previous.?.error_rate,
            .note = if (previous != null) "vs. last run" else "",
            .icon = theme.icon.cross,
            .color = theme.red,
            .tint = theme.red_dim,
            .bars = &bars[4],
        },
    };
    for (stats, 0..) |stat, i| widgets.liveStatCard(c, row.column(i, stats.len, theme.gap), stat);
}

fn latencyText(buffer: []u8, ms: f64) []const u8 {
    if (ms >= 1000) return std.fmt.bufPrint(buffer, "{d:.2}", .{ms / 1000}) catch "";
    if (ms < 10) return std.fmt.bufPrint(buffer, "{d:.2}", .{ms}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.0}", .{ms}) catch "";
}

/// `+22%`, `-16%` or `0%`.
fn change(buffer: []u8, now: f64, before: f64) []const u8 {
    if (before == 0) return if (now == 0) "0%" else "new";
    const percent = (now - before) * 100 / before;
    if (@abs(percent) < 0.5) return "0%";
    return std.fmt.bufPrint(buffer, "{s}{d:.0}%", .{ if (percent > 0) "+" else "", percent }) catch "";
}

fn drawCharts(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const run = &ui.m.load;
    const samples = run.samples.items;
    const n = @min(samples.len, 2048);
    var rps: [2048]f32 = undefined;
    var p50: [2048]f32 = undefined;
    var p95: [2048]f32 = undefined;
    var p99: [2048]f32 = undefined;
    var errors: [2048]f32 = undefined;
    var users: [2048]f32 = undefined;
    const from = samples.len - n;
    for (samples[from..], 0..) |s, i| {
        rps[i] = s.rps;
        p50[i] = s.p50_ms;
        p95[i] = s.p95_ms;
        p99[i] = s.p99_ms;
        errors[i] = s.error_pct;
        users[i] = s.users;
    }
    const seconds: f32 = if (run.busy()) @as(f32, @floatFromInt(run.settings.duration_ms)) / 1000 else if (n > 0) @max(1, samples[samples.len - 1].t) else 60;
    const empty = "Start a load test to see live results.";
    var notes: [3][48]u8 = undefined;

    const top: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 200 };
    widgets.liveChart(c, top.column(0, 3, theme.gap), "Requests Per Second", std.fmt.bufPrint(&notes[0], "Avg: {d:.0} rps", .{average(rps[0..n])}) catch "", .count, seconds, &.{.{ .values = rps[0..n], .color = theme.amber, .area = true }}, &.{}, empty);
    widgets.liveChart(c, top.column(1, 3, theme.gap), "Latency Percentiles", "", .ms, seconds, &.{
        .{ .values = p50[0..n], .color = theme.green },
        .{ .values = p95[0..n], .color = theme.amber },
        .{ .values = p99[0..n], .color = theme.red },
    }, &.{ "p50", "p95", "p99" }, empty);
    widgets.liveChart(c, top.column(2, 3, theme.gap), "Error Rate", std.fmt.bufPrint(&notes[1], "Avg: {d:.1}%", .{average(errors[0..n])}) catch "", .percent, seconds, &.{.{ .values = errors[0..n], .color = theme.red }}, &.{}, empty);

    const bottom: Rect = .{ .x = r.x, .y = r.y + 200 + theme.gap, .w = r.w, .h = 200 };
    const m = ui.m;
    const cpu = m.cpu.items[m.cpu.items.len - @min(m.cpu.items.len, n) ..];
    const memory = m.memory_mb.items[m.memory_mb.items.len - @min(m.memory_mb.items.len, n) ..];
    var cpu_note: [48]u8 = undefined;
    var memory_note: [48]u8 = undefined;
    widgets.liveChart(c, bottom.column(0, 3, theme.gap), "CPU Usage (ZTest)", std.fmt.bufPrint(&cpu_note, "Avg: {d:.0}%", .{average(cpu)}) catch "", .percent, seconds, &.{.{ .values = cpu, .color = theme.blue, .area = true }}, &.{}, "The load generator's own CPU use.");
    widgets.liveChart(c, bottom.column(1, 3, theme.gap), "Memory Usage (ZTest)", std.fmt.bufPrint(&memory_note, "Avg: {d:.0} MB", .{average(memory)}) catch "", .mb, seconds, &.{.{ .values = memory, .color = theme.purple, .area = true }}, &.{}, "The load generator's own memory.");
    widgets.liveChart(c, bottom.column(2, 3, theme.gap), "Active Virtual Users", std.fmt.bufPrint(&notes[2], "Peak: {d}", .{run.peakUsers()}) catch "", .count, seconds, &.{.{ .values = users[0..n], .color = theme.green, .area = true }}, &.{}, empty);
}

fn average(values: []const f32) f64 {
    if (values.len == 0) return 0;
    var sum: f64 = 0;
    for (values) |v| sum += v;
    return sum / @as(f64, @floatFromInt(values.len));
}

const columns = [_]struct { title: []const u8, at: f32 }{
    .{ .title = "#", .at = 0 },
    .{ .title = "Endpoint", .at = 0.04 },
    .{ .title = "Method", .at = 0.30 },
    .{ .title = "Total Requests", .at = 0.38 },
    .{ .title = "Throughput (rps)", .at = 0.50 },
    .{ .title = "Avg. Latency", .at = 0.62 },
    .{ .title = "p95 Latency", .at = 0.72 },
    .{ .title = "p99 Latency", .at = 0.82 },
    .{ .title = "Error Rate", .at = 0.92 },
};

fn cell(table: Rect, index: usize, y: f32, h: f32) Rect {
    const end = if (index + 1 < columns.len) columns[index + 1].at else 1;
    return .{ .x = table.x + table.w * columns[index].at, .y = y, .w = table.w * (end - columns[index].at) - 6, .h = h };
}

fn drawEndpoints(ui: *Ui, r: Rect) void {
    const c = ui.c;
    widgets.panel(c, r);
    c.text(.heading, "Endpoint Results", .{ .x = r.x + 20, .y = r.y + 12, .w = r.w - 260, .h = 26 }, .left, theme.text);
    c.text(.small, "Each run in this session, newest first.", .{ .x = r.x + 20, .y = r.y + 38, .w = r.w - 260, .h = 18 }, .left, theme.muted);
    const search: Rect = .{ .x = r.right() - 20 - 220, .y = r.y + 14, .w = 220, .h = 34 };
    widgets.searchField(ui, search, .result_search, ui.m.search_text, "Search endpoints...");

    const table: Rect = .{ .x = r.x + 20, .y = r.y + 62, .w = r.w - 40, .h = r.h - 70 };
    const row_h = 36;
    for (columns, 0..) |column, i| c.text(.small, column.title, cell(table, i, table.y, row_h), .left, theme.muted);

    const rows = ui.m.load.rows.items;
    var y = table.y + row_h;
    if (rows.len == 0) {
        c.line(table.x, y, table.right(), y, theme.grid, 1);
        c.text(.small, "No load tests yet. Set a target endpoint above and start one.", .{ .x = table.x, .y = y + 8, .w = table.w, .h = 24 }, .left, theme.muted);
        return;
    }
    var buffer: [9][32]u8 = undefined;
    var shown: usize = 0;
    var i = rows.len;
    while (i > 0 and shown < 10) {
        i -= 1;
        const row = rows[i];
        if (!matches(ui, row.endpoint)) continue;
        shown += 1;
        c.line(table.x, y, table.right(), y, theme.grid, 1);
        c.text(.body, std.fmt.bufPrint(&buffer[0], "{d}", .{i + 1}) catch "", cell(table, 0, y, row_h), .left, theme.muted);
        c.text(.body, row.endpoint, cell(table, 1, y, row_h), .left, theme.text);
        const method = cell(table, 2, y, row_h);
        const get = std.mem.eql(u8, row.method, "GET");
        widgets.pill(c, .{ .x = method.x, .y = y + 7, .w = 58, .h = 22 }, row.method, if (get) theme.green else theme.blue, if (get) theme.green_dim else theme.blue_dim);
        c.text(.body, timefmt.grouped(&buffer[1], row.requests), cell(table, 3, y, row_h), .left, theme.text);
        c.text(.body, std.fmt.bufPrint(&buffer[2], "{d:.0}", .{row.rps}) catch "", cell(table, 4, y, row_h), .left, theme.text);
        c.text(.body, msText(&buffer[3], row.mean_ms), cell(table, 5, y, row_h), .left, theme.text);
        c.text(.body, msText(&buffer[4], row.p95_ms), cell(table, 6, y, row_h), .left, if (row.p95_ms > 1000) theme.blue else theme.text);
        c.text(.body, msText(&buffer[5], row.p99_ms), cell(table, 7, y, row_h), .left, theme.text);
        c.text(.body, std.fmt.bufPrint(&buffer[6], "{d:.1}%", .{row.error_rate}) catch "", cell(table, 8, y, row_h), .left, if (row.error_rate > 1) theme.red else theme.green);
        y += row_h;
    }
}

fn msText(buffer: []u8, ms: f64) []const u8 {
    if (ms >= 1000) return std.fmt.bufPrint(buffer, "{d:.1} s", .{ms / 1000}) catch "";
    if (ms < 10) return std.fmt.bufPrint(buffer, "{d:.2} ms", .{ms}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.0} ms", .{ms}) catch "";
}

/// The endpoint search is read from its field by the window each frame.
fn matches(ui: *Ui, endpoint: []const u8) bool {
    const query = ui.m.search_text;
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(endpoint, query) != null;
}
