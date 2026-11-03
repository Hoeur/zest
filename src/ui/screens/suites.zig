//! Test suites, laid out as `ui/`'s third mockup: the `.ztest` files under the
//! workspace, run on the core runner, with results as they finish.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const state = @import("../state.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");
const timefmt = @import("../timefmt.zig");
const native = @import("../native.zig");
const suite_run = @import("../suite_run.zig");
const history = @import("../../core/history.zig");
const redact = @import("../../core/redact.zig");

const list_width = 270;
const detail_tabs = [_][]const u8{ "Request", "Response", "Logs", "Assertions" };

pub fn draw(ui: *Ui, area: Rect) f32 {
    const top = area.y + 16 - ui.state.scroll;
    const list: Rect = .{ .x = area.x + 20, .y = top, .w = list_width, .h = 0 };
    const detail: Rect = .{ .x = list.right() + 20, .y = top, .w = area.right() - list.right() - 40, .h = 0 };
    const list_end = drawList(ui, list);
    const detail_end = drawDetail(ui, detail);
    return @max(list_end, detail_end) - area.y + ui.state.scroll + theme.page_margin;
}

/// The last suite run recorded for `suite`, from history.
fn lastRun(ui: *Ui, suite: suite_run.SuiteFile) ?history.Entry {
    const entries = ui.m.history.entries.items;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        if (e.kind == .suite and std.mem.eql(u8, e.suite, suite.path)) return e;
    }
    // Runs recorded with a full path still match by name.
    return ui.m.history.last(.suite, suite.name);
}

fn outcomeOf(ui: *Ui, suite: suite_run.SuiteFile) ?history.Outcome {
    const e = lastRun(ui, suite) orelse return null;
    return e.outcome;
}

fn drawList(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const suites = ui.m.catalog.suites;
    c.text(.subtitle, "Test Suites", .{ .x = r.x, .y = r.y, .w = 160, .h = 38 }, .left, theme.text);
    const new: Rect = .{ .x = r.right() - 112, .y = r.y + 2, .w = 112, .h = 36 };
    if (widgets.primaryIconButton(ui, new, theme.icon.add, "New Suite")) ui.act(.suite_new, 0, new);

    const search: Rect = .{ .x = r.x, .y = r.y + 52, .w = r.w, .h = 36 };
    widgets.searchField(ui, search, .suite_search, ui.m.suite_search_text, "Search test suites...");

    var counts: [3]usize = .{ 0, 0, 0 };
    for (suites) |suite| {
        if (!searchMatches(ui.m.suite_search_text, suite)) continue;
        counts[0] += 1;
        const outcome = outcomeOf(ui, suite);
        if (outcome == .passed) counts[1] += 1;
        if (outcome == .failed) counts[2] += 1;
    }
    const filters = [_]state.SuiteFilter{ .all, .active, .scheduled };
    const names = [_][]const u8{ "All", "Passing", "Failing" };
    const bar: Rect = .{ .x = r.x, .y = search.bottom() + 12, .w = r.w, .h = 34 };
    for (filters, names, counts, 0..) |filter, name, n, i| {
        var buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{s}  {d}", .{ name, n }) catch name;
        if (widgets.chip(ui, bar.column(i, filters.len, 8), label, null, ui.state.suite_filter == filter)) {
            ui.state.suite_filter = filter;
        }
    }

    var y = bar.bottom() + 12;
    if (suites.len == 0) {
        c.text(.small, "No .ztest files under", .{ .x = r.x, .y = y, .w = r.w, .h = 20 }, .left, theme.muted);
        c.text(.small, ui.workspace.root, .{ .x = r.x, .y = y + 20, .w = r.w, .h = 20 }, .left, theme.text);
        c.text(.small, "Create one with New Suite.", .{ .x = r.x, .y = y + 40, .w = r.w, .h = 20 }, .left, theme.muted);
        return y + 64;
    }
    for (suites, 0..) |suite, i| {
        if (!searchMatches(ui.m.suite_search_text, suite)) continue;
        const outcome = outcomeOf(ui, suite);
        const keep = switch (ui.state.suite_filter) {
            .all => true,
            .active => outcome == .passed,
            .scheduled => outcome == .failed,
        };
        if (!keep) continue;
        const row: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 58 };
        if (ui.pressed(row)) {
            ui.state.suite = i;
            ui.state.open_test = null;
        }
        const selected = ui.state.suite == i;
        if (selected) {
            c.fillRound(row, 8, theme.amber_dim);
            c.strokeRound(row, 8, theme.amber);
        } else if (ui.hovered(row)) {
            c.fillRound(row, 8, theme.raised);
        }
        const icon: Rect = .{ .x = row.x + 10, .y = row.y + 12, .w = 34, .h = 34 };
        c.fillRound(icon, 8, theme.raised);
        c.text(.icon, theme.icon.layers, icon, .center, theme.text);
        c.text(.strong, suite.name, .{ .x = icon.right() + 12, .y = row.y + 9, .w = row.w - 90, .h = 20 }, .left, theme.text);
        var buffer: [64]u8 = undefined;
        var ago: [24]u8 = undefined;
        const last = if (lastRun(ui, suite)) |e| timefmt.ago(&ago, ui.m.now - e.unix) else "never";
        const meta = if (suite.problem != null)
            "Cannot be read"
        else
            std.fmt.bufPrint(&buffer, "{d} tests \u{00B7} Last run: {s}", .{ suite.tests, last }) catch "";
        c.text(.small, meta, .{ .x = icon.right() + 12, .y = row.y + 30, .w = row.w - 90, .h = 18 }, .left, if (suite.problem != null) theme.red else theme.muted);
        const dot = if (suite.problem != null) theme.red else if (outcome) |o| switch (o) {
            .passed => theme.green,
            .failed => theme.red,
            else => theme.muted,
        } else theme.muted;
        c.circle(row.right() - 16, row.y + 29, 4, dot);
        y += 62;
    }
    return y;
}

