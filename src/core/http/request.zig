//! What to send. Plain data with no I/O, so every encoding can be unit tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Method = std.http.Method;
pub const Header = std.http.Header;

/// A name and value in a query string, form or cookie.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Part = struct {
    name: []const u8,
    value: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub const Body = union(enum) {
    none,
    raw: []const u8,
    json: []const u8,
    form: []const Param,
    multipart: []const Part,
};

pub const Auth = union(enum) {
    none,
    basic: struct { user: []const u8, password: []const u8 },
    bearer: []const u8,
    api_key_header: Header,
    api_key_query: Param,
};

/// Used when the user names no time limit.
pub const default_timeout_ms = 30_000;

pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    query: []const Param = &.{},
    headers: []const Header = &.{},
    cookies: []const Param = &.{},
    body: Body = .none,
    auth: Auth = .none,
    /// Covers the whole exchange, including redirects. Null waits forever.
    timeout_ms: ?u64 = null,
    /// Zero returns the 3xx response instead of following it. Credentials are
    /// dropped when a redirect changes the scheme, host or port.
    max_redirects: u16 = 5,
    max_response_size: usize = 64 * 1024 * 1024,
};

pub const EncodeError = Allocator.Error || error{InvalidHeader};

/// Returns `url` with `query` and any API key added, without its fragment.
/// Allocations are not freed individually, so pass an arena.
pub fn fullUrl(arena: Allocator, request: Request) Allocator.Error![]const u8 {
    const fragment = std.mem.findScalar(u8, request.url, '#') orelse request.url.len;
    const base = request.url[0..fragment];

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var has_query = std.mem.findScalar(u8, base, '?') != null;
    w.writeAll(base) catch return error.OutOfMemory;

    var params: std.ArrayList(Param) = .empty;
    try params.appendSlice(arena, request.query);
    if (request.auth == .api_key_query) try params.append(arena, request.auth.api_key_query);

    for (params.items) |param| {
        w.writeByte(if (has_query) '&' else '?') catch return error.OutOfMemory;
        has_query = true;
        writeParam(w, param, "%20") catch return error.OutOfMemory;
    }
    return out.written();
}

/// Returns the `Cookie` header value, or null without cookies.
pub fn cookieHeader(arena: Allocator, cookies: []const Param) EncodeError!?[]const u8 {
    if (cookies.len == 0) return null;
    var out: Io.Writer.Allocating = .init(arena);
    for (cookies, 0..) |cookie, i| {
        for ([_][]const u8{ cookie.name, cookie.value }) |text| try checkHeaderText(text);
        if (std.mem.findScalar(u8, cookie.value, ';') != null) return error.InvalidHeader;
        out.writer.print("{s}{s}={s}", .{ if (i == 0) "" else "; ", cookie.name, cookie.value }) catch
            return error.OutOfMemory;
    }
    return out.written();
}

pub const EncodedBody = struct {
    /// Null when the request has no body.
    data: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

/// `boundary` separates multipart parts and must not occur in them.
pub fn encodeBody(arena: Allocator, body: Body, boundary: []const u8) EncodeError!EncodedBody {
    return switch (body) {
        .none => .{},
        .raw => |data| .{ .data = data },
        .json => |data| .{ .data = data, .content_type = "application/json" },
        .form => |fields| .{
            .data = try encodeForm(arena, fields),
            .content_type = "application/x-www-form-urlencoded",
        },
        .multipart => |parts| .{
            .data = try encodeMultipart(arena, parts, boundary),
            .content_type = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary}),
        },
    };
}

/// True when `boundary` is safe to use for `parts`.
pub fn boundaryFits(parts: []const Part, boundary: []const u8) bool {
    for (parts) |part| {
        if (std.mem.find(u8, part.value, boundary) != null) return false;
    }
    return true;
}

fn encodeForm(arena: Allocator, fields: []const Param) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    for (fields, 0..) |field, i| {
        if (i > 0) out.writer.writeByte('&') catch return error.OutOfMemory;
        writeParam(&out.writer, field, "+") catch return error.OutOfMemory;
    }
    return out.written();
}

fn encodeMultipart(arena: Allocator, parts: []const Part, boundary: []const u8) EncodeError![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeMultipart(w, parts, boundary) catch |err| switch (err) {
        error.InvalidHeader => |e| return e,
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.written();
}

fn writeMultipart(w: *Io.Writer, parts: []const Part, boundary: []const u8) !void {
    for (parts) |part| {
        try w.print("--{s}\r\nContent-Disposition: form-data; name=\"", .{boundary});
        try writeQuoted(w, part.name);
        try w.writeByte('"');
        if (part.filename) |filename| {
            try w.writeAll("; filename=\"");
            try writeQuoted(w, filename);
            try w.writeByte('"');
        }
        try w.writeAll("\r\n");
        if (part.content_type) |content_type| {
            try checkHeaderText(content_type);
            try w.print("Content-Type: {s}\r\n", .{content_type});
        }
        try w.print("\r\n{s}\r\n", .{part.value});
    }
    try w.print("--{s}--\r\n", .{boundary});
}

/// The escaping browsers use for multipart names, so a name cannot end its
/// header early.
fn writeQuoted(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '"' => try w.writeAll("%22"),
        '\r' => try w.writeAll("%0D"),
        '\n' => try w.writeAll("%0A"),
        else => try w.writeByte(c),
    };
}

