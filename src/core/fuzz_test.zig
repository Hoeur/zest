//! Fuzz tests for code that reads untrusted text: `.ztest` files, assertions,
//! desktop drafts, `ztest.json` and `{{variable}}` templates.
//!
//! Each property runs two ways. `zig build test --fuzz` explores inputs with the
//! fuzzer. A plain `zig build test` replays a fixed number of seeded mutations
//! of the corpus, so CI catches regressions without the fuzzer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assertion = @import("assertions/assertion.zig");
const evaluate = @import("assertions/evaluate.zig");
const config = @import("config.zig");
const draft = @import("http/draft.zig");
const parser = @import("parser/parser.zig");
const writer = @import("parser/writer.zig");
const redact = @import("redact.zig").redact;
const variables = @import("runner/variables.zig");

const testing = std.testing;

const suite_corpus = [_][]const u8{
    "suite \"S\"\ntest \"T\"\nGET u\nexpect status == 200\nend\n",
    \\suite "Auth"
    \\var base = "https://a.test"
    \\var secret key = "k"
    \\setup
    \\  POST {{base}}/login
    \\  header Content-Type application/json
    \\  body { "user": "ada", "list": [1, "]", {"x": null}] }
    \\  expect status == 200
    \\  extract secret token = body.token
    \\end
    \\test "Read"
    \\  timeout 2s
    \\  GET {{base}}/me#frag
    \\  query q a b
    \\  auth bearer {{token}}
    \\  expect body.items[0].name == "Apple"
    \\  expect response_time < 500ms
    \\end
    \\test "Skip"
    \\  skip
    \\  DELETE {{base}}/x
    \\  auth basic u p
    \\  body "raw\ntext"
    \\end
    \\teardown
    \\  DELETE {{base}}/session
    \\end
    \\
    ,
    "\xEF\xBB\xBFsuite \"S\"\r\n# c\r\ntest \"T\"\r\nGET u\r\nbody [\r\n1\r\n]\r\nend\r\n",
};

const assertion_corpus = [_][]const u8{
    "status == 200",
    "body.items[0].name == \"Apple\"",
    "response_time <= 1.5s",
    "header.content-type contains \"json\"",
    "body.a.b[2] not_exists",
    "body != null",
};

/// Parsing never crashes, and a parsed suite either cannot be written or
/// writes text that parses and writes back to the same text.
fn checkSuite(source: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: parser.Diagnostic = .{};
    const suite = parser.parse(arena, source, &diagnostic) catch |err| switch (err) {
        error.SyntaxError => {
            try testing.expect(diagnostic.message.len > 0);
            return;
        },
        error.OutOfMemory => |e| return e,
    };

    var write_diagnostic: writer.Diagnostic = .{};
    var first: Io.Writer.Allocating = .init(arena);
    writer.write(&first.writer, suite, &write_diagnostic) catch |err| switch (err) {
        error.Unrepresentable => return,
        error.WriteFailed => return error.OutOfMemory,
    };
    const reparsed = parser.parse(arena, first.written(), &diagnostic) catch |err| {
        std.debug.print("written suite does not parse: {s} (line {d})\n{s}\n", .{ diagnostic.message, diagnostic.line, first.written() });
        return err;
    };
    var second: Io.Writer.Allocating = .init(arena);
    try writer.write(&second.writer, reparsed, &write_diagnostic);
    try testing.expectEqualStrings(first.written(), second.written());
}

/// Parsing an assertion never crashes, and one that parses can be checked
/// against JSON and non-JSON bodies.
fn checkAssertion(text: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = assertion.parse(arena, text) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return,
    };
    for ([_][]const u8{ "{\"items\":[{\"name\":\"Apple\"}],\"a\":{\"b\":[1,2,3]}}", "not json", "" }) |body| {
        const response: @import("http/response.zig").Response = .{
            .status = 200,
            .status_text = "OK",
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .cookies = &.{},
            .body = body,
            .duration_ns = 1_000_000,
        };
        const results = try evaluate.evaluate(arena, response, &.{parsed}, &.{"Apple"});
        try testing.expectEqual(1, results.len);
        try testing.expect(std.mem.find(u8, results[0].actual, "Apple") == null);
        _ = try evaluate.extract(arena, response, parsed.target, parsed.name);
    }
}

/// Splits input at the first NUL into headers and body, as the desktop editors
/// would hand them over.
fn checkDraft(input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const split = std.mem.findScalar(u8, input, 0) orelse input.len;
    const headers = input[0..split];
    const body = if (split < input.len) input[split + 1 ..] else "";
    for ([_]draft.BodyKind{ .none, .raw, .json }) |kind| {
        var diagnostic: draft.Diagnostic = .{};
        const request = draft.prepare(arena_state.allocator(), .{ .url = "http://a.test", .headers = headers, .body_kind = kind, .body = body }, &diagnostic) catch continue;
        for (request.headers) |h| try @import("http/request.zig").checkHeader(h);
    }
}

fn checkConfig(text: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = config.parse(arena_state.allocator(), text) catch return;
}

