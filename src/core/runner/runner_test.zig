//! Runs suites against a scripted loopback server, so the tests need no network.

const std = @import("std");
const Io = std.Io;
const http = @import("../http/client.zig");
const Server = @import("../http/client_test.zig").Server;
const ast = @import("../parser/ast.zig");
const parser = @import("../parser/parser.zig");
const runner = @import("runner.zig");
const Status = runner.Status;

const testing = std.testing;
const io = testing.io;

const ok_reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
const server_error_reply = "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n";
const token_reply = "HTTP/1.1 200 OK\r\nX-Id: 42\r\nContent-Length: 15\r\n\r\n{\"token\":\"abc\"}";

/// What the listener heard, one entry per case.
const Seen = struct {
    name: []const u8,
    status: Status,
    is_hook: bool,
    failure: ?[]const u8,
    failed_assertions: usize,
    /// What each failed assertion found.
    actual: []const u8,
};

const Recorder = struct {
    arena: std.mem.Allocator,
    seen: std.ArrayList(Seen) = .empty,

    pub fn caseFinished(r: *Recorder, result: runner.CaseResult) !void {
        var failed: usize = 0;
        var actual: std.ArrayList(u8) = .empty;
        for (result.assertions) |assertion| {
            if (!assertion.passed) failed += 1;
            try actual.appendSlice(r.arena, assertion.actual);
        }
        try r.seen.append(r.arena, .{
            .name = result.case.name,
            .status = result.status,
            .is_hook = result.is_hook,
            // Copied because results only live for this call.
            .failure = if (result.failure) |failure| try r.arena.dupe(u8, failure.message) else null,
            .failed_assertions = failed,
            .actual = actual.items,
        });
    }
};

/// Runs `sources` in order, with `{{base}}` set to a server sending `replies`.
const Fixture = struct {
    server: Server,
    task: Io.Future(Io.Cancelable!void) = undefined,
    client: http.Client = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    recorder: Recorder = undefined,
    engine: runner.Runner = undefined,

    fn start(f: *Fixture, options: runner.Options) !void {
        f.task = try io.concurrent(Server.serve, .{&f.server});
        f.client = .init(testing.allocator, io);
        f.arena = .init(testing.allocator);
        f.recorder = .{ .arena = f.arena.allocator() };
        f.engine = .{ .gpa = testing.allocator, .arena = f.arena.allocator(), .client = &f.client, .options = options };
    }

    fn stop(f: *Fixture) void {
        f.task.cancel(io) catch {};
        f.client.deinit();
        f.arena.deinit();
        f.server.listener.deinit(io);
    }

    fn runSource(f: *Fixture, source: []const u8) !void {
        const arena = f.arena.allocator();
        const text = try std.mem.replaceOwned(u8, arena, source, "{{base}}", try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{f.server.port()}));
        var diagnostic: parser.Diagnostic = .{};
        const suite = try arena.create(ast.Suite);
        suite.* = try parser.parse(arena, text, &diagnostic);
        try f.engine.runSuite(suite, &f.recorder);
    }

    fn seen(f: *Fixture) []const Seen {
        return f.recorder.seen.items;
    }

    fn expectStatuses(f: *Fixture, expected: []const Status) !void {
        const items = f.seen();
        try testing.expectEqual(expected.len, items.len);
        for (expected, items) |status, item| try testing.expectEqual(status, item.status);
    }

    /// Requests that reached the server.
    fn sent(f: *Fixture) usize {
        return f.server.next_reply;
    }

    fn received(f: *Fixture) []const u8 {
        return f.server.received[0..f.server.received_len];
    }
};

