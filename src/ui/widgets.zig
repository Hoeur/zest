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

/// A button that works. Returns true on the frame it is clicked.
pub fn button(ui: *Ui, r: Rect, label: []const u8, primary: bool) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    const hot = ui.hovered(r);
    if (primary) {
        c.fillRound(r, 8, if (hot) theme.key else theme.amber);
        c.text(.strong, label, r, .center, theme.on_amber);
    } else {
        if (hot) c.fillRound(r, 8, theme.raised);
        c.strokeRound(r, 8, if (hot) theme.amber else theme.border);
        c.text(.body, label, r, .center, theme.text);
    }
    return clicked;
}

/// An amber button with an icon before its label, such as New Suite.
pub fn primaryIconButton(ui: *Ui, r: Rect, icon: []const u8, label: []const u8) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    c.fillRound(r, 8, if (ui.hovered(r)) theme.key else theme.amber);
    const w = c.measure(.strong, label) + 24;
    const x = r.x + (r.w - w) / 2;
    c.text(.icon, icon, .{ .x = x, .y = r.y, .w = 18, .h = r.h }, .left, theme.on_amber);
    c.text(.strong, label, .{ .x = x + 24, .y = r.y, .w = r.right() - x - 24, .h = r.h }, .left, theme.on_amber);
    return clicked;
}

/// An outlined button with an icon before its label.
pub fn iconTextButton(ui: *Ui, r: Rect, icon: []const u8, label: []const u8) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    const hot = ui.hovered(r);
    if (hot) c.fillRound(r, 8, theme.raised);
    c.strokeRound(r, 8, if (hot) theme.amber else theme.border);
    const w = c.measure(.small, label) + 26;
    const x = r.x + (r.w - w) / 2;
    c.text(.icon, icon, .{ .x = x, .y = r.y, .w = 20, .h = r.h }, .left, theme.text);
    c.text(.small, label, .{ .x = x + 26, .y = r.y, .w = r.right() - x - 26, .h = r.h }, .left, theme.text);
    return clicked;
}

/// A square outlined button with an icon.
pub fn iconButton(ui: *Ui, r: Rect, icon: []const u8) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    const hot = ui.hovered(r);
    if (hot) c.fillRound(r, 8, theme.raised);
    c.strokeRound(r, 8, if (hot) theme.amber else theme.border);
    c.text(.icon, icon, r, .center, theme.text);
    return clicked;
}

/// An outlined button with an optional leading icon and a trailing chevron,
/// for actions that open a menu.
pub fn menuButton(ui: *Ui, r: Rect, icon: ?[]const u8, label: []const u8) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    const hot = ui.hovered(r);
    if (hot) c.fillRound(r, 8, theme.raised);
    c.strokeRound(r, 8, if (hot) theme.amber else theme.border);
    var x = r.x + 12;
    if (icon) |glyph| {
        c.text(.icon, glyph, .{ .x = x, .y = r.y, .w = 20, .h = r.h }, .left, theme.text);
        x += 26;
    }
    c.text(.small, label, .{ .x = x, .y = r.y, .w = r.right() - x - 26, .h = r.h }, .left, theme.text);
    c.text(.icon, theme.icon.chevron_down, .{ .x = r.right() - 24, .y = r.y, .w = 16, .h = r.h }, .left, theme.muted);
    return clicked;
}

pub const Split = struct { main: bool = false, menu: bool = false };

/// The amber primary action with a separate chevron for more choices.
pub fn splitButton(ui: *Ui, r: Rect, icon: ?[]const u8, label: []const u8, enabled: bool) Split {
    return split(ui, r, icon, label, enabled, true);
}

/// A secondary action with a chevron, outlined, such as Run All.
pub fn outlineSplitButton(ui: *Ui, r: Rect, icon: ?[]const u8, label: []const u8, enabled: bool) Split {
    return split(ui, r, icon, label, enabled, false);
}