fn searchMatches(query: []const u8, suite: suite_run.SuiteFile) bool {
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(suite.name, query) != null or std.ascii.findIgnoreCase(suite.path, query) != null;
}

/// Totals for the selected suite: from its run when it is the one running or
/// last run in this session, otherwise from history.
const Totals = struct {
    total: usize,
    passed: usize,
    failed: usize,
    skipped: usize,
    duration_ms: u64,
    known: bool,
};

fn totalsFor(ui: *Ui, suite: suite_run.SuiteFile, here: bool) Totals {
    const run = &ui.m.suites;
    if (here) {
        var t: Totals = .{ .total = run.plannedTests(), .passed = 0, .failed = 0, .skipped = 0, .duration_ms = run.elapsedMs(), .known = true };
        for (run.finishedCases()) |case| {
            if (case.kind != .@"test") continue;
            switch (case.status) {
                .passed => t.passed += 1,
                .failed => t.failed += 1,
                .skipped => t.skipped += 1,
                .not_run => {},
            }
        }
        return t;
    }
    if (lastRun(ui, suite)) |e| return .{ .total = e.passed + e.failed + e.skipped, .passed = e.passed, .failed = e.failed, .skipped = e.skipped, .duration_ms = e.duration_ms, .known = true };
    return .{ .total = suite.tests, .passed = 0, .failed = 0, .skipped = suite.skipped, .duration_ms = 0, .known = false };
}

/// True when the session's run is of `suite`.
fn isCurrent(ui: *Ui, suite: suite_run.SuiteFile) bool {
    const run = &ui.m.suites;
    if (run.phase == .idle or run.path.len == 0) return false;
    return std.mem.endsWith(u8, run.path, suite.path);
}

