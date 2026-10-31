//! Sends requests with `std.http.Client`, adding what it lacks: a timeout, Ctrl-C
//! cancellation, a response-size limit and captured response data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const encoding = @import("request.zig");
const Request = encoding.Request;
const Header = encoding.Header;
const response_model = @import("response.zig");
const Response = response_model.Response;
const shutdown = @import("../shutdown.zig");

/// How often a running request checks for Ctrl-C.
const poll_ms = 50;

pub const Error = Allocator.Error || error{
    InvalidUrl,
    InvalidHeader,
    UnsupportedScheme,
    Timeout,
    Interrupted,
    ConnectFailed,
    TlsFailed,
    TooManyRedirects,
    MalformedResponse,
    ResponseTooLarge,
    RequestFailed,
};

/// A message for the user.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.InvalidUrl => "invalid URL: it must start with http:// or https://",
        error.UnsupportedScheme => "unsupported URL scheme: use http:// or https://",
        error.InvalidHeader => "invalid header: names and values cannot contain line breaks",
        error.Timeout => "request timed out",
        error.Interrupted => "interrupted",
        error.ConnectFailed => "could not connect to the host",
        error.TlsFailed => "TLS failed: the certificate may be invalid or untrusted",
        error.TooManyRedirects => "too many redirects",
        error.MalformedResponse => "the server sent a malformed response",
        error.ResponseTooLarge => "the response is larger than the size limit",
        error.RequestFailed => "the request failed",
    };
}

pub const Client = struct {
    io: Io,
    /// Holds open connections, so reusing a `Client` reuses them.
    inner: http.Client,

    pub fn init(gpa: Allocator, io: Io) Client {
        return .{ .io = io, .inner = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(c: *Client) void {
        c.inner.deinit();
    }

    /// Everything returned is allocated from `arena`. The request runs on its
    /// own task so that it can be cancelled, and blocks the caller until then.
    pub fn send(c: *Client, arena: Allocator, request: Request) Error!Response {
        return c.sendCancelable(arena, request, null);
    }

    /// An optional request-local flag lets a desktop caller cancel without
    /// changing process-wide shutdown state. The caller keeps it alive until return.
    pub fn sendCancelable(c: *Client, arena: Allocator, request: Request, canceled: ?*const std.atomic.Value(bool)) Error!Response {
        if (canceled) |flag| if (flag.load(.acquire)) return error.Interrupted;
        var task: Task = .{ .client = c, .arena = arena, .request = request };
        var future = c.io.concurrent(Task.run, .{&task}) catch return error.RequestFailed;

        const deadline: Io.Timeout = if (request.timeout_ms) |ms|
            (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } }).toDeadline(c.io)
        else
            .none;

        while (true) {
            if (shutdown.isRequested() or (if (canceled) |flag| flag.load(.acquire) else false)) {
                _ = future.cancel(c.io) catch null;
                return error.Interrupted;
            }
            if (deadline.toDurationFromNow(c.io)) |left| if (left.raw.nanoseconds <= 0) {
                _ = future.cancel(c.io) catch null;
                return error.Timeout;
            };
            const poll: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(poll_ms), .clock = .awake } };
            task.done.waitTimeout(c.io, poll) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => {
                    _ = future.cancel(c.io) catch null;
                    return error.Interrupted;
                },
            };
            return future.await(c.io);
        }
    }
};

const Task = struct {
    client: *Client,
    arena: Allocator,
    request: Request,
    done: Io.Event = .unset,

    fn run(task: *Task) Error!Response {
        defer task.done.set(task.client.io);
        return perform(task.client, task.arena, task.request);
    }
};

/// One request on the wire. A redirect can change any of these.
const Hop = struct {
    method: http.Method,
    uri: std.Uri,
    body: encoding.EncodedBody,
    /// False once a redirect has left the origin the caller named.
    credentials: bool = true,
    /// An explicitly supplied content type is retained until a redirect drops it.
    keep_content_type: bool = true,
};

