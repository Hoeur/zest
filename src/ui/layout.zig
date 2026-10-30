//! Rectangles in logical pixels. Knows nothing about drawing.

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }

    pub fn inset(r: Rect, by: f32) Rect {
        return .{ .x = r.x + by, .y = r.y + by, .w = r.w - by * 2, .h = r.h - by * 2 };
    }

    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }

    /// Cell `index` of `count` equal columns separated by `gap`.
    pub fn column(r: Rect, index: usize, count: usize, gap: f32) Rect {
        const n: f32 = @floatFromInt(count);
        const i: f32 = @floatFromInt(index);
        const w = (r.w - gap * (n - 1)) / n;
        return .{ .x = r.x + i * (w + gap), .y = r.y, .w = w, .h = r.h };
    }
};

const testing = @import("std").testing;

test "contains excludes the far edges" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try testing.expect(r.contains(10, 14));
    try testing.expect(!r.contains(15, 12));
    try testing.expect(!r.contains(12, 15));
}

test "columns fill the width exactly" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 10 };
    try testing.expectEqual(@as(f32, 30), r.column(0, 3, 5).w);
    try testing.expectEqual(@as(f32, 35), r.column(1, 3, 5).x);
    try testing.expectEqual(@as(f32, 100), r.column(2, 3, 5).right());
}
