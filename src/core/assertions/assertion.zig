//! The assertion model and its text form, such as `body.items[0].id == 7`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Step = union(enum) {
    key: []const u8,
    index: usize,
};

pub const Target = union(enum) {
    status,
    response_time,
    /// The raw body when the path is empty, otherwise a value in its JSON.
    body: []const Step,
    /// Matched ignoring case.
    header: []const u8,
};

pub const Operator = enum {
    eq,
    ne,
    gt,
    lt,
    ge,
    le,
    exists,
    not_exists,
    contains,
    starts_with,
    ends_with,

    pub fn symbol(op: Operator) []const u8 {
        return switch (op) {
            .eq => "==",
            .ne => "!=",
            .gt => ">",
            .lt => "<",
            .ge => ">=",
            .le => "<=",
            else => @tagName(op),
        };
    }

    fn isOrdering(op: Operator) bool {
        return switch (op) {
            .gt, .lt, .ge, .le => true,
            else => false,
        };
    }

    fn isPresence(op: Operator) bool {
        return op == .exists or op == .not_exists;
    }
};

pub const Literal = union(enum) {
    none,
    null,
    boolean: bool,
    /// Kept as text, so large or precise values compare exactly.
    number: []const u8,
    string: []const u8,
    duration_ns: u64,
};

pub const Assertion = struct {
    /// The source text, shown when reporting a result.
    text: []const u8,
    /// The part of `text` that names the target.
    name: []const u8,
    target: Target,
    op: Operator,
    expected: Literal,
};

pub const ParseError = Allocator.Error || error{
    MissingOperator,
    UnknownTarget,
    InvalidPath,
    UnknownOperator,
    MissingValue,
    UnexpectedValue,
    InvalidValue,
    WrongValueType,
};

pub fn describe(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.MissingOperator => "expected <target> <operator> [value]",
        error.UnknownTarget => "the target must be status, response_time, body, body.<path> or header.<name>",
        error.InvalidPath => "a path looks like body.items[0].name",
        error.UnknownOperator => "the operator must be ==, !=, >, <, >=, <=, exists, not_exists, contains, starts_with or ends_with",
        error.MissingValue => "this operator needs a value",
        error.UnexpectedValue => "exists and not_exists take no value",
        error.InvalidValue => "the value must be a quoted string, number, true, false, null, or a time such as 500ms or 2s",
        error.WrongValueType => "this target and operator cannot use this value",
    };
}

/// Allocations are not freed individually, so pass an arena. `text` must
/// outlive the result.
pub fn parse(arena: Allocator, text: []const u8) ParseError!Assertion {
    const trimmed = std.mem.trim(u8, text, " ");
    const name_end = std.mem.findScalar(u8, trimmed, ' ') orelse return error.MissingOperator;
    const name = trimmed[0..name_end];
    const after_name = std.mem.trimStart(u8, trimmed[name_end..], " ");
    const op_end = std.mem.findScalar(u8, after_name, ' ') orelse after_name.len;

    const assertion: Assertion = .{
        .text = trimmed,
        .name = name,
        .target = try parseTarget(arena, name),
        .op = parseOperator(after_name[0..op_end]) orelse return error.UnknownOperator,
        .expected = try parseLiteral(arena, std.mem.trim(u8, after_name[op_end..], " ")),
    };
    try check(assertion);
    return assertion;
}

pub fn parseTarget(arena: Allocator, name: []const u8) ParseError!Target {
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "response_time")) return .response_time;
    if (std.mem.eql(u8, name, "body")) return .{ .body = &.{} };

    const header_prefix = "header.";
    if (std.mem.startsWith(u8, name, header_prefix)) {
        if (name.len == header_prefix.len) return error.InvalidPath;
        return .{ .header = name[header_prefix.len..] };
    }
    if (std.mem.startsWith(u8, name, "body.") or std.mem.startsWith(u8, name, "body[")) {
        return .{ .body = try parsePath(arena, name["body".len..]) };
    }
    return error.UnknownTarget;
}

