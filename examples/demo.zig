//! A tour of zest. Every test here passes or skips.

const std = @import("std");
const zest = @import("zest");
const T = zest.T;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn parsePort(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 10);
}

const MathTests = struct {
    pub fn addsNumbers(t: *T) !void {
        try t.equal(5, add(2, 3));
    }

    pub fn comparesFloats(t: *T) !void {
        try t.near(0.3, 0.1 + 0.2, 0.0001);
    }
};

const ParserTests = struct {
    pub fn parsesValidPort(t: *T) !void {
        try t.equal(8080, try parsePort("8080"));
    }

    pub fn rejectsTooLargePort(t: *T) !void {
        try t.fails(error.Overflow, parsePort("70000"));
    }
};

const ListTests = struct {
    var list: std.ArrayList(i32) = .empty;

    pub fn beforeEach(t: *T) !void {
        list = .empty;
        try list.append(t.allocator, 1);
    }

    pub fn afterEach(t: *T) !void {
        list.deinit(t.allocator);
    }

    pub fn startsWithOneItem(t: *T) !void {
        try t.equal(@as(usize, 1), list.items.len);
    }

    pub fn grows(t: *T) !void {
        try list.append(t.allocator, 2);
        try t.equal(@as([]const i32, &.{ 1, 2 }), list.items);
    }

    pub fn notReadyYet(t: *T) !void {
        return t.skip("waiting on the sort feature");
    }
};

pub fn main(init: std.process.Init) !void {
    try zest.run(init, .{ MathTests, ParserTests, ListTests });
}
