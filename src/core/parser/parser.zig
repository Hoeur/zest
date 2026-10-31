//! Turns `.ztest` source into a `Suite`. The format is in `docs/TEST_FORMAT.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assertion = @import("../assertions/assertion.zig");
const http = @import("../http/request.zig");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
pub const Diagnostic = lexer.Diagnostic;

pub const Error = Allocator.Error || lexer.Error;

const CaseKeyword = enum { end, header, body, expect, extract, skip, disabled, timeout, @"var" };
const SuiteKeyword = enum { @"var", setup, teardown, @"test" };

/// On `error.SyntaxError`, `diagnostic` says what is wrong and on which line.
/// Allocations are not freed individually, so pass an arena. `source` must
/// outlive the result.
pub fn parse(arena: Allocator, source: []const u8, diagnostic: *Diagnostic) Error!ast.Suite {
    var parser: Parser = .{ .arena = arena, .lexer = .init(source, diagnostic), .diagnostic = diagnostic };
    return parser.parseSuite();
}

const Parser = struct {
    arena: Allocator,
    lexer: Lexer,
    diagnostic: *Diagnostic,

    fn parseSuite(p: *Parser) Error!ast.Suite {
        const first = try p.nextStatement();
        if (!isWord(first, "suite")) return p.fail(first.line, "a file must start with: suite \"name\"", .{});
        const name = try p.expectString("suite");
        try p.endLine();

        var variables: std.ArrayList(ast.Variable) = .empty;
        var tests: std.ArrayList(ast.Case) = .empty;
        var setup: ?ast.Case = null;
        var teardown: ?ast.Case = null;
        while (true) {
            const token = try p.nextStatement();
            if (token.tag == .eof) break;
            const keyword = keywordOf(SuiteKeyword, token) orelse {
                return p.fail(token.line, "expected var, setup, teardown or test, found {s}", .{describe(token)});
            };
            switch (keyword) {
                .@"var" => try variables.append(p.arena, try p.parseVariable(token.line)),
                .setup => {
                    if (setup != null) return p.fail(token.line, "a suite can only have one setup", .{});
                    try p.endLine();
                    setup = try p.parseCase("setup", token.line, true);
                },
                .teardown => {
                    if (teardown != null) return p.fail(token.line, "a suite can only have one teardown", .{});
                    try p.endLine();
                    teardown = try p.parseCase("teardown", token.line, true);
                },
                .@"test" => {
                    const test_name = try p.expectString("test");
                    try p.endLine();
                    try tests.append(p.arena, try p.parseCase(test_name, token.line, false));
                },
            }
        }
        // A file that runs nothing would otherwise pass in CI.
        if (tests.items.len == 0) return p.fail(first.line, "a suite needs at least one test", .{});
        return .{
            .name = name,
            .variables = variables.items,
            .setup = setup,
            .teardown = teardown,
            .tests = tests.items,
        };
    }

    /// Reads up to and including `end`.
    fn parseCase(p: *Parser, name: []const u8, line: usize, is_hook: bool) Error!ast.Case {
        var case: ast.Case = .{
            .name = name,
            .line = line,
            .variables = &.{},
            .request = undefined,
            .expects = &.{},
            .extracts = &.{},
        };
        var has_request = false;
        var variables: std.ArrayList(ast.Variable) = .empty;
        var headers: std.ArrayList(http.Header) = .empty;
        var expects: std.ArrayList(ast.Expect) = .empty;
        var extracts: std.ArrayList(ast.Extract) = .empty;
        var body: ast.Body = .none;

        while (true) {
            const token = try p.nextStatement();
            if (token.tag == .eof) return p.fail(line, "'{s}' has no 'end'", .{name});

            if (methodOf(token)) |method| {
                if (has_request) return p.fail(token.line, "a test can only send one request", .{});
                has_request = true;
                const url = p.lexer.restOfLine();
                if (url.len == 0) return p.fail(token.line, "{s} needs a URL", .{token.text});
                case.request = .{ .method = method, .url = url, .headers = &.{}, .body = .none, .line = token.line };
                continue;
            }

            const keyword = keywordOf(CaseKeyword, token) orelse {
                return p.fail(token.line, "expected a request or test statement, found {s}", .{describe(token)});
            };
            switch (keyword) {
                .end => {
                    try p.endLine();
                    break;
                },
                .header => try headers.append(p.arena, try p.parseHeader(token.line)),
                .body => {
                    if (body != .none) return p.fail(token.line, "a test can only have one body", .{});
                    body = try p.parseBody(token.line);
                },
                .expect => try expects.append(p.arena, try p.parseExpect(token.line)),
                .extract => try extracts.append(p.arena, try p.parseExtract(token.line)),
                .skip, .disabled => {
                    if (is_hook) return p.fail(token.line, "{s} and teardown cannot use {s}", .{ name, token.text });
                    case.mode = if (keyword == .skip) .skip else .disabled;
                    try p.endLine();
                },
                .timeout => case.timeout_ms = try p.parseTimeout(token.line),
                .@"var" => try variables.append(p.arena, try p.parseVariable(token.line)),
            }
        }

        if (!has_request) return p.fail(line, "'{s}' has no request, such as: GET https://example.com", .{name});
        case.request.headers = headers.items;
        case.request.body = body;
        case.variables = variables.items;
        case.expects = expects.items;
        case.extracts = extracts.items;
        return case;
    }

    fn parseVariable(p: *Parser, line: usize) Error!ast.Variable {
        var name = try p.next();
        var equals = try p.next();
        const secret = isSecretFlag(name, equals);
        if (secret) {
            name = equals;
            equals = try p.next();
        }
        if (name.tag != .identifier or !ast.isVariableName(name.text)) {
            return p.fail(line, "expected a variable name, found {s}", .{describe(name)});
        }
        if (equals.tag != .operator or !std.mem.eql(u8, equals.text, "=")) {
            return p.fail(line, "expected = after {s}, found {s}", .{ name.text, describe(equals) });
        }
        const value = try p.next();
        const text = switch (value.tag) {
            .string => try p.decodeString(value),
            .number => value.text,
            else => if (isWord(value, "true") or isWord(value, "false"))
                value.text
            else
                return p.fail(line, "a variable's value must be a quoted string, number, true or false", .{}),
        };
        try p.endLine();
        return .{ .name = name.text, .value = text, .line = line, .secret = secret };
    }

    fn parseHeader(p: *Parser, line: usize) Error!http.Header {
        const name = p.lexer.word();
        const value = p.lexer.restOfLine();
        if (name.len == 0 or value.len == 0) return p.fail(line, "a header looks like: header Name value", .{});
        if (std.mem.findScalar(u8, name, ':') != null) {
            return p.fail(line, "write a header without a colon: header Name value", .{});
        }
        return .{ .name = name, .value = value };
    }

    fn parseBody(p: *Parser, line: usize) Error!ast.Body {
        const first = p.lexer.peek() orelse 0;
        const body: ast.Body = switch (first) {
            '{', '[' => .{ .json = try p.lexer.block() },
            '"' => .{ .raw = try p.decodeString(try p.next()) },
            else => return p.fail(line, "a body is JSON starting with {{ or [, or a quoted string", .{}),
        };
        try p.endLine();
        return body;
    }

    fn parseExpect(p: *Parser, line: usize) Error!ast.Expect {
        const parsed = assertion.parse(p.arena, p.lexer.restOfLine()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return p.fail(line, "{s}", .{assertion.describe(err)});
        };
        return .{ .assertion = parsed, .line = line };
    }

    fn parseExtract(p: *Parser, line: usize) Error!ast.Extract {
        var name = try p.next();
        var equals = try p.next();
        const secret = isSecretFlag(name, equals);
        if (secret) {
            name = equals;
            equals = try p.next();
        }
        if (name.tag != .identifier or !ast.isVariableName(name.text) or
            equals.tag != .operator or !std.mem.eql(u8, equals.text, "="))
        {
            return p.fail(line, "an extract looks like: extract token = body.token", .{});
        }
        const source_text = p.lexer.restOfLine();
        const source = assertion.parseTarget(p.arena, source_text) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return p.fail(line, "{s}", .{assertion.describe(err)});
        };
        return .{ .name = name.text, .source = source, .source_text = source_text, .line = line, .secret = secret };
    }

    fn parseTimeout(p: *Parser, line: usize) Error!u64 {
        const value = try p.next();
        const ns = assertion.parseDuration(value.text) orelse 0;
        if (value.tag != .number or ns == 0) {
            return p.fail(line, "a timeout is a time above zero, such as 500ms or 2s", .{});
        }
        try p.endLine();
        return @max(1, ns / std.time.ns_per_ms);
    }

    fn expectString(p: *Parser, keyword: []const u8) Error![]const u8 {
        const token = try p.next();
        if (token.tag != .string) {
            return p.fail(token.line, "{s} needs a quoted name, found {s}", .{ keyword, describe(token) });
        }
        return p.decodeString(token);
    }

    /// JSON rules, the same as assertion values.
    fn decodeString(p: *Parser, token: Token) Error![]const u8 {
        return std.json.parseFromSliceLeaky([]const u8, p.arena, token.text, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| e,
            else => p.fail(token.line, "this string has an invalid escape", .{}),
        };
    }

    fn next(p: *Parser) lexer.Error!Token {
        return p.lexer.next();
    }

    /// Skips blank lines.
    fn nextStatement(p: *Parser) lexer.Error!Token {
        while (true) {
            const token = try p.next();
            if (token.tag != .newline) return token;
        }
    }

    fn endLine(p: *Parser) Error!void {
        const token = try p.next();
        if (token.tag == .newline or token.tag == .eof) return;
        return p.fail(token.line, "expected the end of the line, found {s}", .{describe(token)});
    }

    fn fail(p: *Parser, line: usize, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(p.arena, fmt, args) catch return error.OutOfMemory;
        p.diagnostic.* = .{ .line = line, .message = message };
        return error.SyntaxError;
    }
};