fn drawDetail(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const suites = ui.m.catalog.suites;
    if (suites.len == 0) {
        const box: Rect = .{ .x = r.x, .y = r.y + 52, .w = r.w, .h = 180 };
        widgets.panel(c, box);
        c.text(.heading, "No suites yet", .{ .x = box.x + 24, .y = box.y + 30, .w = box.w - 48, .h = 28 }, .left, theme.text);
        c.text(.body, "A suite is a .ztest file. Create one with New Suite, or save a request from API Tests.", .{ .x = box.x + 24, .y = box.y + 66, .w = box.w - 48, .h = 22 }, .left, theme.muted);
        c.text(.body, "Run `ztest init` in a folder for an example project.", .{ .x = box.x + 24, .y = box.y + 92, .w = box.w - 48, .h = 22 }, .left, theme.muted);
        return box.bottom();
    }
    ui.state.suite = @min(ui.state.suite, suites.len - 1);
    const suite = suites[ui.state.suite];
    const run = &ui.m.suites;
    const here = isCurrent(ui, suite);
    const running = here and run.busy();

    // Header: icon, name, status, actions.
    const icon: Rect = .{ .x = r.x, .y = r.y + 2, .w = 40, .h = 40 };
    c.fillRound(icon, 10, theme.raised);
    c.text(.icon_large, theme.icon.layers, icon, .center, theme.text);
    const more: Rect = .{ .x = r.right() - 34, .y = r.y + 4, .w = 34, .h = 38 };
    const run_box: Rect = .{ .x = more.x - 10 - 150, .y = r.y + 4, .w = 150, .h = 38 };
    const export_box: Rect = .{ .x = run_box.x - 10 - 150, .y = r.y + 4, .w = 150, .h = 38 };
    const open_box: Rect = .{ .x = export_box.x - 10 - 120, .y = r.y + 4, .w = 120, .h = 38 };
    if (widgets.iconButton(ui, more, theme.icon.more)) ui.act(.suite_more, 0, more);
    if (running) {
        if (widgets.button(ui, run_box, if (run.phase == .stopping) "Stopping..." else "Stop", true) and run.phase == .running) ui.act(.suite_stop, 0, run_box);
    } else {
        const split = widgets.splitButton(ui, run_box, theme.icon.play, "Run Suite", suite.problem == null and !run.busy());
        if (split.main) ui.act(.suite_run, 0, run_box);
        if (split.menu) ui.act(.suite_run_menu, 0, .{ .x = run_box.right() - 240, .y = run_box.y, .w = 240, .h = run_box.h });
    }
    const can_export = here and run.phase == .done;
    if (can_export) {
        if (widgets.iconTextButton(ui, export_box, theme.icon.download, "Export Report")) ui.act(.suite_export, 0, export_box);
    } else {
        widgets.disabledButton(c, export_box, "Export Report", false);
    }
    if (widgets.iconTextButton(ui, open_box, theme.icon.link, "Open")) ui.act(.suite_open_test, std.math.maxInt(usize), open_box);

    const name_x = icon.right() + 14;
    const name_w = @min(c.measure(.subtitle, suite.name), open_box.x - name_x - 110);
    c.text(.subtitle, suite.name, .{ .x = name_x, .y = r.y, .w = name_w, .h = 36 }, .left, theme.text);
    const totals = totalsFor(ui, suite, here);
    const status: struct { label: []const u8, color: u32, tint: u32 } = if (running)
        .{ .label = "Running", .color = theme.blue, .tint = theme.blue_dim }
    else if (!totals.known)
        .{ .label = "Not run", .color = theme.muted, .tint = theme.raised }
    else if (totals.failed > 0)
        .{ .label = "Failing", .color = theme.red, .tint = theme.red_dim }
    else
        .{ .label = "Passing", .color = theme.green, .tint = theme.green_dim };
    const pill: Rect = .{ .x = name_x + name_w + 12, .y = r.y + 7, .w = 84, .h = 24 };
    c.fillRound(pill, 12, status.tint);
    c.circle(pill.x + 14, pill.y + 12, 4, status.color);
    c.text(.small, status.label, .{ .x = pill.x + 24, .y = pill.y, .w = pill.w - 28, .h = pill.h }, .left, status.color);
    c.text(.body, suite.path, .{ .x = name_x, .y = r.y + 36, .w = open_box.x - name_x - 10, .h = 22 }, .left, theme.muted);
    if (run.problem.len > 0 and here) c.text(.small, run.problem, .{ .x = name_x, .y = r.y + 56, .w = r.w - 60, .h = 20 }, .left, theme.red);
    if (suite.problem) |problem| c.text(.small, problem, .{ .x = name_x, .y = r.y + 56, .w = r.w - 60, .h = 20 }, .left, theme.red);

    var y = r.y + 82;
    drawTotals(ui, .{ .x = r.x, .y = y, .w = r.w, .h = 92 }, totals);
    y += 92 + 12;
    drawConfiguration(ui, .{ .x = r.x, .y = y, .w = r.w, .h = 96 }, suite);
    y += 96 + 12;

    var tab_labels: [5][]const u8 = .{ "Execution Results", "", "Configuration", "History", "Artifacts" };
    var cases_buffer: [32]u8 = undefined;
    tab_labels[1] = std.fmt.bufPrint(&cases_buffer, "Test Cases ({d})", .{suite.tests}) catch "Test Cases";
    const bar: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 42 };
    if (widgets.tabs(ui, bar, &tab_labels, ui.state.suite_tab)) |tab| ui.state.suite_tab = tab;
    y = bar.bottom() + 10;
    const body: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 0 };
    return switch (ui.state.suite_tab) {
        0 => drawResults(ui, body, suite, here, totals),
        1 => drawCases(ui, body),
        2 => drawSettings(ui, body),
        3 => drawHistory(ui, body, suite),
        else => drawArtifacts(ui, body),
    };
}

