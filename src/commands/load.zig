//! `ztest load`: sends one request from many virtual users for a set time and
//! prints throughput, latency percentiles and errors.

const std = @import("std");
const Io = std.Io;
const Assertion = @import("../core/assertions/assertion.zig").Assertion;
const Context = @import("../core/context.zig").Context;
const ExitCode = @import("../core/errors.zig").ExitCode;
const Request = @import("../core/http/request.zig").Request;
const load = @import("../core/load/load.zig");
const report = @import("../core/report/report.zig");
const shutdown = @import("../core/shutdown.zig");

pub const Settings = struct {
    users: u32,
    duration_ms: u64,
    ramp_up_ms: u64,
    rps: u32,
    reports: []const report.Target = &.{},
    version: []const u8 = "",
};

/// Progress goes to the diagnostics stream once a second, so stdout holds only
/// the final summary. Every failed response makes the exit code 1.
pub fn run(context: Context, out: *Io.Writer, request: Request, assertions: []const Assertion, settings: Settings) !ExitCode {
    var engine: load.Engine = .{
        .gpa = context.gpa,
        .io = context.io,
        .config = .{
            .request = request,
            .assertions = assertions,
            .users = settings.users,
            .duration_ms = settings.duration_ms,
            .ramp_up_ms = settings.ramp_up_ms,
            .rps = settings.rps,
        },
    };
    load.check(engine.config) catch |err| {
        context.log.err("{s}", .{load.describeConfigError(err)});
        return .config_error;
    };

    var timestamp: [20]u8 = undefined;
    const started_at = report.formatTimestamp(&timestamp, Io.Timestamp.now(context.io, .real).toSeconds());
    try out.print("Load test: {s} {s}\n", .{ @tagName(request.method), request.url });
    try out.print("{d} users for {d}s", .{ settings.users, settings.duration_ms / std.time.ms_per_s });
    if (settings.ramp_up_ms > 0) try out.print(", ramping up over {d}s", .{settings.ramp_up_ms / std.time.ms_per_s});
    if (settings.rps > 0) try out.print(", at most {d} requests/s", .{settings.rps});
    try out.writeAll("\n\n");
    try out.flush();

    engine.start() catch |err| {
        context.log.err("cannot start the virtual users: {s}", .{@errorName(err)});
        return .internal_error;
    };
    defer engine.deinit();

    var last_report: u64 = 0;
    while (!engine.done()) {
        if (shutdown.isRequested()) engine.stop();
        context.io.sleep(.fromMilliseconds(100), .awake) catch engine.stop();
        const progress = engine.progress();
        const second = progress.elapsed_ns / std.time.ns_per_s;
        if (second > last_report and !engine.done()) {
            last_report = second;
            context.log.info("{d: >4}s  {d: >9} requests  {d: >7} failed  {d: >4} users", .{
                second, progress.requests, progress.failed, progress.active_users,
            });
        }
    }
    const result = engine.finish();
    try printResult(out, result);

    for (settings.reports) |target| {
        writeReport(context, target, result, settings, started_at) catch |err| {
            context.log.err("cannot write {s}: {s}", .{ target.path, @errorName(err) });
            return .config_error;
        };
        try out.print("Report: {s}\n", .{target.path});
    }

    if (result.interrupted or shutdown.isRequested()) return .interrupted;
    if (result.stats.requests == 0) {
        context.log.err("no requests were sent", .{});
        return .test_failure;
    }
    return if (result.stats.failed > 0) .test_failure else .success;
}

