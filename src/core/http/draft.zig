//! Validates a text request draft from the desktop app and snapshots it into an
//! owned HTTP model. Also converts a draft to and from a `.ztest` case, so a
//! request can be saved and reopened.
//!
//! Headers, query parameters and assertions are edited as text, one per line.
//! A line that starts with `#` is switched off: it is kept in the editor but not
//! sent, checked or saved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("request.zig");
const assertion = @import("../assertions/assertion.zig");
const ast = @import("../parser/ast.zig");
const variables = @import("../runner/variables.zig");

pub const BodyKind = enum { none, raw, json };
pub const max_headers_size = 32 * 1024;
pub const max_params_size = 32 * 1024;
pub const max_assertions_size = 32 * 1024;
pub const max_body_size = 256 * 1024;

pub const AuthKind = enum {
    none,
    basic,
    bearer,
    api_key_header,
    api_key_query,

    pub fn label(kind: AuthKind) []const u8 {
        return switch (kind) {
            .none => "No Auth",
            .basic => "Basic Auth",
            .bearer => "Bearer Token",
            .api_key_header => "API Key (header)",
            .api_key_query => "API Key (query)",
        };
    }

    /// What the two fields hold, or null for a field the kind does not use.
    pub fn fields(kind: AuthKind) [2]?[]const u8 {
        return switch (kind) {
            .none => .{ null, null },
            .basic => .{ "Username", "Password" },
            .bearer => .{ null, "Token" },
            .api_key_header => .{ "Header name", "Key" },
            .api_key_query => .{ "Parameter name", "Key" },
        };
    }
};

/// `name` is the user, header or parameter name; `value` is the password,
/// token or key. Both may hold `{{variables}}`.
pub const AuthDraft = struct {
    kind: AuthKind = .none,
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const Draft = struct {
    method: model.Method = .GET,
    url: []const u8,
    /// One `Name: value` per line.
    headers: []const u8 = "",
    /// One `name=value` per line.
    params: []const u8 = "",
    auth: AuthDraft = .{},
    body_kind: BodyKind = .none,
    body: []const u8 = "",
    /// One assertion per line, as `expect` takes it, such as `status == 200`.
    assertions: []const u8 = "",
    /// Values for `{{name}}`, lowest priority first, so a later name wins.
    variables: []const ast.Variable = &.{},
};

/// Which editor a problem is in, and on which line.
pub const Field = enum { none, url, headers, params, auth, body, assertions };

pub const Diagnostic = struct {
    line: usize = 0,
    field: Field = .none,
    /// The undefined name for `error.MissingVariable`, or why an assertion is
    /// invalid. Never holds the user's header values or body text.
    detail: []const u8 = "",
};

pub const Error = Allocator.Error || error{
    InvalidHeader,
    ManagedHeader,
    InvalidParam,
    InvalidAuth,
    InvalidAssertion,
    InvalidJson,
    MissingVariable,
    RequestTooLarge,
};

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.InvalidHeader => "Use Name: value with a valid header name and no control characters",
        error.ManagedHeader => "Content-Length and Transfer-Encoding are set automatically",
        error.InvalidParam => "Use name=value with a name and no control characters",
        error.InvalidAuth => "Fill in every authentication field, without line breaks",
        error.InvalidAssertion => "This assertion is not valid",
        error.InvalidJson => "The request body is not valid JSON",
        error.MissingVariable => "A variable is not defined",
        error.RequestTooLarge => "Request exceeds 32 KiB of headers, parameters or assertions, or 256 KiB of body text",
        error.OutOfMemory => "Out of memory while preparing the request",
    };
}

/// One message for the user, such as `Header line 2: Use Name: value ...`.
/// Never includes header values, parameter values or body text.
pub fn message(allocator: Allocator, err: Error, diagnostic: Diagnostic) Allocator.Error![]const u8 {
    if (err == error.MissingVariable) return std.fmt.allocPrint(allocator, "{{{{{s}}}}} is not defined. Add it to ztest.json or choose an environment.", .{diagnostic.detail});
    const what: []const u8 = switch (diagnostic.field) {
        .headers => "Header",
        .params => "Parameter",
        .assertions => "Assertion",
        else => "",
    };
    const text = if (err == error.InvalidAssertion and diagnostic.detail.len > 0) diagnostic.detail else describe(err);
    if (diagnostic.line > 0 and what.len > 0) return std.fmt.allocPrint(allocator, "{s} line {d}: {s}", .{ what, diagnostic.line, text });
    return allocator.dupe(u8, text);
}

