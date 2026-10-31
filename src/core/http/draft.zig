//! Validates a text request draft and snapshots it into an owned HTTP model.
const std = @import("std");
const model = @import("request.zig");

pub const BodyKind = enum { none, raw, json };
pub const max_headers_size = 32 * 1024;
pub const max_body_size = 256 * 1024;
pub const Draft = struct {
    method: model.Method = .GET,
    url: []const u8,
    headers: []const u8 = "",
    body_kind: BodyKind = .none,
    body: []const u8 = "",
};
pub const Diagnostic = struct { line: usize = 0 };
pub const Error = std.mem.Allocator.Error || error{ InvalidHeader, ManagedHeader, InvalidJson, RequestTooLarge };

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.InvalidHeader => "Use Name: value with a valid header name and no control characters",
        error.ManagedHeader => "Content-Length and Transfer-Encoding are set automatically",
        error.InvalidJson => "The request body is not valid JSON",
        error.RequestTooLarge => "Request exceeds 32 KiB of headers or 256 KiB of body text",
        error.OutOfMemory => "Out of memory while preparing the request",
    };
}

/// All returned slices belong to allocator; use an arena for one request.
/// Validation errors never include the user's header values or body text.
pub fn prepare(allocator: std.mem.Allocator, draft: Draft, diagnostic: *Diagnostic) Error!model.Request {
    diagnostic.* = .{};
    if (draft.headers.len > max_headers_size or (draft.body_kind != .none and draft.body.len > max_body_size)) return error.RequestTooLarge;
    var headers: std.ArrayList(model.Header) = .empty;
    var lines = std.mem.splitScalar(u8, draft.headers, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw, " \t");
        if (line.len == 0) continue;
        diagnostic.line = line_number;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) return error.InvalidHeader;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
        }
        for (value) |byte| {
            if ((byte < 32 and byte != '\t') or byte == 127) return error.InvalidHeader;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.ManagedHeader;
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, value) });
    }
    diagnostic.line = 0;
    if (draft.body_kind == .json and !try std.json.validate(allocator, draft.body)) return error.InvalidJson;
    const body: model.Body = switch (draft.body_kind) {
        .none => .none,
        .raw => .{ .raw = try allocator.dupe(u8, draft.body) },
        .json => .{ .json = try allocator.dupe(u8, draft.body) },
    };
    return .{
        .method = draft.method,
        .url = try allocator.dupe(u8, std.mem.trim(u8, draft.url, " \r\n\t")),
        .headers = headers.items,
        .body = body,
    };
}

const testing = std.testing;

test "text headers preserve duplicates colons and empty values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const request = try prepare(arena.allocator(), .{ .url = " http://localhost/ ", .headers = "X-Tag: one\r\n\r\nX-Tag: two:three\nX-Empty:\n" }, &diagnostic);
    try testing.expectEqualStrings("http://localhost/", request.url);
    try testing.expectEqual(3, request.headers.len);
    try testing.expectEqualStrings("X-Tag", request.headers[0].name);
    try testing.expectEqualStrings("two:three", request.headers[1].value);
    try testing.expectEqualStrings("", request.headers[2].value);
}

test "invalid header diagnostics identify the line without exposing its value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    for ([_][]const u8{ "missing-colon", "Bad Name: secret", "X: secret\rmore", ": secret", "X: secret\x00" }) |bad| {
        const text = try std.fmt.allocPrint(arena.allocator(), "X-Good: yes\r\n{s}", .{bad});
        try testing.expectError(error.InvalidHeader, prepare(arena.allocator(), .{ .url = "http://localhost/", .headers = text }, &diagnostic));
        try testing.expectEqual(2, diagnostic.line);
    }
    try testing.expectError(error.ManagedHeader, prepare(arena.allocator(), .{ .url = "http://localhost/", .headers = "cOnTeNt-LeNgTh: 123" }, &diagnostic));
    try testing.expectError(error.ManagedHeader, prepare(arena.allocator(), .{ .url = "http://localhost/", .headers = "Transfer-Encoding: chunked" }, &diagnostic));
}

test "body modes validate JSON and ignore the retained body draft in None mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.InvalidJson, prepare(arena.allocator(), .{ .url = "http://localhost/", .body_kind = .json, .body = "{]" }, &diagnostic));
    const none = try prepare(arena.allocator(), .{ .url = "http://localhost/", .body = "{]" }, &diagnostic);
    try testing.expect(none.body == .none);
    const raw = try prepare(arena.allocator(), .{ .url = "http://localhost/", .body_kind = .raw, .body = "\r\n{]\r\n" }, &diagnostic);
    try testing.expectEqualStrings("\r\n{]\r\n", raw.body.raw);
}

test "oversized draft text fails before request execution" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const large = try arena.allocator().alloc(u8, max_body_size + 1);
    @memset(large, 'a');
    try testing.expectError(error.RequestTooLarge, prepare(arena.allocator(), .{ .url = "http://localhost/", .body_kind = .raw, .body = large }, &diagnostic));
    try testing.expectError(error.RequestTooLarge, prepare(arena.allocator(), .{ .url = "http://localhost/", .headers = large[0 .. max_headers_size + 1] }, &diagnostic));
}
