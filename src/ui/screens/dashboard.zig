//! Dashboard, laid out as `ui/`'s first mockup, from the run history in
//! `.ztest/history.jsonl` and the suites in the workspace.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");
const timefmt = @import("../timefmt.zig");
const native = @import("../native.zig");
const history = @import("../../core/history.zig");

pub fn draw(ui: *Ui, area: Rect) f32 {
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    var y = widgets.pageHeader(ui, area, "Dashboard", ui.state.screen.subtitle());
    drawActions(ui, .{ .x = x, .y = y - 78, .w = w, .h = 44 });

    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 150 };
    drawStats(ui, row);
    y += row.h + theme.gap;

    const trend_width = (w - theme.gap) * 0.66;
    const trend: Rect = .{ .x = x, .y = y, .w = trend_width, .h = 300 };
    const recent: Rect = .{ .x = trend.right() + theme.gap, .y = y, .w = w - trend_width - theme.gap, .h = 300 };
    drawTrend(ui, trend);
    drawActivity(ui, recent);
    y += trend.h + theme.gap;

    const table: Rect = .{ .x = x, .y = y, .w = w, .h = 72 + 40 * (runs_per_page + 1) + 70 };
    drawRuns(ui, table);
    return table.bottom() - area.y + ui.state.scroll + theme.page_margin;
}

/// Run All and New Test, at the right of the title.
fn drawActions(ui: *Ui, r: Rect) void {
    const m = ui.m;
    const new: Rect = .{ .x = r.right() - 158, .y = r.y, .w = 158, .h = r.h };
    const run: Rect = .{ .x = new.x - 14 - 150, .y = r.y, .w = 150, .h = r.h };
    const busy = m.suites.busy();
    var label_buffer: [32]u8 = undefined;
    const label = if (busy and m.run_all_total > 0)
        std.fmt.bufPrint(&label_buffer, "Running {d}/{d}", .{ m.run_all_total - m.run_all_left, m.run_all_total }) catch "Running"
    else if (busy)
        "Running..."
    else
        "Run All";
    const all = widgets.outlineSplitButton(ui, run, theme.icon.play, label, m.catalog.suites.len > 0 and !busy);
    if (all.main) ui.act(.run_all, 0, run);
    if (all.menu) ui.act(.run_all_menu, 0, .{ .x = run.right() - 240, .y = run.y, .w = 240, .h = run.h });
    const split = widgets.splitButton(ui, new, theme.icon.add, "New Test", true);
    if (split.main) ui.act(.new_test, 0, new);
    if (split.menu) ui.act(.new_test_menu, 0, .{ .x = new.right() - 220, .y = new.y, .w = 220, .h = new.h });
}

const Window = struct { passed: f32 = 0, failed: f32 = 0, ms_sum: f64 = 0, ms_count: f64 = 0 };

/// Tests in the 7 days before `end`.
fn week(entries: []const history.Entry, end: i64) Window {
    var w: Window = .{};
    for (entries) |e| {
        if (e.kind != .@"test" or e.unix > end or e.unix <= end - 7 * std.time.s_per_day) continue;
        switch (e.outcome) {
            .passed => w.passed += 1,
            .failed => w.failed += 1,
            else => {},
        }
        if (e.outcome == .passed or e.outcome == .failed) {
            w.ms_sum += @floatFromInt(e.duration_ms);
            w.ms_count += 1;
        }
    }
    return w;
}

fn change(buffer: []u8, now: f64, before: f64) []const u8 {
    if (before == 0) return "";
    const percent = (now - before) * 100 / before;
    return std.fmt.bufPrint(buffer, "{s}{d:.0}%", .{ if (percent >= 0) "+" else "", percent }) catch "";
}

