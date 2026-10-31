//! Checks assertions against a response and reports the results.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Order = std.math.Order;
const json = std.json;
const model = @import("assertion.zig");
const Assertion = model.Assertion;
const Literal = model.Literal;
const Operator = model.Operator;
const Step = model.Step;
const Target = model.Target;
const Response = @import("../http/response.zig").Response;
const redact = @import("../redact.zig").redact;

/// How much of a value a failure message shows.
const max_shown = 200;

pub const Result = struct {
    assertion: Assertion,
    passed: bool,
    /// What was found, written like the assertion, such as `status == 500`.
    actual: []const u8,
};

const Value = union(enum) {
    missing,
    not_json,
    duration_ns: u64,
    /// A header or raw body, which has no type of its own.
    text: []const u8,
    json: json.Value,
};

/// Every result is owned by `arena`, which must outlive it. `secrets` are hidden
/// in `Result.actual`.
pub fn evaluate(arena: Allocator, response: Response, assertions: []const Assertion, secrets: []const []const u8) Allocator.Error![]const Result {
    const document = try parseBody(arena, response.body, assertions);
    const results = try arena.alloc(Result, assertions.len);
    for (results, assertions) |*result, assertion| {
        const value = try resolve(arena, assertion.target, response, document);
        result.* = .{
            .assertion = assertion,
            .passed = holds(assertion.op, value, assertion.expected),
            .actual = try describeActual(arena, assertion.name, value, secrets),
        };
    }
    return results;
}

pub const Extracted = union(enum) {
    value: []const u8,
    /// Why there is no value, written like `Result.actual`.
    problem: []const u8,
};

/// Reads `target` as text for a variable. JSON strings lose their quotes, and
/// `response_time` is in milliseconds. `name` is the target's source text.
pub fn extract(arena: Allocator, response: Response, target: Target, name: []const u8) Allocator.Error!Extracted {
    const needs_json = target == .body and target.body.len > 0;
    const document = if (needs_json) try parseJson(arena, response.body) else null;
    const value = try resolve(arena, target, response, document);
    return switch (value) {
        .missing, .not_json => .{ .problem = try describeActual(arena, name, value, &.{}) },
        .duration_ns => |ns| .{ .value = try std.fmt.allocPrint(arena, "{d}", .{ns / std.time.ns_per_ms}) },
        .text => |text| .{ .value = text },
        .json => |v| .{ .value = switch (v) {
            .string => |text| text,
            .number_string => |text| text,
            else => try json.Stringify.valueAlloc(arena, v, .{}),
        } },
    };
}

pub fn countFailed(results: []const Result) usize {
    var failed: usize = 0;
    for (results) |result| {
        if (!result.passed) failed += 1;
    }
    return failed;
}

pub fn printReport(out: *Io.Writer, results: []const Result) Io.Writer.Error!void {
    for (results, 0..) |result, i| {
        if (result.passed) {
            try out.print("PASSED {s}\n", .{result.assertion.text});
        } else {
            if (i > 0 and results[i - 1].passed) try out.writeByte('\n');
            try out.print(
                "FAILED\n\nExpected:\n{s}\n\nActual:\n{s}\n\n",
                .{ result.assertion.text, result.actual },
            );
        }
    }
    const failed = countFailed(results);
    try out.print("{d} passed, {d} failed\n", .{ results.len - failed, failed });
}

/// Null when the body is not JSON. Skipped unless an assertion needs it,
/// because a large body is expensive to parse.
fn parseBody(arena: Allocator, body: []const u8, assertions: []const Assertion) Allocator.Error!?json.Value {
    for (assertions) |assertion| {
        if (assertion.target == .body and assertion.target.body.len > 0) break;
    } else return null;
    return parseJson(arena, body);
}

fn parseJson(arena: Allocator, body: []const u8) Allocator.Error!?json.Value {
    return json.parseFromSliceLeaky(json.Value, arena, body, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => null,
    };
}

fn resolve(arena: Allocator, target: Target, response: Response, document: ?json.Value) Allocator.Error!Value {
    return switch (target) {
        .status => .{ .json = .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{response.status}) } },
        .response_time => .{ .duration_ns = response.duration_ns },
        .header => |name| if (response.header(name)) |value| .{ .text = value } else .missing,
        .body => |path| if (path.len == 0) rawBody(response.body) else if (document) |root| lookup(root, path) else .not_json,
    };
}

fn rawBody(body: []const u8) Value {
    return if (body.len == 0) .missing else .{ .text = body };
}

