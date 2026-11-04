//! Load generation: virtual users repeat a request or suite for a set time,
//! optionally ramped up and held to a total request rate. Holds no output code,
//! so the CLI and the desktop app can share it.
//!
//! Each user owns its HTTP client, so connections are reused per user, and its
//! own statistics, so the hot path takes no locks. Only a few counters for live
//! progress are shared, as atomics. Results are merged when the run ends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Atomic = std.atomic.Value;
const Assertion = @import("../assertions/assertion.zig").Assertion;
const evaluate = @import("../assertions/evaluate.zig");
const http = @import("../http/client.zig");
const request_model = @import("../http/request.zig");
const Request = request_model.Request;
const Response = @import("../http/response.zig").Response;
const ast = @import("../parser/ast.zig");
const runner = @import("../runner/runner.zig");

/// Each user is a task, and each request runs on a task of its own so it can
/// time out, so a run uses about twice this many threads.
pub const max_users = 1000;
/// Keeps the per-second series small even for long soak tests.
pub const max_duration_ms: u64 = 24 * std.time.ms_per_hour;

pub const SingleRequest = struct {
    request: Request,
    /// A response fails when any of these fail.
    assertions: []const Assertion = &.{},
};

pub const Scenario = struct {
    suite: *const ast.Suite,
    variables: []const ast.Variable = &.{},
};

pub const Source = union(enum) {
    request: SingleRequest,
    scenario: Scenario,
};

pub const Config = struct {
    source: Source,
    users: u32 = 10,
    duration_ms: u64 = 10_000,
    /// Users start evenly spread over this time, from the run's start.
    ramp_up_ms: u64 = 0,
    /// Requests per second across all users. Zero sends as fast as they can.
    rps: u32 = 0,
};

pub const ConfigError = error{ NoUsers, TooManyUsers, NoDuration, DurationTooLong, RampUpTooLong, NoRunnableScenarioTests };

pub fn describeConfigError(err: ConfigError) []const u8 {
    return switch (err) {
        error.NoUsers => "--users must be at least 1",
        error.TooManyUsers => std.fmt.comptimePrint("--users can be at most {d}", .{max_users}),
        error.NoDuration => "--duration must be above zero",
        error.DurationTooLong => "--duration can be at most 24h",
        error.RampUpTooLong => "--ramp-up must be shorter than --duration",
        error.NoRunnableScenarioTests => "the scenario must have at least one runnable test",
    };
}

pub fn check(config: Config) ConfigError!void {
    if (config.users == 0) return error.NoUsers;
    if (config.users > max_users) return error.TooManyUsers;
    if (config.duration_ms == 0) return error.NoDuration;
    if (config.duration_ms > max_duration_ms) return error.DurationTooLong;
    if (config.ramp_up_ms >= config.duration_ms and config.ramp_up_ms > 0) return error.RampUpTooLong;
    if (config.source == .scenario and !runner.hasRunnableTest(config.source.scenario.suite)) {
        return error.NoRunnableScenarioTests;
    }
}

/// Why a request did not count as a success.
pub const Problem = enum {
    timeout,
    connect,
    tls,
    malformed,
    too_large,
    assertion,
    other,

    pub fn label(p: Problem) []const u8 {
        return switch (p) {
            .timeout => "timed out",
            .connect => "could not connect",
            .tls => "TLS failed",
            .malformed => "malformed response",
            .too_large => "response too large",
            .assertion => "assertion failed",
            .other => "other error",
        };
    }

    fn of(err: http.Error) Problem {
        return switch (err) {
            error.Timeout => .timeout,
            error.ConnectFailed => .connect,
            error.TlsFailed => .tls,
            error.MalformedResponse => .malformed,
            error.ResponseTooLarge => .too_large,
            else => .other,
        };
    }
};