pub const Prepared = struct {
    request: model.Request,
    assertions: []const assertion.Assertion,
    /// Values of secret variables, to hide wherever results are shown.
    secrets: []const []const u8,
};

/// Kept for callers that only send. See `prepareAll`.
pub fn prepare(allocator: Allocator, draft: Draft, diagnostic: *Diagnostic) Error!model.Request {
    return (try prepareAll(allocator, draft, diagnostic)).request;
}

/// All returned slices belong to allocator; use an arena for one request.
/// Variables are replaced first, so every check sees the text that is sent.
pub fn prepareAll(allocator: Allocator, draft: Draft, diagnostic: *Diagnostic) Error!Prepared {
    diagnostic.* = .{};
    try checkSizes(draft);
    var filler: Filler = .{ .allocator = allocator, .variables = draft.variables, .diagnostic = diagnostic };

    filler.field = .headers;
    var headers: std.ArrayList(model.Header) = .empty;
    var header_lines = Lines.init(draft.headers);
    while (header_lines.next()) |line| {
        diagnostic.* = .{ .line = header_lines.number, .field = .headers };
        const header = try parseHeaderLine(line.text);
        const name = try filler.fill(header.name);
        const value = try filler.fill(header.value);
        try checkHeaderName(name);
        try checkValue(value, error.InvalidHeader);
        if (std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.ManagedHeader;
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, value) });
    }

    filler.field = .params;
    var query: std.ArrayList(model.Param) = .empty;
    var param_lines = Lines.init(draft.params);
    while (param_lines.next()) |line| {
        diagnostic.* = .{ .line = param_lines.number, .field = .params };
        const param = try parseParamLine(line.text);
        const name = try filler.fill(param.name);
        const value = try filler.fill(param.value);
        try checkValue(name, error.InvalidParam);
        try checkValue(value, error.InvalidParam);
        try query.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, value) });
    }
    diagnostic.line = 0;

    filler.field = .auth;
    diagnostic.* = .{ .field = .auth };
    const auth = try buildAuth(&filler, draft.auth);

    filler.field = .body;
    diagnostic.* = .{ .field = .body };
    const body: model.Body = switch (draft.body_kind) {
        .none => .none,
        .raw => .{ .raw = try allocator.dupe(u8, try filler.fill(draft.body)) },
        .json => blk: {
            const text = try filler.fill(draft.body);
            if (!try std.json.validate(allocator, text)) return error.InvalidJson;
            break :blk .{ .json = try allocator.dupe(u8, text) };
        },
    };

    filler.field = .assertions;
    var assertions: std.ArrayList(assertion.Assertion) = .empty;
    var assertion_lines = Lines.init(draft.assertions);
    while (assertion_lines.next()) |line| {
        diagnostic.* = .{ .line = assertion_lines.number, .field = .assertions };
        var parsed = try parseAssertion(allocator, line.text, diagnostic);
        if (parsed.expected == .string) parsed.expected = .{ .string = try allocator.dupe(u8, try filler.fill(parsed.expected.string)) };
        try assertions.append(allocator, parsed);
    }
    diagnostic.line = 0;

    filler.field = .url;
    const url = try filler.fill(std.mem.trim(u8, draft.url, " \r\n\t"));

    var secrets: std.ArrayList([]const u8) = .empty;
    for (draft.variables) |variable| {
        if (variable.secret and variable.value.len > 0) try secrets.append(allocator, try allocator.dupe(u8, variable.value));
    }
    diagnostic.* = .{};
    return .{
        .request = .{
            .method = draft.method,
            .url = try allocator.dupe(u8, url),
            .headers = headers.items,
            .query = query.items,
            .auth = auth,
            .body = body,
        },
        .assertions = assertions.items,
        .secrets = secrets.items,
    };
}

fn checkSizes(draft: Draft) Error!void {
    if (draft.headers.len > max_headers_size or draft.params.len > max_params_size or
        draft.assertions.len > max_assertions_size or
        (draft.body_kind != .none and draft.body.len > max_body_size))
    {
        return error.RequestTooLarge;
    }
}

const Filler = struct {
    allocator: Allocator,
    variables: []const ast.Variable,
    diagnostic: *Diagnostic,
    field: Field = .none,

    fn fill(f: *Filler, text: []const u8) Error![]const u8 {
        f.diagnostic.field = f.field;
        const runtime: variables.Runtime = .empty;
        const scope: variables.Scope = .{ .runtime = &runtime, .case = &.{}, .suite = &.{}, .base = f.variables };
        var missing: []const u8 = "";
        return variables.interpolate(f.allocator, text, scope, &missing) catch |err| switch (err) {
            error.OutOfMemory => |e| e,
            error.MissingVariable => {
                f.diagnostic.detail = missing;
                return error.MissingVariable;
            },
        };
    }
};