/// `secret` is a flag only when a name follows, so `var secret = 1` still works.
fn isSecretFlag(first: Token, second: Token) bool {
    return isWord(first, "secret") and second.tag == .identifier;
}

fn describe(token: Token) []const u8 {
    return switch (token.tag) {
        .newline => "the end of the line",
        .eof => "the end of the file",
        else => token.text,
    };
}

fn isWord(token: Token, word: []const u8) bool {
    return token.tag == .identifier and std.mem.eql(u8, token.text, word);
}

fn keywordOf(comptime Keyword: type, token: Token) ?Keyword {
    return if (token.tag == .identifier) std.meta.stringToEnum(Keyword, token.text) else null;
}

fn methodOf(token: Token) ?http.Method {
    return if (token.tag == .identifier) std.meta.stringToEnum(http.Method, token.text) else null;
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    diagnostic: Diagnostic = .{},

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn parseText(f: *Fixture, source: []const u8) Error!ast.Suite {
        return parse(f.arena.allocator(), source, &f.diagnostic);
    }
};

fn expectFailure(source: []const u8, line: usize, message: []const u8) !void {
    var f: Fixture = .{};
    defer f.deinit();
    try testing.expectError(error.SyntaxError, f.parseText(source));
    try testing.expectEqualStrings(message, f.diagnostic.message);
    try testing.expectEqual(line, f.diagnostic.line);
}