/// Latencies in microseconds, kept to about 1.5% precision with fixed memory,
/// in the manner of an HDR histogram: exact below 128µs, then 64 buckets for
/// every power of two.
pub const Histogram = struct {
    pub const bucket_count = 64 * 32;
    counts: [bucket_count]u64 = @splat(0),
    count: u64 = 0,
    sum_us: u64 = 0,
    min_us: u64 = std.math.maxInt(u64),
    max_us: u64 = 0,

    pub fn record(h: *Histogram, us: u64) void {
        h.counts[bucketOf(us)] += 1;
        h.count += 1;
        h.sum_us +|= us;
        h.min_us = @min(h.min_us, us);
        h.max_us = @max(h.max_us, us);
    }

    pub fn merge(h: *Histogram, other: *const Histogram) void {
        for (&h.counts, other.counts) |*a, b| a.* += b;
        h.count += other.count;
        h.sum_us +|= other.sum_us;
        h.min_us = @min(h.min_us, other.min_us);
        h.max_us = @max(h.max_us, other.max_us);
    }

    pub fn mean(h: *const Histogram) u64 {
        return if (h.count == 0) 0 else h.sum_us / h.count;
    }

    pub fn min(h: *const Histogram) u64 {
        return if (h.count == 0) 0 else h.min_us;
    }

    /// The smallest recorded bucket that holds `percent` of the values, as its
    /// highest value, and never above the largest value seen.
    pub fn percentile(h: *const Histogram, percent: f64) u64 {
        if (h.count == 0) return 0;
        const wanted: u64 = @max(1, @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(h.count)) * percent / 100.0))));
        var seen: u64 = 0;
        for (h.counts, 0..) |n, i| {
            seen += n;
            if (seen >= wanted) return @min(h.max_us, upperOf(i));
        }
        return h.max_us;
    }

    fn bucketOf(us: u64) usize {
        if (us < 128) return @intCast(us);
        const msb: u6 = @intCast(63 - @clz(us));
        const shift: u6 = msb - 6;
        const index = (@as(usize, shift) + 1) * 64 + @as(usize, @intCast((us >> shift) - 64));
        return @min(index, bucket_count - 1);
    }

    fn upperOf(index: usize) u64 {
        if (index < 128) return index;
        const shift: u6 = @intCast(index / 64 - 1);
        const base = (@as(u64, index % 64) + 64) << shift;
        return base + (@as(u64, 1) << shift) - 1;
    }
};

pub const Stats = struct {
    requests: u64 = 0,
    succeeded: u64 = 0,
    failed: u64 = 0,
    /// Scenario cases that failed before reaching the HTTP client.
    scenario_errors: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    /// Completed responses only, by status class: index 1 is 1xx up to 5 for 5xx.
    status_classes: [6]u64 = @splat(0),
    problems: std.EnumArray(Problem, u64) = .initFill(0),
    latency: Histogram = .{},

    pub fn merge(s: *Stats, other: *const Stats) void {
        s.requests += other.requests;
        s.succeeded += other.succeeded;
        s.failed += other.failed;
        s.scenario_errors += other.scenario_errors;
        s.bytes_sent += other.bytes_sent;
        s.bytes_received += other.bytes_received;
        for (&s.status_classes, other.status_classes) |*a, b| a.* += b;
        for (std.enums.values(Problem)) |p| s.problems.getPtr(p).* += other.problems.get(p);
        s.latency.merge(&other.latency);
    }
};

/// One second of the run, written by every user as requests finish.
pub const Second = struct {
    requests: Atomic(u32) = .init(0),
    failed: Atomic(u32) = .init(0),
    latency_sum_us: Atomic(u64) = .init(0),
};

/// What a finished run produced. Slices belong to the engine's allocator.
pub const Result = struct {
    users: u32,
    duration_ns: u64,
    stats: Stats,
    seconds: []const Second,
    interrupted: bool,
    worker_failed: bool = false,

    pub fn rps(r: Result) f64 {
        if (r.duration_ns == 0) return 0;
        return @as(f64, @floatFromInt(r.stats.requests)) * std.time.ns_per_s / @as(f64, @floatFromInt(r.duration_ns));
    }

    pub fn failureRate(r: Result) f64 {
        if (r.stats.requests == 0) return 0;
        return @as(f64, @floatFromInt(r.stats.failed)) * 100 / @as(f64, @floatFromInt(r.stats.requests));
    }
};

