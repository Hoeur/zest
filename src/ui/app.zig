//! The app shell: sidebar, top bar and screen routing, redrawn from `State`
//! on every frame.

const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Rect = @import("layout.zig").Rect;
const state = @import("state.zig");
const theme = @import("theme.zig");
const dashboard = @import("screens/dashboard.zig");
const api_test = @import("screens/api_test.zig");
const suites = @import("screens/suites.zig");
const load_test = @import("screens/load_test.zig");
const placeholder = @import("screens/placeholder.zig");

pub const Input = struct {
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    clicked: bool = false,
    /// Where the click landed. The mouse may move again before the repaint.
    click_x: f32 = -1,
    click_y: f32 = -1,
};

/// Everything a frame needs, passed down to the screens.
pub const Ui = struct {
    c: *Canvas,
    state: *state.State,
    input: Input,
    /// Set when the pointer is over something clickable.
    hand: bool = false,
    /// Set when a click changed state, so the frame must be redrawn.
    changed: bool = false,
    /// While drawing the page: the only part of it that can be hit, because
    /// scrolled content continues invisibly under the top bar.
    hit_area: ?Rect = null,

    fn reachable(ui: *const Ui, x: f32, y: f32) bool {
        const area = ui.hit_area orelse return true;
        return area.contains(x, y);
    }

    pub fn hovered(ui: *const Ui, r: Rect) bool {
        return r.contains(ui.input.mouse_x, ui.input.mouse_y) and ui.reachable(ui.input.mouse_x, ui.input.mouse_y);
    }

    /// Returns true on the frame `r` is clicked.
    pub fn pressed(ui: *Ui, r: Rect) bool {
        if (ui.hovered(r)) ui.hand = true;
        const hit = ui.input.clicked and r.contains(ui.input.click_x, ui.input.click_y) and
            ui.reachable(ui.input.click_x, ui.input.click_y);
        if (hit) ui.changed = true;
        return hit;
    }
};

pub const Result = struct {
    hand: bool,
    changed: bool,
};

const nav = [_]struct { screen: state.Screen, icon: []const u8 }{
    .{ .screen = .dashboard, .icon = theme.icon.home },
    .{ .screen = .api_tests, .icon = theme.icon.link },
    .{ .screen = .test_suites, .icon = theme.icon.layers },
    .{ .screen = .load_tests, .icon = theme.icon.pulse },
    .{ .screen = .reports, .icon = theme.icon.chart },
    .{ .screen = .environments, .icon = theme.icon.database },
    .{ .screen = .settings, .icon = theme.icon.settings },
};

pub fn frame(c: *Canvas, s: *state.State, input: Input, width: f32, height: f32) Result {
    var ui: Ui = .{ .c = c, .state = s, .input = input };
    const main: Rect = .{
        .x = theme.sidebar_width,
        .y = theme.topbar_height,
        .w = width - theme.sidebar_width,
        .h = height - theme.topbar_height,
    };

    // The page goes first so the bars paint over anything scrolled beneath them.
    c.clip(main);
    ui.hit_area = main;
    const content_height = switch (s.screen) {
        .dashboard => dashboard.draw(&ui, main),
        .api_tests => api_test.draw(&ui, main),
        .test_suites => suites.draw(&ui, main),
        .load_tests => load_test.draw(&ui, main),
        else => placeholder.draw(&ui, main),
    };
    ui.hit_area = null;
    c.unclip();
    s.clampScroll(content_height, main.h);

    drawSidebar(&ui, height);
    drawTopBar(&ui, width);
    return .{ .hand = ui.hand, .changed = ui.changed };
}

fn drawSidebar(ui: *Ui, height: f32) void {
    const c = ui.c;
    c.fill(.{ .x = 0, .y = 0, .w = theme.sidebar_width, .h = height }, theme.sidebar);
    c.line(theme.sidebar_width, 0, theme.sidebar_width, height, theme.border, 1);

    c.drawLogo(.{ .x = 14, .y = 24, .w = 44, .h = 44 });
    c.text(.heading, "ZTest", .{ .x = 60, .y = 26, .w = 175, .h = 24 }, .left, theme.text);
    c.text(.tiny, "Test. Build. Ship with Confidence.", .{ .x = 60, .y = 50, .w = 182, .h = 18 }, .left, theme.muted);

    var y: f32 = 100;
    for (nav) |item| {
        const row: Rect = .{ .x = 16, .y = y, .w = theme.sidebar_width - 32, .h = 46 };
        const active = ui.state.screen == item.screen;
        if (ui.pressed(row) and !active) {
            ui.state.navigate(item.screen);
        }
        if (active) {
            c.fillRound(row, 8, theme.amber_dim);
            c.fill(.{ .x = row.x, .y = row.y + 6, .w = 2, .h = row.h - 12 }, theme.amber);
        } else if (ui.hovered(row)) {
            c.fillRound(row, 8, theme.raised);
        }
        const color = if (active) theme.amber else theme.text;
        c.text(.icon, item.icon, .{ .x = row.x + 14, .y = row.y, .w = 24, .h = row.h }, .left, color);
        c.text(.body, item.screen.label(), .{ .x = row.x + 46, .y = row.y, .w = row.w - 52, .h = row.h }, .left, color);
        y += 52;
    }
}

fn drawTopBar(ui: *Ui, width: f32) void {
    const c = ui.c;
    const bar: Rect = .{ .x = theme.sidebar_width, .y = 0, .w = width - theme.sidebar_width, .h = theme.topbar_height };
    c.fill(bar, theme.background);
    c.line(bar.x, bar.bottom(), bar.right(), bar.bottom(), theme.border, 1);

    const environment: Rect = .{ .x = bar.right() - 215, .y = 14, .w = 165, .h = 38 };
    const search: Rect = .{ .x = bar.x + theme.page_margin, .y = 14, .w = @min(680, environment.x - bar.x - theme.page_margin * 2), .h = 38 };
    c.strokeRound(search, 8, theme.border);
    c.text(.icon, theme.icon.search, .{ .x = search.x + 14, .y = search.y, .w = 20, .h = search.h }, .left, theme.muted);
    c.text(.body, "Search tests, suites, or endpoints...", .{ .x = search.x + 42, .y = search.y, .w = search.w - 56, .h = search.h }, .left, theme.muted);

    if (ui.pressed(environment)) {
        ui.state.environment = ui.state.environment.next();
    }
    if (ui.hovered(environment)) c.fillRound(environment, 8, theme.raised);
    c.strokeRound(environment, 8, theme.border);
    const dot = switch (ui.state.environment) {
        .production => theme.green,
        .staging, .development => theme.amber,
    };
    c.circle(environment.x + 20, environment.y + 19, 5, dot);
    c.text(.body, ui.state.environment.label(), .{ .x = environment.x + 36, .y = environment.y, .w = 100, .h = environment.h }, .left, theme.text);
    c.text(.icon, theme.icon.chevron_down, .{ .x = environment.right() - 30, .y = environment.y, .w = 18, .h = environment.h }, .left, theme.muted);

    c.text(.icon, theme.icon.bell, .{ .x = bar.right() - 42, .y = 14, .w = 28, .h = 38 }, .center, theme.text);
}