fn split(ui: *Ui, r: Rect, icon: ?[]const u8, label: []const u8, enabled: bool, primary: bool) Split {
    const c = ui.c;
    const arrow_w: f32 = 38;
    const main: Rect = .{ .x = r.x, .y = r.y, .w = r.w - arrow_w, .h = r.h };
    const arrow: Rect = .{ .x = r.right() - arrow_w, .y = r.y, .w = arrow_w, .h = r.h };
    var result: Split = .{};
    if (enabled) {
        result.main = ui.pressed(main);
        result.menu = ui.pressed(arrow);
    }
    const base = if (!primary) theme.panel else if (enabled) theme.amber else theme.amber_dim;
    const hot = if (primary) theme.key else theme.raised;
    c.fillRound(r, 8, base);
    if (enabled and ui.hovered(main)) c.fillRound(main, 8, hot);
    if (enabled and ui.hovered(arrow)) c.fillRound(arrow, 8, hot);
    if (!primary) c.strokeRound(r, 8, theme.border);
    c.line(arrow.x, r.y + 8, arrow.x, r.bottom() - 8, if (primary) 0x60000000 else theme.border, 1);
    const ink = if (!enabled) theme.muted else if (primary) theme.on_amber else theme.text;
    var w: f32 = c.measure(.strong, label);
    if (icon != null) w += 26;
    var x = main.x + (main.w - w) / 2;
    if (icon) |glyph| {
        c.text(.icon, glyph, .{ .x = x, .y = r.y, .w = 20, .h = r.h }, .left, ink);
        x += 26;
    }
    c.text(.strong, label, .{ .x = x, .y = r.y, .w = main.right() - x, .h = r.h }, .left, ink);
    c.text(.icon, theme.icon.chevron_down, arrow, .center, ink);
    return result;
}

/// A dropdown-looking box that opens a menu when clicked.
pub fn dropdown(ui: *Ui, r: Rect, label: []const u8, accent: bool) bool {
    const c = ui.c;
    const clicked = ui.pressed(r);
    c.fillRound(r, 8, theme.background);
    c.strokeRound(r, 8, if (ui.hovered(r)) theme.amber else theme.border);
    c.text(.small, label, .{ .x = r.x + 12, .y = r.y, .w = r.w - 40, .h = r.h }, .left, if (accent) theme.amber else theme.text);
    c.text(.icon, theme.icon.chevron_down, .{ .x = r.right() - 26, .y = r.y, .w = 16, .h = r.h }, .left, theme.muted);
    return clicked;
}

/// A small grey count beside a tab label.
pub fn badge(c: *Canvas, x: f32, y: f32, count: usize) f32 {
    var buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch "";
    const w = c.measure(.tiny, text) + 14;
    c.fillRound(.{ .x = x, .y = y, .w = w, .h = 20 }, 6, theme.raised);
    c.text(.tiny, text, .{ .x = x, .y = y, .w = w, .h = 20 }, .center, theme.text);
    return w;
}

