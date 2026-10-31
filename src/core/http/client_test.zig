//! Exercises `Client` against scripted servers on the loopback interface, so
//! the tests need no network.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Client = @import("client.zig").Client;
const Request = @import("request.zig").Request;

const testing = std.testing;
const io = testing.io;

/// Replies to each connection's requests in turn, then closes it. An empty
/// entry in `replies` means the server stays silent until the test ends.
pub const Server = struct {
    listener: net.Server,
    replies: []const []const u8,
    /// The most recent request's head and body.
    received: [4096]u8 = undefined,
    received_len: usize = 0,
    connections: usize = 0,
    next_reply: usize = 0,

    pub fn listen(replies: []const []const u8) !Server {
        const address: net.IpAddress = try .parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(io, .{ .reuse_address = true }), .replies = replies };
    }

    pub fn port(s: *const Server) u16 {
        return s.listener.socket.address.getPort();
    }

    fn url(s: *const Server, buffer: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ s.port(), path });
    }

    fn received_text(s: *const Server) []const u8 {
        return s.received[0..s.received_len];
    }

    pub fn serve(s: *Server) Io.Cancelable!void {
        while (s.next_reply < s.replies.len) {
            const stream = s.listener.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return,
            };
            defer stream.close(io);
            s.connections += 1;
            s.serveConnection(stream) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => {},
            };
        }
    }

    fn serveConnection(s: *Server, stream: net.Stream) error{ Canceled, Closed }!void {
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);

        while (s.next_reply < s.replies.len) {
            s.readRequest(&reader.interface) catch return error.Closed;
            const reply = s.replies[s.next_reply];
            s.next_reply += 1;
            if (reply.len == 0) {
                while (true) try io.sleep(.fromSeconds(1), .awake);
            }
            writer.interface.writeAll(reply) catch return error.Closed;
            writer.interface.flush() catch return error.Closed;
            if (std.mem.find(u8, reply, "Connection: close") != null) return error.Closed;
        }
    }

    fn readRequest(s: *Server, reader: *Io.Reader) !void {
        s.received_len = 0;
        var content_length: usize = 0;
        while (true) {
            const line = try reader.takeDelimiterInclusive('\n');
            @memcpy(s.received[s.received_len..][0..line.len], line);
            s.received_len += line.len;
            const lower_prefix = "content-length: ";
            if (line.len > lower_prefix.len and std.ascii.startsWithIgnoreCase(line, lower_prefix)) {
                const digits = std.mem.trim(u8, line[lower_prefix.len..], " \r\n");
                content_length = try std.fmt.parseInt(usize, digits, 10);
            }
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
        const body = try reader.take(content_length);
        @memcpy(s.received[s.received_len..][0..body.len], body);
        s.received_len += body.len;
    }
};

/// A running server plus the client and arena a test needs.
const Fixture = struct {
    server: Server,
    task: Io.Future(Io.Cancelable!void) = undefined,
    client: Client = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn start(f: *Fixture) !void {
        f.task = try io.concurrent(Server.serve, .{&f.server});
        f.client = .init(testing.allocator, io);
        f.arena = .init(testing.allocator);
    }

    fn stop(f: *Fixture) void {
        f.task.cancel(io) catch {};
        f.client.deinit();
        f.arena.deinit();
        f.server.listener.deinit(io);
    }

    fn send(f: *Fixture, request: Request) !@import("response.zig").Response {
        return f.client.send(f.arena.allocator(), request);
    }
};

const ok_reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi";
const closing_reply = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi";

fn startServer(replies: []const []const u8) !Fixture {
    return .{ .server = try .listen(replies) };
}

test "GET captures status, headers, body and timing" {
    var f = try startServer(&.{ok_reply});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{ .url = try f.server.url(&buffer, "/users?id=1") });

    try testing.expectEqual(200, response.status);
    try testing.expectEqualStrings("OK", response.status_text);
    try testing.expectEqualStrings("hi", response.body);
    try testing.expectEqualStrings("text/plain", response.header("content-type").?);
    try testing.expectEqual(2, response.size());
    try testing.expect(response.duration_ns > 0);
    try testing.expect(std.mem.startsWith(u8, f.server.received_text(), "GET /users?id=1 HTTP/1.1\r\n"));
}