test "the README example parses" {
    var f: Fixture = .{};
    defer f.deinit();

    const suite = try f.parseText(
        \\suite "Authentication"
        \\
        \\test "Login successfully"
        \\
        \\POST {{baseUrl}}/api/login
        \\
        \\header Content-Type application/json
        \\
        \\body {
        \\  "email": "test@example.com",
        \\  "password": "123456"
        \\}
        \\
        \\expect status == 200
        \\expect response_time < 500ms
        \\expect body.token exists
        \\
        \\end
        \\
    );
    try testing.expectEqualStrings("Authentication", suite.name);
    try testing.expectEqual(1, suite.tests.len);

    const case = suite.tests[0];
    try testing.expectEqualStrings("Login successfully", case.name);
    try testing.expectEqual(3, case.line);
    try testing.expectEqual(http.Method.POST, case.request.method);
    try testing.expectEqualStrings("{{baseUrl}}/api/login", case.request.url);
    try testing.expectEqual(5, case.request.line);
    try testing.expectEqualStrings("Content-Type", case.request.headers[0].name);
    try testing.expectEqualStrings("application/json", case.request.headers[0].value);
    try testing.expectEqualStrings("{\n  \"email\": \"test@example.com\",\n  \"password\": \"123456\"\n}", case.request.body.json);
    try testing.expectEqual(3, case.expects.len);
    try testing.expectEqualStrings("response_time < 500ms", case.expects[1].assertion.text);
    try testing.expectEqual(16, case.expects[2].line);
}