/// Live counters, safe to read from any thread while the run goes on.
pub const Progress = struct {
    elapsed_ns: u64,
    requests: u64,
    failed: u64,
    active_users: u32,
};

pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    config: Config,
    users: []User = &.{},
    seconds: []Second = &.{},
    futures: []Io.Future(void) = &.{},
    started: usize = 0,
    start_ns: i96 = 0,
    deadline_ns: i96 = 0,
    interval_ns: u64 = 0,
    /// Earliest next request start, in nanoseconds relative to start_ns.
    next_start_ns: Atomic(u64) = .init(0),
    requests: Atomic(u64) = .init(0),
    failed: Atomic(u64) = .init(0),
    active: Atomic(u32) = .init(0),
    finished: Atomic(u32) = .init(0),
    stopping: Atomic(bool) = .init(false),
    interrupted: Atomic(bool) = .init(false),
    worker_failed: Atomic(bool) = .init(false),
    /// A coarse, shared latency histogram, so a live view can take the
    /// difference of two snapshots and chart percentiles as the run goes.
    live: [live_buckets]Atomic(u32) = @splat(.init(0)),
    peak_users: Atomic(u32) = .init(0),

    const User = struct {
        engine: *Engine,
        index: u32,
        stats: Stats = .{},
    };

    /// Checks the configuration, then starts every user. Keep the engine at a
    /// stable address until `finish`. `config` slices must outlive it too.
    pub fn start(e: *Engine) !void {
        try check(e.config);
        const config = e.config;
        const second_count: usize = @intCast(config.duration_ms / std.time.ms_per_s + 2);
        e.seconds = try e.gpa.alloc(Second, second_count);
        errdefer e.gpa.free(e.seconds);
        @memset(e.seconds, .{});
        e.users = try e.gpa.alloc(User, config.users);
        errdefer e.gpa.free(e.users);
        e.futures = try e.gpa.alloc(Io.Future(void), config.users);
        errdefer e.gpa.free(e.futures);
        for (e.users, 0..) |*user, i| user.* = .{ .engine = e, .index = @intCast(i) };

        e.interval_ns = if (config.rps == 0) 0 else std.math.divCeil(u64, std.time.ns_per_s, config.rps) catch unreachable;
        e.start_ns = Io.Timestamp.now(e.io, .awake).toNanoseconds();
        e.deadline_ns = e.start_ns + @as(i96, config.duration_ms) * std.time.ns_per_ms;
        for (e.users, e.futures) |*user, *future| {
            future.* = e.io.concurrent(runUser, .{user}) catch |err| {
                // Users that started hold pointers into the memory freed below.
                e.stop();
                for (e.futures[0..e.started]) |*started| started.await(e.io);
                return err;
            };
            e.started += 1;
        }
    }

    /// Ends the run early and cancels requests in flight.
    pub fn stop(e: *Engine) void {
        e.interrupted.store(true, .release);
        e.stopping.store(true, .release);
    }

    /// True once every user has returned, so `finish` will not block.
    pub fn done(e: *const Engine) bool {
        return e.finished.load(.acquire) >= e.started;
    }

    pub fn progress(e: *const Engine) Progress {
        return .{
            .elapsed_ns = @intCast(@max(0, e.now() - e.start_ns)),
            .requests = e.requests.load(.monotonic),
            .failed = e.failed.load(.monotonic),
            .active_users = e.active.load(.monotonic),
        };
    }

    /// Copies the live histogram. Subtract an earlier copy to get the
    /// latencies of the requests that finished in between.
    pub fn liveSnapshot(e: *const Engine, out: *[live_buckets]u64) void {
        for (out, &e.live) |*n, *bucket| n.* = bucket.load(.monotonic);
    }

    /// Waits for every user and merges their statistics. Call once.
    pub fn finish(e: *Engine) Result {
        for (e.futures[0..e.started]) |*future| future.await(e.io);
        const end = e.now();
        var stats: Stats = .{};
        for (e.users) |*user| stats.merge(&user.stats);
        const elapsed: u64 = @intCast(@max(0, @min(end, e.deadline_ns) - e.start_ns));
        const used = @min(e.seconds.len, elapsed / std.time.ns_per_s + 1);
        return .{
            .users = e.config.users,
            .duration_ns = elapsed,
            .stats = stats,
            .seconds = e.seconds[0..used],
            .interrupted = e.interrupted.load(.acquire),
            .worker_failed = e.worker_failed.load(.acquire),
        };
    }

    pub fn deinit(e: *Engine) void {
        e.gpa.free(e.futures);
        e.gpa.free(e.users);
        e.gpa.free(e.seconds);
        e.* = undefined;
    }

    fn now(e: *const Engine) i96 {
        return Io.Timestamp.now(e.io, .awake).toNanoseconds();
    }

    /// Sleeps until `when`, waking every 100ms to notice `stop`. False when
    /// the run is over first.
    fn waitUntil(e: *Engine, when: i96) bool {
        while (true) {
            if (e.stopping.load(.acquire)) return false;
            const left = when - e.now();
            if (left <= 0) return true;
            const step: i96 = @min(left, 100 * std.time.ns_per_ms);
            e.io.sleep(.fromNanoseconds(step), .awake) catch return false;
        }
    }

    /// All HTTP attempts share one clock. Idle time does not bank future slots.
    fn requestStart(e: *Engine) ?i96 {
        while (!e.stopping.load(.acquire)) {
            const now_ns = e.now();
            if (now_ns >= e.deadline_ns) return null;
            if (e.interval_ns == 0) return now_ns;
            const next = e.next_start_ns.load(.monotonic);
            const earliest = e.start_ns + next;
            if (now_ns < earliest) {
                if (!e.waitUntil(@min(earliest, e.deadline_ns))) return null;
                continue;
            }
            const elapsed: u64 = @intCast(now_ns - e.start_ns);
            if (e.next_start_ns.cmpxchgWeak(next, elapsed + e.interval_ns, .monotonic, .monotonic) == null) return now_ns;
        }
        return null;
    }

    fn recordSecond(e: *Engine, at: i96, latency_us: u64, failed: bool) void {
        const index: usize = @intCast(@max(0, at - e.start_ns) / std.time.ns_per_s);
        if (index >= e.seconds.len) return;
        const second = &e.seconds[index];
        _ = second.requests.fetchAdd(1, .monotonic);
        if (failed) _ = second.failed.fetchAdd(1, .monotonic);
        _ = second.latency_sum_us.fetchAdd(latency_us, .monotonic);
    }

    fn runUser(user: *User) void {
        const e = user.engine;
        defer _ = e.finished.fetchAdd(1, .release);
        const config = e.config;

        const offset: i96 = if (config.users <= 1) 0 else @divTrunc(@as(i96, config.ramp_up_ms) * std.time.ns_per_ms * user.index, config.users);
        if (!e.waitUntil(e.start_ns + offset)) return;

        const active = e.active.fetchAdd(1, .monotonic) + 1;
        _ = e.peak_users.fetchMax(active, .monotonic);
        defer _ = e.active.fetchSub(1, .monotonic);

        var client: http.Client = .init(e.gpa, e.io);
        defer client.deinit();
        switch (config.source) {
            .request => |source| runSingle(user, &client, source),
            .scenario => |source| runScenario(user, &client, source),
        }
    }

    fn runSingle(user: *User, client: *http.Client, source: SingleRequest) void {
        const e = user.engine;
        var arena_state: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena_state.deinit();
        const sent_size = requestSize(source.request);
        while (e.requestStart()) |started_at| {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const response = client.sendCancelable(arena, source.request, &e.stopping) catch |err| {
                if (err == error.Interrupted) {
                    e.stop();
                    return;
                }
                record(user, started_at, sent_size, null, Problem.of(err));
                continue;
            };
            const results = evaluate.evaluate(arena, response, source.assertions, &.{}) catch &.{};
            const failed = results.len != source.assertions.len or evaluate.countFailed(results) > 0;
            record(user, started_at, sent_size, response, if (failed) .assertion else null);
        }
    }

    fn runScenario(user: *User, client: *http.Client, source: Scenario) void {
        const e = user.engine;
        var iteration: std.heap.ArenaAllocator = .init(e.gpa);
        defer iteration.deinit();
        var listener: ScenarioListener = .{ .user = user };
        while (!e.stopping.load(.acquire) and e.now() < e.deadline_ns) {
            _ = iteration.reset(.free_all);
            var suite_runner: runner.Runner = .{
                .gpa = e.gpa,
                .arena = iteration.allocator(),
                .client = client,
                .options = .{ .fail_fast = true },
                .variables = source.variables,
                .cancel = &e.stopping,
            };
            suite_runner.runSuite(source.suite, &listener) catch {
                e.worker_failed.store(true, .release);
                e.stopping.store(true, .release);
                return;
            };
            if (suite_runner.summary.interrupted or user.stats.scenario_errors > 0) return;
        }
    }

    const ScenarioListener = struct {
        user: *User,
        started_at: i96 = 0,

        pub fn requestStarting(listener: *@This()) bool {
            listener.started_at = listener.user.engine.requestStart() orelse return false;
            return true;
        }

        pub fn caseFinished(listener: *@This(), result: runner.CaseResult) !void {
            const user = listener.user;
            switch (result.status) {
                .not_run => if (result.request != null and !user.engine.stopping.load(.acquire)) user.engine.stop(),
                .skipped => {},
                .failed, .passed => {
                    const request = result.request orelse {
                        user.stats.scenario_errors += 1;
                        return;
                    };
                    const problem: ?Problem = if (result.http_error) |err| Problem.of(err) else if (result.failure != null)
                        .other
                    else if (result.status == .failed)
                        .assertion
                    else
                        null;
                    record(user, listener.started_at, requestSize(request), result.response, problem);
                },
            }
        }
    };

    fn record(user: *User, started_at: i96, sent_size: u64, response: ?Response, problem: ?Problem) void {
        const e = user.engine;
        const stats = &user.stats;
        var latency_us: u64 = 0;
        stats.requests += 1;
        stats.bytes_sent += sent_size;
        if (response) |value| {
            latency_us = value.duration_ns / std.time.ns_per_us;
            stats.bytes_received += responseSize(value);
            stats.status_classes[@min(5, value.status / 100)] += 1;
            stats.latency.record(latency_us);
            _ = e.live[liveBucket(latency_us)].fetchAdd(1, .monotonic);
        }
        if (problem) |value| {
            stats.failed += 1;
            stats.problems.getPtr(value).* += 1;
            _ = e.failed.fetchAdd(1, .monotonic);
        } else {
            stats.succeeded += 1;
        }
        _ = e.requests.fetchAdd(1, .monotonic);
        e.recordSecond(started_at, latency_us, problem != null);
    }
};

