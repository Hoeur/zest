//! These tests fail on purpose to show what zest reports.

const std = @import("std");
const zest = @import("zest");
const T = zest.T;

const Failures = struct {
    pub fn wrongValue(t: *T) !void {
        try t.equal("hello", "world");
    }

    pub fn forgotToFree(t: *T) !void {
        _ = try t.allocator.alloc(u8, 16);
    }
};

pub fn main(init: std.process.Init) !void {
    try zest.run(init, .{Failures});
}