/// Read-only box with text, as an input or dropdown will look once editable.
pub fn field(c: *Canvas, r: Rect, label: []const u8, with_chevron: bool) void {
    c.fillRound(r, 8, theme.background);
    c.strokeRound(r, 8, theme.border);
    const end: f32 = if (with_chevron) 30 else 12;
    c.text(.body, label, .{ .x = r.x + 12, .y = r.y, .w = r.w - 12 - end, .h = r.h }, .left, theme.text);
    if (with_chevron) c.text(.icon, theme.icon.chevron_down, .{ .x = r.right() - 28, .y = r.y, .w = 18, .h = r.h }, .left, theme.muted);
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
    const icon_box: Rect = .{ .x = r.x + 16, .y = r.y + 16, .w = 42, .h = 42 };
    c.fillRound(icon_box, 10, stat.tint);
    c.text(.icon_large, stat.icon, icon_box, .center, stat.color);
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

pub const Unit = enum { count, ms, percent, mb };

pub const Line = struct {
    values: []const f32,
    color: u32,
    area: bool = false,
};

/// A line chart of live samples taken once a second, with a y axis rounded to
/// a readable maximum and time labels from 0 to `seconds`. Draws `empty`
/// instead when there are fewer than two points.
pub fn liveChart(c: *Canvas, r: Rect, title: []const u8, note: []const u8, unit: Unit, seconds: f32, lines: []const Line, legend: []const []const u8, empty: []const u8) void {
    panel(c, r);
    c.text(.strong, title, .{ .x = r.x + 14, .y = r.y + 10, .w = r.w - 120, .h = 22 }, .left, theme.text);
    if (legend.len > 0) {
        var x = r.right() - 14;
        var i = legend.len;
        while (i > 0) {
            i -= 1;
            const w = c.measure(.tiny, legend[i]) + 20;
            x -= w;
            c.circle(x + 5, r.y + 21, 4, lines[i].color);
            c.text(.tiny, legend[i], .{ .x = x + 12, .y = r.y + 10, .w = w, .h = 22 }, .left, theme.muted);
            x -= 6;
        }
    } else {
        c.text(.tiny, note, .{ .x = r.right() - 160, .y = r.y + 10, .w = 146, .h = 22 }, .right, theme.muted);
    }

    const chart: Rect = .{ .x = r.x + 58, .y = r.y + 42, .w = r.w - 74, .h = r.h - 70 };
    var peak: f32 = 0;
    var points: usize = 0;
    for (lines) |line| {
        points = @max(points, line.values.len);
        for (line.values) |v| peak = @max(peak, v);
    }
    // Four even steps; an empty chart gets a typical range instead of zeros.
    const top = if (points < 2) switch (unit) {
        .count, .percent => @as(f32, 100),
        .ms => 1000,
        .mb => 1024,
    } else 4 * niceMax(@max(peak, @as(f32, if (unit == .percent) 4 else 1)) / 4);
    var label: [24]u8 = undefined;
    for (0..5) |i| {
        const share: f32 = @as(f32, @floatFromInt(i)) / 4;
        const y = chart.bottom() - chart.h * share;
        c.line(chart.x, y, chart.right(), y, theme.grid, 1);
        c.text(.tiny, axisLabel(&label, top * share, unit), .{ .x = r.x + 4, .y = y - 8, .w = 50, .h = 16 }, .right, theme.muted);
    }
    for (0..6) |i| {
        const share: f32 = @as(f32, @floatFromInt(i)) / 5;
        const t: u64 = @intFromFloat(seconds * share);
        const text = std.fmt.bufPrint(&label, "{d}:{d:0>2}", .{ t / 60, t % 60 }) catch "";
        const x = chart.x + chart.w * share;
        c.text(.tiny, text, .{ .x = x - 22, .y = chart.bottom() + 6, .w = 44, .h = 16 }, .center, theme.muted);
    }
    if (points < 2) {
        c.text(.small, empty, chart, .center, theme.muted);
        return;
    }
    for (lines) |line| {
        if (line.values.len < 2) continue;
        var buffer: [302]PointF = undefined;
        const n = @min(line.values.len, 300);
        for (0..n) |i| {
            // Down-sampled evenly when there are more points than pixels.
            const source = i * (line.values.len - 1) / @max(1, n - 1);
            const v = @min(line.values[source], top);
            buffer[i] = .{
                .x = chart.x + chart.w * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1)),
                .y = chart.bottom() - (if (top > 0) chart.h * v / top else 0),
            };
        }
        if (line.area) {
            buffer[n] = .{ .x = buffer[n - 1].x, .y = chart.bottom() };
            buffer[n + 1] = .{ .x = buffer[0].x, .y = chart.bottom() };
            c.fillPolygon(buffer[0 .. n + 2], (line.color & 0x00FFFFFF) | 0x30000000);
        }
        c.polyline(buffer[0..n], line.color, 2);
    }
}

/// 1, 2, 2.5 or 5 times a power of ten, at or above `value`.
pub fn niceMax(value: f32) f32 {
    if (value <= 0) return 1;
    const power = std.math.pow(f32, 10, @floor(std.math.log10(value)));
    for ([_]f32{ 1, 2, 2.5, 5, 10 }) |step| {
        if (value <= step * power) return step * power;
    }
    return 10 * power;
}

fn axisLabel(buffer: []u8, value: f32, unit: Unit) []const u8 {
    return switch (unit) {
        .count => if (value >= 1000) std.fmt.bufPrint(buffer, "{d:.1}k", .{value / 1000}) catch "" else std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch "",
        .ms => if (value >= 1000) std.fmt.bufPrint(buffer, "{d:.1} s", .{value / 1000}) catch "" else std.fmt.bufPrint(buffer, "{d:.0} ms", .{value}) catch "",
        .percent => std.fmt.bufPrint(buffer, "{d:.0}%", .{value}) catch "",
        .mb => if (value >= 1024) std.fmt.bufPrint(buffer, "{d:.1} GB", .{value / 1024}) catch "" else std.fmt.bufPrint(buffer, "{d:.0} MB", .{value}) catch "",
    };
}

/// A stat card with live text, laid out like `statCard`.
pub const LiveStat = struct {
    label: []const u8,
    value: []const u8,
    unit: []const u8 = "",
    /// Empty when there is nothing to compare with.
    delta: []const u8 = "",
    note: []const u8 = "",
    good: bool = true,
    icon: []const u8,
    color: u32,
    tint: u32,
    bars: []const f32 = &.{},
};