fn drawTotals(ui: *Ui, row: Rect, t: Totals) void {
    const c = ui.c;
    var buffers: [5][32]u8 = undefined;
    const total_f: f64 = @floatFromInt(@max(1, t.total));
    var skipped_buffer: [24]u8 = undefined;
    var duration_buffer: [24]u8 = undefined;
    const items = [_]struct { value: []const u8, label: []const u8, note: []const u8, color: u32, tint: u32, icon: []const u8 }{
        .{ .value = std.fmt.bufPrint(&buffers[0], "{d}", .{t.total}) catch "", .label = "Total Tests", .note = "", .color = theme.text, .tint = theme.raised, .icon = theme.icon.file },
        .{ .value = std.fmt.bufPrint(&buffers[1], "{d}", .{t.passed}) catch "", .label = "Passed", .note = if (t.known) percent(&buffers[2], t.passed, total_f) else "", .color = theme.green, .tint = theme.green_dim, .icon = theme.icon.check },
        .{ .value = std.fmt.bufPrint(&buffers[3], "{d}", .{t.failed}) catch "", .label = "Failed", .note = if (t.known) percent(&buffers[4], t.failed, total_f) else "", .color = theme.red, .tint = theme.red_dim, .icon = theme.icon.cross },
        .{ .value = std.fmt.bufPrint(&skipped_buffer, "{d}", .{t.skipped}) catch "", .label = "Skipped", .note = "", .color = theme.amber, .tint = theme.amber_dim, .icon = theme.icon.minus },
        .{ .value = if (t.known) timefmt.duration(&duration_buffer, t.duration_ms) else "-", .label = "Total Duration", .note = "", .color = theme.text, .tint = theme.raised, .icon = theme.icon.clock },
    };
    for (items, 0..) |item, i| {
        const card = row.column(i, items.len, 10);
        widgets.panel(c, card);
        const badge: Rect = .{ .x = card.x + 14, .y = card.y + 22, .w = 48, .h = 48 };
        c.fillRound(badge, 10, item.tint);
        c.text(.icon_large, item.icon, badge, .center, item.color);
        const text_x = badge.right() + 12;
        const text_w = card.right() - text_x - 8;
        c.text(.subtitle, item.value, .{ .x = text_x, .y = card.y + 14, .w = text_w, .h = 30 }, .left, theme.text);
        c.text(.small, item.label, .{ .x = text_x, .y = card.y + 44, .w = text_w, .h = 18 }, .left, theme.muted);
        if (item.note.len > 0) c.text(.small, item.note, .{ .x = text_x, .y = card.y + 62, .w = text_w, .h = 18 }, .left, item.color);
    }
}

fn percent(buffer: []u8, n: usize, total: f64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:.1}%", .{@as(f64, @floatFromInt(n)) * 100 / total}) catch "";
}

fn drawConfiguration(ui: *Ui, r: Rect, suite: suite_run.SuiteFile) void {
    const c = ui.c;
    widgets.panel(c, r);
    const third = (r.w - 36) / 3;
    const parts = [_]struct { icon: []const u8, title: []const u8 }{
        .{ .icon = theme.icon.layers, .title = "Environment" },
        .{ .icon = theme.icon.settings, .title = "Run Configuration" },
        .{ .icon = theme.icon.calendar, .title = "Last Run" },
    };
    for (parts, 0..) |part, i| {
        const x = r.x + 18 + @as(f32, @floatFromInt(i)) * (third + 0);
        if (i > 0) c.line(x - 10, r.y + 16, x - 10, r.bottom() - 16, theme.border, 1);
        const icon: Rect = .{ .x = x, .y = r.y + 18, .w = 38, .h = 38 };
        c.fillRound(icon, 10, theme.raised);
        c.text(.icon, part.icon, icon, .center, theme.text);
        const tx = icon.right() + 14;
        const tw = x + third - tx - 20;
        c.text(.small, part.title, .{ .x = tx, .y = r.y + 14, .w = tw, .h = 20 }, .left, theme.text);
        const box: Rect = .{ .x = tx, .y = r.y + 40, .w = @min(200, tw), .h = 32 };
        switch (i) {
            0 => if (widgets.dropdown(ui, box, ui.workspace.environmentName(), false)) ui.workspace.cycleEnvironment(),
            1 => {
                if (widgets.dropdown(ui, box, if (ui.m.fail_fast) "Stop at first failure" else "Default", false)) ui.m.fail_fast = !ui.m.fail_fast;
                c.text(.tiny, if (ui.m.fail_fast) "Later tests are not run after a failure" else "Every test runs, in file order", .{ .x = tx, .y = box.bottom() + 2, .w = tw, .h = 16 }, .left, theme.muted);
            },
            else => {
                if (lastRun(ui, suite)) |e| {
                    var date: [48]u8 = undefined;
                    c.text(.body, timefmt.dateTime(&date, native.local(e.unix), false), .{ .x = tx, .y = r.y + 40, .w = tw, .h = 22 }, .left, theme.text);
                    var meta: [64]u8 = undefined;
                    c.text(.tiny, std.fmt.bufPrint(&meta, "{d} passed \u{00B7} {d} failed \u{00B7} {s}", .{ e.passed, e.failed, if (e.environment.len > 0) e.environment else "global" }) catch "", .{ .x = tx, .y = r.y + 64, .w = tw, .h = 16 }, .left, theme.muted);
                } else {
                    c.text(.body, "Never run", .{ .x = tx, .y = r.y + 40, .w = tw, .h = 22 }, .left, theme.muted);
                }
            },
        }
    }
}

