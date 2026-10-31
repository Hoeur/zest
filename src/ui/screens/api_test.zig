//! Live API request builder. Native child controls occupy the rectangles below.

const std = @import("std");
const Ui = @import("../app.zig").Ui;
const Rect = @import("../layout.zig").Rect;
const widgets = @import("../widgets.zig");
const theme = @import("../theme.zig");

pub const Controls = struct { method: Rect, url: Rect, send: Rect, headers: Rect, body_kind: Rect, body: Rect, response: Rect };

/// Shared geometry keeps native controls aligned with the painted panels at
/// every window size and DPI. The response control owns its own scrolling.
pub fn controls(area: Rect) Controls {
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    const half = (w - 48) / 2;
    return .{
        .method = .{ .x = x + 18, .y = area.y + 128, .w = 104, .h = 32 },
        .url = .{ .x = x + 134, .y = area.y + 128, .w = w - 270, .h = 32 },
        .send = .{ .x = x + w - 124, .y = area.y + 128, .w = 106, .h = 32 },
        .headers = .{ .x = x + 18, .y = area.y + 222, .w = half, .h = 108 },
        .body_kind = .{ .x = x + w - 138, .y = area.y + 190, .w = 120, .h = 26 },
        .body = .{ .x = x + 30 + half, .y = area.y + 222, .w = half, .h = 108 },
        .response = .{ .x = x + 18, .y = area.y + 436, .w = w - 36, .h = @max(64, area.h - 436 - theme.page_margin - 18) },
    };
}

pub fn draw(ui: *Ui, area: Rect) f32 {
    const c = ui.c;
    const x = area.x + theme.page_margin;
    const w = area.w - theme.page_margin * 2;
    const y = area.y;
    _ = widgets.pageHeader(ui, area, "API Tests", "Send an HTTP request and inspect the real response.");
    widgets.panel(c, .{ .x = x, .y = y + 92, .w = w, .h = 256 });
    c.text(.small, "Method", .{ .x = x + 18, .y = y + 100, .w = 100, .h = 22 }, .left, theme.muted);
    c.text(.small, "Request URL", .{ .x = x + 134, .y = y + 100, .w = w - 270, .h = 22 }, .left, theme.muted);
    c.text(.small, "30-second timeout  |  4 MiB response limit  |  Ctrl+Enter to send", .{ .x = x + 18, .y = y + 166, .w = w - 36, .h = 22 }, .left, theme.muted);
    const boxes = controls(area);
    c.text(.small, "Headers (one Name: value per line)", .{ .x = boxes.headers.x, .y = y + 194, .w = boxes.headers.w, .h = 22 }, .left, theme.muted);
    c.text(.small, "Body", .{ .x = boxes.body.x, .y = y + 194, .w = boxes.body.w - 130, .h = 22 }, .left, theme.muted);
    widgets.panel(c, .{ .x = x, .y = y + 364, .w = w, .h = area.h - 364 - theme.page_margin });
    c.text(.heading, "Response", .{ .x = x + 18, .y = y + 374, .w = 150, .h = 30 }, .left, theme.text);
    var buffer: [160]u8 = undefined;
    const summary = if (ui.api.phase == .completed) blk: {
        const response = ui.api.response.?;
        break :blk std.fmt.bufPrint(&buffer, "Status {d}   |   {d} ms   |   {d} bytes", .{ response.status, response.duration_ns / std.time.ns_per_ms, response.size() }) catch "Response received";
    } else ui.api.message();
    const color = switch (ui.api.phase) {
        .failed => theme.red,
        .completed => if (ui.api.response.?.status >= 400) theme.amber else theme.green,
        else => theme.muted,
    };
    c.text(.body, summary, .{ .x = x + 160, .y = y + 374, .w = w - 178, .h = 30 }, .right, color);
    if (widgets.tabs(ui, .{ .x = x + 12, .y = y + 402, .w = w - 24, .h = 30 }, &.{ "Body", "Headers" }, ui.state.response_tab)) |tab| ui.state.response_tab = tab;
    return area.h;
}
