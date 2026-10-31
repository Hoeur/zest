//! `ztest api`: sends one request and prints the response.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Assertion = @import("../core/assertions/assertion.zig").Assertion;
const assertions_eval = @import("../core/assertions/evaluate.zig");
const Context = @import("../core/context.zig").Context;
const ExitCode = @import("../core/errors.zig").ExitCode;
const http = @import("../core/http/client.zig");
const Request = @import("../core/http/request.zig").Request;
const Response = @import("../core/http/response.zig").Response;

/// `out` receives the response, so `--raw` output can be piped. For the same
/// reason, `--raw` sends the assertion report to the diagnostics stream.
pub fn run(context: Context, out: *Io.Writer, request: Request, assertions: []const Assertion, raw: bool) !ExitCode {
    var client: http.Client = .init(context.gpa, context.io);
    defer client.deinit();

    context.log.debug("{s} {s}", .{ @tagName(request.method), request.url });
    const response = client.send(context.arena, request) catch |err| {
        if (err == error.OutOfMemory) return err;
        context.log.err("{s}", .{http.describe(err)});
        return exitCode(err);
    };

    if (raw) {
        try out.writeAll(response.body);
    } else {
        try printSummary(out, response);
        try out.writeByte('\n');
        try printBody(context.arena, out, response.body);
    }
    if (assertions.len == 0) return .success;

    const results = try assertions_eval.evaluate(context.arena, response, assertions, &.{});
    const report = if (raw) context.log.out else out;
    if (!raw) try out.writeByte('\n');
    try assertions_eval.printReport(report, results);
    try report.flush();
    return if (assertions_eval.countFailed(results) == 0) .success else .test_failure;
}

/// An HTTP error status is still a completed request, so only a failure to
/// finish the exchange leaves here as non-zero.
fn exitCode(err: http.Error) ExitCode {
    return switch (err) {
        error.InvalidUrl, error.UnsupportedScheme, error.InvalidHeader => .config_error,
        error.Interrupted => .interrupted,
        error.OutOfMemory => .internal_error,
        else => .test_failure,
    };
}

fn printSummary(out: *Io.Writer, response: Response) Io.Writer.Error!void {
    try out.print("{d} {s}\n", .{ response.status, response.status_text });
    try out.print("Time: {d}ms\n", .{response.duration_ns / std.time.ns_per_ms});
    try out.writeAll("Size: ");
    try printSize(out, response.size());
    try out.writeByte('\n');
}

fn printSize(out: *Io.Writer, bytes: usize) Io.Writer.Error!void {
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return out.print("{d} B", .{bytes});
    if (bytes < 1024 * 1024) return out.print("{d:.1} KB", .{value / 1024});
    return out.print("{d:.1} MB", .{value / (1024 * 1024)});
}

/// Indents JSON and prints anything else as it arrived.
fn printBody(arena: Allocator, out: *Io.Writer, body: []const u8) !void {
    if (body.len == 0) return;
    // Numbers stay as text, so large or precise values print unchanged.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{
        .parse_numbers = false,
    }) catch {
        try out.writeAll(body);
        if (!std.mem.endsWith(u8, body, "\n")) try out.writeByte('\n');
        return;
    };
    try std.json.Stringify.value(parsed, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

const testing = std.testing;

test "sizes use the largest fitting unit" {
    var buffer: [32]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    try printSize(&out, 512);
    try out.writeByte(' ');
    try printSize(&out, 1229);
    try out.writeByte(' ');
    try printSize(&out, 3 * 1024 * 1024);
    try testing.expectEqualStrings("512 B 1.2 KB 3.0 MB", out.buffered());
}

test "summary matches the documented format" {
    var buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    const body: [1229]u8 = @splat('x');
    try printSummary(&out, .{
        .status = 200,
        .status_text = "OK",
        .headers = &.{},
        .cookies = &.{},
        .body = &body,
        .duration_ns = 82 * std.time.ns_per_ms,
    });
    try testing.expectEqualStrings("200 OK\nTime: 82ms\nSize: 1.2 KB\n", out.buffered());
}

test "JSON is indented and keeps exact numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    try printBody(arena.allocator(), &out, "{\"id\":12345678901234567890,\"pi\":3.10}");
    try testing.expectEqualStrings("{\n  \"id\": 12345678901234567890,\n  \"pi\": 3.10\n}\n", out.buffered());
}

test "other bodies print unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    try printBody(arena.allocator(), &out, "<html>");
    try testing.expectEqualStrings("<html>\n", out.buffered());
}

test "usage mistakes and network failures have different exit codes" {
    try testing.expectEqual(ExitCode.config_error, exitCode(error.InvalidUrl));
    try testing.expectEqual(ExitCode.test_failure, exitCode(error.Timeout));
    try testing.expectEqual(ExitCode.interrupted, exitCode(error.Interrupted));
}
