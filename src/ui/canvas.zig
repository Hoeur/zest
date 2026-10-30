//! Drawing primitives over GDI+, in logical pixels. All GDI+ use stays in this
//! file and `main.zig`, so a different renderer only has to replace those two.

const std = @import("std");
const win = @import("win32.zig");
const Rect = @import("layout.zig").Rect;

const logo_png = @embedFile("assets/logo.png");

pub const Font = enum {
    tiny,
    small,
    body,
    strong,
    heading,
    subtitle,
    stat,
    title,
    icon,
    icon_large,
    mono,

    fn spec(f: Font) struct { family: usize, size: f32, bold: bool } {
        return switch (f) {
            .tiny => .{ .family = 0, .size = 11, .bold = false },
            .small => .{ .family = 0, .size = 12, .bold = false },
            .body => .{ .family = 0, .size = 13.5, .bold = false },
            .strong => .{ .family = 0, .size = 13.5, .bold = true },
            .heading => .{ .family = 0, .size = 17, .bold = true },
            .subtitle => .{ .family = 0, .size = 24, .bold = true },
            .stat => .{ .family = 0, .size = 30, .bold = true },
            .title => .{ .family = 0, .size = 32, .bold = true },
            .icon => .{ .family = 1, .size = 15, .bold = false },
            .icon_large => .{ .family = 1, .size = 19, .bold = false },
            .mono => .{ .family = 2, .size = 13, .bold = false },
        };
    }
};

pub const Align = enum(i32) { left = 0, center = 1, right = 2 };

