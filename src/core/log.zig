//! Diagnostics for the CLI. Write command results to stdout, not here.

const std = @import("std");
const Io = std.Io;

pub const Level = enum { quiet, normal, verbose };

pub const Logger = struct {
    out: *Io.Writer,
    level: Level = .normal,
    color: bool = false,

    /// Always shown, even with `--quiet`.
    pub fn err(l: *Logger, comptime fmt: []const u8, args: anytype) void {
        l.write("error: ", "\x1b[31m", fmt, args);
    }

    pub fn info(l: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (l.level != .quiet) l.write("", "", fmt, args);
    }

    /// Only shown with `--verbose`.
    pub fn debug(l: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (l.level == .verbose) l.write("debug: ", "\x1b[2m", fmt, args);
    }

    /// A failed diagnostic has nowhere to be reported, so it is dropped.
    fn write(l: *Logger, prefix: []const u8, code: []const u8, comptime fmt: []const u8, args: anytype) void {
        const paint = l.color and code.len > 0;
        if (paint) l.out.writeAll(code) catch {};
        l.out.writeAll(prefix) catch {};
        if (paint) l.out.writeAll("\x1b[0m") catch {};
        l.out.print(fmt ++ "\n", args) catch {};
        l.out.flush() catch {};
    }
};

const testing = std.testing;

test "level decides what is shown" {
    var buffer: [128]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    var quiet: Logger = .{ .out = &out, .level = .quiet };
    quiet.info("hidden", .{});
    quiet.debug("hidden", .{});
    quiet.err("kept {d}", .{1});
    try testing.expectEqualStrings("error: kept 1\n", out.buffered());

    out.end = 0;
    var normal: Logger = .{ .out = &out };
    normal.info("shown", .{});
    normal.debug("hidden", .{});
    try testing.expectEqualStrings("shown\n", out.buffered());

    out.end = 0;
    var verbose: Logger = .{ .out = &out, .level = .verbose };
    verbose.debug("shown", .{});
    try testing.expectEqualStrings("debug: shown\n", out.buffered());
}

test "color wraps only the prefix" {
    var buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var log: Logger = .{ .out = &out, .color = true };
    log.err("bad", .{});
    try testing.expectEqualStrings("\x1b[31merror: \x1b[0mbad\n", out.buffered());
}
