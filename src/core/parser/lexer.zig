//! Splits `.ztest` source into tokens. URLs, header values and JSON bodies are
//! not made of tokens, so the parser reads those with `restOfLine`, `word` and
//! `block`, which take raw text from the current position.

const std = @import("std");

pub const Tag = enum { identifier, string, number, operator, newline, eof };

pub const Token = struct {
    tag: Tag,
    /// A slice of the source. A string keeps its quotes and escapes.
    text: []const u8,
    line: usize,
};

/// Set when parsing fails. `message` lives as long as the parser's arena.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{SyntaxError};

pub const Lexer = struct {
    source: []const u8,
    diagnostic: *Diagnostic,
    index: usize = 0,
    line: usize = 1,
    line_start: usize = 0,

    pub fn init(source: []const u8, diagnostic: *Diagnostic) Lexer {
        const bom = "\xEF\xBB\xBF";
        const start: usize = if (std.mem.startsWith(u8, source, bom)) bom.len else 0;
        return .{ .source = source, .diagnostic = diagnostic, .index = start, .line_start = start };
    }

    pub fn next(l: *Lexer) Error!Token {
        while (true) {
            l.skipSpaces();
            if (l.index == l.source.len) return .{ .tag = .eof, .text = "", .line = l.line };

            const c = l.source[l.index];
            if (c == '\n') {
                const token: Token = .{ .tag = .newline, .text = "\n", .line = l.line };
                l.advanceLine();
                return token;
            }
            if (c != '#') return l.scan(c);
            // A `#` can appear in a URL or header value, so comments need a line of their own.
            if (std.mem.trim(u8, l.source[l.line_start..l.index], " \t").len != 0) {
                return l.fail("a comment must be on its own line");
            }
            l.index = std.mem.findScalarPos(u8, l.source, l.index, '\n') orelse l.source.len;
        }
    }

    /// The next byte after any spaces, without consuming it.
    pub fn peek(l: *Lexer) ?u8 {
        l.skipSpaces();
        return if (l.index < l.source.len) l.source[l.index] else null;
    }

    /// The rest of the line without its surrounding spaces. Leaves the line
    /// break to be read as a token.
    pub fn restOfLine(l: *Lexer) []const u8 {
        const end = std.mem.findScalarPos(u8, l.source, l.index, '\n') orelse l.source.len;
        const text = std.mem.trim(u8, l.source[l.index..end], " \t\r");
        l.index = end;
        return text;
    }

    /// The text up to the next space. Empty at the end of a line.
    pub fn word(l: *Lexer) []const u8 {
        l.skipSpaces();
        const start = l.index;
        while (l.index < l.source.len and !std.ascii.isWhitespace(l.source[l.index])) l.index += 1;
        return l.source[start..l.index];
    }

    /// A balanced `{...}` or `[...]` that may span lines. Brackets inside JSON
    /// strings do not count.
    pub fn block(l: *Lexer) Error![]const u8 {
        const start = l.index;
        const start_line = l.line;
        var depth: usize = 0;
        var in_string = false;
        var escaped = false;
        while (l.index < l.source.len) : (l.index += 1) {
            const c = l.source[l.index];
            if (c == '\n') {
                l.line += 1;
                l.line_start = l.index + 1;
            }
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth == 0) {
                        l.index += 1;
                        return l.source[start..l.index];
                    }
                },
                else => {},
            }
        }
        l.line = start_line;
        return l.fail("this body is never closed");
    }

    fn scan(l: *Lexer, c: u8) Error!Token {
        const start = l.index;
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (l.index < l.source.len and isIdentifierByte(l.source[l.index])) l.index += 1;
            return l.make(.identifier, start);
        }
        if (std.ascii.isDigit(c) or c == '-') {
            l.index += 1;
            while (l.index < l.source.len and isNumberByte(l.source[l.index])) l.index += 1;
            return l.make(.number, start);
        }
        return switch (c) {
            '"' => l.scanString(),
            '=', '!', '<', '>' => l.scanOperator(),
            else => l.fail("unexpected character"),
        };
    }

    fn scanString(l: *Lexer) Error!Token {
        const start = l.index;
        l.index += 1;
        while (l.index < l.source.len and l.source[l.index] != '\n') : (l.index += 1) {
            switch (l.source[l.index]) {
                '\\' => l.index += 1,
                '"' => {
                    l.index += 1;
                    return l.make(.string, start);
                },
                else => {},
            }
        }
        return l.fail("this string is never closed");
    }

    fn scanOperator(l: *Lexer) Error!Token {
        const start = l.index;
        const c = l.source[l.index];
        l.index += 1;
        if (l.index < l.source.len and l.source[l.index] == '=') {
            l.index += 1;
        } else if (c == '!') {
            return l.fail("unexpected character");
        }
        return l.make(.operator, start);
    }

    fn make(l: *Lexer, tag: Tag, start: usize) Token {
        return .{ .tag = tag, .text = l.source[start..l.index], .line = l.line };
    }

    fn skipSpaces(l: *Lexer) void {
        while (l.index < l.source.len) : (l.index += 1) {
            switch (l.source[l.index]) {
                ' ', '\t', '\r' => {},
                else => return,
            }
        }
    }

    fn advanceLine(l: *Lexer) void {
        l.index += 1;
        l.line += 1;
        l.line_start = l.index;
    }

    fn fail(l: *Lexer, message: []const u8) Error {
        l.diagnostic.* = .{ .line = l.line, .message = message };
        return error.SyntaxError;
    }
};

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isNumberByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.';
}