pub fn liveStatCard(c: *Canvas, r: Rect, stat: LiveStat) void {
    panel(c, r);
    const icon_box: Rect = .{ .x = r.x + 16, .y = r.y + 16, .w = 42, .h = 42 };
    c.fillRound(icon_box, 10, stat.tint);
    c.text(.icon_large, stat.icon, icon_box, .center, stat.color);
    c.text(.body, stat.label, .{ .x = icon_box.right() + 12, .y = icon_box.y, .w = r.right() - icon_box.right() - 18, .h = icon_box.h }, .left, theme.text);

    const value: Rect = .{ .x = r.x + 18, .y = r.y + 70, .w = r.w - 30, .h = 42 };
    const fits = c.measure(.stat, stat.value) + c.measure(.heading, stat.unit) + 8 <= value.w * 0.62;
    const font: @import("canvas.zig").Font = if (fits) .stat else .subtitle;
    c.text(font, stat.value, value, .left, theme.text);
    if (stat.unit.len > 0) {
        const after = c.measure(font, stat.value) + 7;
        c.text(.heading, stat.unit, .{ .x = value.x + after, .y = value.y + 6, .w = 60, .h = value.h - 6 }, .left, theme.text);
    }
    if (stat.bars.len > 0) {
        const spark: Rect = .{ .x = r.right() - 84, .y = r.y + 72, .w = 68, .h = 40 };
        var peak: f32 = 0;
        for (stat.bars) |b| peak = @max(peak, b);
        // Thin bars, right-aligned, however few there are.
        const slot = @min(6, spark.w / @as(f32, @floatFromInt(stat.bars.len)));
        const left = spark.right() - slot * @as(f32, @floatFromInt(stat.bars.len));
        for (stat.bars, 0..) |b, i| {
            const h = if (peak > 0) @max(2, spark.h * b / peak) else 2;
            c.fill(.{ .x = left + @as(f32, @floatFromInt(i)) * slot, .y = spark.bottom() - h, .w = slot * 0.6, .h = h }, stat.color);
        }
    }
    if (stat.delta.len > 0) {
        // An arrow for the direction, coloured by whether that is good.
        const ink = if (stat.good) theme.green else theme.red;
        const up = stat.delta[0] != '-';
        const flat = std.mem.eql(u8, std.mem.trimStart(u8, stat.delta, "+-"), "0%");
        const ax = r.x + 24;
        const ay = r.y + 128;
        if (flat) {
            c.fill(.{ .x = ax - 6, .y = ay - 1, .w = 12, .h = 2 }, theme.muted);
        } else if (up) {
            c.triangle(ax - 5, ay + 4, ax + 5, ay + 4, ax, ay - 5, ink);
        } else {
            c.triangle(ax - 5, ay - 4, ax + 5, ay - 4, ax, ay + 5, ink);
        }
        const dx = r.x + 36;
        c.text(.strong, if (flat) "0%" else stat.delta, .{ .x = dx, .y = r.y + 118, .w = 70, .h = 20 }, .left, if (flat) theme.text else ink);
        c.text(.small, stat.note, .{ .x = dx + c.measure(.strong, stat.delta) + 8, .y = r.y + 118, .w = r.right() - dx - c.measure(.strong, stat.delta) - 16, .h = 20 }, .left, theme.muted);
    } else {
        c.text(.small, stat.note, .{ .x = r.x + 18, .y = r.y + 118, .w = r.w - 30, .h = 20 }, .left, theme.muted);
    }
}

/// A search box. Its native field is placed only while it has focus or text,
/// so the placeholder shows otherwise; a click asks the window to focus it.
pub fn searchField(ui: *Ui, r: Rect, id: @import("fields.zig").Id, text: []const u8, placeholder: []const u8) void {
    const c = ui.c;
    const focused = ui.m.focused_field == id;
    c.fillRound(r, 8, theme.background);
    c.strokeRound(r, 8, if (focused) theme.amber else if (ui.hovered(r)) theme.muted else theme.border);
    c.text(.icon, theme.icon.search, .{ .x = r.x + 12, .y = r.y, .w = 18, .h = r.h }, .left, theme.muted);
    const inner: Rect = .{ .x = r.x + 38, .y = r.y + (r.h - 20) / 2, .w = r.w - 48, .h = 20 };
    if (focused or text.len > 0) {
        ui.place(id, inner);
        return;
    }
    c.text(.small, placeholder, .{ .x = inner.x, .y = r.y, .w = inner.w, .h = r.h }, .left, theme.muted);
    if (ui.pressed(r)) ui.act(.focus_field, @backingInt(id), r);
}
