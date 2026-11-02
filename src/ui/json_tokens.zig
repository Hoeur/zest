//! Small, tolerant JSON lexer for editor colors; request validation stays in core.
const std = @import("std");
pub const Kind = enum { key, string, number, literal };
pub const Token = struct { start: usize, end: usize, kind: Kind };
pub const Lexer = struct {
    text: []const u16,
    index: usize = 0,

    pub fn next(l: *Lexer) ?Token {
        while (l.index < l.text.len) {
            const start = l.index;
            const ch = l.text[l.index];
            l.index += 1;
            if (ch == '"') {
                var closed = false;
                while (l.index < l.text.len) {
                    const current = l.text[l.index];
                    l.index += 1;
                    if (current == '\\' and l.index < l.text.len) {
                        l.index += 1;
                    } else if (current == '"') {
                        closed = true;
                        break;
                    }
                }
                var after = l.index;
                while (after < l.text.len and whitespace(l.text[after])) after += 1;
                return .{ .start = start, .end = l.index, .kind = if (closed and after < l.text.len and l.text[after] == ':') .key else .string };
            }
            if (digit(ch) or ch == '-') {
                while (l.index < l.text.len) {
                    const current = l.text[l.index];
                    if (!digit(current) and current != '.' and current != 'e' and current != 'E' and current != '+' and current != '-') break;
                    l.index += 1;
                }
                return .{ .start = start, .end = l.index, .kind = .number };
            }
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                while (l.index < l.text.len and ((l.text[l.index] >= 'a' and l.text[l.index] <= 'z') or (l.text[l.index] >= 'A' and l.text[l.index] <= 'Z'))) l.index += 1;
                const word = l.text[start..l.index];
                for ([_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("true"), std.unicode.utf8ToUtf16LeStringLiteral("false"), std.unicode.utf8ToUtf16LeStringLiteral("null") }) |literal| {
                    if (std.mem.eql(u16, word, literal)) return .{ .start = start, .end = l.index, .kind = .literal };
                }
            }
        }
        return null;
    }
};

fn digit(ch: u16) bool {
    return ch >= '0' and ch <= '9';
}
fn whitespace(ch: u16) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

const testing = std.testing;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

test "JSON colors distinguish escaped strings keys numbers and literals" {
    var lexer: Lexer = .{ .text = wide("{\"a\\\"b\" \r\n : \"value\\\\end\", \"n\": -1.5e+2, \"ok\": true, \"empty\": null}") };
    const expected = [_]Kind{ .key, .string, .key, .number, .key, .literal, .key, .literal };
    var previous: usize = 0;
    for (expected) |kind| {
        const token = lexer.next().?;
        try testing.expectEqual(kind, token.kind);
        try testing.expect(token.start >= previous and token.end > token.start and token.end <= lexer.text.len);
        previous = token.end;
    }
    try testing.expectEqual(null, lexer.next());
}

test "unfinished edits and invalid words remain bounded" {
    var lexer: Lexer = .{ .text = wide("notJSON {\"key\": \"unfinished\\") };
    try testing.expectEqual(Kind.key, lexer.next().?.kind);
    const value = lexer.next().?;
    try testing.expectEqual(Kind.string, value.kind);
    try testing.expectEqual(lexer.text.len, value.end);
    try testing.expectEqual(null, lexer.next());
}

test "color ranges count UTF-16 units including surrogate pairs" {
    var lexer: Lexer = .{ .text = wide("{\"x\":\"😀\",\"y\":42}") };
    _ = lexer.next();
    const emoji = lexer.next().?;
    try testing.expectEqual(4, emoji.end - emoji.start);
    const key = lexer.next().?;
    try testing.expectEqualStrings("key", @tagName(key.kind));
    try testing.expectEqual(10, key.start);
    const number = lexer.next().?;
    try testing.expectEqual(14, number.start);
    try testing.expectEqual(16, number.end);
}