fn perform(c: *Client, arena: Allocator, request: Request) Error!Response {
    const io = c.io;
    const url = try encoding.fullUrl(arena, request);
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (http.Client.Protocol.fromUri(uri) == null) return error.UnsupportedScheme;

    var hop: Hop = .{ .method = request.method, .uri = uri, .body = try encodeBody(io, arena, request.body) };
    var redirects_left = request.max_redirects;
    const start: Io.Timestamp = .now(io, .awake);

    while (true) {
        const options = try buildOptions(arena, request, hop.body, hop.credentials, hop.keep_content_type);
        var http_request = c.inner.request(hop.method, hop.uri, options) catch |err| return mapError(err);
        defer http_request.deinit();

        sendBody(&http_request, hop) catch |err| return mapError(err);
        var response = http_request.receiveHead(&.{}) catch |err| return mapError(err);

        if (request.max_redirects > 0) {
            if (try nextHop(arena, hop, response.head)) |next| {
                if (redirects_left == 0) return error.TooManyRedirects;
                redirects_left -= 1;
                hop = next;
                // Reading the body to its end lets the connection be reused.
                _ = response.reader(&.{}).discardRemaining() catch 0;
                continue;
            }
        }

        // Copied first, because reading the body invalidates the head.
        const status: u16 = @backingInt(response.head.status);
        const status_text = try arena.dupe(u8, response.head.reason);
        const phrase = response.head.status.phrase() orelse "";
        const headers = try copyHeaders(arena, response.head);
        const content_encoding = response.head.content_encoding;

        const data = try readBody(arena, &response, content_encoding, request.max_response_size);
        return .{
            .status = status,
            .status_text = if (status_text.len > 0) status_text else phrase,
            .headers = headers,
            .cookies = try response_model.parseCookies(arena, headers),
            .body = data,
            .duration_ns = @intCast(start.untilNow(io, .awake).toNanoseconds()),
        };
    }
}

fn sendBody(http_request: *http.Client.Request, hop: Hop) !void {
    // Methods that expect a body must declare one, even an empty one.
    const data = hop.body.data orelse if (hop.method.requestHasBody()) "" else return http_request.sendBodiless();
    http_request.transfer_encoding = .{ .content_length = data.len };
    var writer = try http_request.sendBodyUnflushed(&.{});
    try writer.writer.writeAll(data);
    try writer.end();
    try http_request.connection.?.flush();
}

/// Returns where a redirect response leads, or null if `head` is not one.
///
/// `std.http.Client` can follow redirects, but it cannot resend a body and it
/// keeps `Authorization` when redirected to another site, so this does it.
fn nextHop(arena: Allocator, hop: Hop, head: http.Client.Response.Head) Error!?Hop {
    const location = head.location orelse return null;
    var next = hop;
    switch (head.status) {
        .see_other => next.method = if (hop.method == .HEAD) .HEAD else .GET,
        .moved_permanently, .found => if (hop.method == .POST) {
            next.method = .GET;
        },
        .temporary_redirect, .permanent_redirect => {},
        else => return null,
    }
    if (next.method != hop.method) {
        next.body = .{};
        next.keep_content_type = false;
    }

    // The resolved URI points into this buffer, so it needs room for a merged path.
    const buffer = try arena.alloc(u8, location.len + hop.uri.path.percent_encoded.len + 2);
    @memcpy(buffer[0..location.len], location);
    var aux = buffer;
    next.uri = hop.uri.resolveInPlace(location.len, &aux) catch return error.MalformedResponse;
    next.credentials = hop.credentials and sameOrigin(hop.uri, next.uri);
    return next;
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    var a_buffer: [Io.net.HostName.max_len]u8 = undefined;
    var b_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const a_host = Io.net.HostName.fromUri(a, &a_buffer) catch return false;
    const b_host = Io.net.HostName.fromUri(b, &b_buffer) catch return false;
    const a_protocol = http.Client.Protocol.fromUri(a) orelse return false;
    const b_protocol = http.Client.Protocol.fromUri(b) orelse return false;
    return a_protocol == b_protocol and uriPort(a, a_protocol) == uriPort(b, b_protocol) and
        std.ascii.eqlIgnoreCase(a_host.bytes, b_host.bytes);
}