test "every statement parses" {
    var f: Fixture = .{};
    defer f.deinit();

    const suite = try f.parseText(
        \\# Shared values
        \\suite "All"
        \\var baseUrl = "https://example.com"
        \\var retries = 3
        \\var strict = true
        \\
        \\setup
        \\  POST {{baseUrl}}/login
        \\  extract token = body.token
        \\  extract etag = header.etag
        \\end
        \\
        \\teardown
        \\  DELETE {{baseUrl}}/session
        \\end
        \\
        \\test "one"
        \\  var id = "7"
        \\  timeout 2s
        \\  GET {{baseUrl}}/users/{{id}}#top
        \\  header Authorization Bearer {{token}}
        \\  body "line one\nline two"
        \\end
        \\
        \\test "two"
        \\  skip
        \\  GET {{baseUrl}}
        \\end
        \\
        \\test "three"
        \\  disabled
        \\  GET {{baseUrl}}
        \\end
    );
    try testing.expectEqual(3, suite.variables.len);
    try testing.expectEqualStrings("https://example.com", suite.variables[0].value);
    try testing.expectEqualStrings("3", suite.variables[1].value);
    try testing.expectEqualStrings("true", suite.variables[2].value);

    try testing.expectEqualStrings("token", suite.setup.?.extracts[0].name);
    try testing.expectEqual(1, suite.setup.?.extracts[0].source.body.len);
    try testing.expectEqualStrings("etag", suite.setup.?.extracts[1].source.header);
    try testing.expectEqualStrings("header.etag", suite.setup.?.extracts[1].source_text);
    try testing.expectEqual(http.Method.DELETE, suite.teardown.?.request.method);

    const one = suite.tests[0];
    try testing.expectEqualStrings("id", one.variables[0].name);
    try testing.expectEqual(2000, one.timeout_ms.?);
    try testing.expectEqualStrings("{{baseUrl}}/users/{{id}}#top", one.request.url);
    try testing.expectEqualStrings("Bearer {{token}}", one.request.headers[0].value);
    try testing.expectEqualStrings("line one\nline two", one.request.body.raw);
    try testing.expectEqual(ast.Mode.run, one.mode);
    try testing.expectEqual(ast.Mode.skip, suite.tests[1].mode);
    try testing.expectEqual(ast.Mode.disabled, suite.tests[2].mode);
}

test "Windows line endings parse the same" {
    var f: Fixture = .{};
    defer f.deinit();

    const suite = try f.parseText("suite \"S\"\r\ntest \"T\"\r\nGET http://a.test\r\nheader X-A b\r\nexpect status == 200\r\nend\r\n");
    const case = suite.tests[0];
    try testing.expectEqualStrings("http://a.test", case.request.url);
    try testing.expectEqualStrings("b", case.request.headers[0].value);
    try testing.expectEqualStrings("status == 200", case.expects[0].assertion.text);
}

test "a line number survives a multi-line body" {
    try expectFailure(
        \\suite "S"
        \\test "T"
        \\GET http://a.test
        \\body {
        \\  "a": 1
        \\}
        \\expect nope == 1
        \\end
    , 7, assertion.describe(error.UnknownTarget));
}

test "file structure mistakes are reported" {
    try expectFailure("", 1, "a file must start with: suite \"name\"");
    try expectFailure("test \"T\"\nend", 1, "a file must start with: suite \"name\"");
    try expectFailure("suite Auth", 1, "suite needs a quoted name, found Auth");
    try expectFailure("suite \"S\" extra", 1, "expected the end of the line, found extra");
    try expectFailure("suite \"S\"\n", 1, "a suite needs at least one test");
    try expectFailure("suite \"S\"\nGET http://a.test", 2, "expected var, setup, teardown or test, found GET");
    try expectFailure("suite \"S\"\nsetup\nGET u\nend\nsetup\nGET u\nend\ntest \"T\"\nGET u\nend", 5, "a suite can only have one setup");
    try expectFailure("suite \"S\"\nteardown\nGET u\nend\nteardown", 5, "a suite can only have one teardown");
}