fn buildAuth(filler: *Filler, auth: AuthDraft) Error!model.Auth {
    const fields = auth.kind.fields();
    if (fields[0] != null) try checkAuthPart(auth.name);
    if (fields[1] != null) try checkAuthPart(auth.value);
    const a = filler.allocator;
    return switch (auth.kind) {
        .none => .none,
        .bearer => .{ .bearer = try a.dupe(u8, try filler.fill(auth.value)) },
        .basic => .{ .basic = .{ .user = try a.dupe(u8, try filler.fill(auth.name)), .password = try a.dupe(u8, try filler.fill(auth.value)) } },
        .api_key_header => blk: {
            const name = try filler.fill(auth.name);
            checkHeaderName(name) catch return error.InvalidAuth;
            break :blk .{ .api_key_header = .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, try filler.fill(auth.value)) } };
        },
        .api_key_query => .{ .api_key_query = .{ .name = try a.dupe(u8, try filler.fill(auth.name)), .value = try a.dupe(u8, try filler.fill(auth.value)) } },
    };
}

fn checkAuthPart(text: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidAuth;
    checkValue(text, error.InvalidAuth) catch return error.InvalidAuth;
}

fn parseAssertion(allocator: Allocator, text: []const u8, diagnostic: *Diagnostic) Error!assertion.Assertion {
    const owned = try allocator.dupe(u8, text);
    return assertion.parse(allocator, owned) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => {
            diagnostic.detail = assertion.describe(err);
            return error.InvalidAssertion;
        },
    };
}

/// Enabled, non-blank lines with their 1-based numbers.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,

    const Line = struct { text: []const u8 };

    fn init(text: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(l: *Lines) ?Line {
        while (l.it.next()) |raw| {
            l.number += 1;
            const text = std.mem.trim(u8, if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw, " \t");
            if (text.len == 0 or text[0] == '#') continue;
            return .{ .text = text };
        }
        return null;
    }
};

fn parseHeaderLine(line: []const u8) Error!model.Header {
    const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidHeader;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    if (name.len == 0) return error.InvalidHeader;
    return .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
}

fn parseParamLine(line: []const u8) Error!model.Param {
    const equals = std.mem.findScalar(u8, line, '=') orelse line.len;
    const name = std.mem.trim(u8, line[0..equals], " \t");
    if (name.len == 0) return error.InvalidParam;
    const value = if (equals < line.len) std.mem.trim(u8, line[equals + 1 ..], " \t") else "";
    return .{ .name = name, .value = value };
}

fn checkHeaderName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
    }
}

fn checkValue(value: []const u8, comptime err: Error) Error!void {
    for (value) |byte| {
        if ((byte < 32 and byte != '\t') or byte == 127) return err;
    }
}

// Saving and opening --------------------------------------------------------

