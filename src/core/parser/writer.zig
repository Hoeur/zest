//! Writes a `Suite` back to `.ztest` text that `parser.parse` reads into the
//! same suite. The desktop app saves requests with this. Comments and blank
//! lines in an original file are not kept, because the AST does not hold them.

const std = @import("std");
const Io = std.Io;
const http = @import("../http/request.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const Error = Io.Writer.Error || error{Unrepresentable};

/// Set on `error.Unrepresentable`: what cannot be written, and why.
pub const Diagnostic = struct {
    /// Such as "a header value". Empty when `problem` says it all.
    subject: []const u8 = "",
    problem: []const u8 = "",

    /// One sentence for the user, such as "A header value cannot span lines".
    pub fn format(d: Diagnostic, w: *Io.Writer) Io.Writer.Error!void {
        const text = if (d.subject.len > 0) d.subject else d.problem;
        if (text.len > 0) {
            try w.writeByte(std.ascii.toUpper(text[0]));
            try w.writeAll(text[1..]);
        }
        if (d.subject.len > 0) try w.print(" {s}", .{d.problem});
    }
};

pub fn write(out: *Io.Writer, suite: ast.Suite, diagnostic: *Diagnostic) Error!void {
    if (suite.tests.len == 0) return fail(diagnostic, "a suite needs at least one test");
    try out.writeAll("suite ");
    try quoted(out, suite.name);
    try out.writeAll("\n");
    if (suite.variables.len > 0) try out.writeByte('\n');
    for (suite.variables) |variable| try writeVariable(out, variable, "", diagnostic);
    if (suite.setup) |setup| try writeCase(out, "setup", setup, diagnostic);
    for (suite.tests) |case| try writeCase(out, null, case, diagnostic);
    if (suite.teardown) |teardown| try writeCase(out, "teardown", teardown, diagnostic);
}

/// `hook` is `setup` or `teardown`, or null for a test.
fn writeCase(out: *Io.Writer, hook: ?[]const u8, case: ast.Case, diagnostic: *Diagnostic) Error!void {
    try out.writeByte('\n');
    if (hook) |keyword| {
        if (case.mode != .run) return fail(diagnostic, "setup and teardown cannot be skipped or disabled");
        try out.print("{s}\n", .{keyword});
    } else {
        try out.writeAll("test ");
        try quoted(out, case.name);
        try out.writeByte('\n');
    }
    const indent = "  ";
    switch (case.mode) {
        .run => {},
        .skip => try out.writeAll(indent ++ "skip\n"),
        .disabled => try out.writeAll(indent ++ "disabled\n"),
    }
    if (case.timeout_ms) |ms| {
        if (ms == 0) return fail(diagnostic, "a timeout must be above zero");
        try out.print(indent ++ "timeout {d}ms\n", .{ms});
    }
    for (case.variables) |variable| try writeVariable(out, variable, indent, diagnostic);

    const request = case.request;
    try out.print(indent ++ "{s} ", .{@tagName(request.method)});
    try rest(out, request.url, false, "the URL", diagnostic);
    for (request.query) |param| {
        try out.writeAll(indent ++ "query ");
        try word(out, param.name, "a query parameter name", diagnostic);
        if (param.value.len > 0) try out.writeByte(' ');
        try rest(out, param.value, true, "a query parameter value", diagnostic);
    }
    switch (request.auth) {
        .none => {},
        .bearer => |token| {
            try out.writeAll(indent ++ "auth bearer ");
            try rest(out, token, false, "the bearer token", diagnostic);
        },
        .basic => |basic| {
            try out.writeAll(indent ++ "auth basic ");
            try word(out, basic.user, "the Basic auth user", diagnostic);
            try out.writeByte(' ');
            try rest(out, basic.password, false, "the Basic auth password", diagnostic);
        },
        .api_key_header => |header| {
            if (std.mem.findScalar(u8, header.name, ':') != null) return fail(diagnostic, "an API key header name cannot contain ':'");
            try out.writeAll(indent ++ "auth header ");
            try word(out, header.name, "the API key header name", diagnostic);
            try out.writeByte(' ');
            try rest(out, header.value, false, "the API key", diagnostic);
        },
        .api_key_query => |param| {
            try out.writeAll(indent ++ "auth query ");
            try word(out, param.name, "the API key parameter name", diagnostic);
            try out.writeByte(' ');
            try rest(out, param.value, false, "the API key", diagnostic);
        },
    }
    for (request.headers) |header| {
        if (std.mem.findScalar(u8, header.name, ':') != null) return fail(diagnostic, "a header name cannot contain ':'");
        try out.writeAll(indent ++ "header ");
        try word(out, header.name, "a header name", diagnostic);
        try out.writeByte(' ');
        try rest(out, header.value, false, "a header value", diagnostic);
    }
    switch (request.body) {
        .none => {},
        .raw => |text| {
            try out.writeAll(indent ++ "body ");
            try quoted(out, text);
            try out.writeByte('\n');
        },
        .json => |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (!isBlock(trimmed)) return fail(diagnostic, "a JSON body must be one object or array to be saved");
            try out.writeAll(indent ++ "body ");
            try out.writeAll(trimmed);
            try out.writeByte('\n');
        },
    }
    for (case.expects) |expect| {
        try out.writeAll(indent ++ "expect ");
        try rest(out, expect.assertion.text, false, "an assertion", diagnostic);
    }
    for (case.extracts) |extract| {
        try out.print(indent ++ "extract {s}", .{if (extract.secret) "secret " else ""});
        if (!ast.isVariableName(extract.name)) return fail(diagnostic, "an extract needs a variable name made of letters, digits and _");
        try out.print("{s} = ", .{extract.name});
        try rest(out, extract.source_text, false, "an extract source", diagnostic);
    }
    try out.writeAll("end\n");
}

