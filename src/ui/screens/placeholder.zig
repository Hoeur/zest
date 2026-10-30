//! Stands in for screens that are routed but not built yet.

const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const widgets = @import("../widgets.zig");
const theme = @import("../theme.zig");

pub fn draw(ui: *Ui, area: Rect) f32 {
    const screen = ui.state.screen;
    const top = widgets.pageHeader(ui, area, screen.label(), screen.subtitle());
    const box: Rect = .{ .x = area.x + theme.page_margin, .y = top, .w = area.w - theme.page_margin * 2, .h = 160 };
    widgets.panel(ui.c, box);
    ui.c.text(.heading, "Not built yet", .{ .x = box.x, .y = box.y + 50, .w = box.w, .h = 28 }, .center, theme.text);
    ui.c.text(.body, "This screen is routed. Its content comes in a later milestone.", .{ .x = box.x, .y = box.y + 82, .w = box.w, .h = 22 }, .center, theme.muted);
    return box.bottom() - area.y + ui.state.scroll + theme.page_margin;
}
