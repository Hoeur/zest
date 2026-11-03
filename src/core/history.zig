//! Run history: one JSON object per line in `.ztest/history.jsonl`, beside
//! `ztest.json`. The desktop app appends suite runs, their tests, load tests
//! and single requests, and the dashboard reads them back. Values are already
//! masked by the code that produced them, so no secret reaches the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_name = ".ztest";
pub const file_name = "history.jsonl";
pub const path = dir_name ++ "/" ++ file_name;
/// Older entries are dropped when the file is rewritten.
pub const max_entries = 2000;
const max_file_size: Io.Limit = .limited(16 * 1024 * 1024);

pub const Kind = enum { suite, @"test", load, request };
pub const Outcome = enum { passed, failed, skipped, not_run };

pub const Entry = struct {
    kind: Kind,
    /// When it started, in Unix seconds.
    unix: i64,
    outcome: Outcome,
    /// A suite, test or load test's name, or a request's URL.
    name: []const u8,
    /// A test's suite, or a suite's file.
    suite: []const u8 = "",
    environment: []const u8 = "",
    method: []const u8 = "",
    duration_ms: u64 = 0,
    /// Tests in a suite run.
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    /// Load tests.
    users: u32 = 0,
    requests: u64 = 0,
    rps: f64 = 0,
    mean_ms: f64 = 0,
    p95_ms: f64 = 0,
    p99_ms: f64 = 0,
    failure_rate: f64 = 0,
};

pub const History = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) History {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(h: *History) void {
        h.arena.deinit();
    }

    /// Replaces the entries with the file in `dir`. A missing file is an empty
    /// history, and a line that cannot be read is skipped.
    pub fn load(h: *History, io: Io, dir: Io.Dir) !void {
        _ = h.arena.reset(.retain_capacity);
        h.entries = .empty;
        const arena = h.arena.allocator();
        const text = dir.readFileAlloc(io, path, arena, max_file_size) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            const entry = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
            try h.entries.append(arena, entry);
        }
    }

    /// Adds `items` to memory and to the end of the file in `dir`. When the
    /// history is full, the file is rewritten without the oldest entries.
    pub fn append(h: *History, io: Io, dir: Io.Dir, items: []const Entry) !void {
        const arena = h.arena.allocator();
        for (items) |item| try h.entries.append(arena, try copy(arena, item));

        var out: Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        const rewrite = h.entries.items.len > max_entries;
        if (rewrite) {
            const keep = h.entries.items[h.entries.items.len - max_entries ..];
            std.mem.copyForwards(Entry, h.entries.items[0..keep.len], keep);
            h.entries.shrinkRetainingCapacity(max_entries);
        }
        for (if (rewrite) h.entries.items else items) |item| {
            try std.json.Stringify.value(item, .{}, &out.writer);
            try out.writer.writeByte('\n');
        }

        try dir.createDirPath(io, dir_name);
        if (rewrite) return dir.writeFile(io, .{ .sub_path = path, .data = out.written() });
        var file = try dir.createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        const end = try file.length(io);
        try file.writePositionalAll(io, out.written(), end);
    }

    /// Newest first, of the given kinds.
    pub fn recent(h: *const History, kinds: []const Kind, out: []Entry) []Entry {
        var n: usize = 0;
        var i = h.entries.items.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            const entry = h.entries.items[i];
            if (std.mem.findScalar(Kind, kinds, entry.kind) == null) continue;
            out[n] = entry;
            n += 1;
        }
        return out[0..n];
    }

    /// The newest entry of `kind` whose `name` matches, if any.
    pub fn last(h: *const History, kind: Kind, name: []const u8) ?Entry {
        var i = h.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = h.entries.items[i];
            if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

fn copy(arena: Allocator, item: Entry) Allocator.Error!Entry {
    var owned = item;
    inline for (.{ "name", "suite", "environment", "method" }) |field| {
        @field(owned, field) = try arena.dupe(u8, @field(item, field));
    }
    return owned;
}

pub const Day = struct {
    /// Days since the Unix epoch, in local time.
    day: i64,
    passed: u32 = 0,
    failed: u32 = 0,
};

/// Test results per day for the `out.len` days ending today, oldest first.
/// `offset_s` is the local time zone's offset from UTC.
pub fn days(entries: []const Entry, now_unix: i64, offset_s: i64, out: []Day) void {
    const today = @divFloor(now_unix + offset_s, std.time.s_per_day);
    for (out, 0..) |*d, i| d.* = .{ .day = today - @as(i64, @intCast(out.len - 1 - i)) };
    for (entries) |entry| {
        if (entry.kind != .@"test") continue;
        const day = @divFloor(entry.unix + offset_s, std.time.s_per_day);
        const index = day - out[0].day;
        if (index < 0 or index >= out.len) continue;
        const d = &out[@intCast(index)];
        switch (entry.outcome) {
            .passed => d.passed += 1,
            .failed => d.failed += 1,
            else => {},
        }
    }
}

/// The latest outcome of each test, by suite and name, counted.
pub const Latest = struct { passed: usize = 0, failed: usize = 0, skipped: usize = 0 };

pub fn latestOutcomes(entries: []const Entry) Latest {
    var counts: Latest = .{};
    for (entries, 0..) |entry, i| {
        if (entry.kind != .@"test") continue;
        // Counted only when no later entry is the same test.
        const newer = for (entries[i + 1 ..]) |other| {
            if (other.kind == .@"test" and std.mem.eql(u8, other.name, entry.name) and std.mem.eql(u8, other.suite, entry.suite)) break true;
        } else false;
        if (newer) continue;
        switch (entry.outcome) {
            .passed => counts.passed += 1,
            .failed => counts.failed += 1,
            .skipped => counts.skipped += 1,
            .not_run => {},
        }
    }
    return counts;
}

const testing = std.testing;

test "entries survive a write and a read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var h: History = .init(testing.allocator);
    defer h.deinit();
    try h.load(testing.io, tmp.dir);
    try testing.expectEqual(0, h.entries.items.len);

    try h.append(testing.io, tmp.dir, &.{
        .{ .kind = .suite, .unix = 100, .outcome = .failed, .name = "Users", .suite = "tests/users.ztest", .passed = 2, .failed = 1, .duration_ms = 40 },
        .{ .kind = .@"test", .unix = 100, .outcome = .passed, .name = "List", .suite = "Users", .method = "GET", .duration_ms = 12 },
    });
    try h.append(testing.io, tmp.dir, &.{.{ .kind = .load, .unix = 200, .outcome = .passed, .name = "http://a/", .users = 5, .rps = 120.5, .p95_ms = 3.25 }});

    var again: History = .init(testing.allocator);
    defer again.deinit();
    try again.load(testing.io, tmp.dir);
    try testing.expectEqual(3, again.entries.items.len);
    try testing.expectEqualStrings("tests/users.ztest", again.entries.items[0].suite);
    try testing.expectEqual(120.5, again.entries.items[2].rps);

    var buffer: [4]Entry = undefined;
    const newest = again.recent(&.{ .suite, .load }, &buffer);
    try testing.expectEqual(2, newest.len);
    try testing.expectEqual(Kind.load, newest[0].kind);
    try testing.expectEqual(40, again.last(.suite, "Users").?.duration_ms);
}