fn writeVariable(out: *Io.Writer, variable: ast.Variable, indent: []const u8, diagnostic: *Diagnostic) Error!void {
    if (!ast.isVariableName(variable.name)) return fail(diagnostic, "a variable name is made of letters, digits and _");
    try out.print("{s}var {s}{s} = ", .{ indent, if (variable.secret) "secret " else "", variable.name });
    try quoted(out, variable.value);
    try out.writeByte('\n');
}

/// Text up to the next space, as `lexer.word` reads it.
fn word(out: *Io.Writer, text: []const u8, what: []const u8, diagnostic: *Diagnostic) Error!void {
    if (text.len == 0) return failWith(diagnostic, what, "is empty");
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) return failWith(diagnostic, what, "cannot contain spaces");
    }
    try out.writeAll(text);
}

/// The rest of a line, as `lexer.restOfLine` reads it, then the line break.
fn rest(out: *Io.Writer, text: []const u8, allow_empty: bool, what: []const u8, diagnostic: *Diagnostic) Error!void {
    if (!allow_empty and text.len == 0) return failWith(diagnostic, what, "is empty");
    if (std.mem.findAny(u8, text, "\r\n") != null) return failWith(diagnostic, what, "cannot span lines");
    if (text.len > 0 and (isBlank(text[0]) or isBlank(text[text.len - 1]))) {
        return failWith(diagnostic, what, "cannot start or end with a space");
    }
    try out.writeAll(text);
    try out.writeByte('\n');
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// A JSON string, which the parser decodes with the same rules.
fn quoted(out: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(text, .{}, out);
}

fn isBlock(text: []const u8) bool {
    if (text.len < 2) return false;
    return (text[0] == '{' and text[text.len - 1] == '}') or (text[0] == '[' and text[text.len - 1] == ']');
}

fn fail(diagnostic: *Diagnostic, problem: []const u8) error{Unrepresentable} {
    diagnostic.* = .{ .problem = problem };
    return error.Unrepresentable;
}

fn failWith(diagnostic: *Diagnostic, subject: []const u8, problem: []const u8) error{Unrepresentable} {
    diagnostic.* = .{ .subject = subject, .problem = problem };
    return error.Unrepresentable;
}

const testing = std.testing;

/// Parses `source`, writes it, and checks that the text parses to the same
/// suite and writes the same text again.
fn expectRoundTrip(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parse_diagnostic: parser.Diagnostic = .{};
    const first = try parser.parse(allocator, source, &parse_diagnostic);

    var diagnostic: Diagnostic = .{};
    var out: Io.Writer.Allocating = .init(allocator);
    try write(&out.writer, first, &diagnostic);
    const text = out.written();

    const second = parser.parse(allocator, text, &parse_diagnostic) catch |err| {
        std.debug.print("line {d}: {s}\n{s}\n", .{ parse_diagnostic.line, parse_diagnostic.message, text });
        return err;
    };
    try expectSameSuite(first, second);

    var again: Io.Writer.Allocating = .init(allocator);
    try write(&again.writer, second, &diagnostic);
    try testing.expectEqualStrings(text, again.written());
}

fn expectSameSuite(a: ast.Suite, b: ast.Suite) !void {
    try testing.expectEqualStrings(a.name, b.name);
    try expectSameVariables(a.variables, b.variables);
    try testing.expectEqual(a.setup != null, b.setup != null);
    if (a.setup) |setup| try expectSameCase(setup, b.setup.?);
    try testing.expectEqual(a.teardown != null, b.teardown != null);
    if (a.teardown) |teardown| try expectSameCase(teardown, b.teardown.?);
    try testing.expectEqual(a.tests.len, b.tests.len);
    for (a.tests, b.tests) |x, y| try expectSameCase(x, y);
}

fn expectSameVariables(a: []const ast.Variable, b: []const ast.Variable) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqualStrings(x.value, y.value);
        try testing.expectEqual(x.secret, y.secret);
    }
}