fn drawResults(ui: *Ui, r: Rect, suite: suite_run.SuiteFile, here: bool, totals: Totals) f32 {
    const c = ui.c;
    const run = &ui.m.suites;
    const inner_x = r.x + 16;
    const inner_w = r.w - 32;
    var y = r.y + 14;

    if (!here) {
        const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 120 };
        c.strokeRound(box, 12, theme.border);
        c.text(.strong, "Not run in this session", .{ .x = inner_x, .y = y + 6, .w = inner_w, .h = 22 }, .left, theme.text);
        var meta: [96]u8 = undefined;
        const note = if (lastRun(ui, suite)) |e| std.fmt.bufPrint(&meta, "Last run: {d} passed, {d} failed. Run it to see each test's details.", .{ e.passed, e.failed }) catch "" else "Run Suite sends every test in order and shows each result as it finishes.";
        c.text(.body, note, .{ .x = inner_x, .y = y + 34, .w = inner_w, .h = 22 }, .left, theme.muted);
        return box.bottom();
    }

    const running = run.busy();
    const outcome: state.Outcome = if (totals.failed > 0) .failed else .passed;
    if (running) {
        c.circle(inner_x + 18, y + 18, 18, theme.blue_dim);
        c.text(.icon, theme.icon.refresh, .{ .x = inner_x, .y = y, .w = 36, .h = 36 }, .center, theme.blue);
    } else {
        widgets.outcomeBadge(c, inner_x + 18, y + 18, 18, outcome);
    }
    const title = if (running) "Test Suite Running" else if (run.summary.interrupted) "Test Suite Stopped" else "Test Suite Execution Completed";
    c.text(.strong, title, .{ .x = inner_x + 48, .y = y, .w = inner_w - 200, .h = 20 }, .left, theme.text);
    var date: [48]u8 = undefined;
    var took: [24]u8 = undefined;
    var meta: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&meta, "Started at {s} \u{00B7} Duration: {s} \u{00B7} Environment: {s}", .{
        timefmt.dateTime(&date, native.local(run.started_unix), false),
        timefmt.duration(&took, run.elapsedMs()),
        if (run.environment.len > 0) run.environment else "global",
    }) catch "";
    c.text(.small, line, .{ .x = inner_x + 48, .y = y + 20, .w = inner_w - 200, .h = 18 }, .left, theme.muted);
    const pill_label = if (running) "Running" else if (run.summary.interrupted) "Stopped" else "Completed";
    widgets.pill(c, .{ .x = inner_x + inner_w - 110, .y = y + 6, .w = 104, .h = 26 }, pill_label, if (running) theme.blue else theme.green, if (running) theme.blue_dim else theme.green_dim);
    y += 48;

    // Progress: shares of the planned tests that passed, failed or skipped.
    const bar: Rect = .{ .x = inner_x, .y = y, .w = inner_w - 70, .h = 8 };
    c.fillRound(bar, 4, theme.raised);
    const planned: f32 = @floatFromInt(@max(1, totals.total));
    var bx = bar.x;
    for ([_]struct { n: usize, color: u32 }{ .{ .n = totals.passed, .color = theme.green }, .{ .n = totals.failed, .color = theme.red }, .{ .n = totals.skipped, .color = theme.amber } }) |part| {
        const w = bar.w * @as(f32, @floatFromInt(part.n)) / planned;
        if (w > 0) c.fill(.{ .x = bx, .y = bar.y, .w = w, .h = bar.h }, part.color);
        bx += w;
    }
    var count_buffer: [24]u8 = undefined;
    c.text(.small, std.fmt.bufPrint(&count_buffer, "{d} tests", .{totals.total}) catch "", .{ .x = bar.right() + 8, .y = y - 6, .w = 62, .h = 20 }, .right, theme.muted);
    y += 22;

    const filters = [_]state.ResultFilter{ .all, .passed, .failed, .skipped };
    const names = [_][]const u8{ "All", "Passed", "Failed", "Skipped" };
    const dots = [_]?u32{ null, theme.green, theme.red, theme.amber };
    const counts = [_]usize{ totals.passed + totals.failed + totals.skipped, totals.passed, totals.failed, totals.skipped };
    for (filters, names, dots, counts, 0..) |filter, name, dot, n, i| {
        var buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{s}  {d}", .{ name, n }) catch name;
        const chip_rect: Rect = .{ .x = inner_x + @as(f32, @floatFromInt(i)) * 118, .y = y, .w = 110, .h = 34 };
        if (widgets.chip(ui, chip_rect, label, dot, ui.state.result_filter == filter)) ui.state.result_filter = filter;
    }
    const search: Rect = .{ .x = inner_x + inner_w - 200, .y = y, .w = 200, .h = 34 };
    widgets.searchField(ui, search, .result_search, ui.m.search_text, "Search tests...");
    y += 46;

    for (run.finishedCases(), 0..) |case, index| {
        const outcome_of: state.Outcome = switch (case.status) {
            .passed => .passed,
            .failed => .failed,
            .skipped, .not_run => .skipped,
        };
        if (!ui.state.result_filter.allows(outcome_of)) continue;
        if (ui.m.search_text.len > 0 and std.ascii.findIgnoreCase(case.name, ui.m.search_text) == null) continue;
        y = drawCase(ui, case, index, inner_x, inner_w, y);
    }
    if (running) {
        c.text(.small, "Running...", .{ .x = inner_x + 10, .y = y + 6, .w = 200, .h = 20 }, .left, theme.muted);
        y += 30;
    }
    const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = y + 10 - r.y };
    c.strokeRound(box, 12, theme.border);
    return box.bottom();
}