/// Buckets of the live histogram: four per power of two of microseconds, so
/// about 19% wide, up to about 70 minutes.
pub const live_buckets = 128;

pub fn liveBucket(us: u64) usize {
    if (us < 4) return @intCast(us);
    const msb: u6 = @intCast(63 - @clz(us));
    const fraction: usize = @intCast((us >> (msb - 2)) & 3);
    return @min(live_buckets - 1, @as(usize, msb) * 4 + fraction);
}

/// The highest latency in microseconds that `index` holds.
pub fn liveUpper(index: usize) u64 {
    // Indexes 4 to 7 are never used: 4µs and up start at index 8.
    if (index < 8) return @min(index, 3);
    const msb: u6 = @intCast(index / 4);
    const fraction: u64 = index % 4;
    return ((4 + fraction + 1) << (msb - 2)) - 1;
}

/// A percentile, in microseconds, of `counts` from `liveSnapshot`
/// differences. Zero when nothing was counted.
pub fn livePercentile(counts: []const u64, percent: f64) u64 {
    var total: u64 = 0;
    for (counts) |n| total += n;
    if (total == 0) return 0;
    const wanted: u64 = @max(1, @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * percent / 100.0))));
    var seen: u64 = 0;
    for (counts, 0..) |n, i| {
        seen += n;
        if (seen >= wanted) return liveUpper(i);
    }
    return liveUpper(counts.len - 1);
}

