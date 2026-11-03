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
const Session = @import("api_request.zig").Session;
const Workspace = @import("workspace.zig").Workspace;
pub const Model = @import("model.zig").Model;
const fields = @import("fields.zig");
const widgets = @import("widgets.zig");

/// Work a click asks for that needs the window, such as a file dialog or a
/// menu. The frame only records it, with `Ui.arg` and the point clicked, and
/// the window runs it after painting.
pub const Action = enum(usize) {
    none,
    send,
    open,
    save,
    save_as,
    new,
    edit_tests,
    previous_test,
    next_test,
    // API Tests menus and buttons.
    more_menu,
    run_menu,
    send_menu,
    snippets_menu,
    save_as_menu,
    insert_variable,
    variable_filter,
    copy_variable,
    reveal_variable,
    response_format,
    response_copy,
    response_expand,
    assert_templates,
    assert_add,
    assert_operator,
    assert_delete,
    assert_edit,
    // Load Tests.
    load_start,
    load_stop,
    load_configs,
    // Test Suites.
    suite_select,
    suite_new,
    suite_run,
    suite_run_menu,
    suite_stop,
    suite_export,
    suite_open_test,
    suite_more,
    copy_text,
    // Dashboard.
    run_all,
    run_all_menu,
    new_test,
    new_test_menu,
    trend_range,
    runs_suite_filter,
    run_row_menu,
    // Top bar.
    environment_menu,
    notifications_menu,
    // Elsewhere.
    focus_field,
    reload,
    open_suite_file,
};

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
    api: *Session,
    workspace: *Workspace,
    m: *Model,
    input: Input,
    action: Action = .none,
    /// The action's subject, such as an assertion's line.
    arg: usize = 0,
    /// Where a menu opens, in logical pixels.
    point_x: f32 = 0,
    point_y: f32 = 0,
    placements: [16]fields.Placement = undefined,
    placement_count: usize = 0,
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

    /// Puts a native field over `r` for this frame.
    pub fn place(ui: *Ui, id: fields.Id, r: Rect) void {
        if (ui.placement_count == ui.placements.len) return;
        ui.placements[ui.placement_count] = .{ .id = id, .rect = r };
        ui.placement_count += 1;
    }

    /// Records a click's action, with a menu under `r` when one opens.
    pub fn act(ui: *Ui, action: Action, arg: usize, r: Rect) void {
        ui.action = action;
        ui.arg = arg;
        ui.point_x = r.x;
        ui.point_y = r.bottom() + 2;
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
    action: Action = .none,
    arg: usize = 0,
    point_x: f32 = 0,
    point_y: f32 = 0,
    placements: [16]fields.Placement = undefined,
    placement_count: usize = 0,
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

pub fn frame(c: *Canvas, s: *state.State, m: *Model, input: Input, width: f32, height: f32) Result {
    var ui: Ui = .{ .c = c, .state = s, .api = &m.api, .workspace = &m.workspace, .m = m, .input = input };
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
    // API Tests shows notes in its header; other pages float them.
    if (s.screen != .api_tests and m.toast_until > m.now and m.toast.len > 0) drawToast(c, m.toast, main);
    return .{
        .hand = ui.hand,
        .changed = ui.changed,
        .action = ui.action,
        .arg = ui.arg,
        .point_x = ui.point_x,
        .point_y = ui.point_y,
        .placements = ui.placements,
        .placement_count = ui.placement_count,
    };
}

fn drawToast(c: *Canvas, text: []const u8, area: Rect) void {
    const w = @min(area.w - 40, c.measure(.body, text) + 56);
    const box: Rect = .{ .x = area.x + (area.w - w) / 2, .y = area.bottom() - 70, .w = w, .h = 44 };
    c.fillRound(box, 10, theme.raised);
    c.strokeRound(box, 10, theme.border);
    c.text(.icon, theme.icon.info, .{ .x = box.x + 16, .y = box.y, .w = 20, .h = box.h }, .left, theme.amber);
    c.text(.body, text, .{ .x = box.x + 42, .y = box.y, .w = box.w - 56, .h = box.h }, .left, theme.text);
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

    const environment: Rect = .{ .x = bar.right() - 245, .y = 14, .w = 195, .h = 38 };
    const search: Rect = .{ .x = bar.x + theme.page_margin, .y = 14, .w = @min(680, environment.x - bar.x - theme.page_margin * 2), .h = 38 };
    widgets.searchField(ui, search, .global_search, "", "Search tests, suites, or endpoints...");
    if (ui.m.focused_field != .global_search) {
        const key: Rect = .{ .x = search.right() - 50, .y = search.y + 9, .w = 40, .h = 20 };
        c.strokeRound(key, 5, theme.border);
        c.text(.tiny, "Ctrl K", key, .center, theme.muted);
    }

    // Every page uses the environments from ztest.json.
    if (ui.pressed(environment)) ui.act(.environment_menu, 0, environment);
    if (ui.hovered(environment)) c.fillRound(environment, 8, theme.raised);
    c.strokeRound(environment, 8, theme.border);
    const dot = if (ui.workspace.config_problem != null) theme.red else if (ui.workspace.selected != null) theme.green else theme.blue;
    c.circle(environment.x + 20, environment.y + 19, 5, dot);
    c.text(.body, ui.workspace.environmentName(), .{ .x = environment.x + 36, .y = environment.y, .w = environment.w - 70, .h = environment.h }, .left, theme.text);
    c.text(.icon, theme.icon.chevron_down, .{ .x = environment.right() - 30, .y = environment.y, .w = 18, .h = environment.h }, .left, theme.muted);

    const bell: Rect = .{ .x = bar.right() - 44, .y = 14, .w = 34, .h = 38 };
    if (ui.hovered(bell)) c.fillRound(bell, 8, theme.raised);
    c.strokeRound(bell, 8, theme.border);
    c.text(.icon, theme.icon.bell, bell, .center, theme.text);
    if (ui.pressed(bell)) ui.act(.notifications_menu, 0, .{ .x = bell.right() - 320, .y = bell.y, .w = 320, .h = bell.h });
}