fn drawCase(ui: *Ui, case: suite_run.CaseView, index: usize, x: f32, w: f32, top: f32) f32 {
    const c = ui.c;
    var y = top;
    const row: Rect = .{ .x = x, .y = y, .w = w, .h = 38 };
    const open = ui.state.open_test == index;
    const more: Rect = .{ .x = row.right() - 30, .y = y + 5, .w = 28, .h = 28 };
    if (ui.pressed(more)) {
        ui.act(.suite_open_test, index, more);
    } else if (ui.pressed(row)) {
        ui.state.open_test = state.toggled(ui.state.open_test, index);
    }
    if (ui.hovered(row)) c.fillRound(row, 6, theme.raised);
    c.text(.icon, if (open) theme.icon.chevron_down else theme.icon.chevron_right, .{ .x = x + 4, .y = y, .w = 18, .h = row.h }, .left, theme.muted);
    const outcome: state.Outcome = switch (case.status) {
        .passed => .passed,
        .failed => .failed,
        .skipped, .not_run => .skipped,
    };
    widgets.outcomeBadge(c, x + 36, y + 19, 10, outcome);
    var name_buffer: [160]u8 = undefined;
    const name = if (case.kind == .@"test") case.name else std.fmt.bufPrint(&name_buffer, "[{s}] {s}", .{ @tagName(case.kind), case.name }) catch case.name;
    c.text(.body, name, .{ .x = x + 56, .y = y, .w = w * 0.34, .h = row.h }, .left, theme.text);
    var route: [192]u8 = undefined;
    c.text(.tiny, std.fmt.bufPrint(&route, "{s} {s}", .{ case.method, case.url }) catch "", .{ .x = x + 56 + w * 0.34 + 8, .y = y, .w = w * 0.38, .h = row.h }, .left, theme.muted);
    var took: [24]u8 = undefined;
    c.text(.small, if (case.status == .skipped or case.status == .not_run) "-" else timefmt.duration(&took, case.duration_ms), .{ .x = row.right() - 190, .y = y, .w = 70, .h = row.h }, .right, theme.text);
    const pill: Rect = .{ .x = row.right() - 110, .y = y + 8, .w = 72, .h = 23 };
    switch (case.status) {
        .passed => widgets.pill(c, pill, "Passed", theme.green, theme.green_dim),
        .failed => widgets.pill(c, pill, "Failed", theme.red, theme.red_dim),
        .skipped => widgets.pill(c, pill, "Skipped", theme.amber, theme.amber_dim),
        .not_run => widgets.pill(c, pill, "Not run", theme.muted, theme.raised),
    }
    if (ui.hovered(more)) c.fillRound(more, 6, theme.border);
    c.text(.icon, theme.icon.more, more, .center, theme.muted);
    y += row.h;
    if (open) y = drawCaseDetails(ui, case, x + 40, w - 40, y);
    return y;
}