fn parsePath(arena: Allocator, path: []const u8) ParseError![]const Step {
    var steps: std.ArrayList(Step) = .empty;
    var rest = path;
    while (rest.len > 0) {
        if (rest[0] == '.') {
            const end = std.mem.findAny(u8, rest[1..], ".[") orelse rest.len - 1;
            if (end == 0) return error.InvalidPath;
            try steps.append(arena, .{ .key = rest[1..][0..end] });
            rest = rest[1 + end ..];
        } else if (rest[0] == '[') {
            const end = std.mem.findScalar(u8, rest, ']') orelse return error.InvalidPath;
            const index = std.fmt.parseInt(usize, rest[1..end], 10) catch return error.InvalidPath;
            try steps.append(arena, .{ .index = index });
            rest = rest[end + 1 ..];
        } else {
            return error.InvalidPath;
        }
    }
    return steps.items;
}

fn parseOperator(text: []const u8) ?Operator {
    for (std.enums.values(Operator)) |op| {
        if (std.mem.eql(u8, text, op.symbol())) return op;
    }
    return null;
}

fn parseLiteral(arena: Allocator, text: []const u8) ParseError!Literal {
    if (text.len == 0) return .none;
    if (std.mem.eql(u8, text, "null")) return .null;
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (text[0] == '"') {
        // JSON rules, so quotes and line breaks can be escaped.
        const string = std.json.parseFromSliceLeaky([]const u8, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.InvalidValue,
        };
        return .{ .string = string };
    }
    if (isNumber(text)) return .{ .number = text };
    if (parseDuration(text)) |ns| return .{ .duration_ns = ns };
    return error.InvalidValue;
}

/// Rejects the `nan` and `inf` that `parseFloat` would otherwise accept.
pub fn isNumber(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isDigit(text[0]) or text[0] == '-')) return false;
    const value = std.fmt.parseFloat(f64, text) catch return false;
    return std.math.isFinite(value);
}

/// A number with an `ms` or `s` unit, in nanoseconds.
pub fn parseDuration(text: []const u8) ?u64 {
    const unit: struct { digits: []const u8, ns: f64 } = if (std.mem.endsWith(u8, text, "ms"))
        .{ .digits = text[0 .. text.len - 2], .ns = std.time.ns_per_ms }
    else if (std.mem.endsWith(u8, text, "s"))
        .{ .digits = text[0 .. text.len - 1], .ns = std.time.ns_per_s }
    else
        return null;
    if (!isNumber(unit.digits) or unit.digits[0] == '-') return null;
    const scaled = (std.fmt.parseFloat(f64, unit.digits) catch return null) * unit.ns;
    return std.math.lossyCast(u64, scaled);
}

/// Rejects combinations that could never mean anything, so a typo is a usage
/// error and not a test that always fails.
fn check(a: Assertion) ParseError!void {
    if (a.op.isPresence()) {
        if (a.expected != .none) return error.UnexpectedValue;
    } else if (a.expected == .none) {
        return error.MissingValue;
    }

    switch (a.target) {
        .status => if (a.op.isPresence() or a.expected != .number) return error.WrongValueType,
        .response_time => if (a.op.isPresence() or a.expected != .duration_ns) return error.WrongValueType,
        .body, .header => if (a.expected == .duration_ns) return error.WrongValueType,
    }
    if (a.op.isOrdering() and a.expected == .string) return error.WrongValueType;
    if (a.op.isOrdering() and (a.expected == .boolean or a.expected == .null)) return error.WrongValueType;
    switch (a.op) {
        .contains, .starts_with, .ends_with => if (a.expected != .string) return error.WrongValueType,
        else => {},
    }
}

const testing = std.testing;

fn parseTest(arena: *std.heap.ArenaAllocator, text: []const u8) ParseError!Assertion {
    return parse(arena.allocator(), text);
}