fn drawStats(ui: *Ui, row: Rect) void {
    const c = ui.c;
    const m = ui.m;
    const entries = m.history.entries.items;
    const latest = history.latestOutcomes(entries);
    const this_week = week(entries, m.now);
    const last_week = week(entries, m.now - 7 * std.time.s_per_day);
    var days: [12]history.Day = undefined;
    history.days(entries, m.now, native.utcOffset(m.now), &days);
    var passed_bars: [12]f32 = undefined;
    var failed_bars: [12]f32 = undefined;
    for (days, 0..) |d, i| {
        passed_bars[i] = @floatFromInt(d.passed);
        failed_bars[i] = @floatFromInt(d.failed);
    }
    // Throughput from the most recent load tests, oldest first.
    var loads_buffer: [12]history.Entry = undefined;
    const loads = m.history.recent(&.{.load}, &loads_buffer);
    var rps_bars: [12]f32 = @splat(0);
    for (loads, 0..) |e, i| rps_bars[loads.len - 1 - i] = @floatCast(e.rps);
    var suite_runs_buffer: [12]history.Entry = undefined;
    const suite_runs = m.history.recent(&.{.suite}, &suite_runs_buffer);
    var suite_bars: [12]f32 = @splat(0);
    for (suite_runs, 0..) |e, i| suite_bars[suite_runs.len - 1 - i] = @floatFromInt(e.passed + e.failed);

    var b: [5][32]u8 = undefined;
    var d: [5][16]u8 = undefined;
    const avg_now = if (this_week.ms_count > 0) this_week.ms_sum / this_week.ms_count else 0;
    const avg_before = if (last_week.ms_count > 0) last_week.ms_sum / last_week.ms_count else 0;
    const stats = [_]widgets.LiveStat{
        .{
            .label = "Total Test Suites",
            .value = std.fmt.bufPrint(&b[0], "{d}", .{m.catalog.suites.len}) catch "",
            .note = "in this folder",
            .icon = theme.icon.layers,
            .color = theme.amber,
            .tint = theme.raised,
            .bars = suite_bars[0..suite_runs.len],
        },
        .{
            .label = "Passing Tests",
            .value = std.fmt.bufPrint(&b[1], "{d}", .{latest.passed}) catch "",
            .delta = change(&d[1], this_week.passed, last_week.passed),
            .good = this_week.passed >= last_week.passed,
            .note = if (last_week.passed > 0) "vs. last 7 days" else "by latest run",
            .icon = theme.icon.check,
            .color = theme.green,
            .tint = theme.green_dim,
            .bars = &passed_bars,
        },
        .{
            .label = "Failing Tests",
            .value = std.fmt.bufPrint(&b[2], "{d}", .{latest.failed}) catch "",
            .delta = change(&d[2], this_week.failed, last_week.failed),
            .good = this_week.failed <= last_week.failed,
            .note = if (last_week.failed > 0) "vs. last 7 days" else "by latest run",
            .icon = theme.icon.cross,
            .color = theme.red,
            .tint = theme.red_dim,
            .bars = &failed_bars,
        },
        .{
            .label = "Avg. Response Time",
            .value = if (this_week.ms_count > 0) std.fmt.bufPrint(&b[3], "{d:.0}", .{avg_now}) catch "" else "-",
            .unit = if (this_week.ms_count > 0) "ms" else "",
            .delta = change(&d[3], avg_now, avg_before),
            .good = avg_now <= avg_before,
            .note = if (avg_before > 0) "vs. last 7 days" else "tests, last 7 days",
            .icon = theme.icon.stopwatch,
            .color = theme.amber,
            .tint = theme.raised,
        },
        .{
            .label = "Throughput",
            .value = if (loads.len > 0) std.fmt.bufPrint(&b[4], "{d:.0}", .{loads[0].rps}) catch "" else "-",
            .unit = if (loads.len > 0) "rps" else "",
            .delta = if (loads.len > 1) change(&d[4], loads[0].rps, loads[1].rps) else "",
            .good = loads.len < 2 or loads[0].rps >= loads[1].rps,
            .note = if (loads.len > 1) "vs. previous load test" else if (loads.len == 1) "last load test" else "no load tests yet",
            .icon = theme.icon.bolt,
            .color = theme.amber,
            .tint = theme.amber_dim,
            .bars = rps_bars[0..loads.len],
        },
    };
    for (stats, 0..) |stat, i| widgets.liveStatCard(c, row.column(i, stats.len, theme.gap), stat);
}