fn drawCaseDetails(ui: *Ui, case: suite_run.CaseView, x: f32, w: f32, top: f32) f32 {
    const c = ui.c;
    // As many lines as the chosen view has, up to a readable limit.
    const text = switch (ui.state.detail_tab) {
        0 => case.request_text,
        1 => case.response_text,
        2 => case.log_text,
        else => "",
    };
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| lines += 1;
    const shown_lines = if (ui.state.detail_tab == 3) case.assertions.len + @intFromBool(case.failure != null) else @min(lines, 16);
    const box: Rect = .{ .x = x, .y = top + 4, .w = w, .h = 58 + @as(f32, @floatFromInt(@max(shown_lines, 1))) * 20 };
    c.fillRound(box, 8, theme.background);
    c.strokeRound(box, 8, theme.border);
    const bar: Rect = .{ .x = box.x + 10, .y = box.y + 4, .w = box.w - 60, .h = 36 };
    if (widgets.tabs(ui, bar, &detail_tabs, ui.state.detail_tab)) |tab| ui.state.detail_tab = tab;
    const copy: Rect = .{ .x = box.right() - 40, .y = box.y + 8, .w = 28, .h = 28 };
    if (ui.hovered(copy)) c.fillRound(copy, 6, theme.raised);
    c.text(.icon, theme.icon.copy, copy, .center, theme.muted);
    if (ui.pressed(copy)) {
        ui.m.copy_request = text;
        ui.act(.copy_text, 0, copy);
    }

    var y = bar.bottom() + 8;
    if (ui.state.detail_tab == 3) {
        if (case.failure) |failure| {
            c.text(.mono, failure, .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, theme.red);
            y += 20;
        }
        if (case.assertions.len == 0 and case.failure == null) c.text(.small, "No assertions in this test.", .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, theme.muted);
        for (case.assertions) |a| {
            var buffer: [256]u8 = undefined;
            const line = if (a.passed) std.fmt.bufPrint(&buffer, "PASS  {s}", .{a.text}) catch a.text else std.fmt.bufPrint(&buffer, "FAIL  {s}   Actual: {s}", .{ a.text, a.actual }) catch a.text;
            c.text(.mono, line, .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, if (a.passed) theme.green else theme.red);
            y += 20;
        }
        return box.bottom() + 6;
    }
    if (text.len == 0) {
        c.text(.small, "Nothing was sent: the test was skipped, stopped, or failed before its request.", .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, theme.muted);
        return box.bottom() + 6;
    }
    var lines_it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines_it.next()) |line| : (n += 1) {
        if (n == 16) break;
        const failing = std.mem.startsWith(u8, line, "ERROR");
        c.text(.mono, line, .{ .x = box.x + 14, .y = y, .w = box.w - 28, .h = 19 }, .left, if (failing) theme.red else theme.text);
        y += 20;
    }
    return box.bottom() + 6;
}

fn drawCases(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const selected = ui.m.selected_suite orelse {
        c.text(.body, "This suite cannot be read.", .{ .x = r.x, .y = r.y + 10, .w = r.w, .h = 22 }, .left, theme.muted);
        return r.y + 40;
    };
    var y = r.y;
    const header: Rect = .{ .x = r.x + 16, .y = y, .w = r.w - 32, .h = 30 };
    c.text(.small, "Test", .{ .x = header.x + 40, .y = y, .w = 200, .h = 30 }, .left, theme.muted);
    c.text(.small, "Request", .{ .x = header.x + header.w * 0.42, .y = y, .w = 200, .h = 30 }, .left, theme.muted);
    c.text(.small, "Checks", .{ .x = header.right() - 170, .y = y, .w = 80, .h = 30 }, .left, theme.muted);
    y += 32;
    for (selected.tests, 0..) |case, i| {
        const row: Rect = .{ .x = r.x + 16, .y = y, .w = r.w - 32, .h = 36 };
        c.line(row.x, y, row.right(), y, theme.grid, 1);
        if (ui.hovered(row)) c.fillRound(row, 6, theme.raised);
        if (ui.pressed(row)) ui.act(.suite_open_test, std.math.maxInt(usize) - 1 - i, row);
        var number: [8]u8 = undefined;
        c.text(.small, std.fmt.bufPrint(&number, "{d}", .{i + 1}) catch "", .{ .x = row.x, .y = y, .w = 28, .h = row.h }, .right, theme.muted);
        c.text(.body, case.name, .{ .x = row.x + 40, .y = y, .w = row.w * 0.42 - 44, .h = row.h }, .left, theme.text);
        var route: [192]u8 = undefined;
        c.text(.small, std.fmt.bufPrint(&route, "{s} {s}", .{ @tagName(case.request.method), case.request.url }) catch "", .{ .x = row.x + row.w * 0.42, .y = y, .w = row.w * 0.42 - 180, .h = row.h }, .left, theme.muted);
        var checks: [24]u8 = undefined;
        c.text(.small, std.fmt.bufPrint(&checks, "{d} expect", .{case.expects.len}) catch "", .{ .x = row.right() - 170, .y = y, .w = 80, .h = row.h }, .left, theme.text);
        switch (case.mode) {
            .run => {},
            .skip => widgets.pill(c, .{ .x = row.right() - 80, .y = y + 7, .w = 70, .h = 22 }, "Skip", theme.amber, theme.amber_dim),
            .disabled => widgets.pill(c, .{ .x = row.right() - 80, .y = y + 7, .w = 70, .h = 22 }, "Disabled", theme.muted, theme.raised),
        }
        y += row.h;
    }
    c.text(.tiny, "Click a test to open it in API Tests.", .{ .x = r.x + 16, .y = y + 6, .w = r.w - 32, .h = 18 }, .left, theme.muted);
    return y + 30;
}