fn lookup(root: json.Value, path: []const Step) Value {
    var value = root;
    for (path) |step| {
        value = switch (step) {
            .key => |key| if (value == .object) value.object.get(key) orelse return .missing else return .missing,
            .index => |index| if (value == .array and index < value.array.items.len) value.array.items[index] else return .missing,
        };
    }
    return .{ .json = value };
}

/// A value that could not be found fails every check but `not_exists`, so a
/// typo in a path never passes a `!=` by accident.
fn holds(op: Operator, value: Value, expected: Literal) bool {
    if (value == .not_json) return false;
    if (value == .missing) return op == .not_exists;
    return switch (op) {
        .exists => true,
        .not_exists => false,
        .eq => equal(value, expected),
        .ne => !equal(value, expected),
        .gt => compare(value, expected) == .gt,
        .lt => compare(value, expected) == .lt,
        .ge => if (compare(value, expected)) |order| order != .lt else false,
        .le => if (compare(value, expected)) |order| order != .gt else false,
        .contains => contains(value, expected.string),
        .starts_with => if (textOf(value)) |text| std.mem.startsWith(u8, text, expected.string) else false,
        .ends_with => if (textOf(value)) |text| std.mem.endsWith(u8, text, expected.string) else false,
    };
}

fn equal(value: Value, expected: Literal) bool {
    return switch (expected) {
        .none => unreachable,
        .null => value == .json and value.json == .null,
        .boolean => |boolean| value == .json and value.json == .bool and value.json.bool == boolean,
        .number, .duration_ns => compare(value, expected) == .eq,
        .string => |string| if (textOf(value)) |text| std.mem.eql(u8, text, string) else false,
    };
}

/// Null when the two are not both numbers.
fn compare(value: Value, expected: Literal) ?Order {
    switch (expected) {
        .duration_ns => |ns| return if (value == .duration_ns) std.math.order(value.duration_ns, ns) else null,
        .number => |number| return switch (value) {
            .text => |text| compareNumbers(text, number),
            .json => |v| if (v == .number_string) compareNumbers(v.number_string, number) else null,
            else => null,
        },
        else => return null,
    }
}

/// Integers compare exactly first, because `f64` cannot hold large IDs.
fn compareNumbers(a: []const u8, b: []const u8) ?Order {
    if (!model.isNumber(a) or !model.isNumber(b)) return null;
    if (std.fmt.parseInt(i128, a, 10)) |x| {
        if (std.fmt.parseInt(i128, b, 10)) |y| return std.math.order(x, y) else |_| {}
    } else |_| {}
    const x = std.fmt.parseFloat(f64, a) catch return null;
    const y = std.fmt.parseFloat(f64, b) catch return null;
    return std.math.order(x, y);
}

fn contains(value: Value, needle: []const u8) bool {
    if (value == .json and value.json == .array) {
        for (value.json.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
        }
        return false;
    }
    const text = textOf(value) orelse return false;
    return std.mem.find(u8, text, needle) != null;
}

fn textOf(value: Value) ?[]const u8 {
    return switch (value) {
        .text => |text| text,
        .json => |v| if (v == .string) v.string else null,
        else => null,
    };
}

/// Secrets go before shortening, which could otherwise show the start of one.
fn describeActual(arena: Allocator, name: []const u8, value: Value, secrets: []const []const u8) Allocator.Error![]const u8 {
    return switch (value) {
        .missing => std.fmt.allocPrint(arena, "{s} is missing", .{name}),
        .not_json => "body is not valid JSON",
        .duration_ns => |ns| std.fmt.allocPrint(arena, "{s} == {d}ms", .{ name, ns / std.time.ns_per_ms }),
        .text => |text| std.fmt.allocPrint(arena, "{s} == {s}", .{ name, try showText(arena, text, secrets) }),
        .json => |v| if (v == .string)
            std.fmt.allocPrint(arena, "{s} == {s}", .{ name, try showText(arena, v.string, secrets) })
        else
            std.fmt.allocPrint(arena, "{s} == {s}", .{ name, shorten(try redact(arena, try json.Stringify.valueAlloc(arena, v, .{}), secrets)) }),
    };
}

/// Quoted and escaped, so a response cannot send control codes to the terminal.
fn showText(arena: Allocator, text: []const u8, secrets: []const []const u8) Allocator.Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return "<binary data>";
    return json.Stringify.valueAlloc(arena, shorten(try redact(arena, text, secrets)), .{});
}

