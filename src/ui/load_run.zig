//! Load Tests page data: one load test at a time on the core engine, sampled
//! once a second for the live charts, and the results of earlier runs. No
//! Win32 code, so it is tested with the CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const load = @import("../core/load/load.zig");
const draft = @import("../core/http/draft.zig");
const history = @import("../core/history.zig");

/// One point of the live charts.
pub const Sample = struct {
    /// Seconds since the start.
    t: f32,
    rps: f32,
    p50_ms: f32,
    p95_ms: f32,
    p99_ms: f32,
    error_pct: f32,
    users: f32,
};

/// A finished run, as the Endpoint Results table shows it.
pub const Row = struct {
    endpoint: []const u8,
    method: []const u8,
    users: u32,
    duration_s: f32,
    requests: u64,
    rps: f64,
    mean_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
    error_rate: f64,
    started_unix: i64,
    interrupted: bool,
};

pub const Settings = struct {
    users: u32 = 10,
    duration_ms: u64 = 60_000,
    ramp_up_ms: u64 = 0,
    rps: u32 = 0,
};

pub const Phase = enum { idle, running, stopping, done, failed };

pub const LoadRun = struct {
    gpa: Allocator,
    io: Io,
    /// The request being sent, for the current run.
    request_arena: std.heap.ArenaAllocator,
    /// Rows of every run, kept for the session.
    rows_arena: std.heap.ArenaAllocator,
    engine: load.Engine = undefined,
    has_engine: bool = false,
    phase: Phase = .idle,
    problem: []const u8 = "",
    problem_buffer: [256]u8 = undefined,
    settings: Settings = .{},
    /// What the user typed, with `{{variables}}`, for the table.
    endpoint: []const u8 = "",
    method: []const u8 = "GET",
    samples: std.ArrayList(Sample) = .empty,
    rows: std.ArrayList(Row) = .empty,
    result: ?load.Result = null,
    started_unix: i64 = 0,
    last_sample_ns: i96 = 0,
    last_requests: u64 = 0,
    last_failed: u64 = 0,
    last_live: [load.live_buckets]u64 = @splat(0),

    pub fn init(gpa: Allocator, io: Io) LoadRun {
        return .{ .gpa = gpa, .io = io, .request_arena = .init(gpa), .rows_arena = .init(gpa) };
    }

    /// Stops and joins a running test before freeing it.
    pub fn deinit(r: *LoadRun) void {
        if (r.phase == .running or r.phase == .stopping) {
            r.engine.stop();
            _ = r.engine.finish();
        }
        if (r.has_engine) r.engine.deinit();
        r.samples.deinit(r.gpa);
        r.rows.deinit(r.gpa);
        r.request_arena.deinit();
        r.rows_arena.deinit();
    }

    pub fn busy(r: *const LoadRun) bool {
        return r.phase == .running or r.phase == .stopping;
    }

    /// Prepares `source` like a desktop request, with its variables, and
    /// starts the users. On failure `problem` says why and nothing is sent.
    pub fn start(r: *LoadRun, source: draft.Draft, settings: Settings) !void {
        if (r.busy()) return error.Busy;
        if (r.has_engine) {
            r.engine.deinit();
            r.has_engine = false;
        }
        _ = r.request_arena.reset(.retain_capacity);
        const arena = r.request_arena.allocator();
        r.problem = "";
        r.result = null;
        r.samples.clearRetainingCapacity();
        errdefer r.phase = .failed;

        var diagnostic: draft.Diagnostic = .{};
        const prepared = draft.prepareAll(arena, source, &diagnostic) catch |err| {
            const text = draft.message(arena, err, diagnostic) catch draft.describe(err);
            r.setProblem("{s}", .{text});
            return err;
        };
        var request = prepared.request;
        request.timeout_ms = 30_000;
        request.max_response_size = 4 * 1024 * 1024;
        r.endpoint = try arena.dupe(u8, std.mem.trim(u8, source.url, " \t\r\n"));
        r.method = @tagName(source.method);
        r.settings = settings;
        r.engine = .{
            .gpa = r.gpa,
            .io = r.io,
            .config = .{
                .source = .{ .request = .{ .request = request, .assertions = prepared.assertions } },
                .users = settings.users,
                .duration_ms = settings.duration_ms,
                .ramp_up_ms = settings.ramp_up_ms,
                .rps = settings.rps,
            },
        };
        load.check(r.engine.config) catch |err| {
            r.setProblem("{s}", .{switch (err) {
                error.NoUsers => "Virtual users must be at least 1",
                error.TooManyUsers => std.fmt.comptimePrint("Virtual users can be at most {d}", .{load.max_users}),
                error.NoDuration => "Duration must be above zero",
                error.DurationTooLong => "Duration can be at most 24 hours",
                error.RampUpTooLong => "Ramp-up must be shorter than the duration",
                error.NoRunnableScenarioTests => load.describeConfigError(err),
            }});
            return err;
        };
        r.engine.start() catch |err| {
            r.setProblem("Could not start the virtual users: {s}", .{@errorName(err)});
            return err;
        };
        r.has_engine = true;
        r.phase = .running;
        r.started_unix = Io.Timestamp.now(r.io, .real).toSeconds();
        r.last_sample_ns = r.engine.start_ns;
        r.last_requests = 0;
        r.last_failed = 0;
        r.last_live = @splat(0);
    }

    pub fn stop(r: *LoadRun) void {
        if (r.phase != .running) return;
        r.engine.stop();
        r.phase = .stopping;
    }

    /// Call often from the UI thread. Takes a sample each second and finishes
    /// the run once every user is done. True when something changed.
    pub fn tick(r: *LoadRun) !bool {
        if (!r.busy()) return false;
        const now = Io.Timestamp.now(r.io, .awake).toNanoseconds();
        var changed = false;
        if (now - r.last_sample_ns >= std.time.ns_per_s) {
            try r.sample(now);
            changed = true;
        }
        if (r.engine.done()) {
            if (now - r.last_sample_ns >= std.time.ns_per_s / 4) try r.sample(now);
            r.result = r.engine.finish();
            try r.addRow(r.result.?);
            r.phase = .done;
            changed = true;
        }
        return changed;
    }

    fn sample(r: *LoadRun, now: i96) !void {
        const progress = r.engine.progress();
        const seconds: f32 = @floatFromInt(@max(1, now - r.last_sample_ns));
        const dt = seconds / std.time.ns_per_s;
        const requests = progress.requests - r.last_requests;
        const failed = progress.failed - r.last_failed;
        var live: [load.live_buckets]u64 = undefined;
        r.engine.liveSnapshot(&live);
        var delta: [load.live_buckets]u64 = undefined;
        for (&delta, live, r.last_live) |*d, a, b| d.* = a -| b;
        try r.samples.append(r.gpa, .{
            .t = @as(f32, @floatFromInt(progress.elapsed_ns)) / std.time.ns_per_s,
            .rps = @as(f32, @floatFromInt(requests)) / dt,
            .p50_ms = ms(load.livePercentile(&delta, 50)),
            .p95_ms = ms(load.livePercentile(&delta, 95)),
            .p99_ms = ms(load.livePercentile(&delta, 99)),
            .error_pct = if (requests == 0) 0 else @as(f32, @floatFromInt(failed)) * 100 / @as(f32, @floatFromInt(requests)),
            .users = @floatFromInt(progress.active_users),
        });
        r.last_sample_ns = now;
        r.last_requests = progress.requests;
        r.last_failed = progress.failed;
        r.last_live = live;
    }

    fn addRow(r: *LoadRun, result: load.Result) !void {
        const arena = r.rows_arena.allocator();
        const h = &result.stats.latency;
        try r.rows.append(r.gpa, .{
            .endpoint = try arena.dupe(u8, r.endpoint),
            .method = r.method,
            .users = result.users,
            .duration_s = @as(f32, @floatFromInt(result.duration_ns)) / std.time.ns_per_s,
            .requests = result.stats.requests,
            .rps = result.rps(),
            .mean_ms = ms(h.mean()),
            .p95_ms = ms(h.percentile(95)),
            .p99_ms = ms(h.percentile(99)),
            .error_rate = result.failureRate(),
            .started_unix = r.started_unix,
            .interrupted = result.interrupted or r.phase == .stopping,
        });
    }

    pub fn peakUsers(r: *const LoadRun) u32 {
        if (!r.has_engine) return 0;
        return r.engine.peak_users.load(.monotonic);
    }

    /// Requests and failures so far, live or final.
    pub fn totals(r: *const LoadRun) struct { requests: u64, failed: u64 } {
        if (r.result) |result| return .{ .requests = result.stats.requests, .failed = result.stats.failed };
        if (!r.has_engine) return .{ .requests = 0, .failed = 0 };
        const p = r.engine.progress();
        return .{ .requests = p.requests, .failed = p.failed };
    }

    pub fn elapsedS(r: *const LoadRun) f32 {
        if (r.result) |result| return @as(f32, @floatFromInt(result.duration_ns)) / std.time.ns_per_s;
        if (!r.has_engine) return 0;
        return @as(f32, @floatFromInt(r.engine.progress().elapsed_ns)) / std.time.ns_per_s;
    }

    /// For the history file, once `phase` is `done`.
    pub fn historyEntry(r: *const LoadRun) ?history.Entry {
        const row = if (r.rows.items.len > 0) r.rows.items[r.rows.items.len - 1] else return null;
        return .{
            .kind = .load,
            .unix = row.started_unix,
            .outcome = if (row.error_rate > 0) .failed else if (row.interrupted) .not_run else .passed,
            .name = row.endpoint,
            .method = row.method,
            .duration_ms = @intFromFloat(row.duration_s * 1000),
            .users = row.users,
            .requests = row.requests,
            .rps = row.rps,
            .mean_ms = row.mean_ms,
            .p95_ms = row.p95_ms,
            .p99_ms = row.p99_ms,
            .failure_rate = row.error_rate,
        };
    }

    fn setProblem(r: *LoadRun, comptime fmt: []const u8, args: anytype) void {
        r.problem = std.fmt.bufPrint(&r.problem_buffer, fmt, args) catch "The load test could not start";
    }
};