fn drawSettings(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const selected = ui.m.selected_suite orelse return r.y + 20;
    var y = r.y;
    const items = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "Setup", .value = if (selected.setup != null) "Runs before the tests" else "None" },
        .{ .label = "Teardown", .value = if (selected.teardown != null) "Runs after the tests, even when setup fails" else "None" },
        .{ .label = "Environment", .value = ui.workspace.environmentName() },
        .{ .label = "ztest.json", .value = ui.workspace.root },
    };
    for (items) |item| {
        c.text(.small, item.label, .{ .x = r.x + 16, .y = y, .w = 140, .h = 30 }, .left, theme.muted);
        c.text(.body, item.value, .{ .x = r.x + 170, .y = y, .w = r.w - 186, .h = 30 }, .left, theme.text);
        y += 32;
    }
    y += 8;
    c.text(.strong, "Suite variables", .{ .x = r.x + 16, .y = y, .w = 300, .h = 24 }, .left, theme.text);
    y += 30;
    if (selected.variables.len == 0) {
        c.text(.small, "None", .{ .x = r.x + 16, .y = y, .w = 300, .h = 22 }, .left, theme.muted);
        y += 26;
    }
    for (selected.variables) |variable| {
        var name: [80]u8 = undefined;
        c.text(.mono, std.fmt.bufPrint(&name, "{{{{{s}}}}}", .{variable.name}) catch variable.name, .{ .x = r.x + 16, .y = y, .w = 220, .h = 24 }, .left, theme.amber);
        c.text(.body, if (variable.secret) redact.mask else variable.value, .{ .x = r.x + 250, .y = y, .w = r.w - 266, .h = 24 }, .left, theme.text);
        y += 28;
    }
    return y + 10;
}

fn drawHistory(ui: *Ui, r: Rect, suite: suite_run.SuiteFile) f32 {
    const c = ui.c;
    var y = r.y;
    const entries = ui.m.history.entries.items;
    var shown: usize = 0;
    var i = entries.len;
    while (i > 0 and shown < 20) {
        i -= 1;
        const e = entries[i];
        if (e.kind != .suite or !(std.mem.eql(u8, e.suite, suite.path) or std.mem.endsWith(u8, e.suite, suite.path))) continue;
        shown += 1;
        const row: Rect = .{ .x = r.x + 16, .y = y, .w = r.w - 32, .h = 38 };
        c.line(row.x, y, row.right(), y, theme.grid, 1);
        var date: [48]u8 = undefined;
        c.text(.body, timefmt.dateTime(&date, native.local(e.unix), false), .{ .x = row.x, .y = y, .w = 220, .h = row.h }, .left, theme.text);
        var meta: [96]u8 = undefined;
        var took: [24]u8 = undefined;
        c.text(.small, std.fmt.bufPrint(&meta, "{d} passed \u{00B7} {d} failed \u{00B7} {d} skipped \u{00B7} {s}", .{ e.passed, e.failed, e.skipped, timefmt.duration(&took, e.duration_ms) }) catch "", .{ .x = row.x + 230, .y = y, .w = row.w - 420, .h = row.h }, .left, theme.muted);
        c.text(.small, if (e.environment.len > 0) e.environment else "global", .{ .x = row.right() - 190, .y = y, .w = 100, .h = row.h }, .left, theme.text);
        const pill: Rect = .{ .x = row.right() - 80, .y = y + 8, .w = 72, .h = 23 };
        switch (e.outcome) {
            .passed => widgets.pill(c, pill, "Passed", theme.green, theme.green_dim),
            .failed => widgets.pill(c, pill, "Failed", theme.red, theme.red_dim),
            else => widgets.pill(c, pill, "Stopped", theme.muted, theme.raised),
        }
        y += row.h;
    }
    if (shown == 0) {
        c.text(.body, "No runs recorded for this suite yet.", .{ .x = r.x + 16, .y = y + 6, .w = r.w - 32, .h = 22 }, .left, theme.muted);
        y += 34;
    }
    var note: [160]u8 = undefined;
    c.text(.tiny, std.fmt.bufPrint(&note, "Kept in {s}/{s}", .{ ui.workspace.root, history.path }) catch "", .{ .x = r.x + 16, .y = y + 6, .w = r.w - 32, .h = 18 }, .left, theme.muted);
    return y + 30;
}

fn drawArtifacts(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    var y = r.y;
    const artifacts = ui.m.artifacts.items;
    if (artifacts.len == 0) {
        c.text(.body, "No reports exported yet. Run the suite, then use Export Report.", .{ .x = r.x + 16, .y = y + 6, .w = r.w - 32, .h = 22 }, .left, theme.muted);
        return y + 40;
    }
    for (artifacts) |path| {
        c.text(.icon, theme.icon.file, .{ .x = r.x + 16, .y = y, .w = 20, .h = 34 }, .left, theme.muted);
        c.text(.body, path, .{ .x = r.x + 44, .y = y, .w = r.w - 60, .h = 34 }, .left, theme.text);
        y += 36;
    }
    return y + 10;
}