test "a bad line is skipped and the file is capped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, dir_name);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "not json\n{\"kind\":\"load\",\"unix\":1,\"outcome\":\"passed\",\"name\":\"x\",\"future\":1}\n" });
    var h: History = .init(testing.allocator);
    defer h.deinit();
    try h.load(testing.io, tmp.dir);
    try testing.expectEqual(1, h.entries.items.len);

    var many: [max_entries]Entry = undefined;
    for (&many, 0..) |*e, i| e.* = .{ .kind = .request, .unix = @intCast(i), .outcome = .passed, .name = "u" };
    try h.append(testing.io, tmp.dir, &many);
    try testing.expectEqual(max_entries, h.entries.items.len);
    try testing.expectEqual(0, h.entries.items[0].unix);

    var again: History = .init(testing.allocator);
    defer again.deinit();
    try again.load(testing.io, tmp.dir);
    try testing.expectEqual(max_entries, again.entries.items.len);
}

test "days and latest outcomes count tests" {
    const day = std.time.s_per_day;
    const entries = [_]Entry{
        .{ .kind = .@"test", .unix = 10 * day + 5, .outcome = .failed, .name = "A", .suite = "S" },
        .{ .kind = .@"test", .unix = 12 * day + 5, .outcome = .passed, .name = "A", .suite = "S" },
        .{ .kind = .@"test", .unix = 12 * day + 9, .outcome = .failed, .name = "B", .suite = "S" },
        .{ .kind = .suite, .unix = 12 * day, .outcome = .failed, .name = "S" },
    };
    var out: [3]Day = undefined;
    days(&entries, 12 * day + 100, 0, &out);
    try testing.expectEqual(10, out[0].day);
    try testing.expectEqual(1, out[0].failed);
    try testing.expectEqual(1, out[2].passed);
    try testing.expectEqual(1, out[2].failed);
    const latest = latestOutcomes(&entries);
    try testing.expectEqual(1, latest.passed);
    try testing.expectEqual(1, latest.failed);
}
