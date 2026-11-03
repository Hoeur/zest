//! Reports, Environments and Settings. The mockups do not draw these pages, so
//! they follow the same panels and tables as the others.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const widgets = @import("../widgets.zig");
const theme = @import("../theme.zig");
const timefmt = @import("../timefmt.zig");
const native = @import("../native.zig");
const history = @import("../../core/history.zig");
const redact = @import("../../core/redact.zig");
const config = @import("../../core/config.zig");

pub fn draw(ui: *Ui, area: Rect) f32 {
    const screen = ui.state.screen;
    const top = widgets.pageHeader(ui, area, screen.label(), screen.subtitle());
    const box: Rect = .{ .x = area.x + theme.page_margin, .y = top, .w = area.w - theme.page_margin * 2, .h = 0 };
    const end = switch (screen) {
        .reports => reports(ui, box),
        .environments => environments(ui, box),
        else => settings(ui, box),
    };
    return end - area.y + ui.state.scroll + theme.page_margin;
}

fn reports(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const m = ui.m;
    var y = r.y;
    const exported: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 70 + @as(f32, @floatFromInt(@max(1, m.artifacts.items.len))) * 34 };
    widgets.panel(c, exported);
    c.text(.heading, "Exported Reports", .{ .x = r.x + 20, .y = y + 14, .w = r.w - 40, .h = 26 }, .left, theme.text);
    c.text(.small, "Export a suite's results from Test Suites, or use ztest run --report in CI.", .{ .x = r.x + 20, .y = y + 40, .w = r.w - 40, .h = 18 }, .left, theme.muted);
    var ry = y + 66;
    if (m.artifacts.items.len == 0) c.text(.body, "None this session.", .{ .x = r.x + 20, .y = ry, .w = r.w - 40, .h = 28 }, .left, theme.muted);
    for (m.artifacts.items) |path| {
        c.text(.icon, theme.icon.file, .{ .x = r.x + 20, .y = ry, .w = 20, .h = 28 }, .left, theme.muted);
        c.text(.body, path, .{ .x = r.x + 48, .y = ry, .w = r.w - 68, .h = 28 }, .left, theme.text);
        ry += 34;
    }
    y = exported.bottom() + theme.gap;

    const entries = m.history.entries.items;
    const shown = @min(entries.len, 25);
    const runs: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 110 + @as(f32, @floatFromInt(@max(1, shown))) * 38 };
    widgets.panel(c, runs);
    c.text(.heading, "Run History", .{ .x = r.x + 20, .y = y + 14, .w = r.w - 40, .h = 26 }, .left, theme.text);
    var note: [200]u8 = undefined;
    c.text(.small, std.fmt.bufPrint(&note, "Suite runs, load tests and requests, newest first, from {s}/{s}.", .{ ui.workspace.root, history.path }) catch "", .{ .x = r.x + 20, .y = y + 40, .w = r.w - 40, .h = 18 }, .left, theme.muted);
    const cols = [_]struct { title: []const u8, at: f32 }{
        .{ .title = "Kind", .at = 0 },
        .{ .title = "Name", .at = 0.10 },
        .{ .title = "Result", .at = 0.48 },
        .{ .title = "Details", .at = 0.60 },
        .{ .title = "Started At", .at = 0.80 },
    };
    const table: Rect = .{ .x = r.x + 20, .y = y + 70, .w = r.w - 40, .h = 0 };
    for (cols) |col| c.text(.small, col.title, .{ .x = table.x + table.w * col.at, .y = table.y, .w = 160, .h = 30 }, .left, theme.muted);
    var ty = table.y + 34;
    if (entries.len == 0) c.text(.body, "Nothing recorded yet.", .{ .x = table.x, .y = ty, .w = table.w, .h = 30 }, .left, theme.muted);
    var i = entries.len;
    while (i > entries.len - shown) {
        i -= 1;
        const e = entries[i];
        c.line(table.x, ty, table.right(), ty, theme.grid, 1);
        c.text(.body, @tagName(e.kind), .{ .x = table.x, .y = ty, .w = table.w * 0.1, .h = 38 }, .left, theme.muted);
        c.text(.body, e.name, .{ .x = table.x + table.w * 0.10, .y = ty, .w = table.w * 0.37, .h = 38 }, .left, theme.text);
        const pill: Rect = .{ .x = table.x + table.w * 0.48, .y = ty + 8, .w = 72, .h = 23 };
        switch (e.outcome) {
            .passed => widgets.pill(c, pill, "Passed", theme.green, theme.green_dim),
            .failed => widgets.pill(c, pill, "Failed", theme.red, theme.red_dim),
            .skipped => widgets.pill(c, pill, "Skipped", theme.amber, theme.amber_dim),
            .not_run => widgets.pill(c, pill, "Stopped", theme.muted, theme.raised),
        }
        var detail: [96]u8 = undefined;
        var took: [24]u8 = undefined;
        const text = switch (e.kind) {
            .suite => std.fmt.bufPrint(&detail, "{d} passed, {d} failed", .{ e.passed, e.failed }) catch "",
            .load => std.fmt.bufPrint(&detail, "{d:.0} rps, p95 {d:.0} ms", .{ e.rps, e.p95_ms }) catch "",
            else => timefmt.duration(&took, e.duration_ms),
        };
        c.text(.small, text, .{ .x = table.x + table.w * 0.60, .y = ty, .w = table.w * 0.19, .h = 38 }, .left, theme.text);
        var date: [48]u8 = undefined;
        c.text(.small, timefmt.dateTime(&date, native.local(e.unix), false), .{ .x = table.x + table.w * 0.80, .y = ty, .w = table.w * 0.2, .h = 38 }, .left, theme.muted);
        ty += 38;
    }
    return runs.bottom();
}