test "POST sends the JSON body and its content type" {
    var f = try startServer(&.{"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n"});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{
        .method = .POST,
        .url = try f.server.url(&buffer, "/login"),
        .body = .{ .json = "{\"a\":1}" },
    });

    try testing.expectEqual(201, response.status);
    const text = f.server.received_text();
    try testing.expect(std.mem.startsWith(u8, text, "POST /login HTTP/1.1\r\n"));
    try testing.expect(std.mem.find(u8, text, "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "{\"a\":1}"));
}

test "every method reaches the server" {
    const methods = [_]std.http.Method{ .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS };
    for (methods) |method| {
        var f = try startServer(&.{"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"});
        try f.start();
        defer f.stop();

        var buffer: [64]u8 = undefined;
        const response = try f.send(.{ .method = method, .url = try f.server.url(&buffer, "/") });
        try testing.expectEqual(204, response.status);
        try testing.expect(std.mem.startsWith(u8, f.server.received_text(), @tagName(method)));
    }
}

test "auth, cookies and custom headers are sent" {
    var f = try startServer(&.{ok_reply});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    _ = try f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .auth = .{ .basic = .{ .user = "ada", .password = "pw" } },
        .cookies = &.{.{ .name = "sid", .value = "1" }},
        .headers = &.{.{ .name = "X-Trace", .value = "abc" }},
    });
    const text = f.server.received_text();
    try testing.expect(std.mem.find(u8, text, "authorization: Basic YWRhOnB3\r\n") != null);
    try testing.expect(std.mem.find(u8, text, "Cookie: sid=1\r\n") != null);
    try testing.expect(std.mem.find(u8, text, "X-Trace: abc\r\n") != null);
}

test "a user header replaces the default instead of repeating it" {
    var f = try startServer(&.{ok_reply});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    _ = try f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .headers = &.{.{ .name = "User-Agent", .value = "mine" }},
    });
    const text = f.server.received_text();
    try testing.expect(std.mem.find(u8, text, "user-agent: mine\r\n") != null);
    try testing.expect(std.mem.find(u8, text, "ztest") == null);
}

test "response cookies are captured" {
    var f = try startServer(&.{"HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc; Path=/\r\nContent-Length: 0\r\n\r\n"});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{ .url = try f.server.url(&buffer, "/") });
    try testing.expectEqualStrings("sid", response.cookies[0].name);
    try testing.expectEqualStrings("abc", response.cookies[0].value);
}

test "redirects are followed" {
    var f = try startServer(&.{
        "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        ok_reply,
    });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{ .url = try f.server.url(&buffer, "/start") });
    try testing.expectEqual(200, response.status);
    try testing.expectEqualStrings("hi", response.body);
    try testing.expect(std.mem.startsWith(u8, f.server.received_text(), "GET /next HTTP/1.1\r\n"));
}

test "a redirect limit stops a loop" {
    const loop = "HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n";
    var f = try startServer(&.{ loop, loop });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    try testing.expectError(error.TooManyRedirects, f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .max_redirects = 1,
    }));
}

test "a 307 resends the method and body" {
    var f = try startServer(&.{
        "HTTP/1.1 307 Temporary Redirect\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        ok_reply,
    });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{
        .method = .POST,
        .url = try f.server.url(&buffer, "/"),
        .body = .{ .raw = "payload" },
    });
    try testing.expectEqual(200, response.status);
    const text = f.server.received_text();
    try testing.expect(std.mem.startsWith(u8, text, "POST /next HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, text, "payload"));
}

test "a 303 becomes a GET without the body" {
    var f = try startServer(&.{
        "HTTP/1.1 303 See Other\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        ok_reply,
    });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    _ = try f.send(.{
        .method = .POST,
        .url = try f.server.url(&buffer, "/"),
        .body = .{ .json = "{}" },
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
    const text = f.server.received_text();
    try testing.expect(std.mem.startsWith(u8, text, "GET /next HTTP/1.1\r\n"));
    try testing.expect(std.mem.find(u8, text, "content-type") == null);
    try testing.expect(std.mem.endsWith(u8, text, "\r\n\r\n"));
}

test "zero redirects returns the 3xx response" {
    var f = try startServer(&.{"HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n"});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{ .url = try f.server.url(&buffer, "/"), .max_redirects = 0 });
    try testing.expectEqual(302, response.status);
    try testing.expectEqualStrings("/next", response.header("location").?);
}

test "credentials stop at a redirect to another host" {
    var f = try startServer(&.{ "", ok_reply });
    var reply_buffer: [160]u8 = undefined;
    const redirect = try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 302 Found\r\nLocation: http://localhost:{d}/next\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        .{f.server.port()},
    );
    const replies = [_][]const u8{ redirect, ok_reply };
    f.server.replies = &replies;
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const response = try f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .timeout_ms = 5000,
        .auth = .{ .bearer = "secret-token" },
        .cookies = &.{.{ .name = "sid", .value = "secret-cookie" }},
        .headers = &.{
            .{ .name = "X-Trace", .value = "kept" },
            .{ .name = "Authorization", .value = "Bearer other-secret" },
        },
    });
    try testing.expectEqual(200, response.status);
    const text = f.server.received_text();
    try testing.expect(std.mem.find(u8, text, "X-Trace: kept") != null);
    try testing.expect(std.mem.find(u8, text, "secret") == null);
    try testing.expect(std.mem.find(u8, text, "authorization") == null);
}

