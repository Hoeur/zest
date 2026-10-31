//! What came back. Every slice is owned by the arena passed to `Client.send`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const request = @import("request.zig");
const Header = request.Header;
const Param = request.Param;

pub const Response = struct {
    status: u16,
    /// The server's reason phrase, or the standard one if it sent none.
    status_text: []const u8,
    headers: []const Header,
    cookies: []const Param,
    body: []const u8,
    duration_ns: u64,

    /// The size of the body after decompression.
    pub fn size(r: Response) usize {
        return r.body.len;
    }

    /// The first header called `name`, ignoring case.
    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

/// Reads the name and value of each `Set-Cookie` header, ignoring attributes.
pub fn parseCookies(arena: Allocator, headers: []const Header) Allocator.Error![]const Param {
    var cookies: std.ArrayList(Param) = .empty;
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        const end = std.mem.findScalar(u8, h.value, ';') orelse h.value.len;
        const pair = h.value[0..end];
        const equals = std.mem.findScalar(u8, pair, '=') orelse continue;
        try cookies.append(arena, .{
            .name = std.mem.trim(u8, pair[0..equals], " "),
            .value = std.mem.trim(u8, pair[equals + 1 ..], " "),
        });
    }
    return cookies.items;
}

const testing = std.testing;

test "parseCookies keeps the pair and skips other headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cookies = try parseCookies(arena.allocator(), &.{
        .{ .name = "Set-Cookie", .value = "sid=abc; Path=/; HttpOnly" },
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "set-cookie", .value = "theme=dark" },
        .{ .name = "set-cookie", .value = "broken" },
    });
    try testing.expectEqual(2, cookies.len);
    try testing.expectEqualStrings("sid", cookies[0].name);
    try testing.expectEqualStrings("abc", cookies[0].value);
    try testing.expectEqualStrings("dark", cookies[1].value);
}

test "header lookup ignores case" {
    const response: Response = .{
        .status = 200,
        .status_text = "OK",
        .headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
        .cookies = &.{},
        .body = "hi",
        .duration_ns = 0,
    };
    try testing.expectEqualStrings("text/plain", response.header("content-type").?);
    try testing.expectEqual(null, response.header("etag"));
    try testing.expectEqual(2, response.size());
}