fn legend(c: *Canvas, x: f32, y: f32, color: u32, label: []const u8) void {
    c.circle(x, y + 10, 5, color);
    c.text(.small, label, .{ .x = x + 11, .y = y, .w = 50, .h = 20 }, .left, theme.muted);
}

fn drawTrend(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const m = ui.m;
    widgets.panel(c, r);
    c.text(.heading, "Test Results Trend", .{ .x = r.x + 20, .y = r.y + 14, .w = r.w - 200, .h = 26 }, .left, theme.text);
    c.text(.small, "Total test results over time", .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 200, .h = 18 }, .left, theme.muted);
    const range: Rect = .{ .x = r.right() - 20 - 130, .y = r.y + 16, .w = 130, .h = 36 };
    var range_buffer: [24]u8 = undefined;
    const count = @min(ui.state.trend_days, 14);
    if (widgets.dropdown(ui, range, std.fmt.bufPrint(&range_buffer, "Last {d} days", .{count}) catch "", false)) ui.act(.trend_range, 0, range);
    legend(c, range.x - 160, r.y + 24, theme.green, "Passed");
    legend(c, range.x - 80, r.y + 24, theme.red, "Failed");

    var all_days: [14]history.Day = undefined;
    const days = all_days[0..count];
    const offset = native.utcOffset(m.now);
    history.days(m.history.entries.items, m.now, offset, days);
    var peak: f32 = 0;
    for (days) |day| peak = @max(peak, @as(f32, @floatFromInt(day.passed + day.failed)));
    // Four even steps of a round number.
    const max = 4 * widgets.niceMax(@max(peak, 4) / 4);

    const chart: Rect = .{ .x = r.x + 52, .y = r.y + 76, .w = r.w - 76, .h = r.h - 118 };
    for (0..5) |i| {
        const share: f32 = @as(f32, @floatFromInt(i)) / 4;
        const y = chart.bottom() - chart.h * share;
        c.line(chart.x, y, chart.right(), y, theme.grid, 1);
        var buffer: [12]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d:.0}", .{max * share}) catch "";
        c.text(.small, label, .{ .x = r.x + 6, .y = y - 9, .w = 38, .h = 18 }, .right, theme.muted);
    }
    const slot = chart.w / @as(f32, @floatFromInt(days.len));
    for (days, 0..) |day, i| {
        const left = chart.x + slot * @as(f32, @floatFromInt(i));
        const passed = chart.h * @as(f32, @floatFromInt(day.passed)) / max;
        const failed = chart.h * @as(f32, @floatFromInt(day.failed)) / max;
        const bx = left + slot * 0.25;
        const bw = slot * 0.5;
        if (passed > 0) c.fill(.{ .x = bx, .y = chart.bottom() - passed, .w = bw, .h = passed }, theme.green);
        if (failed > 0) c.fill(.{ .x = bx, .y = chart.bottom() - passed - failed, .w = bw, .h = failed }, theme.red);
        var label: [16]u8 = undefined;
        const parts = timefmt.partsOf(day.day * std.time.s_per_day);
        // Every other day when there are two weeks, so the dates fit.
        if (days.len > 7 and (days.len - 1 - i) % 2 == 1) continue;
        c.text(.small, timefmt.shortDate(&label, parts), .{ .x = left, .y = chart.bottom() + 8, .w = slot, .h = 18 }, .center, theme.muted);
    }
    if (peak == 0) c.text(.small, "Run a suite to see results here.", chart, .center, theme.muted);
}