/// A case for the `.ztest` writer, from raw editor text: `{{variables}}` stay
/// as written. Switched-off lines are not included.
pub fn toCase(allocator: Allocator, draft: Draft, name: []const u8, diagnostic: *Diagnostic) Error!ast.Case {
    diagnostic.* = .{};
    try checkSizes(draft);
    var headers: std.ArrayList(model.Header) = .empty;
    var header_lines = Lines.init(draft.headers);
    diagnostic.field = .headers;
    while (header_lines.next()) |line| {
        diagnostic.line = header_lines.number;
        const header = try parseHeaderLine(line.text);
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) });
    }
    var query: std.ArrayList(model.Param) = .empty;
    var param_lines = Lines.init(draft.params);
    diagnostic.field = .params;
    while (param_lines.next()) |line| {
        diagnostic.line = param_lines.number;
        const param = try parseParamLine(line.text);
        try query.append(allocator, .{ .name = try allocator.dupe(u8, param.name), .value = try allocator.dupe(u8, param.value) });
    }
    var expects: std.ArrayList(ast.Expect) = .empty;
    var assertion_lines = Lines.init(draft.assertions);
    diagnostic.field = .assertions;
    while (assertion_lines.next()) |line| {
        diagnostic.line = assertion_lines.number;
        try expects.append(allocator, .{ .assertion = try parseAssertion(allocator, line.text, diagnostic), .line = 0 });
    }
    diagnostic.* = .{ .field = .auth };
    const fields = draft.auth.kind.fields();
    if (fields[0] != null) try checkAuthPart(draft.auth.name);
    if (fields[1] != null) try checkAuthPart(draft.auth.value);
    const name_part = try allocator.dupe(u8, std.mem.trim(u8, draft.auth.name, " \t"));
    const value_part = try allocator.dupe(u8, std.mem.trim(u8, draft.auth.value, " \t"));
    const auth: model.Auth = switch (draft.auth.kind) {
        .none => .none,
        .bearer => .{ .bearer = value_part },
        .basic => .{ .basic = .{ .user = name_part, .password = value_part } },
        .api_key_header => .{ .api_key_header = .{ .name = name_part, .value = value_part } },
        .api_key_query => .{ .api_key_query = .{ .name = name_part, .value = value_part } },
    };
    diagnostic.* = .{ .field = .body };
    const body: ast.Body = switch (draft.body_kind) {
        .none => .none,
        .raw => .{ .raw = try allocator.dupe(u8, draft.body) },
        // Variables may make JSON invalid until they are replaced, as in a file.
        .json => .{ .json = try allocator.dupe(u8, std.mem.trim(u8, draft.body, " \t\r\n")) },
    };
    diagnostic.* = .{};
    return .{
        .name = try allocator.dupe(u8, name),
        .line = 0,
        .variables = &.{},
        .request = .{
            .method = draft.method,
            .url = try allocator.dupe(u8, std.mem.trim(u8, draft.url, " \t\r\n")),
            .headers = headers.items,
            .query = query.items,
            .auth = auth,
            .body = body,
            .line = 0,
        },
        .expects = expects.items,
        .extracts = &.{},
    };
}

/// Editor text for `case`, with Windows line endings for the native editors.
/// `variables` is left empty: the caller decides which values apply.
pub fn fromCase(allocator: Allocator, case: ast.Case) Allocator.Error!Draft {
    var headers: std.Io.Writer.Allocating = .init(allocator);
    for (case.request.headers) |h| headers.writer.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.OutOfMemory;
    var params: std.Io.Writer.Allocating = .init(allocator);
    for (case.request.query) |p| params.writer.print("{s}={s}\r\n", .{ p.name, p.value }) catch return error.OutOfMemory;
    var expects: std.Io.Writer.Allocating = .init(allocator);
    for (case.expects) |e| expects.writer.print("{s}\r\n", .{e.assertion.text}) catch return error.OutOfMemory;
    const auth: AuthDraft = switch (case.request.auth) {
        .none => .{},
        .bearer => |token| .{ .kind = .bearer, .value = token },
        .basic => |b| .{ .kind = .basic, .name = b.user, .value = b.password },
        .api_key_header => |h| .{ .kind = .api_key_header, .name = h.name, .value = h.value },
        .api_key_query => |p| .{ .kind = .api_key_query, .name = p.name, .value = p.value },
    };
    const body_kind: BodyKind, const body: []const u8 = switch (case.request.body) {
        .none => .{ .none, "" },
        .raw => |text| .{ .raw, try crlf(allocator, text) },
        .json => |text| .{ .json, try crlf(allocator, text) },
    };
    return .{
        .method = case.request.method,
        .url = case.request.url,
        .headers = headers.written(),
        .params = params.written(),
        .auth = auth,
        .body_kind = body_kind,
        .body = body,
        .assertions = expects.written(),
    };
}

fn crlf(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text, 0..) |c, i| {
        if (c == '\n' and (i == 0 or text[i - 1] != '\r')) try out.append(allocator, '\r');
        try out.append(allocator, c);
    }
    return out.items;
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
        try testing.expectEqual(Field.headers, diagnostic.field);
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

test "lines starting with # are switched off" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const prepared = try prepareAll(arena.allocator(), .{
        .url = "http://localhost/",
        .headers = "# X-Off: 1\r\nX-On: 2",
        .params = "#off=1\r\non=2\r\nflag",
        .assertions = "# status == 500\r\nstatus == 200",
    }, &diagnostic);
    try testing.expectEqual(1, prepared.request.headers.len);
    try testing.expectEqualStrings("X-On", prepared.request.headers[0].name);
    try testing.expectEqual(2, prepared.request.query.len);
    try testing.expectEqualStrings("flag", prepared.request.query[1].name);
    try testing.expectEqualStrings("", prepared.request.query[1].value);
    try testing.expectEqual(1, prepared.assertions.len);
}