test "tests run in order and are counted" {
    var f: Fixture = .{ .server = try .listen(&.{ ok_reply, server_error_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "passes"
        \\GET {{base}}/a
        \\expect status == 200
        \\end
        \\test "fails"
        \\GET {{base}}/b
        \\expect status == 200
        \\expect body not_exists
        \\end
        \\test "skipped"
        \\skip
        \\GET {{base}}/c
        \\end
        \\test "disabled"
        \\disabled
        \\GET {{base}}/d
        \\end
    );
    try f.expectStatuses(&.{ .passed, .failed, .skipped });
    try testing.expectEqual(1, f.seen()[1].failed_assertions);
    try testing.expectEqual(2, f.sent());

    const summary = f.engine.summary;
    try testing.expectEqual(1, summary.passed);
    try testing.expectEqual(1, summary.failed);
    try testing.expectEqual(1, summary.skipped);
    try testing.expectEqual(0, summary.not_run);
}

test "a failed test does not stop the next one by default" {
    var f: Fixture = .{ .server = try .listen(&.{ server_error_reply, ok_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "one"
        \\GET {{base}}
        \\expect status == 200
        \\end
        \\test "two"
        \\GET {{base}}
        \\expect status == 200
        \\end
    );
    try f.expectStatuses(&.{ .failed, .passed });
}

const hooked_suite =
    \\suite "S"
    \\setup
    \\POST {{base}}/login
    \\expect status == 200
    \\end
    \\teardown
    \\DELETE {{base}}/session
    \\end
    \\test "one"
    \\GET {{base}}/a
    \\expect status == 200
    \\end
    \\test "two"
    \\GET {{base}}/b
    \\end
;

test "setup and teardown wrap the tests and are not counted as tests" {
    var f: Fixture = .{ .server = try .listen(&.{ ok_reply, ok_reply, ok_reply, ok_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(hooked_suite);
    try f.expectStatuses(&.{ .passed, .passed, .passed, .passed });
    try testing.expectEqualStrings("setup", f.seen()[0].name);
    try testing.expect(f.seen()[0].is_hook);
    try testing.expectEqualStrings("teardown", f.seen()[3].name);
    try testing.expectEqual(2, f.engine.summary.passed);
    try testing.expectEqual(0, f.engine.summary.failed);
}

test "a failed setup stops the tests but teardown still runs" {
    var f: Fixture = .{ .server = try .listen(&.{ server_error_reply, ok_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(hooked_suite);
    try f.expectStatuses(&.{ .failed, .not_run, .not_run, .passed });
    try testing.expectEqual(2, f.sent());
    try testing.expectEqual(1, f.engine.summary.failed);
    try testing.expectEqual(2, f.engine.summary.not_run);
}

test "a failed teardown fails the run" {
    const source =
        \\suite "S"
        \\teardown
        \\DELETE {{base}}
        \\expect status == 200
        \\end
        \\test "one"
        \\GET {{base}}
        \\end
    ;
    var f: Fixture = .{ .server = try .listen(&.{ ok_reply, server_error_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(source);
    try f.expectStatuses(&.{ .passed, .failed });
    try testing.expectEqual(1, f.engine.summary.failed);
}

test "fail-fast stops later tests and suites but runs teardown" {
    var f: Fixture = .{ .server = try .listen(&.{ ok_reply, server_error_reply, ok_reply }) };
    try f.start(.{ .fail_fast = true });
    defer f.stop();

    try f.runSource(hooked_suite);
    try f.expectStatuses(&.{ .passed, .failed, .not_run, .passed });

    try f.runSource(hooked_suite);
    try f.expectStatuses(&.{ .passed, .failed, .not_run, .passed, .not_run, .not_run });
    try testing.expectEqual(3, f.sent());
}

test "a suite with nothing to run sends no hooks" {
    var f: Fixture = .{ .server = try .listen(&.{}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\setup
        \\POST {{base}}
        \\end
        \\teardown
        \\DELETE {{base}}
        \\end
        \\test "later"
        \\skip
        \\GET {{base}}
        \\end
    );
    try f.expectStatuses(&.{.skipped});
    try testing.expectEqual(0, f.sent());
}

test "an extracted value reaches later requests and the teardown" {
    var f: Fixture = .{ .server = try .listen(&.{ token_reply, ok_reply, ok_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\setup
        \\POST {{base}}/login
        \\extract token = body.token
        \\extract id = header.x-id
        \\end
        \\test "uses it"
        \\GET {{base}}/users/{{id}}
        \\header Authorization Bearer {{token}}
        \\expect status == 200
        \\end
        \\teardown
        \\POST {{base}}/logout
        \\body { "token": "{{token}}" }
        \\end
    );
    try f.expectStatuses(&.{ .passed, .passed, .passed });
    try testing.expect(std.mem.find(u8, f.received(), "{ \"token\": \"abc\" }") != null);
}

test "request text and expected strings use variables, and a test's var wins" {
    var f: Fixture = .{ .server = try .listen(&.{token_reply}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\var path = "/suite"
        \\var want = "wrong"
        \\test "one"
        \\var want = "abc"
        \\GET {{base}}{{path}}
        \\header X-Sent {{want}}
        \\expect body.token == "{{want}}"
        \\end
    );
    try f.expectStatuses(&.{.passed});
    try testing.expect(std.mem.startsWith(u8, f.received(), "GET /suite HTTP/1.1\r\n"));
    try testing.expect(std.mem.find(u8, f.received(), "X-Sent: abc\r\n") != null);
}

test "a missing variable fails the case without sending it" {
    var f: Fixture = .{ .server = try .listen(&.{}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "url"
        \\GET {{base}}/{{gone}}
        \\end
        \\test "expect"
        \\GET {{base}}
        \\expect body == "{{gone}}"
        \\end
    );
    try f.expectStatuses(&.{ .failed, .failed });
    try testing.expectEqualStrings("{{gone}} is not defined", f.seen()[0].failure.?);
    try testing.expectEqualStrings("{{gone}} is not defined", f.seen()[1].failure.?);
    try testing.expectEqual(0, f.sent());
}

test "a body that is not JSON after replacement is not sent" {
    var f: Fixture = .{ .server = try .listen(&.{}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\var id = "not a number"
        \\test "one"
        \\POST {{base}}
        \\body { "id": {{id}} }
        \\end
    );
    try f.expectStatuses(&.{.failed});
    try testing.expectEqualStrings("the body is not valid JSON once variables are replaced", f.seen()[0].failure.?);
    try testing.expectEqual(0, f.sent());
}

test "a failed extract fails the case and leaves the variable undefined" {
    var f: Fixture = .{ .server = try .listen(&.{ok_reply}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "one"
        \\GET {{base}}
        \\extract token = body.token
        \\end
        \\test "two"
        \\GET {{base}}/{{token}}
        \\end
    );
    try f.expectStatuses(&.{ .failed, .failed });
    try testing.expectEqualStrings("cannot extract token: body is not valid JSON", f.seen()[0].failure.?);
    try testing.expectEqualStrings("{{token}} is not defined", f.seen()[1].failure.?);
}

test "a failed assertion does not run its extracts" {
    var f: Fixture = .{ .server = try .listen(&.{token_reply}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "one"
        \\GET {{base}}
        \\expect status == 201
        \\extract gone = body.gone
        \\end
    );
    try f.expectStatuses(&.{.failed});
    try testing.expectEqual(null, f.seen()[0].failure);
}

test "a request that times out fails the test" {
    var f: Fixture = .{ .server = try .listen(&.{""}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "slow"
        \\timeout 50ms
        \\GET {{base}}
        \\end
    );
    try f.expectStatuses(&.{.failed});
    try testing.expectEqualStrings("request timed out", f.seen()[0].failure.?);
}

test "a bad URL fails the test with the client's message" {
    var f: Fixture = .{ .server = try .listen(&.{}) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\var url = "ftp://a.test"
        \\test "one"
        \\GET {{url}}
        \\end
    );
    try f.expectStatuses(&.{.failed});
    try testing.expectEqualStrings("unsupported URL scheme: use http:// or https://", f.seen()[0].failure.?);
}

test "global and environment values fill in below a suite's" {
    var f: Fixture = .{ .server = try .listen(&.{ok_reply}) };
    try f.start(.{});
    defer f.stop();
    f.engine.variables = &.{
        .{ .name = "path", .value = "global", .line = 0 },
        .{ .name = "path", .value = "environment", .line = 0 },
        .{ .name = "shared", .value = "base", .line = 0 },
    };

    try f.runSource(
        \\suite "S"
        \\var shared = "suite"
        \\test "one"
        \\GET {{base}}/{{path}}/{{shared}}
        \\end
    );
    try f.expectStatuses(&.{.passed});
    try testing.expect(std.mem.startsWith(u8, f.received(), "GET /environment/suite HTTP/1.1\r\n"));
}

test "a secret is sent but hidden from results" {
    const echo = "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n{\"key\":\"k1\"}";
    var f: Fixture = .{ .server = try .listen(&.{ echo, echo }) };
    try f.start(.{});
    defer f.stop();
    f.engine.variables = &.{.{ .name = "base_key", .value = "k1", .line = 0, .secret = true }};

    // The second test's own values cannot be missed by the first.
    try f.runSource(
        \\suite "S"
        \\test "environment"
        \\GET {{base}}/{{base_key}}
        \\expect body.key == "other"
        \\end
        \\test "own"
        \\var secret mine = "k1"
        \\GET {{base}}/{{mine}}
        \\expect body == "other"
        \\end
    );
    try f.expectStatuses(&.{ .failed, .failed });
    try testing.expect(std.mem.startsWith(u8, f.received(), "GET /k1 HTTP/1.1\r\n"));
    try testing.expectEqualStrings("body.key == \"********\"", f.seen()[0].actual);
    try testing.expectEqual(null, std.mem.find(u8, f.seen()[1].actual, "k1"));
}

test "an extracted secret is hidden from then on, even in its own case" {
    var f: Fixture = .{ .server = try .listen(&.{ token_reply, token_reply, token_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "S"
        \\test "own case"
        \\GET {{base}}
        \\expect body.token == "wrong"
        \\extract secret token = body.token
        \\end
        \\test "works"
        \\GET {{base}}
        \\extract secret token = body.token
        \\end
        \\test "later"
        \\GET {{base}}
        \\header X-Sent {{token}}
        \\expect body.token == "wrong"
        \\end
    );
    try f.expectStatuses(&.{ .failed, .passed, .failed });
    try testing.expectEqualStrings("body.token == \"********\"", f.seen()[0].actual);
    try testing.expectEqualStrings("body.token == \"********\"", f.seen()[2].actual);
    try testing.expect(std.mem.find(u8, f.received(), "X-Sent: abc\r\n") != null);
}

test "a secret stays hidden in later suites" {
    var f: Fixture = .{ .server = try .listen(&.{ token_reply, token_reply }) };
    try f.start(.{});
    defer f.stop();

    try f.runSource(
        \\suite "A"
        \\test "one"
        \\GET {{base}}
        \\extract secret token = body.token
        \\end
    );
    try f.runSource(
        \\suite "B"
        \\test "two"
        \\GET {{base}}
        \\expect body.token == "wrong"
        \\end
    );
    try testing.expectEqualStrings("body.token == \"********\"", f.seen()[1].actual);
}