pub const Canvas = struct {
    g: win.Handle = null,
    brush: win.Handle = null,
    pen: win.Handle = null,
    path: win.Handle = null,
    format: win.Handle = null,
    families: [3]win.Handle = @splat(null),
    fonts: [@typeInfo(Font).@"enum".field_names.len]win.Handle = @splat(null),
    logo: win.Handle = null,

    pub fn init() !Canvas {
        var c: Canvas = .{};
        errdefer c.deinit();
        // GDI+ reads from the stream for as long as the bitmap exists, so it is
        // kept until exit along with the bitmap.
        const stream = win.SHCreateMemStream(logo_png.ptr, logo_png.len);
        if (stream == null) return error.GdiPlusFailed;
        try check(win.GdipCreateBitmapFromStream(stream, &c.logo));
        try check(win.GdipCreateSolidFill(0, &c.brush));
        try check(win.GdipCreatePen1(0, 1, win.UnitPixel, &c.pen));
        try check(win.GdipCreatePath(0, &c.path));

        var typographic: win.Handle = null;
        try check(win.GdipStringFormatGetGenericTypographic(&typographic));
        try check(win.GdipCloneStringFormat(typographic, &c.format));
        _ = win.GdipSetStringFormatFlags(c.format, win.StringFormatFlagsNoWrap | win.StringFormatFlagsMeasureTrailingSpaces);
        _ = win.GdipSetStringFormatTrimming(c.format, win.StringTrimmingEllipsisCharacter);
        _ = win.GdipSetStringFormatLineAlign(c.format, 1);

        const names = [_][*:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas"),
        };
        for (names, &c.families) |name, *family| {
            try check(win.GdipCreateFontFamilyFromName(name, null, family));
        }
        for (&c.fonts, 0..) |*font, i| {
            const spec = @as(Font, @enumFromInt(i)).spec();
            try check(win.GdipCreateFont(c.families[spec.family], spec.size, @intFromBool(spec.bold), win.UnitPixel, font));
        }
        return c;
    }

    pub fn deinit(c: *Canvas) void {
        for (c.fonts) |font| if (font != null) {
            _ = win.GdipDeleteFont(font);
        };
        for (c.families) |family| if (family != null) {
            _ = win.GdipDeleteFontFamily(family);
        };
        if (c.format != null) _ = win.GdipDeleteStringFormat(c.format);
        if (c.path != null) _ = win.GdipDeletePath(c.path);
        if (c.pen != null) _ = win.GdipDeletePen(c.pen);
        if (c.brush != null) _ = win.GdipDeleteBrush(c.brush);
        if (c.logo != null) _ = win.GdipDisposeImage(c.logo);
    }

    /// Targets `hdc` until `end`. `scale` maps logical to device pixels.
    pub fn begin(c: *Canvas, hdc: win.Handle, scale: f32, clear_color: u32) !void {
        try check(win.GdipCreateFromHDC(hdc, &c.g));
        _ = win.GdipSetSmoothingMode(c.g, win.SmoothingModeAntiAlias);
        _ = win.GdipSetTextRenderingHint(c.g, win.TextRenderingHintClearTypeGridFit);
        _ = win.GdipSetInterpolationMode(c.g, win.InterpolationModeHighQualityBicubic);
        _ = win.GdipScaleWorldTransform(c.g, scale, scale, 0);
        _ = win.GdipGraphicsClear(c.g, clear_color);
    }

    pub fn end(c: *Canvas) void {
        _ = win.GdipDeleteGraphics(c.g);
        c.g = null;
    }

    pub fn clip(c: *Canvas, r: Rect) void {
        _ = win.GdipSetClipRect(c.g, r.x, r.y, r.w, r.h, win.CombineModeReplace);
    }

    pub fn unclip(c: *Canvas) void {
        _ = win.GdipResetClip(c.g);
    }

    pub fn fill(c: *Canvas, r: Rect, color: u32) void {
        _ = win.GdipSetSolidFillColor(c.brush, color);
        _ = win.GdipFillRectangle(c.g, c.brush, r.x, r.y, r.w, r.h);
    }

    pub fn circle(c: *Canvas, cx: f32, cy: f32, radius: f32, color: u32) void {
        _ = win.GdipSetSolidFillColor(c.brush, color);
        _ = win.GdipFillEllipse(c.g, c.brush, cx - radius, cy - radius, radius * 2, radius * 2);
    }

    fn roundedPath(c: *Canvas, r: Rect, radius: f32) void {
        const d = radius * 2;
        _ = win.GdipResetPath(c.path);
        _ = win.GdipAddPathArc(c.path, r.x, r.y, d, d, 180, 90);
        _ = win.GdipAddPathArc(c.path, r.right() - d, r.y, d, d, 270, 90);
        _ = win.GdipAddPathArc(c.path, r.right() - d, r.bottom() - d, d, d, 0, 90);
        _ = win.GdipAddPathArc(c.path, r.x, r.bottom() - d, d, d, 90, 90);
        _ = win.GdipClosePathFigure(c.path);
    }

    pub fn fillRound(c: *Canvas, r: Rect, radius: f32, color: u32) void {
        c.roundedPath(r, radius);
        _ = win.GdipSetSolidFillColor(c.brush, color);
        _ = win.GdipFillPath(c.g, c.brush, c.path);
    }

    pub fn strokeRound(c: *Canvas, r: Rect, radius: f32, color: u32) void {
        c.roundedPath(r, radius);
        c.setPen(color, 1);
        _ = win.GdipDrawPath(c.g, c.pen, c.path);
    }

    pub fn line(c: *Canvas, x1: f32, y1: f32, x2: f32, y2: f32, color: u32, width: f32) void {
        c.setPen(color, width);
        _ = win.GdipDrawLine(c.g, c.pen, x1, y1, x2, y2);
    }

    pub fn polyline(c: *Canvas, points: []const win.PointF, color: u32, width: f32) void {
        c.setPen(color, width);
        _ = win.GdipDrawLines(c.g, c.pen, points.ptr, @intCast(points.len));
    }

    pub fn fillPolygon(c: *Canvas, points: []const win.PointF, color: u32) void {
        _ = win.GdipSetSolidFillColor(c.brush, color);
        _ = win.GdipFillPolygon2(c.g, c.brush, points.ptr, @intCast(points.len));
    }

    pub fn drawLogo(c: *Canvas, r: Rect) void {
        _ = win.GdipDrawImageRect(c.g, c.logo, r.x, r.y, r.w, r.h);
    }

    fn setPen(c: *Canvas, color: u32, width: f32) void {
        _ = win.GdipSetPenColor(c.pen, color);
        _ = win.GdipSetPenWidth(c.pen, width);
    }

    /// Draws one line, vertically centered in `r`, cut with "..." if too long.
    pub fn text(c: *Canvas, font: Font, str: []const u8, r: Rect, alignment: Align, color: u32) void {
        var buffer: [256]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buffer, str) catch return;
        _ = win.GdipSetSolidFillColor(c.brush, color);
        _ = win.GdipSetStringFormatAlign(c.format, @intFromEnum(alignment));
        const layout: win.RectF = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        _ = win.GdipDrawString(c.g, &buffer, @intCast(len), c.fonts[@intFromEnum(font)], &layout, c.format, c.brush);
    }

    pub fn measure(c: *Canvas, font: Font, str: []const u8) f32 {
        var buffer: [256]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buffer, str) catch return 0;
        const layout: win.RectF = .{ .x = 0, .y = 0, .w = 4096, .h = 256 };
        var box: win.RectF = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        _ = win.GdipSetStringFormatAlign(c.format, @intFromEnum(Align.left));
        _ = win.GdipMeasureString(c.g, &buffer, @intCast(len), c.fonts[@intFromEnum(font)], &layout, c.format, &box, null, null);
        return box.w;
    }
};

fn check(status: i32) !void {
    if (status != 0) return error.GdiPlusFailed;
}
