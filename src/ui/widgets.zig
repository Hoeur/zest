//! Controls shared by screens.

const std = @import("std");
const Ui = @import("app.zig").Ui;
const Canvas = @import("canvas.zig").Canvas;
const Rect = @import("layout.zig").Rect;
const PointF = @import("win32.zig").PointF;
const sample = @import("sample.zig");
const Outcome = @import("state.zig").Outcome;
const theme = @import("theme.zig");

pub fn panel(c: *Canvas, r: Rect) void {
    c.fillRound(r, 12, theme.panel);
    c.strokeRound(r, 12, theme.border);
}

/// Draws a page title and returns the y below it, scrolled with the page.
pub fn pageHeader(ui: *Ui, area: Rect, title: []const u8, subtitle: []const u8) f32 {
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    const y = area.y + 20 - ui.state.scroll;
    ui.c.text(.title, title, .{ .x = x, .y = y, .w = w, .h = 44 }, .left, theme.text);
    ui.c.text(.body, subtitle, .{ .x = x, .y = y + 46, .w = w, .h = 22 }, .left, theme.muted);
    return y + 84;
}

pub fn pill(c: *Canvas, r: Rect, label: []const u8, color: u32, tint: u32) void {
    c.fillRound(r, r.h / 2, tint);
    c.text(.small, label, r, .center, color);
}

/// Marks a page whose figures are placeholders.
pub fn sampleTag(c: *Canvas, x: f32, y: f32) void {
    pill(c, .{ .x = x, .y = y, .w = 120, .h = 26 }, "Sample data", theme.amber, theme.amber_dim);
}

pub fn outcomePill(c: *Canvas, r: Rect, outcome: Outcome) void {
    switch (outcome) {
        .passed => pill(c, r, "Passed", theme.green, theme.green_dim),
        .failed => pill(c, r, "Failed", theme.red, theme.red_dim),
        .skipped => pill(c, r, "Skipped", theme.amber, theme.amber_dim),
    }
}

pub fn outcomeBadge(c: *Canvas, cx: f32, cy: f32, radius: f32, outcome: Outcome) void {
    const color, const icon = switch (outcome) {
        .passed => .{ theme.green, theme.icon.check },
        .failed => .{ theme.red, theme.icon.cross },
        .skipped => .{ theme.amber, theme.icon.minus },
    };
    c.circle(cx, cy, radius, color);
    c.text(.icon, icon, .{ .x = cx - radius, .y = cy - radius, .w = radius * 2, .h = radius * 2 }, .center, theme.on_amber);
}

/// A button for an action the core cannot perform yet. Never clickable.
pub fn disabledButton(c: *Canvas, r: Rect, label: []const u8, primary: bool) void {
    const faded = 0x70000000;
    if (primary) {
        c.fillRound(r, 8, (theme.amber & 0xFFFFFF) | faded);
        c.text(.strong, label, r, .center, theme.on_amber);
    } else {
        c.strokeRound(r, 8, theme.border);
        c.text(.body, label, r, .center, theme.muted);
    }
}

/// Read-only box with text, as an input or dropdown will look once editable.
pub fn field(c: *Canvas, r: Rect, label: []const u8, dropdown: bool) void {
    c.fillRound(r, 8, theme.background);
    c.strokeRound(r, 8, theme.border);
    const end: f32 = if (dropdown) 30 else 12;
    c.text(.body, label, .{ .x = r.x + 12, .y = r.y, .w = r.w - 12 - end, .h = r.h }, .left, theme.text);
    if (dropdown) c.text(.icon, theme.icon.chevron_down, .{ .x = r.right() - 28, .y = r.y, .w = 18, .h = r.h }, .left, theme.muted);
}

/// Draws a row of tabs on `r` and returns the index clicked, if any.
pub fn tabs(ui: *Ui, r: Rect, labels: []const []const u8, active: usize) ?usize {
    const c = ui.c;
    var picked: ?usize = null;
    var x = r.x;
    c.line(r.x, r.bottom(), r.right(), r.bottom(), theme.border, 1);
    for (labels, 0..) |label, i| {
        const w = c.measure(.body, label) + 24;
        const tab: Rect = .{ .x = x, .y = r.y, .w = w, .h = r.h };
        if (ui.pressed(tab)) picked = i;
        const selected = i == active;
        const color = if (selected) theme.amber else if (ui.hovered(tab)) theme.text else theme.muted;
        c.text(.body, label, tab, .center, color);
        if (selected) c.fill(.{ .x = tab.x, .y = tab.bottom() - 2, .w = tab.w, .h = 2 }, theme.amber);
        x += w + 8;
    }
    return picked;
}

/// A filter chip with an optional colored dot. Returns true when clicked.
pub fn chip(ui: *Ui, r: Rect, label: []const u8, dot: ?u32, active: bool) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    if (ui.hovered(r)) c.fillRound(r, 8, theme.raised);
    c.strokeRound(r, 8, if (active) theme.amber else theme.border);
    var x = r.x;
    var w = r.w;
    if (dot) |color| {
        c.circle(r.x + 14, r.y + r.h / 2, 5, color);
        x += 16;
        w -= 16;
    }
    c.text(.small, label, .{ .x = x, .y = r.y, .w = w, .h = r.h }, .center, theme.text);
    return clicked;
}