fn shorten(text: []const u8) []const u8 {
    if (text.len <= max_shown) return text;
    var end: usize = max_shown;
    while ((text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

const sample_body =
    \\{"success":true,"token":"abc","nothing":null,"total":3,"price":1.50,
    \\"id":12345678901234567890,"tags":["new","sale"],
    \\"user":{"id":7,"name":"Ada"},"items":[{"name":"Apple"},{"name":"Pear"}]}
;

const sample: Response = .{
    .status = 200,
    .status_text = "OK",
    .headers = &.{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Content-Length", .value = "128" },
    },
    .cookies = &.{},
    .body = sample_body,
    .duration_ns = 82 * std.time.ns_per_ms,
};

fn run(arena: Allocator, response: Response, text: []const u8) !Result {
    const assertion = try model.parse(arena, text);
    const results = try evaluate(arena, response, &.{assertion}, &.{});
    return results[0];
}

fn expectAll(response: Response, passed: bool, texts: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (texts) |text| {
        const result = try run(arena.allocator(), response, text);
        if (result.passed != passed) {
            std.debug.print("wrong result for: {s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

test "status compares as a number" {
    try expectAll(sample, true, &.{ "status == 200", "status != 404", "status > 199", "status < 201", "status >= 200", "status <= 200" });
    try expectAll(sample, false, &.{ "status == 404", "status != 200", "status > 200", "status < 200", "status >= 201", "status <= 199" });
}

test "response time compares as a duration" {
    try expectAll(sample, true, &.{ "response_time < 83ms", "response_time <= 82ms", "response_time > 0.05s", "response_time >= 82ms" });
    try expectAll(sample, false, &.{ "response_time < 82ms", "response_time <= 81ms", "response_time > 1s", "response_time >= 83ms" });
}

test "body properties are found through objects and arrays" {
    try expectAll(sample, true, &.{
        "body.success == true",
        "body.token exists",
        "body.user.id == 7",
        "body.user.name == \"Ada\"",
        "body.items[1].name == \"Pear\"",
        "body.nothing == null",
        "body.nothing exists",
        "body.gone not_exists",
        "body.user.gone not_exists",
        "body.items[9] not_exists",
        "body.tags[0].x not_exists",
    });
    try expectAll(sample, false, &.{ "body.gone exists", "body.token not_exists", "body.items[9].name == \"Pear\"" });
}

test "a missing value fails every comparison" {
    try expectAll(sample, false, &.{ "body.gone == null", "body.gone != 5", "body.gone contains \"x\"", "header.gone != \"x\"" });
}

test "body text operators" {
    try expectAll(sample, true, &.{
        "body.token != \"zzz\"",
        "body.token contains \"b\"",
        "body.token starts_with \"ab\"",
        "body.token ends_with \"bc\"",
        "body.tags contains \"sale\"",
    });
    try expectAll(sample, false, &.{
        "body.token contains \"z\"",
        "body.token starts_with \"bc\"",
        "body.token ends_with \"ab\"",
        "body.tags contains \"sal\"",
        "body.total contains \"3\"",
    });
}

test "types are not mixed" {
    try expectAll(sample, false, &.{ "body.total == \"3\"", "body.token == 3", "body.success == 1", "body.nothing == 0", "body.token > 1" });
    try expectAll(sample, true, &.{"body.total != \"3\""});
}

test "numbers compare by value and stay exact" {
    try expectAll(sample, true, &.{
        "body.price == 1.5",
        "body.total == 3.0",
        "body.total > 2.5",
        "body.id == 12345678901234567890",
    });
    try expectAll(sample, false, &.{"body.id == 12345678901234567891"});
}

test "headers ignore name case and read as numbers when compared to one" {
    try expectAll(sample, true, &.{
        "header.content-type exists",
        "header.CONTENT-TYPE contains \"json\"",
        "header.content-type starts_with \"application/\"",
        "header.etag not_exists",
        "header.content-length == \"128\"",
        "header.content-length > 100",
    });
    try expectAll(sample, false, &.{ "header.etag exists", "header.content-type == \"text/plain\"", "header.content-type > 1" });
}

test "the bare body is its raw text" {
    var response = sample;
    response.body = "hello world";
    try expectAll(response, true, &.{ "body == \"hello world\"", "body contains \"lo w\"", "body exists" });

    response.body = "";
    try expectAll(response, true, &.{"body not_exists"});
    try expectAll(response, false, &.{"body exists"});
}

test "a path into a non-JSON body fails with a reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var response = sample;
    response.body = "<html>";

    const allocator = arena.allocator();
    const result = try run(allocator, response, "body.token not_exists");
    try testing.expect(!result.passed);
    try testing.expectEqualStrings("body is not valid JSON", result.actual);
}

test "a repeated JSON key uses the last value" {
    var response = sample;
    response.body = "{\"a\":1,\"a\":2}";
    try expectAll(response, true, &.{"body.a == 2"});
}

test "actual values are written like the assertion" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_][2][]const u8{
        .{ "status == 500", "status == 200" },
        .{ "response_time < 1ms", "response_time == 82ms" },
        .{ "body.token == \"x\"", "body.token == \"abc\"" },
        .{ "body.total == 9", "body.total == 3" },
        .{ "body.user not_exists", "body.user == {\"id\":7,\"name\":\"Ada\"}" },
        .{ "body.gone exists", "body.gone is missing" },
    };
    for (cases) |case| {
        const result = try run(allocator, sample, case[0]);
        try testing.expectEqualStrings(case[1], result.actual);
    }
}

test "binary and control characters never reach the output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var response = sample;

    response.body = "\xff\xfe\x00";
    try testing.expectEqualStrings("body == <binary data>", (try run(allocator, response, "body == \"x\"")).actual);

    response.body = "\x1b[31mred\n";
    try testing.expectEqualStrings("body == \"\\u001b[31mred\\n\"", (try run(allocator, response, "body == \"x\"")).actual);
}

test "long values are cut on a character boundary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const start: [max_shown - 1]u8 = @splat('a');
    var response = sample;
    response.body = start ++ "é" ++ "b";
    const result = try run(allocator, response, "body == \"x\"");
    try testing.expectEqualStrings("body == \"" ++ start ++ "\"", result.actual);
}

test "extract reads each kind of value as text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_][2][]const u8{
        .{ "status", "200" },
        .{ "response_time", "82" },
        .{ "header.content-length", "128" },
        .{ "body.token", "abc" },
        .{ "body.total", "3" },
        .{ "body.id", "12345678901234567890" },
        .{ "body.success", "true" },
        .{ "body.nothing", "null" },
        .{ "body.user", "{\"id\":7,\"name\":\"Ada\"}" },
    };
    for (cases) |case| {
        const target = try model.parseTarget(allocator, case[0]);
        const extracted = try extract(allocator, sample, target, case[0]);
        try testing.expectEqualStrings(case[1], extracted.value);
    }
}