/// An estimate of the bytes on the wire for one request: the request line,
/// headers and body. TLS and framing are not counted.
pub fn requestSize(request: Request) u64 {
    var size: u64 = @tagName(request.method).len + request.url.len + " HTTP/1.1\r\n".len + 1;
    for (request.headers) |h| size += h.name.len + h.value.len + 4;
    for (request.query) |p| size += p.name.len + p.value.len + 2;
    size += switch (request.body) {
        .none => 0,
        .raw, .json => |text| text.len,
        .form => |fields| blk: {
            var n: u64 = 0;
            for (fields) |f| n += f.name.len + f.value.len + 2;
            break :blk n;
        },
        .multipart => |parts| blk: {
            var n: u64 = 0;
            for (parts) |p| n += p.name.len + p.value.len + 64;
            break :blk n;
        },
    };
    return size + 2;
}

/// Headers and body after decompression.
pub fn responseSize(response: @import("../http/response.zig").Response) u64 {
    var size: u64 = response.body.len + response.status_text.len + 15;
    for (response.headers) |h| size += h.name.len + h.value.len + 4;
    return size;
}

// Tests --------------------------------------------------------------------

const testing = std.testing;

test "histogram buckets are exact when small and close when large" {
    try testing.expectEqual(0, Histogram.bucketOf(0));
    try testing.expectEqual(127, Histogram.bucketOf(127));
    for ([_]u64{ 128, 129, 1000, 12_345, 999_999, 5_000_000_000 }) |v| {
        const i = Histogram.bucketOf(v);
        const upper = Histogram.upperOf(i);
        try testing.expect(upper >= v);
        // The bucket is less than 1.6% wide.
        try testing.expect(@as(f64, @floatFromInt(upper - v)) <= @as(f64, @floatFromInt(v)) * 0.016);
    }
    try testing.expect(Histogram.bucketOf(std.math.maxInt(u64)) < Histogram.bucket_count);
}