fn expectSameCase(a: ast.Case, b: ast.Case) !void {
    try testing.expectEqualStrings(a.name, b.name);
    try testing.expectEqual(a.mode, b.mode);
    try testing.expectEqual(a.timeout_ms, b.timeout_ms);
    try expectSameVariables(a.variables, b.variables);
    const x = a.request;
    const y = b.request;
    try testing.expectEqual(x.method, y.method);
    try testing.expectEqualStrings(x.url, y.url);
    try testing.expectEqual(x.headers.len, y.headers.len);
    for (x.headers, y.headers) |h, k| {
        try testing.expectEqualStrings(h.name, k.name);
        try testing.expectEqualStrings(h.value, k.value);
    }
    try testing.expectEqual(x.query.len, y.query.len);
    for (x.query, y.query) |p, q| {
        try testing.expectEqualStrings(p.name, q.name);
        try testing.expectEqualStrings(p.value, q.value);
    }
    try testing.expectEqual(std.meta.activeTag(x.auth), std.meta.activeTag(y.auth));
    switch (x.auth) {
        .none => {},
        .bearer => |t| try testing.expectEqualStrings(t, y.auth.bearer),
        .basic => |v| {
            try testing.expectEqualStrings(v.user, y.auth.basic.user);
            try testing.expectEqualStrings(v.password, y.auth.basic.password);
        },
        .api_key_header => |v| try testing.expectEqualStrings(v.value, y.auth.api_key_header.value),
        .api_key_query => |v| try testing.expectEqualStrings(v.value, y.auth.api_key_query.value),
    }
    try testing.expectEqual(std.meta.activeTag(x.body), std.meta.activeTag(y.body));
    switch (x.body) {
        .none => {},
        .raw => |t| try testing.expectEqualStrings(t, y.body.raw),
        .json => |t| try testing.expectEqualStrings(std.mem.trim(u8, t, " \t\r\n"), y.body.json),
    }
    try testing.expectEqual(a.expects.len, b.expects.len);
    for (a.expects, b.expects) |e, f| try testing.expectEqualStrings(e.assertion.text, f.assertion.text);
    try testing.expectEqual(a.extracts.len, b.extracts.len);
    for (a.extracts, b.extracts) |e, f| {
        try testing.expectEqualStrings(e.name, f.name);
        try testing.expectEqualStrings(e.source_text, f.source_text);
        try testing.expectEqual(e.secret, f.secret);
    }
}