const testing = std.testing;

fn expectTokens(source: []const u8, expected: []const Token) !void {
    var diagnostic: Diagnostic = .{};
    var lexer: Lexer = .init(source, &diagnostic);
    for (expected) |want| {
        const got = try lexer.next();
        try testing.expectEqual(want.tag, got.tag);
        try testing.expectEqualStrings(want.text, got.text);
        try testing.expectEqual(want.line, got.line);
    }
}

fn expectFailure(source: []const u8, line: usize, message: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    var lexer: Lexer = .init(source, &diagnostic);
    const result = while (true) {
        const token = lexer.next() catch |err| break err;
        if (token.tag == .eof) break error.TestExpectedError;
    };
    try testing.expectEqual(error.SyntaxError, result);
    try testing.expectEqual(line, diagnostic.line);
    try testing.expectEqualStrings(message, diagnostic.message);
}

test "tokens carry their type and line" {
    try expectTokens("suite \"Auth\"\n\nvar n = 30s\n", &.{
        .{ .tag = .identifier, .text = "suite", .line = 1 },
        .{ .tag = .string, .text = "\"Auth\"", .line = 1 },
        .{ .tag = .newline, .text = "\n", .line = 1 },
        .{ .tag = .newline, .text = "\n", .line = 2 },
        .{ .tag = .identifier, .text = "var", .line = 3 },
        .{ .tag = .identifier, .text = "n", .line = 3 },
        .{ .tag = .operator, .text = "=", .line = 3 },
        .{ .tag = .number, .text = "30s", .line = 3 },
        .{ .tag = .newline, .text = "\n", .line = 3 },
        .{ .tag = .eof, .text = "", .line = 4 },
    });
}

test "operators are read whole" {
    try expectTokens("== != <= >= < > -1.5", &.{
        .{ .tag = .operator, .text = "==", .line = 1 },
        .{ .tag = .operator, .text = "!=", .line = 1 },
        .{ .tag = .operator, .text = "<=", .line = 1 },
        .{ .tag = .operator, .text = ">=", .line = 1 },
        .{ .tag = .operator, .text = "<", .line = 1 },
        .{ .tag = .operator, .text = ">", .line = 1 },
        .{ .tag = .number, .text = "-1.5", .line = 1 },
    });
}

test "strings keep escaped quotes" {
    try expectTokens("\"say \\\"hi\\\"\"", &.{.{ .tag = .string, .text = "\"say \\\"hi\\\"\"", .line = 1 }});
}

test "comments are skipped but keep line numbers" {
    try expectTokens("  # one\n# two\nend # \n", &.{
        .{ .tag = .newline, .text = "\n", .line = 1 },
        .{ .tag = .newline, .text = "\n", .line = 2 },
        .{ .tag = .identifier, .text = "end", .line = 3 },
    });
    try expectFailure("end # note", 1, "a comment must be on its own line");
}

test "Windows line endings and a byte order mark are ignored" {
    try expectTokens("\xEF\xBB\xBF# note\r\nend\r\nend\r\n", &.{
        .{ .tag = .newline, .text = "\n", .line = 1 },
        .{ .tag = .identifier, .text = "end", .line = 2 },
        .{ .tag = .newline, .text = "\n", .line = 2 },
        .{ .tag = .identifier, .text = "end", .line = 3 },
    });
}

test "bad input names its line" {
    try expectFailure("\n\"open", 2, "this string is never closed");
    try expectFailure("\"open\nend\"", 1, "this string is never closed");
    try expectFailure("\n\n@", 3, "unexpected character");
    try expectFailure("!", 1, "unexpected character");
}

test "raw readers take text the tokens would reject" {
    var diagnostic: Diagnostic = .{};
    var lexer: Lexer = .init("POST {{base}}/a?x=1#top  \r\nheader X-Id a b\nnext", &diagnostic);

    try testing.expectEqualStrings("POST", (try lexer.next()).text);
    try testing.expectEqualStrings("{{base}}/a?x=1#top", lexer.restOfLine());
    try testing.expectEqual(Tag.newline, (try lexer.next()).tag);
    try testing.expectEqualStrings("header", (try lexer.next()).text);
    try testing.expectEqualStrings("X-Id", lexer.word());
    try testing.expectEqualStrings("a b", lexer.restOfLine());
    try testing.expectEqual(Tag.newline, (try lexer.next()).tag);
    try testing.expectEqual(3, (try lexer.next()).line);
}

test "a block ignores brackets in strings and counts its lines" {
    var diagnostic: Diagnostic = .{};
    var lexer: Lexer = .init("{\n  \"a\": \"}\\\"{\",\n  \"b\": [{{id}}]\n} end", &diagnostic);

    try testing.expectEqualStrings("{\n  \"a\": \"}\\\"{\",\n  \"b\": [{{id}}]\n}", try lexer.block());
    const token = try lexer.next();
    try testing.expectEqualStrings("end", token.text);
    try testing.expectEqual(4, token.line);
}

test "an unclosed block names the line it opened on" {
    var diagnostic: Diagnostic = .{};
    var lexer: Lexer = .init("\n{\n  \"a\": 1\n", &diagnostic);

    _ = try lexer.next();
    try testing.expectError(error.SyntaxError, lexer.block());
    try testing.expectEqual(2, diagnostic.line);
}