fn drawActivity(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const m = ui.m;
    widgets.panel(c, r);
    c.text(.heading, "Recent Activity", .{ .x = r.x + 18, .y = r.y + 14, .w = r.w - 36, .h = 26 }, .left, theme.text);
    const view_all: Rect = .{ .x = r.right() - 18 - 84, .y = r.y + 14, .w = 84, .h = 26 };
    if (ui.pressed(view_all)) ui.state.navigate(.reports);
    const link = if (ui.hovered(view_all)) theme.key else theme.amber;
    c.text(.small, "View All", .{ .x = view_all.x, .y = view_all.y, .w = 60, .h = view_all.h }, .left, link);
    c.text(.icon, theme.icon.chevron_right, .{ .x = view_all.right() - 18, .y = view_all.y, .w = 18, .h = view_all.h }, .left, link);

    var buffer: [5]history.Entry = undefined;
    const items = m.history.recent(&.{ .suite, .load, .request }, &buffer);
    if (items.len == 0) {
        c.text(.small, "Nothing yet. Send a request, run a suite,", .{ .x = r.x + 18, .y = r.y + 56, .w = r.w - 36, .h = 20 }, .left, theme.muted);
        c.text(.small, "or start a load test.", .{ .x = r.x + 18, .y = r.y + 76, .w = r.w - 36, .h = 20 }, .left, theme.muted);
        return;
    }
    var y = r.y + 50;
    for (items) |item| {
        const passed = item.outcome == .passed;
        const color, const tint, const icon = switch (item.kind) {
            .load => .{ theme.text, theme.raised, theme.icon.pulse },
            else => if (passed) .{ theme.green, theme.green_dim, theme.icon.check } else if (item.outcome == .failed) .{ theme.red, theme.red_dim, theme.icon.cross } else .{ theme.text, theme.raised, theme.icon.minus },
        };
        const badge: Rect = .{ .x = r.x + 18, .y = y + 6, .w = 30, .h = 30 };
        c.fillRound(badge, 15, tint);
        c.text(.icon, icon, badge, .center, color);

        var title: [160]u8 = undefined;
        var detail: [160]u8 = undefined;
        const verb = switch (item.outcome) {
            .passed => "passed",
            .failed => "failed",
            .skipped => "skipped",
            .not_run => "stopped",
        };
        const t = switch (item.kind) {
            .suite => std.fmt.bufPrint(&title, "{s} suite {s}", .{ item.name, verb }) catch "",
            .load => std.fmt.bufPrint(&title, "Load test completed", .{}) catch "",
            .request => std.fmt.bufPrint(&title, "{s} request {s}", .{ item.method, verb }) catch "",
            .@"test" => item.name,
        };
        var took: [24]u8 = undefined;
        const dt = switch (item.kind) {
            .suite => std.fmt.bufPrint(&detail, "{d} passed \u{00B7} {d} failed \u{00B7} {s}", .{ item.passed, item.failed, timefmt.duration(&took, item.duration_ms) }) catch "",
            .load => std.fmt.bufPrint(&detail, "{d} users \u{00B7} {s} \u{00B7} {d:.0} rps", .{ item.users, timefmt.duration(&took, item.duration_ms), item.rps }) catch "",
            else => item.name,
        };
        const text_x = badge.right() + 12;
        const text_w = r.right() - text_x - 14;
        c.text(.small, t, .{ .x = text_x, .y = y + 2, .w = text_w, .h = 20 }, .left, theme.text);
        c.text(.tiny, dt, .{ .x = text_x, .y = y + 22, .w = text_w - 60, .h = 18 }, .left, theme.muted);
        var age: [24]u8 = undefined;
        c.text(.tiny, timefmt.ago(&age, m.now - item.unix), .{ .x = r.right() - 74, .y = y + 22, .w = 60, .h = 18 }, .right, theme.muted);
        y += 48;
    }
}