test "percentiles come from the recorded values" {
    var h: Histogram = .{};
    try testing.expectEqual(0, h.percentile(99));
    for (1..101) |v| h.record(v * 1000);
    try testing.expectEqual(100, h.count);
    try testing.expectEqual(1000, h.min());
    try testing.expectEqual(50_500, h.mean());
    const p50 = h.percentile(50);
    try testing.expect(p50 >= 50_000 and p50 <= 50_800);
    const p99 = h.percentile(99);
    try testing.expect(p99 >= 99_000 and p99 <= 100_000);
    try testing.expectEqual(100_000, h.percentile(100));

    var other: Histogram = .{};
    other.record(1);
    h.merge(&other);
    try testing.expectEqual(1, h.min());
    try testing.expectEqual(101, h.count);
}

test "configurations are checked" {
    const source: Source = .{ .request = .{ .request = .{ .url = "http://a.test" } } };
    try check(.{ .source = source });
    try testing.expectError(error.NoUsers, check(.{ .source = source, .users = 0 }));
    try testing.expectError(error.TooManyUsers, check(.{ .source = source, .users = max_users + 1 }));
    try testing.expectError(error.NoDuration, check(.{ .source = source, .duration_ms = 0 }));
    try testing.expectError(error.RampUpTooLong, check(.{ .source = source, .duration_ms = 1000, .ramp_up_ms = 1000 }));
    try testing.expectError(error.DurationTooLong, check(.{ .source = source, .duration_ms = max_duration_ms + 1 }));
}

test "stats merge every counter" {
    var a: Stats = .{ .requests = 2, .succeeded = 1, .failed = 1 };
    a.problems.set(.timeout, 1);
    a.status_classes[2] = 1;
    var b: Stats = .{ .requests = 3, .succeeded = 3, .bytes_received = 10 };
    b.status_classes[2] = 3;
    a.merge(&b);
    try testing.expectEqual(5, a.requests);
    try testing.expectEqual(4, a.status_classes[2]);
    try testing.expectEqual(1, a.problems.get(.timeout));
    try testing.expectEqual(10, a.bytes_received);
}

