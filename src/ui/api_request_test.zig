//! Tests the exact background session used by the desktop against loopback HTTP.
const std = @import("std");
const testing = std.testing;
const api = @import("api_request.zig");
const Server = @import("../core/http/client_test.zig").Server;

fn finish(session: *api.Session) !void {
    const start = std.Io.Timestamp.now(testing.io, .awake);
    while (!session.poll()) {
        if (start.untilNow(testing.io, .awake).toMilliseconds() > 5000) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "desktop request snapshots the draft and displays real HTTP errors as responses" {
    var server = try Server.listen(&.{"HTTP/1.1 500 Oops\r\nContent-Length: 5\r\nX-Test: real\r\n\r\nhello"});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/real", .{server.port()});
    try session.start(.POST, url, 2000);
    @memset(url, 'x');
    try testing.expectError(error.Busy, session.start(.GET, "http://ignored", 2000));
    try finish(&session);
    try testing.expectEqual(api.Phase.completed, session.phase);
    try testing.expectEqual(500, session.response.?.status);
    try testing.expectEqualStrings("real", session.response.?.header("x-test").?);
    try testing.expect(std.mem.startsWith(u8, server.received[0..server.received_len], "POST /real HTTP/1.1"));
    const body = try session.preview(testing.allocator, .body);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
    const headers = try session.preview(testing.allocator, .headers);
    defer testing.allocator.free(headers);
    try testing.expect(std.mem.find(u8, headers, "X-Test: real\r\n") != null);
    try testing.expect(session.response.?.duration_ns > 0);
}

test "manual sends recover after the server closes an idle connection" {
    var server = try Server.listen(&.{"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{server.port()});
    try session.start(.GET, url, 2000);
    try finish(&session);
    try task.await(testing.io); // The server closed its socket without a close header.
    server.next_reply = 0;
    server.replies = &.{"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo"};
    task = try testing.io.concurrent(Server.serve, .{&server});
    try session.start(.GET, url, 2000);
    try finish(&session);
    try testing.expectEqual(api.Phase.completed, session.phase);
    try testing.expectEqualStrings("two", session.response.?.body);
    try testing.expectEqual(2, server.connections);
}

test "desktop JSON draft snapshots headers and body and supplies its content type" {
    var server = try Server.listen(&.{"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/json", .{server.port()});
    var headers = "X-Trace: original\r\nX-Trace: second".*;
    var body = "{\"value\":42}".*;
    try session.startDraft(.{ .method = .POST, .url = url, .headers = &headers, .body_kind = .json, .body = &body }, 2000);
    @memset(&headers, 'x');
    @memset(&body, 'x');
    try finish(&session);
    try testing.expectEqual(api.Phase.completed, session.phase);
    const received = server.received[0..server.received_len];
    try testing.expect(std.mem.find(u8, received, "X-Trace: original\r\nX-Trace: second\r\n") != null);
    try testing.expect(std.mem.find(u8, received, "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, received, "{\"value\":42}"));
}

test "desktop raw draft preserves text and an explicit content type" {
    var server = try Server.listen(&.{"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/raw", .{server.port()});
    try session.startDraft(.{ .method = .PUT, .url = url, .headers = "Content-Type: text/plain", .body_kind = .raw, .body = "first\r\nsecond\r\n" }, 2000);
    try finish(&session);
    try testing.expectEqual(api.Phase.completed, session.phase);
    const received = server.received[0..server.received_len];
    try testing.expect(std.mem.find(u8, received, "content-type: text/plain\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, received, "first\r\nsecond\r\n"));
}

test "invalid drafts do not start a worker or leak sensitive values in errors" {
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try testing.expectError(error.InvalidJson, session.startDraft(.{ .url = "http://127.0.0.1:1/", .body_kind = .json, .body = "secret-invalid-json" }, 2000));
    try testing.expect(!session.busy());
    try testing.expectEqual(api.Phase.failed, session.phase);
    try testing.expect(std.mem.find(u8, session.message(), "secret") == null);
    try testing.expectError(error.InvalidHeader, session.startDraft(.{ .url = "http://127.0.0.1:1/", .headers = "X-Good: yes\r\nBad Name: secret-token" }, 2000));
    try testing.expect(!session.busy());
    try testing.expect(std.mem.startsWith(u8, session.message(), "Header line 2:"));
    try testing.expect(std.mem.find(u8, session.message(), "secret") == null);
}

test "desktop request can cancel a silent server and then send again" {
    var server = try Server.listen(&.{""});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{server.port()});
    try session.start(.GET, url, 30_000);
    try testing.io.sleep(.fromMilliseconds(75), .awake);
    session.cancel();
    try finish(&session);
    try testing.expectEqual(api.Phase.canceled, session.phase);
    try testing.expectEqual(null, session.response);
    try session.start(.GET, "not a URL", 2000);
    try finish(&session);
    try testing.expectEqual(api.Phase.failed, session.phase);
    try testing.expect(session.failure != null);
}

test "desktop timeout and shutdown release pending requests" {
    var server = try Server.listen(&.{""});
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    var buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{server.port()});
    try session.start(.GET, url, 25);
    try finish(&session);
    try testing.expectEqual(api.Phase.failed, session.phase);
    try testing.expectEqual(error.Timeout, session.failure.?);
    try session.start(.GET, url, 30_000);
    // deinit cancels and joins this request before the allocator's leak check.
}

test "desktop previews handle binary controls and oversized UTF-8 bodies" {
    var session = api.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    session.phase = .completed;
    session.response = .{ .status = 200, .status_text = "OK", .headers = &.{}, .cookies = &.{}, .duration_ns = 1, .body = "a\x00b\nnext" };
    const controls = try session.preview(testing.allocator, .body);
    defer testing.allocator.free(controls);
    try testing.expectEqualStrings("a?b\r\nnext", controls);
    session.response.?.body = "\xff\xfe";
    const binary = try session.preview(testing.allocator, .body);
    defer testing.allocator.free(binary);
    try testing.expect(std.mem.find(u8, binary, "Binary") != null);
    const huge = try testing.allocator.alloc(u8, api.preview_limit + 10);
    defer testing.allocator.free(huge);
    @memset(huge, 'a');
    @memcpy(huge[api.preview_limit - 1 ..][0..3], "\xe1\x9e\x80");
    session.response.?.body = huge;
    const preview = try session.preview(testing.allocator, .body);
    defer testing.allocator.free(preview);
    try testing.expect(std.unicode.utf8ValidateSlice(preview));
    try testing.expect(std.mem.endsWith(u8, preview, "[Preview truncated at 64 KiB]\r\n"));
}