const runs_per_page = 5;

const columns = [_]struct { title: []const u8, at: f32 }{
    .{ .title = "#", .at = 0 },
    .{ .title = "Test Name", .at = 0.05 },
    .{ .title = "Suite", .at = 0.27 },
    .{ .title = "Environment", .at = 0.42 },
    .{ .title = "Status", .at = 0.56 },
    .{ .title = "Response Time", .at = 0.66 },
    .{ .title = "Started At", .at = 0.77 },
    .{ .title = "Actions", .at = 0.93 },
};

fn cell(table: Rect, index: usize, y: f32, h: f32) Rect {
    const end = if (index + 1 < columns.len) columns[index + 1].at else 1;
    return .{ .x = table.x + table.w * columns[index].at, .y = y, .w = table.w * (end - columns[index].at) - 8, .h = h };
}

fn shownRun(m: anytype, e: history.Entry) bool {
    return e.kind == .@"test" and (m.runs_suite.len == 0 or std.mem.eql(u8, e.suite, m.runs_suite));
}

fn drawRuns(ui: *Ui, r: Rect) void {
    const c = ui.c;
    const m = ui.m;
    widgets.panel(c, r);
    c.text(.heading, "Recent Test Runs", .{ .x = r.x + 20, .y = r.y + 14, .w = r.w - 40, .h = 26 }, .left, theme.text);
    c.text(.small, "Latest test executions across all suites.", .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 40, .h = 18 }, .left, theme.muted);
    const filter: Rect = .{ .x = r.right() - 20 - 170, .y = r.y + 18, .w = 170, .h = 36 };
    if (widgets.dropdown(ui, filter, if (m.runs_suite.len > 0) m.runs_suite else "All Suites", false)) ui.act(.runs_suite_filter, 0, filter);

    const head: Rect = .{ .x = r.x + 20, .y = r.y + 72, .w = r.w - 40, .h = 40 };
    c.fillRound(head, 6, theme.background);
    const table: Rect = .{ .x = head.x + 14, .y = head.y, .w = head.w - 28, .h = 0 };
    const row_h = 40;
    for (columns, 0..) |column, i| c.text(.small, column.title, cell(table, i, table.y, row_h), .left, theme.muted);

    const entries = m.history.entries.items;
    var total: usize = 0;
    for (entries) |e| {
        if (shownRun(m, e)) total += 1;
    }
    const pages = @max(1, (total + runs_per_page - 1) / runs_per_page);
    ui.state.runs_page = @min(ui.state.runs_page, pages - 1);
    const first = ui.state.runs_page * runs_per_page;

    var y = head.bottom();
    if (total == 0) {
        c.text(.small, if (m.runs_suite.len > 0) "No runs of this suite yet." else "No test runs yet. Open Test Suites and run one.", .{ .x = table.x, .y = y + 10, .w = table.w, .h = 22 }, .left, theme.muted);
    }
    // Newest first: walk back from the end, skipping earlier pages.
    var seen: usize = 0;
    var i = entries.len;
    while (i > 0 and seen < first + runs_per_page) {
        i -= 1;
        const run = entries[i];
        if (!shownRun(m, run)) continue;
        seen += 1;
        if (seen <= first) continue;
        c.line(head.x, y + row_h, head.right(), y + row_h, theme.grid, 1);
        var index_buffer: [8]u8 = undefined;
        c.text(.body, std.fmt.bufPrint(&index_buffer, "{d}", .{seen}) catch "", cell(table, 0, y, row_h), .left, theme.muted);
        c.text(.body, run.name, cell(table, 1, y, row_h), .left, theme.text);
        c.text(.body, run.suite, cell(table, 2, y, row_h), .left, theme.text);

        const env = cell(table, 3, y, row_h);
        c.circle(env.x + 5, y + row_h / 2, 5, if (run.environment.len > 0) theme.green else theme.amber);
        c.text(.body, if (run.environment.len > 0) run.environment else "Global", .{ .x = env.x + 18, .y = y, .w = env.w - 18, .h = row_h }, .left, theme.text);

        const status = cell(table, 4, y, row_h);
        const pill: Rect = .{ .x = status.x, .y = y + 8, .w = 66, .h = 24 };
        switch (run.outcome) {
            .passed => widgets.pill(c, pill, "Passed", theme.green, theme.green_dim),
            .failed => widgets.pill(c, pill, "Failed", theme.red, theme.red_dim),
            .skipped => widgets.pill(c, pill, "Skipped", theme.amber, theme.amber_dim),
            .not_run => widgets.pill(c, pill, "Not run", theme.muted, theme.raised),
        }
        var took: [24]u8 = undefined;
        c.text(.body, if (run.outcome == .passed or run.outcome == .failed) timefmt.duration(&took, run.duration_ms) else "-", cell(table, 5, y, row_h), .left, theme.text);
        var date: [48]u8 = undefined;
        c.text(.body, timefmt.dateTime(&date, native.local(run.unix), false), cell(table, 6, y, row_h), .left, theme.text);
        const actions = cell(table, 7, y, row_h);
        const more: Rect = .{ .x = actions.x + 10, .y = y + 6, .w = 30, .h = 28 };
        if (ui.hovered(more)) c.fillRound(more, 6, theme.raised);
        c.text(.icon, theme.icon.more, more, .center, theme.muted);
        if (ui.pressed(more)) ui.act(.run_row_menu, i, more);
        y += row_h;
    }

    // Footer: what is shown, and the pages.
    const footer_y = r.bottom() - 54;
    var showing: [64]u8 = undefined;
    const shown_to = @min(total, first + runs_per_page);
    const note = if (total == 0) "" else std.fmt.bufPrint(&showing, "Showing {d}\u{2013}{d} of {d} test runs", .{ first + 1, shown_to, total }) catch "";
    c.text(.small, note, .{ .x = r.x + 22, .y = footer_y, .w = 300, .h = 36 }, .left, theme.muted);
    if (pages < 2) return;
    const visible = @min(pages, 5);
    const start_page = @min(ui.state.runs_page -| 2, pages - visible);
    const box_w: f32 = 36;
    var bx = r.right() - 22 - box_w * @as(f32, @floatFromInt(visible + 2)) - 6 * @as(f32, @floatFromInt(visible + 1));
    if (pageBox(ui, .{ .x = bx, .y = footer_y, .w = box_w, .h = 36 }, null, false) and ui.state.runs_page > 0) ui.state.runs_page -= 1;
    bx += box_w + 6;
    for (start_page..start_page + visible) |page| {
        if (pageBox(ui, .{ .x = bx, .y = footer_y, .w = box_w, .h = 36 }, page + 1, page == ui.state.runs_page)) ui.state.runs_page = page;
        bx += box_w + 6;
    }
    if (pageBox(ui, .{ .x = bx, .y = footer_y, .w = box_w, .h = 36 }, null, true) and ui.state.runs_page + 1 < pages) ui.state.runs_page += 1;
}

/// A page number, or an arrow when `number` is null (`next` picks which).
fn pageBox(ui: *Ui, r: Rect, number: ?usize, active_or_next: bool) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    const active = number != null and active_or_next;
    c.fillRound(r, 6, if (active) theme.amber_dim else if (ui.hovered(r)) theme.raised else theme.panel);
    c.strokeRound(r, 6, if (active) theme.amber else theme.border);
    if (number) |n| {
        var buffer: [8]u8 = undefined;
        c.text(.small, std.fmt.bufPrint(&buffer, "{d}", .{n}) catch "", r, .center, if (active) theme.amber else theme.text);
    } else {
        c.text(.icon, if (active_or_next) theme.icon.chevron_right else theme.icon.chevron_left, r, .center, theme.text);
    }
    return clicked;
}