test "live buckets cover every latency and percentiles read them back" {
    for ([_]u64{ 0, 3, 4, 7, 100, 1500, 250_000, 60_000_000 }) |us| {
        const i = liveBucket(us);
        try testing.expect(liveUpper(i) >= us);
        if (i > 4) try testing.expect(liveUpper(i - 1) < us);
    }
    var counts: [live_buckets]u64 = @splat(0);
    for (0..90) |_| counts[liveBucket(1000)] += 1;
    for (0..10) |_| counts[liveBucket(50_000)] += 1;
    try testing.expect(livePercentile(&counts, 50) >= 1000 and livePercentile(&counts, 50) < 1300);
    try testing.expect(livePercentile(&counts, 99) >= 50_000);
    try testing.expectEqual(0, livePercentile(&@as([4]u64, @splat(0)), 50));
}

test "a paced scenario extracts a value for the next request and records assertions" {
    const Server = @import("../http/client_test.zig").Server;
    const io = testing.io;
    var server = try Server.listen(&.{
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Token: abc\r\n\r\n",
        "HTTP/1.1 500 Test\r\nContent-Length: 0\r\n\r\n",
    });
    defer server.listener.deinit(io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}", .{server.port()});
    var diagnostic: @import("../parser/parser.zig").Diagnostic = .{};
    const suite = try @import("../parser/parser.zig").parse(arena.allocator(),
        \\suite "Scenario"
        \\setup
        \\GET {{base}}/token
        \\extract secret token = header.x-token
        \\end
        \\test "uses token"
        \\GET {{base}}/data
        \\header X-Token {{token}}
        \\expect status == 200
        \\end
    , &diagnostic);
    var engine: Engine = .{
        .gpa = testing.allocator,
        .io = io,
        .config = .{
            .source = .{ .scenario = .{ .suite = &suite, .variables = &.{.{ .name = "base", .value = base, .line = 0 }} } },
            .users = 1,
            .duration_ms = 900,
            .rps = 2,
        },
    };
    const result = run: {
        var task = try io.concurrent(Server.serve, .{&server});
        defer task.cancel(io) catch {};
        try engine.start();
        break :run engine.finish();
    };
    defer engine.deinit();
    try testing.expectEqual(1, server.connections);
    try testing.expect(std.mem.find(u8, server.received[0..server.received_len], "X-Token: abc\r\n") != null);
    try testing.expectEqual(2, result.stats.requests);
    try testing.expectEqual(1, result.stats.succeeded);
    try testing.expectEqual(1, result.stats.problems.get(.assertion));
    try testing.expectEqual(0, result.stats.scenario_errors);
    try testing.expect(!result.interrupted);
    try testing.expect(result.duration_ns >= 500 * std.time.ns_per_ms);
}

test "stopping a scenario cancels a pending request and preserves partial metrics" {
    const Server = @import("../http/client_test.zig").Server;
    const io = testing.io;
    var server = try Server.listen(&.{});
    defer server.listener.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/", .{server.port()});
    const suite: ast.Suite = .{
        .name = "Scenario",
        .variables = &.{},
        .setup = null,
        .teardown = null,
        .tests = &.{.{
            .name = "pending",
            .line = 1,
            .variables = &.{},
            .request = .{ .method = .GET, .url = url, .headers = &.{}, .body = .none, .line = 1 },
            .expects = &.{},
            .extracts = &.{},
        }},
    };
    var engine: Engine = .{
        .gpa = testing.allocator,
        .io = io,
        .config = .{ .source = .{ .scenario = .{ .suite = &suite } }, .users = 1 },
    };
    try engine.start();
    defer engine.deinit();
    const stream = server.listener.accept(io) catch |err| {
        engine.stop();
        _ = engine.finish();
        return err;
    };
    defer stream.close(io);
    engine.stop();
    const result = engine.finish();
    try testing.expect(result.interrupted);
    try testing.expectEqual(0, result.stats.requests);
    try testing.expect(result.duration_ns < 5 * std.time.ns_per_s);
}