fn ms(us: u64) f32 {
    return @as(f32, @floatFromInt(us)) / std.time.us_per_ms;
}

const testing = std.testing;
const Server = @import("../core/http/client_test.zig").Server;

test "a desktop load test samples, finishes and records a row" {
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    var replies: [40][]const u8 = @splat(ok);
    var server = try Server.listen(&replies);
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};

    var buffer: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}", .{server.port()});
    var run: LoadRun = .init(testing.allocator, testing.io);
    defer run.deinit();
    try run.start(.{
        .url = "{{base}}/health",
        .assertions = "status == 200",
        .variables = &.{.{ .name = "base", .value = base, .line = 0 }},
    }, .{ .users = 1, .duration_ms = 1200, .rps = 10 });

    const begin = Io.Timestamp.now(testing.io, .awake);
    while (run.phase != .done) {
        if (begin.untilNow(testing.io, .awake).toMilliseconds() > 10_000) return error.TestTimedOut;
        _ = try run.tick();
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expect(run.samples.items.len >= 1);
    try testing.expectEqual(1, run.rows.items.len);
    const row = run.rows.items[0];
    try testing.expectEqualStrings("{{base}}/health", row.endpoint);
    // Scheduling delays can reduce throughput. The configured rate is a ceiling.
    try testing.expect(row.requests > 0 and row.requests <= 12);
    try testing.expectEqual(0, row.error_rate);
    try testing.expectEqual(1, run.peakUsers());
    try testing.expectEqual(history.Kind.load, run.historyEntry().?.kind);
}

test "a load test with a mistake does not start" {
    var run: LoadRun = .init(testing.allocator, testing.io);
    defer run.deinit();
    try testing.expectError(error.MissingVariable, run.start(.{ .url = "{{nope}}/x" }, .{}));
    try testing.expectEqual(Phase.failed, run.phase);
    try testing.expect(std.mem.startsWith(u8, run.problem, "{{nope}} is not defined"));
    try testing.expectError(error.NoUsers, run.start(.{ .url = "http://a/" }, .{ .users = 0 }));
    try testing.expectEqualStrings("Virtual users must be at least 1", run.problem);
}