/// Interpolation either names a missing variable or leaves no defined
/// `{{name}}` behind, and redaction leaves no secret behind.
fn checkTemplate(text: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const runtime: variables.Runtime = .empty;
    const scope: variables.Scope = .{
        .runtime = &runtime,
        .case = &.{.{ .name = "a", .value = "1", .line = 1 }},
        .suite = &.{.{ .name = "b", .value = "{{a}}", .line = 1 }},
    };
    var missing: []const u8 = "";
    const filled = variables.interpolate(arena, text, scope, &missing) catch |err| switch (err) {
        error.MissingVariable => {
            try testing.expect(missing.len > 0);
            return;
        },
        error.OutOfMemory => |e| return e,
    };
    const hidden = try redact(arena, filled, &.{ "1", "secret" });
    try testing.expect(std.mem.find(u8, hidden, "secret") == null);
    try testing.expect(std.mem.findScalar(u8, hidden, '1') == null);
}

// Fuzzer entry points ------------------------------------------------------

fn fuzzWith(comptime check: fn ([]const u8) anyerror!void) fn (void, *testing.Smith) anyerror!void {
    return struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [2048]u8 = undefined;
            const len = smith.slice(&buffer);
            try check(buffer[0..len]);
        }
    }.testOne;
}

test "fuzz: .ztest parsing and writing" {
    try testing.fuzz({}, fuzzWith(checkSuite), .{ .corpus = &suite_corpus });
}

test "fuzz: assertions" {
    try testing.fuzz({}, fuzzWith(checkAssertion), .{ .corpus = &assertion_corpus });
}

test "fuzz: desktop drafts" {
    try testing.fuzz({}, fuzzWith(checkDraft), .{ .corpus = &.{ "X-A: 1\r\nX-B:\x00{\"a\":1}", "Bad Name: x\x00[" } });
}

test "fuzz: ztest.json" {
    try testing.fuzz({}, fuzzWith(checkConfig), .{ .corpus = &.{"{\"variables\":{\"a\":1},\"environments\":{\"s\":{\"k\":{\"env\":\"K\"}}}}"} });
}

test "fuzz: templates and redaction" {
    try testing.fuzz({}, fuzzWith(checkTemplate), .{ .corpus = &.{ "{{a}} {{b}} {{ c }} {{}}", "x{{a}}y{{a" } });
}

// Seeded mutations for every test run ---------------------------------------

const mutation_rounds = 1500;

/// Applies a few random edits that favour the format's own bytes, so inputs
/// stay close enough to valid to reach deep into the parser.
fn mutate(random: std.Random, out: *std.ArrayList(u8), arena: Allocator, seed: []const u8) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(arena, seed);
    const interesting = "{}[]\"\\\n\r# =<>!.0123456789aez \t\x00\xff";
    const edits = random.intRangeAtMost(usize, 1, 6);
    for (0..edits) |_| {
        const at = if (out.items.len == 0) 0 else random.uintLessThan(usize, out.items.len + 1);
        switch (random.uintLessThan(u8, 5)) {
            0 => try out.insert(arena, at, interesting[random.uintLessThan(usize, interesting.len)]),
            1 => if (at < out.items.len) {
                _ = out.orderedRemove(at);
            },
            2 => if (at < out.items.len) {
                out.items[at] = random.int(u8);
            },
            3 => if (out.items.len > 0) {
                // Cut the input short anywhere.
                out.shrinkRetainingCapacity(at);
            },
            else => if (at < out.items.len) {
                // Duplicate a run of bytes.
                const end = @min(out.items.len, at + random.uintLessThan(usize, 24));
                const copy = try arena.dupe(u8, out.items[at..end]);
                try out.insertSlice(arena, at, copy);
            },
        }
    }
}

fn replay(comptime check: fn ([]const u8) anyerror!void, corpus: []const []const u8, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input: std.ArrayList(u8) = .empty;
    for (corpus) |entry| try check(entry);
    for (0..mutation_rounds) |_| {
        try mutate(random, &input, arena, corpus[random.uintLessThan(usize, corpus.len)]);
        check(input.items) catch |err| {
            std.debug.print("failing input: {any}\n", .{input.items});
            return err;
        };
    }
}

test "mutated .ztest files never crash and round-trip when written" {
    try replay(checkSuite, &suite_corpus, 0x5eed_2026);
}

test "mutated assertions never crash" {
    try replay(checkAssertion, &assertion_corpus, 0xa55e_7);
}

test "mutated drafts never produce an unsafe header" {
    try replay(checkDraft, &.{ "X-A: 1\r\nX-B:\x00{\"a\":1}", "Bad Name: x\x00[", "\r\n:\n\x00\"" }, 0xd7af7);
}

test "mutated ztest.json never crashes" {
    try replay(checkConfig, &.{"{\"variables\":{\"a\":1,\"b\":\"x\",\"c\":true},\"environments\":{\"s\":{\"k\":{\"env\":\"K\"}}}}"}, 0xc0f1);
}

test "mutated templates never leak a secret" {
    try replay(checkTemplate, &.{ "{{a}} {{b}} {{ c }} {{}}", "x{{a}}y{{a", "{{{{a}}}}" }, 0x7e3a);
}