pub fn statCard(c: *Canvas, r: Rect, stat: sample.Stat) void {
    panel(c, r);
    const badge: Rect = .{ .x = r.x + 16, .y = r.y + 16, .w = 42, .h = 42 };
    c.fillRound(badge, 10, stat.tint);
    c.text(.icon_large, stat.icon, badge, .center, stat.color);
    drawSpark(c, .{ .x = r.right() - 78, .y = r.y + 16, .w = 62, .h = 42 }, stat);
    c.text(.body, stat.label, .{ .x = r.x + 18, .y = r.y + 66, .w = r.w - 30, .h = 20 }, .left, theme.text);

    const value: Rect = .{ .x = r.x + 18, .y = r.y + 88, .w = r.w - 30, .h = 42 };
    const fits = c.measure(.stat, stat.value) <= value.w;
    c.text(if (fits) .stat else .subtitle, stat.value, value, .left, theme.text);
    if (stat.unit.len > 0) {
        const after = c.measure(.stat, stat.value) + 7;
        c.text(.heading, stat.unit, .{ .x = value.x + after, .y = value.y + 6, .w = 50, .h = value.h - 6 }, .left, theme.text);
    }

    const delta_color = if (stat.trend == .down_bad) theme.red else theme.green;
    c.text(.strong, stat.delta, .{ .x = r.x + 18, .y = r.y + 136, .w = 44, .h = 20 }, .left, delta_color);
    c.text(.small, stat.note, .{ .x = r.x + 64, .y = r.y + 136, .w = r.w - 72, .h = 20 }, .left, theme.muted);
}

fn drawSpark(c: *Canvas, r: Rect, stat: sample.Stat) void {
    const bar = r.w / stat.bars.len;
    for (stat.bars, 0..) |value, i| {
        const h = r.h * value / 9;
        c.fill(.{ .x = r.x + @as(f32, @floatFromInt(i)) * bar, .y = r.bottom() - h, .w = bar * 0.55, .h = h }, stat.color);
    }
}

/// Numbered code lines with JSON strings colored. Lines that do not fit are dropped.
pub fn code(c: *Canvas, r: Rect, lines: []const []const u8, highlight: bool) void {
    const line_h = 19;
    const advance = c.measure(.mono, "0");
    var y = r.y;
    for (lines, 1..) |line, number| {
        if (y + line_h > r.bottom()) break;
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch "";
        c.text(.mono, label, .{ .x = r.x, .y = y, .w = 26, .h = line_h }, .right, theme.muted);
        const row: Rect = .{ .x = r.x + 40, .y = y, .w = r.w - 40, .h = line_h };
        if (highlight) {
            codeLine(c, row, line, advance);
        } else {
            c.text(.mono, line, row, .left, theme.text);
        }
        y += line_h;
    }
}

fn codeLine(c: *Canvas, r: Rect, line: []const u8, advance: f32) void {
    var i: usize = 0;
    while (i < line.len) {
        const quote = std.mem.indexOfScalarPos(u8, line, i, '"') orelse line.len;
        segment(c, r, line[i..quote], i, advance, theme.text);
        if (quote == line.len) return;
        const close = std.mem.indexOfScalarPos(u8, line, quote + 1, '"') orelse line.len - 1;
        const is_key = close + 1 < line.len and line[close + 1] == ':';
        segment(c, r, line[quote .. close + 1], quote, advance, if (is_key) theme.key else theme.string);
        i = close + 1;
    }
}

fn segment(c: *Canvas, r: Rect, str: []const u8, column: usize, advance: f32, color: u32) void {
    if (str.len == 0) return;
    const x = r.x + @as(f32, @floatFromInt(column)) * advance;
    if (x >= r.right()) return;
    c.text(.mono, str, .{ .x = x, .y = r.y, .w = r.right() - x, .h = r.h }, .left, color);
}

pub const Series = struct {
    values: []const f32,
    color: u32,
    /// Shades the area under the line.
    area: bool = false,
};

/// A line chart over a 0-10 minute run. `y_labels` go from 0 up to `max`.
pub fn lineChart(c: *Canvas, r: Rect, title: []const u8, note: []const u8, y_labels: []const []const u8, max: f32, series: []const Series) void {
    panel(c, r);
    c.text(.strong, title, .{ .x = r.x + 14, .y = r.y + 10, .w = r.w - 110, .h = 22 }, .left, theme.text);
    c.text(.tiny, note, .{ .x = r.right() - 124, .y = r.y + 10, .w = 110, .h = 22 }, .right, theme.muted);

    const chart: Rect = .{ .x = r.x + 56, .y = r.y + 42, .w = r.w - 72, .h = r.h - 70 };
    const steps: f32 = @floatFromInt(y_labels.len - 1);
    for (y_labels, 0..) |label, i| {
        const y = chart.bottom() - chart.h * @as(f32, @floatFromInt(i)) / steps;
        c.line(chart.x, y, chart.right(), y, theme.grid, 1);
        c.text(.tiny, label, .{ .x = r.x + 6, .y = y - 8, .w = 44, .h = 16 }, .right, theme.muted);
    }
    for (0..6) |i| {
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d}:00", .{i * 2}) catch "";
        const x = chart.x + chart.w * @as(f32, @floatFromInt(i)) / 5;
        c.text(.tiny, label, .{ .x = x - 20, .y = chart.bottom() + 6, .w = 40, .h = 16 }, .center, theme.muted);
    }

    for (series) |s| {
        var points: [64]PointF = undefined;
        const count = @min(s.values.len, points.len - 2);
        for (s.values[0..count], 0..) |value, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
            points[i] = .{ .x = chart.x + chart.w * t, .y = chart.bottom() - chart.h * value / max };
        }
        if (s.area) {
            points[count] = .{ .x = chart.right(), .y = chart.bottom() };
            points[count + 1] = .{ .x = chart.x, .y = chart.bottom() };
            c.fillPolygon(points[0 .. count + 2], (s.color & 0xFFFFFF) | 0x30000000);
        }
        c.polyline(points[0..count], s.color, 2);
    }
}