test "every operator is parsed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(Operator.eq, (try parseTest(&arena, "status == 200")).op);
    try testing.expectEqual(Operator.ne, (try parseTest(&arena, "status != 200")).op);
    try testing.expectEqual(Operator.gt, (try parseTest(&arena, "status > 200")).op);
    try testing.expectEqual(Operator.lt, (try parseTest(&arena, "status < 200")).op);
    try testing.expectEqual(Operator.ge, (try parseTest(&arena, "status >= 200")).op);
    try testing.expectEqual(Operator.le, (try parseTest(&arena, "status <= 200")).op);
    try testing.expectEqual(Operator.exists, (try parseTest(&arena, "body.a exists")).op);
    try testing.expectEqual(Operator.not_exists, (try parseTest(&arena, "body.a not_exists")).op);
    try testing.expectEqual(Operator.contains, (try parseTest(&arena, "body.a contains \"x\"")).op);
    try testing.expectEqual(Operator.starts_with, (try parseTest(&arena, "body.a starts_with \"x\"")).op);
    try testing.expectEqual(Operator.ends_with, (try parseTest(&arena, "body.a ends_with \"x\"")).op);
}

test "paths mix keys and indexes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const a = try parseTest(&arena, "body.items[0].name == \"Apple\"");
    try testing.expectEqualStrings("body.items[0].name", a.name);
    const steps = a.target.body;
    try testing.expectEqual(3, steps.len);
    try testing.expectEqualStrings("items", steps[0].key);
    try testing.expectEqual(0, steps[1].index);
    try testing.expectEqualStrings("name", steps[2].key);

    try testing.expectEqual(2, (try parseTest(&arena, "body[1][2] exists")).target.body.len);
    try testing.expectEqual(0, (try parseTest(&arena, "body exists")).target.body.len);
}

test "header names keep their dashes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const a = try parseTest(&arena, "header.content-type contains \"json\"");
    try testing.expectEqualStrings("content-type", a.target.header);
}

test "values keep their type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(Literal.null, (try parseTest(&arena, "body.a == null")).expected);
    try testing.expectEqual(true, (try parseTest(&arena, "body.a == true")).expected.boolean);
    try testing.expectEqualStrings("-1.5", (try parseTest(&arena, "body.a == -1.5")).expected.number);
    try testing.expectEqualStrings(
        "two words \"q\"",
        (try parseTest(&arena, "body.a == \"two words \\\"q\\\"\"")).expected.string,
    );
    try testing.expectEqual(500 * std.time.ns_per_ms, (try parseTest(&arena, "response_time < 500ms")).expected.duration_ns);
    try testing.expectEqual(1500 * std.time.ns_per_ms, (try parseTest(&arena, "response_time < 1.5s")).expected.duration_ns);
}

test "mistakes are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.MissingOperator, parseTest(&arena, "status"));
    try testing.expectError(error.UnknownTarget, parseTest(&arena, "code == 200"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "body. exists"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "body.a..b exists"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "body.a[x] exists"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "body[-1] exists"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "body.a[0 exists"));
    try testing.expectError(error.InvalidPath, parseTest(&arena, "header. exists"));
    try testing.expectError(error.UnknownOperator, parseTest(&arena, "status = 200"));
    try testing.expectError(error.MissingValue, parseTest(&arena, "status =="));
    try testing.expectError(error.UnexpectedValue, parseTest(&arena, "body.a exists 1"));
    try testing.expectError(error.InvalidValue, parseTest(&arena, "body.a == apple"));
    try testing.expectError(error.InvalidValue, parseTest(&arena, "body.a == \"open"));
    try testing.expectError(error.InvalidValue, parseTest(&arena, "body.a == nan"));
    try testing.expectError(error.InvalidValue, parseTest(&arena, "response_time < -5ms"));
}

test "values that do not fit the target are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.WrongValueType, parseTest(&arena, "status == \"200\""));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "status exists"));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "response_time < 500"));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "body.a < 500ms"));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "body.a > \"x\""));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "body.a > true"));
    try testing.expectError(error.WrongValueType, parseTest(&arena, "body.a contains 5"));
}