fn environments(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const w = ui.workspace;
    var y = r.y;
    var path: [300]u8 = undefined;
    const location = std.fmt.bufPrint(&path, "{s}/{s}", .{ w.root, config.file_name }) catch config.file_name;
    const head: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = 76 };
    widgets.panel(c, head);
    c.text(.strong, location, .{ .x = r.x + 20, .y = y + 14, .w = r.w - 200, .h = 22 }, .left, theme.text);
    c.text(.small, w.config_problem orelse "Variables apply everywhere; an environment's values override them. Pick one in the top bar.", .{ .x = r.x + 20, .y = y + 40, .w = r.w - 200, .h = 20 }, .left, if (w.config_problem != null) theme.red else theme.muted);
    const reload: Rect = .{ .x = r.right() - 20 - 120, .y = y + 20, .w = 120, .h = 36 };
    if (widgets.iconTextButton(ui, reload, theme.icon.refresh, "Reload")) ui.act(.reload, 0, reload);
    y = head.bottom() + theme.gap;

    y = variableTable(ui, .{ .x = r.x, .y = y, .w = r.w, .h = 0 }, "Global variables", w.settings.variables, w.selected == null);
    for (w.settings.environments.items, 0..) |env, i| {
        y = variableTable(ui, .{ .x = r.x, .y = y + theme.gap, .w = r.w, .h = 0 }, env.name, env.variables, w.selected == i);
    }
    if (w.settings.environments.items.len == 0) {
        const none: Rect = .{ .x = r.x, .y = y + theme.gap, .w = r.w, .h = 70 };
        widgets.panel(c, none);
        c.text(.body, "No environments. Add an \"environments\" object to ztest.json, or run ztest init for an example.", .{ .x = r.x + 20, .y = none.y, .w = r.w - 40, .h = none.h }, .left, theme.muted);
        y = none.bottom();
    }
    return y;
}

fn variableTable(ui: *Ui, r: Rect, title: []const u8, variables: config.Variables, active: bool) f32 {
    const c = ui.c;
    const rows = variables.items.len;
    const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 56 + @as(f32, @floatFromInt(@max(1, rows))) * 34 };
    widgets.panel(c, box);
    if (active) c.strokeRound(box, 12, theme.amber);
    c.text(.heading, title, .{ .x = r.x + 20, .y = r.y + 12, .w = r.w - 160, .h = 26 }, .left, theme.text);
    if (active) widgets.pill(c, .{ .x = r.right() - 20 - 90, .y = r.y + 14, .w = 90, .h = 24 }, "In use", theme.green, theme.green_dim);
    var y = r.y + 48;
    if (rows == 0) c.text(.small, "No variables.", .{ .x = r.x + 20, .y = y, .w = r.w - 40, .h = 28 }, .left, theme.muted);
    for (variables.items) |v| {
        var name: [80]u8 = undefined;
        c.text(.mono, std.fmt.bufPrint(&name, "{{{{{s}}}}}", .{v.name}) catch v.name, .{ .x = r.x + 20, .y = y, .w = 260, .h = 28 }, .left, theme.amber);
        var value: [128]u8 = undefined;
        const text = switch (v.source) {
            .text => |t| t,
            .env => |key| std.fmt.bufPrint(&value, "{s}  (from ${s})", .{ redact.mask, key }) catch redact.mask,
        };
        c.text(.body, text, .{ .x = r.x + 300, .y = y, .w = r.w - 320, .h = 28 }, .left, theme.text);
        y += 34;
    }
    return box.bottom();
}

fn settings(ui: *Ui, r: Rect) f32 {
    const c = ui.c;
    const box: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 230 };
    widgets.panel(c, box);
    var location: [300]u8 = undefined;
    const items = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "Version", .value = @import("build_options").version },
        .{ .label = "Workspace", .value = ui.workspace.root },
        .{ .label = "History file", .value = std.fmt.bufPrint(&location, "{s}/{s}", .{ ui.workspace.root, history.path }) catch history.path },
        .{ .label = "Request limits", .value = "30 s timeout, 4 MiB response, 32 MiB request" },
        .{ .label = "Shortcuts", .value = "Ctrl+1-7 pages, Ctrl+S save, Ctrl+O open, Ctrl+Enter send" },
    };
    var y = r.y + 20;
    for (items) |item| {
        c.text(.small, item.label, .{ .x = r.x + 20, .y = y, .w = 160, .h = 34 }, .left, theme.muted);
        c.text(.body, item.value, .{ .x = r.x + 200, .y = y, .w = r.w - 220, .h = 34 }, .left, theme.text);
        y += 40;
    }
    return box.bottom();
}