pub fn printResult(out: *Io.Writer, result: load.Result) Io.Writer.Error!void {
    const s = result.stats;
    const h = &s.latency;
    try out.writeAll(if (result.interrupted) "Load Test Interrupted\n\n" else "Load Test Complete\n\n");
    try row(out, "Total Requests", s.requests);
    try row(out, "Successful", s.succeeded);
    try row(out, "Failed", s.failed);
    try out.print("{s: <18}{d: >12.1}\n", .{ "RPS", result.rps() });
    try out.print("{s: <18}{d: >11.2}%\n", .{ "Failure Rate", result.failureRate() });
    try out.print("{s: <18}{d: >11.1}s\n\n", .{ "Duration", @as(f64, @floatFromInt(result.duration_ns)) / std.time.ns_per_s });

    try latency(out, "Average Latency", h.mean());
    try latency(out, "Min Latency", h.min());
    try latency(out, "p50", h.percentile(50));
    try latency(out, "p90", h.percentile(90));
    try latency(out, "p95", h.percentile(95));
    try latency(out, "p99", h.percentile(99));
    try latency(out, "Max Latency", h.max_us);
    try out.writeByte('\n');

    try out.print("{s: <18}{d: >12}\n", .{ "Bytes Received", s.bytes_received });
    try out.print("{s: <18}{d: >12}\n", .{ "Bytes Sent", s.bytes_sent });

    var any_status = false;
    for (s.status_classes, 0..) |n, class| {
        if (n == 0 or class == 0) continue;
        if (!any_status) try out.writeAll("\nStatus codes\n");
        any_status = true;
        try out.print("  {d}xx{s: <13}{d: >12}\n", .{ class, "", n });
    }
    var any_problem = false;
    for (std.enums.values(load.Problem)) |p| {
        const n = s.problems.get(p);
        if (n == 0) continue;
        if (!any_problem) try out.writeAll("\nFailures\n");
        any_problem = true;
        try out.print("  {s: <16}{d: >12}\n", .{ p.label(), n });
    }
}

fn row(out: *Io.Writer, label: []const u8, value: u64) Io.Writer.Error!void {
    try out.print("{s: <18}{d: >12}\n", .{ label, value });
}

fn latency(out: *Io.Writer, label: []const u8, us: u64) Io.Writer.Error!void {
    if (us < 10 * std.time.us_per_ms) {
        try out.print("{s: <18}{d: >9.2} ms\n", .{ label, @as(f64, @floatFromInt(us)) / std.time.us_per_ms });
    } else {
        try out.print("{s: <18}{d: >9} ms\n", .{ label, us / std.time.us_per_ms });
    }
}

/// The JSON a dashboard or CI step can read: totals, percentiles in
/// milliseconds, and one entry a second.
fn writeReport(context: Context, target: report.Target, result: load.Result, settings: Settings, started_at: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(target.path)) |dir| try cwd.createDirPath(context.io, dir);
    var file = try cwd.createFile(context.io, target.path, .{});
    defer file.close(context.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(context.io, &buffer);
    try writeJson(&writer.interface, result, settings, started_at);
    try writer.interface.flush();
}