test "credentials survive a redirect on the same origin" {
    var f = try startServer(&.{
        "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n",
        ok_reply,
    });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    _ = try f.send(.{ .url = try f.server.url(&buffer, "/"), .auth = .{ .bearer = "token" } });
    try testing.expect(std.mem.find(u8, f.server.received_text(), "Bearer token") != null);
}

test "PUT without a body sends an empty one" {
    var f = try startServer(&.{"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    _ = try f.send(.{ .method = .PUT, .url = try f.server.url(&buffer, "/") });
    try testing.expect(std.mem.find(u8, f.server.received_text(), "content-length: 0\r\n") != null);
}

test "a silent server times out" {
    var f = try startServer(&.{""});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const start: Io.Timestamp = .now(io, .awake);
    try testing.expectError(error.Timeout, f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .timeout_ms = 200,
    }));
    const elapsed_ms = start.untilNow(io, .awake).toMilliseconds();
    try testing.expect(elapsed_ms >= 200 and elapsed_ms < 5000);
}

test "a closed port fails to connect" {
    // Reserves a port, then frees it so that nothing is listening there.
    var server: Server = try .listen(&.{});
    const port = server.port();
    server.listener.deinit(io);

    var client: Client = .init(testing.allocator, io);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{port});
    try testing.expectError(error.ConnectFailed, client.send(arena.allocator(), .{ .url = url }));
}

test "an unknown host fails to connect" {
    // A real .invalid lookup still depends on the machine's resolver (some
    // networks intercept it). Inject only DNS failure; keep the real task/I/O
    // machinery so the client error mapping is tested without external DNS.
    var vtable = io.vtable.*;
    vtable.netLookup = struct {
        fn lookup(_: ?*anyopaque, _: net.HostName, results: *Io.Queue(net.HostName.LookupResult), _: net.HostName.LookupOptions) net.HostName.LookupError!void {
            results.close(io);
            return error.UnknownHostName;
        }
    }.lookup;
    const local_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var client: Client = .init(testing.allocator, local_io);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ConnectFailed, client.send(arena.allocator(), .{
        .url = "http://ztest-host.invalid/",
    }));
}

test "a malformed response is reported" {
    var f = try startServer(&.{"not http at all\r\n\r\n"});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    try testing.expectError(error.MalformedResponse, f.send(.{ .url = try f.server.url(&buffer, "/") }));
}

test "a body over the limit is rejected" {
    var f = try startServer(&.{ok_reply});
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    try testing.expectError(error.ResponseTooLarge, f.send(.{
        .url = try f.server.url(&buffer, "/"),
        .max_response_size = 1,
    }));
}

test "bad requests fail before connecting" {
    var client: Client = .init(testing.allocator, io);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectError(error.InvalidUrl, client.send(allocator, .{ .url = "example.com" }));
    try testing.expectError(error.UnsupportedScheme, client.send(allocator, .{ .url = "ftp://example.com" }));
    try testing.expectError(error.InvalidHeader, client.send(allocator, .{
        .url = "http://127.0.0.1/",
        .headers = &.{.{ .name = "X", .value = "1\r\nEvil: 1" }},
    }));
}

test "a kept-alive connection is reused" {
    var f = try startServer(&.{ ok_reply, ok_reply });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const url = try f.server.url(&buffer, "/");
    _ = try f.send(.{ .url = url });
    _ = try f.send(.{ .url = url });
    try testing.expectEqual(1, f.server.connections);
}

test "a closed connection is replaced" {
    var f = try startServer(&.{ closing_reply, closing_reply });
    try f.start();
    defer f.stop();

    var buffer: [64]u8 = undefined;
    const url = try f.server.url(&buffer, "/");
    _ = try f.send(.{ .url = url });
    _ = try f.send(.{ .url = url });
    try testing.expectEqual(2, f.server.connections);
}