test "variables fill every part, later values win, and secrets are listed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const prepared = try prepareAll(arena.allocator(), .{
        .method = .POST,
        .url = "{{base}}/users",
        .headers = "X-Env: {{env}}",
        .params = "page={{page}}",
        .auth = .{ .kind = .bearer, .value = "{{token}}" },
        .body_kind = .json,
        .body = "{\"id\": {{page}}}",
        .assertions = "body.env == \"{{env}}\"",
        .variables = &.{
            .{ .name = "base", .value = "http://global", .line = 0 },
            .{ .name = "env", .value = "dev", .line = 0 },
            .{ .name = "base", .value = "http://staging", .line = 0 },
            .{ .name = "page", .value = "3", .line = 0 },
            .{ .name = "token", .value = "t0k", .line = 0, .secret = true },
        },
    }, &diagnostic);
    const r = prepared.request;
    try testing.expectEqualStrings("http://staging/users", r.url);
    try testing.expectEqualStrings("dev", r.headers[0].value);
    try testing.expectEqualStrings("3", r.query[0].value);
    try testing.expectEqualStrings("t0k", r.auth.bearer);
    try testing.expectEqualStrings("{\"id\": 3}", r.body.json);
    try testing.expectEqualStrings("dev", prepared.assertions[0].expected.string);
    try testing.expectEqual(1, prepared.secrets.len);
    try testing.expectEqualStrings("t0k", prepared.secrets[0]);
}

test "a missing variable names itself and its field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.MissingVariable, prepareAll(arena.allocator(), .{ .url = "http://a", .params = "a=1\r\nkey={{apiKey}}" }, &diagnostic));
    try testing.expectEqualStrings("apiKey", diagnostic.detail);
    try testing.expectEqual(Field.params, diagnostic.field);
    const text = try message(arena.allocator(), error.MissingVariable, diagnostic);
    try testing.expect(std.mem.startsWith(u8, text, "{{apiKey}} is not defined"));
}

test "auth needs its fields, and assertions explain themselves" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.InvalidAuth, prepareAll(arena.allocator(), .{ .url = "http://a", .auth = .{ .kind = .basic, .name = "ada" } }, &diagnostic));
    try testing.expectError(error.InvalidAuth, prepareAll(arena.allocator(), .{ .url = "http://a", .auth = .{ .kind = .api_key_header, .name = "Bad Name", .value = "k" } }, &diagnostic));
    try testing.expectError(error.InvalidAssertion, prepareAll(arena.allocator(), .{ .url = "http://a", .assertions = "status == 200\r\nstatus" }, &diagnostic));
    try testing.expectEqual(2, diagnostic.line);
    const text = try message(arena.allocator(), error.InvalidAssertion, diagnostic);
    try testing.expectEqualStrings("Assertion line 2: expected <target> <operator> [value]", text);
}

test "a draft saved as a case reopens as the same draft" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostic: Diagnostic = .{};
    const original: Draft = .{
        .method = .PUT,
        .url = "{{base}}/items/7",
        .headers = "Accept: application/json\r\n# X-Off: 1\r\n",
        .params = "q=a b\r\nflag\r\n",
        .auth = .{ .kind = .basic, .name = "{{user}}", .value = "pass word" },
        .body_kind = .json,
        .body = "{\r\n  \"id\": {{id}}\r\n}",
        .assertions = "status == 200\r\nbody.id exists\r\n",
    };
    const case = try toCase(allocator, original, "Update item", &diagnostic);
    try testing.expectEqual(1, case.request.headers.len);
    try testing.expectEqual(2, case.request.query.len);

    // Through the writer and parser, as a saved file would go.
    var text: std.Io.Writer.Allocating = .init(allocator);
    var write_diagnostic: @import("../parser/writer.zig").Diagnostic = .{};
    try @import("../parser/writer.zig").write(&text.writer, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &write_diagnostic);
    var parse_diagnostic: @import("../parser/parser.zig").Diagnostic = .{};
    const suite = try @import("../parser/parser.zig").parse(allocator, text.written(), &parse_diagnostic);

    const reopened = try fromCase(allocator, suite.tests[0]);
    try testing.expectEqual(original.method, reopened.method);
    try testing.expectEqualStrings(original.url, reopened.url);
    try testing.expectEqualStrings("Accept: application/json\r\n", reopened.headers);
    try testing.expectEqualStrings("q=a b\r\nflag=\r\n", reopened.params);
    try testing.expectEqual(AuthKind.basic, reopened.auth.kind);
    try testing.expectEqualStrings("pass word", reopened.auth.value);
    try testing.expectEqual(BodyKind.json, reopened.body_kind);
    try testing.expectEqualStrings(original.body, reopened.body);
    try testing.expectEqualStrings(original.assertions, reopened.assertions);
}