fn writeParam(w: *Io.Writer, param: Param, space: []const u8) Io.Writer.Error!void {
    try writeEncoded(w, param.name, space);
    try w.writeByte('=');
    try writeEncoded(w, param.value, space);
}

/// Percent-encodes everything outside the RFC 3986 unreserved set.
fn writeEncoded(w: *Io.Writer, text: []const u8, space: []const u8) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        ' ' => try w.writeAll(space),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

/// Rejects line breaks, which would let a value smuggle in another header.
pub fn checkHeaderText(text: []const u8) error{InvalidHeader}!void {
    if (std.mem.findAny(u8, text, "\r\n\x00") != null) return error.InvalidHeader;
}

pub fn checkHeader(header: Header) error{InvalidHeader}!void {
    if (header.name.len == 0 or std.mem.findScalar(u8, header.name, ':') != null) return error.InvalidHeader;
    try checkHeaderText(header.name);
    try checkHeaderText(header.value);
}

const testing = std.testing;

const TestArena = struct {
    state: std.heap.ArenaAllocator = .init(testing.allocator),

    fn deinit(a: *TestArena) void {
        a.state.deinit();
    }
};

test "fullUrl encodes query values and drops the fragment" {
    var arena: TestArena = .{};
    defer arena.deinit();

    const url = try fullUrl(arena.state.allocator(), .{
        .url = "https://example.com/a#top",
        .query = &.{ .{ .name = "q", .value = "a b&c" }, .{ .name = "n", .value = "1" } },
    });
    try testing.expectEqualStrings("https://example.com/a?q=a%20b%26c&n=1", url);
}

test "fullUrl extends an existing query and adds an API key" {
    var arena: TestArena = .{};
    defer arena.deinit();

    const url = try fullUrl(arena.state.allocator(), .{
        .url = "http://example.com/a?x=1",
        .auth = .{ .api_key_query = .{ .name = "key", .value = "s3" } },
    });
    try testing.expectEqualStrings("http://example.com/a?x=1&key=s3", url);
}

test "cookies join into one header and reject smuggling" {
    var arena: TestArena = .{};
    defer arena.deinit();
    const allocator = arena.state.allocator();

    try testing.expectEqual(null, try cookieHeader(allocator, &.{}));
    const value = try cookieHeader(allocator, &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "2" } });
    try testing.expectEqualStrings("a=1; b=2", value.?);

    const bad: []const Param = &.{.{ .name = "a", .value = "1; admin=1" }};
    try testing.expectError(error.InvalidHeader, cookieHeader(allocator, bad));
}

test "bodies set their content type" {
    var arena: TestArena = .{};
    defer arena.deinit();
    const allocator = arena.state.allocator();

    try testing.expectEqual(EncodedBody{}, try encodeBody(allocator, .none, ""));

    const raw = try encodeBody(allocator, .{ .raw = "text" }, "");
    try testing.expectEqualStrings("text", raw.data.?);
    try testing.expectEqual(null, raw.content_type);

    const json = try encodeBody(allocator, .{ .json = "{}" }, "");
    try testing.expectEqualStrings("application/json", json.content_type.?);

    const form = try encodeBody(allocator, .{ .form = &.{
        .{ .name = "full name", .value = "a&b" },
        .{ .name = "n", .value = "1" },
    } }, "");
    try testing.expectEqualStrings("full+name=a%26b&n=1", form.data.?);
}

test "multipart writes each part and escapes names" {
    var arena: TestArena = .{};
    defer arena.deinit();

    const encoded = try encodeBody(arena.state.allocator(), .{ .multipart = &.{
        .{ .name = "a\"b", .value = "1" },
        .{ .name = "f", .value = "data", .filename = "x.txt", .content_type = "text/plain" },
    } }, "BOUND");
    try testing.expectEqualStrings("multipart/form-data; boundary=BOUND", encoded.content_type.?);
    try testing.expectEqualStrings(
        "--BOUND\r\nContent-Disposition: form-data; name=\"a%22b\"\r\n\r\n1\r\n" ++
            "--BOUND\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\n" ++
            "Content-Type: text/plain\r\n\r\ndata\r\n--BOUND--\r\n",
        encoded.data.?,
    );
}

test "boundaryFits rejects a boundary found in the data" {
    const parts: []const Part = &.{.{ .name = "a", .value = "xxBOUNDxx" }};
    try testing.expect(!boundaryFits(parts, "BOUND"));
    try testing.expect(boundaryFits(parts, "OTHER"));
}

test "checkHeader rejects injection and bad names" {
    try checkHeader(.{ .name = "X-Id", .value = "1:2" });
    try testing.expectError(error.InvalidHeader, checkHeader(.{ .name = "X", .value = "1\r\nEvil: 1" }));
    try testing.expectError(error.InvalidHeader, checkHeader(.{ .name = "", .value = "1" }));
    try testing.expectError(error.InvalidHeader, checkHeader(.{ .name = "a:b", .value = "1" }));
}