fn uriPort(uri: std.Uri, protocol: http.Client.Protocol) u16 {
    return uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

fn encodeBody(io: Io, arena: Allocator, body: encoding.Body) Error!encoding.EncodedBody {
    var bytes: [16]u8 = undefined;
    var boundary: []const u8 = "";
    if (body == .multipart) while (true) {
        io.random(&bytes);
        boundary = try std.fmt.allocPrint(arena, "ztest{x}", .{&bytes});
        if (encoding.boundaryFits(body.multipart, boundary)) break;
    };
    return encoding.encodeBody(arena, body, boundary);
}

/// Sorts headers into the ones `std.http.Client` writes itself and the rest.
/// Without `credentials`, anything that identifies the user is left out.
fn buildOptions(
    arena: Allocator,
    request: Request,
    body: encoding.EncodedBody,
    credentials: bool,
    keep_content_type: bool,
) Error!http.Client.RequestOptions {
    var options: http.Client.RequestOptions = .{ .redirect_behavior = .unhandled };
    // Compressed replies are still decoded, for a user who sends this header.
    options.headers.accept_encoding = .omit;
    options.headers.user_agent = .{ .override = "ztest" };
    options.headers.authorization = .omit;
    if (body.content_type) |content_type| options.headers.content_type = .{ .override = content_type };

    var extra: std.ArrayList(Header) = .empty;

    if (credentials) {
        switch (request.auth) {
            .none, .api_key_query => {},
            .basic => |basic| {
                const value = try basicValue(arena, basic.user, basic.password);
                options.headers.authorization = .{ .override = value };
            },
            .bearer => |token| {
                try encoding.checkHeaderText(token);
                const value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
                options.headers.authorization = .{ .override = value };
            },
            .api_key_header => |key| {
                try encoding.checkHeader(key);
                try extra.append(arena, key);
            },
        }
        if (try encoding.cookieHeader(arena, request.cookies)) |cookie| {
            try extra.append(arena, .{ .name = "Cookie", .value = cookie });
        }
    }

    for (request.headers) |header| {
        try encoding.checkHeader(header);
        const override: http.Client.Request.Headers.Value = .{ .override = header.value };
        if (eql(header.name, "user-agent")) {
            options.headers.user_agent = override;
        } else if (eql(header.name, "connection")) {
            options.headers.connection = override;
        } else if (eql(header.name, "accept-encoding")) {
            options.headers.accept_encoding = override;
        } else if (eql(header.name, "content-type")) {
            // A body dropped by a redirect takes its content type with it.
            if (keep_content_type) options.headers.content_type = override;
        } else if (eql(header.name, "host")) {
            if (credentials) options.headers.host = override;
        } else if (eql(header.name, "authorization")) {
            if (credentials) options.headers.authorization = override;
        } else if (eql(header.name, "cookie") or eql(header.name, "proxy-authorization")) {
            if (credentials) try extra.append(arena, header);
        } else {
            try extra.append(arena, header);
        }
    }

    options.extra_headers = extra.items;
    return options;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn basicValue(arena: Allocator, user: []const u8, password: []const u8) Allocator.Error![]const u8 {
    const pair = try std.fmt.allocPrint(arena, "{s}:{s}", .{ user, password });
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(pair.len));
    return std.fmt.allocPrint(arena, "Basic {s}", .{encoder.encode(out, pair)});
}

fn copyHeaders(arena: Allocator, head: http.Client.Response.Head) Allocator.Error![]const Header {
    var headers: std.ArrayList(Header) = .empty;
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        try headers.append(arena, .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        });
    }
    return headers.items;
}

fn readBody(
    arena: Allocator,
    response: *http.Client.Response,
    content_encoding: http.ContentEncoding,
    max_size: usize,
) Error![]const u8 {
    const window: []u8 = switch (content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.MalformedResponse,
    };
    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, window);

    return reader.allocRemaining(arena, .limited(max_size)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.StreamTooLong => error.ResponseTooLarge,
        error.ReadFailed => if (response.bodyErr()) |body_err| mapError(body_err) else error.MalformedResponse,
    };
}

/// Reduces the many `std.http` errors to the few a user can act on.
fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Interrupted,
        error.Timeout => error.Timeout,
        error.UnsupportedUriScheme => error.UnsupportedScheme,
        error.UriMissingHost, error.InvalidHostName => error.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.TlsFailed,
        error.TooManyHttpRedirects => error.TooManyRedirects,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.UnknownHostName,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.NoAddressReturned,
        => error.ConnectFailed,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpContentEncodingUnsupported,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.EndOfStream,
        => error.MalformedResponse,
        else => error.RequestFailed,
    };
}