pub fn writeJson(out: *Io.Writer, result: load.Result, settings: Settings, started_at: []const u8) Io.Writer.Error!void {
    const s = result.stats;
    const h = &s.latency;
    var w: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try w.beginObject();
    try w.objectField("tool");
    try w.write("ztest");
    try w.objectField("version");
    try w.write(settings.version);
    try w.objectField("started_at");
    try w.write(started_at);
    try w.objectField("users");
    try w.write(result.users);
    try w.objectField("ramp_up_ms");
    try w.write(settings.ramp_up_ms);
    try w.objectField("target_rps");
    try w.write(settings.rps);
    try w.objectField("duration_ms");
    try w.write(result.duration_ns / std.time.ns_per_ms);
    try w.objectField("interrupted");
    try w.write(result.interrupted);
    try w.objectField("requests");
    try w.write(s.requests);
    try w.objectField("succeeded");
    try w.write(s.succeeded);
    try w.objectField("failed");
    try w.write(s.failed);
    try w.objectField("rps");
    try w.write(result.rps());
    try w.objectField("failure_rate");
    try w.write(result.failureRate());
    try w.objectField("bytes_sent");
    try w.write(s.bytes_sent);
    try w.objectField("bytes_received");
    try w.write(s.bytes_received);
    try w.objectField("latency_ms");
    try w.beginObject();
    const points = [_]struct { name: []const u8, us: u64 }{
        .{ .name = "mean", .us = h.mean() },
        .{ .name = "min", .us = h.min() },
        .{ .name = "p50", .us = h.percentile(50) },
        .{ .name = "p90", .us = h.percentile(90) },
        .{ .name = "p95", .us = h.percentile(95) },
        .{ .name = "p99", .us = h.percentile(99) },
        .{ .name = "max", .us = h.max_us },
    };
    for (points) |point| {
        try w.objectField(point.name);
        try w.write(@as(f64, @floatFromInt(point.us)) / std.time.us_per_ms);
    }
    try w.endObject();
    try w.objectField("status_classes");
    try w.beginObject();
    for (s.status_classes, 0..) |n, class| {
        if (class == 0 or n == 0) continue;
        var name: [3]u8 = .{ '0' + @as(u8, @intCast(class)), 'x', 'x' };
        try w.objectField(&name);
        try w.write(n);
    }
    try w.endObject();
    try w.objectField("failures");
    try w.beginObject();
    for (std.enums.values(load.Problem)) |p| {
        if (s.problems.get(p) == 0) continue;
        try w.objectField(@tagName(p));
        try w.write(s.problems.get(p));
    }
    try w.endObject();
    try w.objectField("seconds");
    try w.beginArray();
    for (result.seconds) |*second| {
        const n = second.requests.load(.monotonic);
        try w.beginObject();
        try w.objectField("requests");
        try w.write(n);
        try w.objectField("failed");
        try w.write(second.failed.load(.monotonic));
        try w.objectField("mean_latency_ms");
        const sum = second.latency_sum_us.load(.monotonic);
        try w.write(if (n == 0) 0 else @as(f64, @floatFromInt(sum / n)) / std.time.us_per_ms);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    try out.writeByte('\n');
}

const testing = std.testing;

fn sampleResult(seconds: []const load.Second) load.Result {
    var stats: load.Stats = .{ .requests = 4, .succeeded = 3, .failed = 1, .bytes_received = 400, .bytes_sent = 100 };
    for ([_]u64{ 1000, 2000, 3000, 40_000 }) |us| stats.latency.record(us);
    stats.status_classes[2] = 3;
    stats.status_classes[5] = 1;
    stats.problems.set(.assertion, 1);
    return .{ .users = 2, .duration_ns = 2 * std.time.ns_per_s, .stats = stats, .seconds = seconds, .interrupted = false };
}

test "the summary shows totals, percentiles and failures" {
    var buffer: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try printResult(&out, sampleResult(&.{}));
    const text = out.buffered();
    for ([_][]const u8{
        "Total Requests               4\n",
        "Failure Rate",
        "25.00%\n",
        "p50                    2.02 ms\n",
        "Max Latency",
        "40 ms\n",
        "  5xx",
        "  assertion failed",
    }) |part| {
        if (std.mem.find(u8, text, part) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ part, text });
            return error.TestUnexpectedResult;
        }
    }
}

test "the JSON report parses and holds the series" {
    var seconds: [2]load.Second = .{ .{}, .{} };
    seconds[0].requests.store(3, .monotonic);
    seconds[0].latency_sum_us.store(6000, .monotonic);
    seconds[1].requests.store(1, .monotonic);
    seconds[1].failed.store(1, .monotonic);
    var buffer: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try writeJson(&out, sampleResult(&seconds), .{ .users = 2, .duration_ms = 2000, .ramp_up_ms = 0, .rps = 0 }, "2026-11-03T00:00:00Z");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(4, root.get("requests").?.integer);
    try testing.expectEqual(1, root.get("status_classes").?.object.get("5xx").?.integer);
    const series = root.get("seconds").?.array.items;
    try testing.expectEqual(2, series.len);
    const mean = series[0].object.get("mean_latency_ms").?;
    try testing.expectEqual(2.0, switch (mean) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TestUnexpectedResult,
    });
}