test "extract says why a value is not there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const gone = try model.parseTarget(allocator, "body.gone");
    try testing.expectEqualStrings("body.gone is missing", (try extract(allocator, sample, gone, "body.gone")).problem);

    var response = sample;
    response.body = "<html>";
    try testing.expectEqualStrings("body is not valid JSON", (try extract(allocator, response, gone, "body.gone")).problem);
}

test "the report matches the documented failure format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var response = sample;
    response.status = 500;

    const results = try evaluate(allocator, response, &.{
        try model.parse(allocator, "status == 200"),
        try model.parse(allocator, "body.token exists"),
    }, &.{});
    try testing.expectEqual(1, countFailed(results));

    var buffer: [128]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try printReport(&out, results);
    try testing.expectEqualStrings(
        \\FAILED
        \\
        \\Expected:
        \\status == 200
        \\
        \\Actual:
        \\status == 500
        \\
        \\PASSED body.token exists
        \\1 passed, 1 failed
        \\
    , out.buffered());
}

test "secrets are hidden in what a check found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Shortening alone would cut this one in the middle of the secret.
    const padding = try allocator.alloc(u8, max_shown - 3);
    @memset(padding, 'x');
    var response = sample;
    response.body = try std.fmt.allocPrint(allocator, "{{\"token\":\"secret\",\"list\":[\"secret\"],\"long\":\"{s}secret\"}}", .{padding});
    const results = try evaluate(allocator, response, &.{
        try model.parse(allocator, "body.token == \"x\""),
        try model.parse(allocator, "body.list == \"x\""),
        try model.parse(allocator, "body.long == \"x\""),
        try model.parse(allocator, "body == \"x\""),
    }, &.{"secret"});
    for (results) |result| {
        try testing.expectEqual(null, std.mem.find(u8, result.actual, "sec"));
    }
    try testing.expectEqualStrings("body.token == \"********\"", results[0].actual);
}