test "every statement survives a round trip" {
    try expectRoundTrip(
        \\# A comment that is not kept.
        \\suite "Auth \"quoted\" é"
        \\var baseUrl = "https://api.example.com"
        \\var secret key = "k\ty"
        \\var n = 3
        \\setup
        \\  POST {{baseUrl}}/login
        \\  header Content-Type application/json
        \\  body {
        \\    "email": "test@example.com",
        \\    "tags": ["a", "b]"]
        \\  }
        \\  expect status == 200
        \\  extract secret token = body.token
        \\end
        \\test "Profile"
        \\  timeout 2s
        \\  var id = "7"
        \\  GET {{baseUrl}}/users/{{id}}#frag
        \\  query fields name, email
        \\  query empty
        \\  auth bearer {{token}}
        \\  header X-Trace a b c
        \\  expect body.user.id exists
        \\  expect body.name == "Ada \"L\""
        \\  extract name = body.name
        \\end
        \\test "Skipped"
        \\  skip
        \\  DELETE {{baseUrl}}/x
        \\  auth basic {{user}} pass word
        \\  body "line\nbreak"
        \\end
        \\test "Off"
        \\  disabled
        \\  PATCH {{baseUrl}}/y
        \\  auth header X-Api-Key {{key}}
        \\end
        \\test "Query key"
        \\  OPTIONS {{baseUrl}}
        \\  auth query api_key {{key}}
        \\  body [1, 2]
        \\end
        \\teardown
        \\  DELETE {{baseUrl}}/session
        \\end
        \\
    );
}

test "the init template survives a round trip" {
    try expectRoundTrip(@import("../../commands/init.zig").suite_template);
}

test "text that the format cannot hold is refused with a reason" {
    var buffer: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var diagnostic: Diagnostic = .{};
    const base: ast.Case = .{
        .name = "T",
        .line = 1,
        .variables = &.{},
        .request = .{ .method = .GET, .url = "http://a.test", .headers = &.{}, .body = .none, .line = 1 },
        .expects = &.{},
        .extracts = &.{},
    };

    var case = base;
    case.request.headers = &.{.{ .name = "X-Empty", .value = "" }};
    try testing.expectError(error.Unrepresentable, write(&out, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &diagnostic));
    var message: [128]u8 = undefined;
    try testing.expectEqualStrings("A header value is empty", try std.fmt.bufPrint(&message, "{f}", .{diagnostic}));

    case = base;
    case.request.url = "http://a.test/\nGET http://evil.test";
    try testing.expectError(error.Unrepresentable, write(&out, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &diagnostic));
    try testing.expectEqualStrings("the URL", diagnostic.subject);
    try testing.expectEqualStrings("cannot span lines", diagnostic.problem);

    case = base;
    case.request.body = .{ .json = "\"just a string\"" };
    try testing.expectError(error.Unrepresentable, write(&out, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &diagnostic));

    case = base;
    case.request.headers = &.{.{ .name = "Bad Name", .value = "v" }};
    try testing.expectError(error.Unrepresentable, write(&out, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &diagnostic));
    try testing.expectEqualStrings("A header name cannot contain spaces", try std.fmt.bufPrint(&message, "{f}", .{diagnostic}));

    try testing.expectError(error.Unrepresentable, write(&out, .{ .name = "S", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{} }, &diagnostic));
}