test "test mistakes are reported" {
    try expectFailure("suite \"S\"\n\ntest \"T\"\nGET u\n", 3, "'T' has no 'end'");
    try expectFailure("suite \"S\"\ntest \"T\"\nend", 2, "'T' has no request, such as: GET https://example.com");
    try expectFailure("suite \"S\"\ntest \"T\"\nGET u\nPOST u\nend", 4, "a test can only send one request");
    try expectFailure("suite \"S\"\ntest \"T\"\nGET\nend", 3, "GET needs a URL");
    try expectFailure("suite \"S\"\ntest \"T\"\nget u\nend", 3, "expected a request or test statement, found get");
    try expectFailure("suite \"S\"\nsetup\nskip\nGET u\nend", 3, "setup and teardown cannot use skip");
}

test "statement mistakes are reported" {
    const prefix = "suite \"S\"\ntest \"T\"\nGET u\n";
    try expectFailure(prefix ++ "header X-A\nend", 4, "a header looks like: header Name value");
    try expectFailure(prefix ++ "header X-A: b\nend", 4, "write a header without a colon: header Name value");
    try expectFailure(prefix ++ "body\nend", 4, "a body is JSON starting with { or [, or a quoted string");
    try expectFailure(prefix ++ "body {\nend", 4, "this body is never closed");
    try expectFailure(prefix ++ "body {} x\nend", 4, "expected the end of the line, found x");
    try expectFailure(prefix ++ "body \"a\"\nbody \"b\"\nend", 5, "a test can only have one body");
    try expectFailure(prefix ++ "body \"\\q\"\nend", 4, "this string has an invalid escape");
    try expectFailure(prefix ++ "expect status = 200\nend", 4, assertion.describe(error.UnknownOperator));
    try expectFailure(prefix ++ "extract token\nend", 4, "an extract looks like: extract token = body.token");
    try expectFailure(prefix ++ "extract token = nope\nend", 4, assertion.describe(error.UnknownTarget));
    try expectFailure(prefix ++ "timeout soon\nend", 4, "a timeout is a time above zero, such as 500ms or 2s");
    try expectFailure(prefix ++ "timeout 0s\nend", 4, "a timeout is a time above zero, such as 500ms or 2s");
    try expectFailure(prefix ++ "var a-b = 1\nend", 4, "expected a variable name, found a-b");
    try expectFailure(prefix ++ "var a 1\nend", 4, "expected = after a, found 1");
    try expectFailure(prefix ++ "var a = nope\nend", 4, "a variable's value must be a quoted string, number, true or false");
}

test "a file cut off anywhere is an error, not a crash" {
    const source =
        \\# note
        \\suite "S\"x"
        \\var a = "b\\"
        \\setup
        \\  GET u
        \\  extract t = body.a[0].b
        \\end
        \\test "T"
        \\  timeout 1.5s
        \\  POST {{a}}
        \\  header X-A b
        \\  body { "a": ["\"}", {{b}}] }
        \\  expect body.a == "x\\"
        \\end
        \\
    ;
    var f: Fixture = .{};
    defer f.deinit();
    _ = try f.parseText(source);

    for (0..source.len) |len| {
        _ = f.parseText(source[0..len]) catch |err| try testing.expectEqual(error.SyntaxError, err);
        _ = f.arena.reset(.retain_capacity);
    }
}

test "secret marks a var or an extract, and is still a usable name" {
    var f: Fixture = .{};
    defer f.deinit();
    const suite = try f.parseText(
        \\suite "S"
        \\var secret key = "k"
        \\var secret = "plain"
        \\var other = 1
        \\test "T"
        \\  GET u
        \\  extract secret token = body.token
        \\  extract secret = body.other
        \\  extract id = body.id
        \\end
    );
    try testing.expectEqualStrings("key", suite.variables[0].name);
    try testing.expect(suite.variables[0].secret);
    try testing.expectEqualStrings("secret", suite.variables[1].name);
    try testing.expect(!suite.variables[1].secret);
    try testing.expect(!suite.variables[2].secret);

    const extracts = suite.tests[0].extracts;
    try testing.expectEqualStrings("token", extracts[0].name);
    try testing.expect(extracts[0].secret);
    try testing.expectEqualStrings("secret", extracts[1].name);
    try testing.expect(!extracts[1].secret);
    try testing.expect(!extracts[2].secret);
}

test "secret mistakes are reported" {
    try expectFailure("suite \"S\"\nvar secret a b = 1\n", 2, "expected = after a, found b");
    try expectFailure("suite \"S\"\nvar secret\n", 2, "expected = after secret, found the end of the line");
}
