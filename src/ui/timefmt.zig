//! Dates and durations as the pages show them. Pure functions, so they are
//! tested on any platform; the local-time lookup is in `native.zig`.

const std = @import("std");

pub const Parts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `Mar 16, 2026, 10:22:41 AM`, or without seconds when `seconds` is false.
pub fn dateTime(buffer: []u8, p: Parts, seconds: bool) []const u8 {
    const hour12: u8 = if (p.hour % 12 == 0) 12 else p.hour % 12;
    const suffix = if (p.hour < 12) "AM" else "PM";
    const month = months[@min(11, @max(1, p.month) - 1)];
    if (seconds) return std.fmt.bufPrint(buffer, "{s} {d}, {d}, {d}:{d:0>2}:{d:0>2} {s}", .{ month, p.day, p.year, hour12, p.minute, p.second, suffix }) catch "";
    return std.fmt.bufPrint(buffer, "{s} {d}, {d}, {d}:{d:0>2} {s}", .{ month, p.day, p.year, hour12, p.minute, suffix }) catch "";
}

/// `Mar 16`.
pub fn shortDate(buffer: []u8, p: Parts) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ months[@min(11, @max(1, p.month) - 1)], p.day }) catch "";
}

/// Parts of a time already shifted to local time, in Unix seconds.
pub fn partsOf(local_unix: i64) Parts {
    const epoch = std.time.epoch;
    const secs: u64 = @intCast(@max(0, local_unix));
    const es: epoch.EpochSeconds = .{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = es.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = time.getHoursIntoDay(),
        .minute = time.getMinutesIntoHour(),
        .second = time.getSecondsIntoMinute(),
    };
}

/// `just now`, `2m ago`, `3h ago`, `5d ago`.
pub fn ago(buffer: []u8, seconds: i64) []const u8 {
    if (seconds < 45) return "just now";
    if (seconds < 3600) return std.fmt.bufPrint(buffer, "{d}m ago", .{@divTrunc(seconds + 30, 60)}) catch "";
    if (seconds < 86_400) return std.fmt.bufPrint(buffer, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "";
    return std.fmt.bufPrint(buffer, "{d}d ago", .{@divTrunc(seconds, 86_400)}) catch "";
}

/// `850 ms`, `1.2 s`, `4m 32s`, `1h 05m`.
pub fn duration(buffer: []u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buffer, "{d} ms", .{ms}) catch "";
    if (ms < 60_000) return std.fmt.bufPrint(buffer, "{d:.1} s", .{@as(f64, @floatFromInt(ms)) / 1000}) catch "";
    const s = ms / 1000;
    if (s < 3600) return std.fmt.bufPrint(buffer, "{d}m {d}s", .{ s / 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buffer, "{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 }) catch "";
}

/// `1.2 KB`, with bytes below 1 KB.
pub fn size(buffer: []u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} KB", .{value / 1024}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1} MB", .{value / (1024 * 1024)}) catch "";
}

/// `1,245,320`.
pub fn grouped(buffer: []u8, value: u64) []const u8 {
    var digits: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "";
    var n: usize = 0;
    for (raw, 0..) |d, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            if (n >= buffer.len) return buffer[0..n];
            buffer[n] = ',';
            n += 1;
        }
        if (n >= buffer.len) return buffer[0..n];
        buffer[n] = d;
        n += 1;
    }
    return buffer[0..n];
}

const testing = std.testing;

test "dates read like the mockups" {
    var buffer: [64]u8 = undefined;
    const p: Parts = .{ .year = 2024, .month = 3, .day = 16, .hour = 10, .minute = 22, .second = 41 };
    try testing.expectEqualStrings("Mar 16, 2024, 10:22:41 AM", dateTime(&buffer, p, true));
    try testing.expectEqualStrings("Mar 16, 2024, 12:05 AM", dateTime(&buffer, .{ .year = 2024, .month = 3, .day = 16, .hour = 0, .minute = 5, .second = 0 }, false));
    try testing.expectEqualStrings("Dec 1, 2026, 1:00 PM", dateTime(&buffer, .{ .year = 2026, .month = 12, .day = 1, .hour = 13, .minute = 0, .second = 0 }, false));
    try testing.expectEqualStrings("Mar 16", shortDate(&buffer, p));
    const parts = partsOf(1793674327);
    try testing.expectEqual(2026, parts.year);
    try testing.expectEqual(11, parts.month);
    try testing.expectEqual(3, parts.day);
}

test "durations, sizes, ages and counts" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("245 ms", duration(&buffer, 245));
    try testing.expectEqualStrings("1.2 s", duration(&buffer, 1200));
    try testing.expectEqualStrings("4m 32s", duration(&buffer, 272_000));
    try testing.expectEqualStrings("1.2 KB", size(&buffer, 1229));
    try testing.expectEqualStrings("just now", ago(&buffer, 10));
    try testing.expectEqualStrings("2m ago", ago(&buffer, 125));
    try testing.expectEqualStrings("3d ago", ago(&buffer, 3 * 86_400 + 5));
    try testing.expectEqualStrings("1,245,320", grouped(&buffer, 1245320));
    try testing.expectEqualStrings("999", grouped(&buffer, 999));
}
