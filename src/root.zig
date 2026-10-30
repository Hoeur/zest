//! zest: a small test framework for Zig.
//!
//! Put tests in a struct as `pub fn name(t: *zest.T) !void`, then pass the
//! struct to `zest.run`. Optional `pub fn beforeEach` and `pub fn afterEach`
//! with the same signature run around every test in that struct.
//!
//! Tests and hooks must be `pub`. Zig's reflection cannot see anything else, so
//! one without `pub` is silently ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{ TestFailed, SkipTest };

/// Passed to every test. Assertions return an error, so call them with `try`.
pub const T = struct {
    /// Fresh for each test. Anything not freed fails the test.
    allocator: Allocator,
    io: Io,
    message_buffer: [2048]u8 = undefined,
    message_len: usize = 0,

    pub fn message(t: *const T) []const u8 {
        return t.message_buffer[0..t.message_len];
    }

    /// Fails the test with a formatted message.
    pub fn fail(t: *T, comptime fmt: []const u8, args: anytype) Error {
        t.setMessage(fmt, args);
        return error.TestFailed;
    }

    /// Stops the test and reports it as skipped.
    pub fn skip(t: *T, reason: []const u8) Error {
        t.setMessage("{s}", .{reason});
        return error.SkipTest;
    }

    pub fn expect(t: *T, ok: bool) Error!void {
        if (!ok) return t.fail("expected true, got false", .{});
    }

    /// Deep equality: slices and strings compare by content, not address.
    pub fn equal(t: *T, expected: anytype, actual: anytype) Error!void {
        const U = @TypeOf(expected, actual);
        const e: U = expected;
        const a: U = actual;
        if (deepEql(e, a)) return;

        var w: Io.Writer = .fixed(&t.message_buffer);
        w.writeAll("expected ") catch {};
        printLimited(&w, e, a);
        w.writeAll(", got ") catch {};
        printLimited(&w, a, e);
        t.message_len = w.end;
        return error.TestFailed;
    }

    /// Passes when `actual` is within `tolerance` of `expected`.
    pub fn near(t: *T, expected: f64, actual: f64, tolerance: f64) Error!void {
        // Checked first because infinity minus infinity is NaN.
        if (expected == actual or @abs(expected - actual) <= tolerance) return;
        return t.fail("expected {d} +/- {d}, got {d}", .{ expected, tolerance, actual });
    }

    /// Passes when `haystack` contains `needle`.
    pub fn contains(t: *T, haystack: []const u8, needle: []const u8) Error!void {
        if (std.mem.find(u8, haystack, needle) != null) return;
        return t.fail("expected \"{s}\" to contain \"{s}\"", .{ haystack, needle });
    }

    /// Passes when `result` is exactly the error `expected`.
    pub fn fails(t: *T, expected: anyerror, result: anytype) Error!void {
        if (result) |_| {
            return t.fail("expected error.{s}, but it succeeded", .{@errorName(expected)});
        } else |err| {
            const actual: anyerror = err;
            if (actual == expected) return;
            return t.fail("expected error.{s}, got error.{s}", .{ @errorName(expected), @errorName(actual) });
        }
    }

    fn setMessage(t: *T, comptime fmt: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(&t.message_buffer);
        w.print(fmt, args) catch {};
        t.message_len = w.end;
    }
};

/// A pair of pointers being compared further up the stack.
const Visit = struct {
    a: usize,
    b: usize,
    len: usize,
    previous: ?*const Visit,

    /// Meeting a pair again means the data is cyclic. Only the rest of the
    /// data can still differ, so the repeated pair counts as equal.
    fn repeats(v: *const Visit) bool {
        var next = v.previous;
        while (next) |seen| : (next = seen.previous) {
            if (seen.a == v.a and seen.b == v.b and seen.len == v.len) return true;
        }
        return false;
    }
};

fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    return deepEqlFrom(a, b, null);
}

fn deepEqlFrom(a: anytype, b: @TypeOf(a), seen: ?*const Visit) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (a.len != b.len) return false;
                const visit: Visit = .{ .a = @intFromPtr(a.ptr), .b = @intFromPtr(b.ptr), .len = a.len, .previous = seen };
                if (visit.repeats()) return true;
                for (a, b) |x, y| if (!deepEqlFrom(x, y, &visit)) return false;
                return true;
            },
            .one => switch (@typeInfo(pointer.child)) {
                .@"fn", .@"opaque" => return a == b,
                else => {
                    const visit: Visit = .{ .a = @intFromPtr(a), .b = @intFromPtr(b), .len = 1, .previous = seen };
                    if (visit.repeats()) return true;
                    return deepEqlFrom(a.*, b.*, &visit);
                },
            },
            .many => {
                if (comptime isCString(@TypeOf(a))) return std.mem.orderZ(u8, a, b) == .eq;
                return a == b;
            },
            else => return a == b,
        },
        .array => {
            for (a, b) |x, y| if (!deepEqlFrom(x, y, seen)) return false;
            return true;
        },
        .vector => return @reduce(.And, a == b),
        .@"struct" => |info| {
            inline for (info.field_names) |name| {
                if (!deepEqlFrom(@field(a, name), @field(b, name), seen)) return false;
            }
            return true;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEqlFrom(a.?, b.?, seen);
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("zest: cannot compare untagged union");
            if (@as(Tag, a) != @as(Tag, b)) return false;
            switch (a) {
                inline else => |value, tag| return deepEqlFrom(value, @field(b, @tagName(tag)), seen),
            }
        },
        .error_union => {
            if (a) |x| {
                return if (b) |y| deepEqlFrom(x, y, seen) else |_| false;
            } else |x| {
                return if (b) |_| false else |y| x == y;
            }
        },
        else => return a == b,
    }
}

fn isString(comptime V: type) bool {
    const pointer = switch (@typeInfo(V)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

fn isCString(comptime V: type) bool {
    const pointer = switch (@typeInfo(V)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return pointer.size == .many and pointer.child == u8 and pointer.sentinel() == 0;
}

/// Each value in a failure message gets at most this many bytes, which leaves
/// room for both values in `T.message_buffer`.
const max_value_len = 1000;
/// Bytes kept before the first difference when a long string is shortened.
const diff_context = 32;

/// Prints `value`, shortening it to `max_value_len`. Long strings start near
/// their first difference from `other` so the mismatch stays visible.
fn printLimited(w: *Io.Writer, value: anytype, other: @TypeOf(value)) void {
    var buffer: [max_value_len]u8 = undefined;
    var limited: Io.Writer = .fixed(&buffer);

    if (comptime isString(@TypeOf(value))) {
        const text: []const u8 = value;
        const start = if (text.len > max_value_len or other.len > max_value_len)
            (std.mem.findDiff(u8, text, other) orelse 0) -| diff_context
        else
            0;
        if (start > 0) limited.writeAll("...") catch {};
        printValue(&limited, text[start..]);
    } else {
        printValue(&limited, value);
    }

    if (limited.end == buffer.len) buffer[buffer.len - 3..].* = "...".*;
    w.writeAll(limited.buffered()) catch {};
}

/// Deep enough for real values, and a limit for data that refers to itself.
const max_print_depth = 4;

fn printValue(w: *Io.Writer, value: anytype) void {
    printNested(w, value, 0);
}

fn printNested(w: *Io.Writer, value: anytype, depth: usize) void {
    const V = @TypeOf(value);
    if (comptime isString(V)) {
        w.print("\"{s}\"", .{value}) catch {};
        return;
    }
    if (comptime isCString(V)) {
        w.print("\"{s}\"", .{std.mem.span(value)}) catch {};
        return;
    }
    if (depth < max_print_depth) switch (@typeInfo(V)) {
        .optional => {
            if (value) |inner| return printNested(w, inner, depth + 1);
            w.writeAll("null") catch {};
            return;
        },
        .pointer => |pointer| if (pointer.size == .slice) return printItems(w, value, depth),
        .array => return printItems(w, value, depth),
        .@"struct" => |info| {
            w.writeAll(".{") catch {};
            inline for (info.field_names, 0..) |name, i| {
                w.writeAll(if (i == 0) " ." else ", .") catch {};
                w.print("{s} = ", .{name}) catch {};
                printNested(w, @field(value, name), depth + 1);
            }
            w.writeAll(" }") catch {};
            return;
        },
        else => {},
    };
    w.print("{any}", .{value}) catch {};
}

fn printItems(w: *Io.Writer, items: anytype, depth: usize) void {
    w.writeAll("{") catch {};
    for (items, 0..) |item, i| {
        w.writeAll(if (i == 0) " " else ", ") catch {};
        printNested(w, item, depth + 1);
    }
    w.writeAll(" }") catch {};
}

const TestFn = *const fn (*T) anyerror!void;

const Case = struct {
    name: []const u8,
    func: TestFn,
};

/// Wraps a test so its inferred error set becomes `anyerror`.
fn wrap(comptime func: anytype) TestFn {
    return struct {
        fn call(t: *T) anyerror!void {
            return func(t);
        }
    }.call;
}

fn isTestFn(comptime F: type) bool {
    const info = switch (@typeInfo(F)) {
        .@"fn" => |info| info,
        else => return false,
    };
    return info.param_types.len == 1 and info.param_types[0] == *T;
}

fn isHook(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "beforeEach") or std.mem.eql(u8, name, "afterEach");
}

/// Collects a suite's public test functions in declaration order.
fn casesOf(comptime Suite: type) []const Case {
    return comptime blk: {
        const names = @typeInfo(Suite).@"struct".decl_names;
        @setEvalBranchQuota(1000 + 100 * names.len);
        var cases: []const Case = &.{};
        for (names) |name| {
            if (isHook(name) or !isTestFn(@TypeOf(@field(Suite, name)))) continue;
            cases = cases ++ [_]Case{.{ .name = name, .func = wrap(@field(Suite, name)) }};
        }
        break :blk cases;
    };
}

fn hookOf(comptime Suite: type, comptime name: []const u8) ?TestFn {
    return if (@hasDecl(Suite, name)) wrap(@field(Suite, name)) else null;
}

fn suiteName(comptime Suite: type) []const u8 {
    const name = @typeName(Suite);
    // Dots inside a generic suite's parameters are not part of its path.
    const end = std.mem.findScalar(u8, name, '(') orelse name.len;
    const start = if (std.mem.findScalarLast(u8, name[0..end], '.')) |dot| dot + 1 else 0;
    return name[start..];
}

pub const Options = struct {
    /// Only run tests whose suite or test name contains this text.
    filter: ?[]const u8 = null,
    color: bool = false,
    /// Print where each failure happened (needs a Debug build).
    traces: bool = true,
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    pub fn total(s: Summary) usize {
        return s.passed + s.failed + s.skipped;
    }
};

const Status = enum { passed, failed, skipped };

const Runner = struct {
    io: Io,
    out: *Io.Writer,
    options: Options,
    summary: Summary = .{},

    fn matches(r: *const Runner, suite: []const u8, name: []const u8) bool {
        const filter = r.options.filter orelse return true;
        return std.mem.find(u8, suite, filter) != null or std.mem.find(u8, name, filter) != null;
    }

    fn paint(r: *Runner, status: Status) ![]const u8 {
        const text, const code = switch (status) {
            .passed => .{ "ok", "\x1b[32m" },
            .failed => .{ "FAIL", "\x1b[31m" },
            .skipped => .{ "skip", "\x1b[33m" },
        };
        if (r.options.color) try r.out.writeAll(code);
        try r.out.writeAll(text);
        return if (r.options.color) "\x1b[0m" else "";
    }

    fn execute(t: *T, case: Case, before: ?TestFn, after: ?TestFn) anyerror!void {
        if (before) |hook| try hook(t);
        const result = case.func(t);
        const hook = after orelse return result;

        // The hook gets its own message so it cannot replace the test's.
        var cleanup = t.*;
        cleanup.message_len = 0;
        const cleaned = hook(&cleanup);

        // A failed test keeps its own report. A skip does not hide a failed hook.
        if (result) |_| {} else |err| if (err != error.SkipTest) return err;
        cleaned catch |err| {
            t.* = cleanup;
            return err;
        };
        return result;
    }

    fn runCase(r: *Runner, case: Case, before: ?TestFn, after: ?TestFn) !void {
        // Flushed first so a test that panics still shows its name.
        try r.out.print("  {s} ... ", .{case.name});
        try r.out.flush();

        // Safety is forced on because leak checks are off by default in
        // ReleaseFast and ReleaseSmall.
        var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        var t: T = .{ .allocator = debug_allocator.allocator(), .io = r.io };
        const start: Io.Timestamp = .now(r.io, .awake);

        const result = execute(&t, case, before, after);
        const elapsed_ns = start.untilNow(r.io, .awake).toNanoseconds();

        // Copied now because Zig clears the trace when an error is handled.
        var trace: ?std.builtin.StackTrace = null;
        var status: Status = .passed;
        if (result) |_| {} else |err| {
            status = if (err == error.SkipTest) .skipped else .failed;
            if (err != error.TestFailed and err != error.SkipTest) {
                t.setMessage("returned error.{s}", .{@errorName(err)});
            }
            if (@errorReturnTrace()) |stack| trace = stack.*;
        }

        const leaked = debug_allocator.deinit() == .leak;
        if (leaked) {
            status = .failed;
            // The allocator's report has interrupted the line, so start it again.
            try r.out.print("  {s} ... ", .{case.name});
        }

        const reset = try r.paint(status);
        try r.out.print("{s} ({d:.2}ms)\n", .{ reset, @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms });
        // A passing test may have caught a failed assertion on purpose.
        if (status != .passed and t.message_len > 0) try r.out.print("      {s}\n", .{t.message()});
        if (leaked) try r.out.writeAll("      leaked memory\n");
        try r.out.flush();

        switch (status) {
            .passed => r.summary.passed += 1,
            .skipped => r.summary.skipped += 1,
            .failed => {
                r.summary.failed += 1;
                if (r.options.traces) {
                    if (trace) |*stack| std.debug.dumpErrorReturnTrace(stack);
                }
            },
        }
    }
};

/// Runs `suites`, a struct type or a tuple of struct types, writing a report
/// to `out`. A test failing does not make this return an error.
pub fn runSuites(io: Io, out: *Io.Writer, comptime suites: anytype, options: Options) !Summary {
    const list = if (@TypeOf(suites) == type) .{suites} else suites;
    var runner: Runner = .{ .io = io, .out = out, .options = options };

    inline for (list) |Suite| {
        const suite = comptime suiteName(Suite);
        const before = comptime hookOf(Suite, "beforeEach");
        const after = comptime hookOf(Suite, "afterEach");

        var printed_header = false;
        for (casesOf(Suite)) |case| {
            if (!runner.matches(suite, case.name)) continue;
            if (!printed_header) {
                try out.print("{s}\n", .{suite});
                printed_header = true;
            }
            try runner.runCase(case, before, after);
        }
    }

    const s = runner.summary;
    try out.print("\n{d} passed, {d} failed, {d} skipped\n", .{ s.passed, s.failed, s.skipped });
    try out.flush();
    return s;
}

/// Program entry point: the first command line argument is an optional name
/// filter. Exits with status 1 if a test fails or no test matches.
pub fn run(init: std.process.Init, comptime suites: anytype) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const stdout = Io.File.stdout();

    const no_color = init.environ_map.get("NO_COLOR") orelse "";
    var color = no_color.len == 0 and try stdout.supportsAnsiEscapeCodes(io);
    if (color) stdout.enableAnsiEscapeCodes(io) catch {
        color = false;
    };

    var buffer: [4096]u8 = undefined;
    // Streaming, because a positional writer overwrites a redirected file.
    var writer = stdout.writerStreaming(io, &buffer);
    const summary = try runSuites(io, &writer.interface, suites, .{
        .filter = if (args.len > 1) args[1] else null,
        .color = color,
    });
    if (summary.failed > 0 or summary.total() == 0) std.process.exit(1);
}

const testing = std.testing;

fn testT() T {
    return .{ .allocator = testing.allocator, .io = testing.io };
}

test "equal compares by content" {
    var t = testT();
    const Point = struct { x: i32, name: []const u8 };
    const heap_name = try testing.allocator.dupe(u8, "origin");
    defer testing.allocator.free(heap_name);

    try t.equal(3, @as(i32, 3));
    try t.equal("abc", @as([]const u8, "abc"));
    try t.equal(Point{ .x = 1, .name = "origin" }, Point{ .x = 1, .name = heap_name });
    try t.equal(@as(?i32, null), null);
}

test "equal reports both values" {
    var t = testT();
    try testing.expectError(error.TestFailed, t.equal(1, @as(i32, 2)));
    try testing.expectEqualStrings("expected 1, got 2", t.message());

    try testing.expectError(error.TestFailed, t.equal("a", @as([]const u8, "b")));
    try testing.expectEqualStrings("expected \"a\", got \"b\"", t.message());
}

test "equal compares tagged unions" {
    var t = testT();
    const Shape = union(enum) { circle: f32, square: f32 };
    try t.equal(Shape{ .circle = 1 }, Shape{ .circle = 1 });
    try testing.expectError(error.TestFailed, t.equal(Shape{ .circle = 1 }, Shape{ .square = 1 }));
}

test "near, contains and fails" {
    var t = testT();
    try t.near(1.0, 1.05, 0.1);
    try testing.expectError(error.TestFailed, t.near(1.0, 2.0, 0.1));

    try t.contains("hello world", "wor");
    try testing.expectError(error.TestFailed, t.contains("hello", "xyz"));

    const parsed: anyerror!u8 = error.Overflow;
    try t.fails(error.Overflow, parsed);
    try testing.expectError(error.TestFailed, t.fails(error.OutOfMemory, parsed));

    const ok: anyerror!u8 = 1;
    try testing.expectError(error.TestFailed, t.fails(error.Overflow, ok));
}

const SampleSuite = struct {
    var order: [16]u8 = undefined;
    var order_len: usize = 0;

    fn record(c: u8) void {
        order[order_len] = c;
        order_len += 1;
    }

    pub const not_a_test = 5;

    pub fn helper(x: i32) i32 {
        return x;
    }

    pub fn beforeEach(t: *T) !void {
        _ = t;
        record('b');
    }

    pub fn afterEach(t: *T) !void {
        _ = t;
        record('a');
    }

    pub fn passes(t: *T) !void {
        record('p');
        try t.equal(1, helper(1));
    }

    pub fn failing(t: *T) !void {
        record('f');
        try t.equal(1, helper(2));
    }

    pub fn skipped(t: *T) !void {
        return t.skip("not ready");
    }

    pub fn returnsOwnError(t: *T) !void {
        _ = t;
        return error.Broken;
    }
};

fn runSample(filter: ?[]const u8, report: *Io.Writer.Allocating) !Summary {
    SampleSuite.order_len = 0;
    return runSuites(testing.io, &report.writer, SampleSuite, .{ .filter = filter, .traces = false });
}

test "runner finds tests, runs hooks and counts results" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runSample(null, &report);
    try testing.expectEqual(1, summary.passed);
    try testing.expectEqual(2, summary.failed);
    try testing.expectEqual(1, summary.skipped);
    try testing.expectEqualStrings("bpabfa", SampleSuite.order[0..6]);

    const text = report.written();
    try testing.expect(std.mem.find(u8, text, "SampleSuite\n") != null);
    try testing.expect(std.mem.find(u8, text, "expected 1, got 2") != null);
    try testing.expect(std.mem.find(u8, text, "not ready") != null);
    try testing.expect(std.mem.find(u8, text, "returned error.Broken") != null);
    try testing.expect(std.mem.find(u8, text, "helper") == null);
}

test "runner filter limits which tests run" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runSample("passes", &report);
    try testing.expectEqual(1, summary.total());
    try testing.expectEqual(1, summary.passed);
}

test "equal survives cyclic data" {
    var t = testT();
    const Node = struct { value: i32, next: ?*const @This() };

    var a: Node = .{ .value = 1, .next = null };
    a.next = &a;
    var b: Node = .{ .value = 1, .next = null };
    b.next = &b;
    try t.equal(&a, &b);

    var c: Node = .{ .value = 2, .next = null };
    c.next = &c;
    try testing.expectError(error.TestFailed, t.equal(&a, &c));
}

test "equal compares vectors and C strings" {
    var t = testT();
    const v: @Vector(2, i32) = .{ 1, 2 };
    const w: @Vector(2, i32) = .{ 1, 3 };
    try t.equal(v, v);
    try testing.expectError(error.TestFailed, t.equal(v, w));

    var copy: [3:0]u8 = "hi\x00".*;
    const hi: [*:0]const u8 = "hi";
    const same: [*:0]const u8 = @ptrCast(&copy);
    const other: [*:0]const u8 = "yo";
    try t.equal(hi, same);
    try testing.expectError(error.TestFailed, t.equal(hi, other));
    try testing.expectEqualStrings("expected \"hi\", got \"yo\"", t.message());
}

test "equal prints nested strings as text" {
    var t = testT();
    const Pair = struct { key: []const u8, value: ?[]const u8 };

    const a: []const []const u8 = &.{"hi"};
    const b: []const []const u8 = &.{"yo"};
    try testing.expectError(error.TestFailed, t.equal(a, b));
    try testing.expectEqualStrings("expected { \"hi\" }, got { \"yo\" }", t.message());

    const c: Pair = .{ .key = "k", .value = "v" };
    const d: Pair = .{ .key = "k", .value = null };
    try testing.expectError(error.TestFailed, t.equal(c, d));
    try testing.expectEqualStrings(
        "expected .{ .key = \"k\", .value = \"v\" }, got .{ .key = \"k\", .value = null }",
        t.message(),
    );
}

test "equal keeps both values and the difference when strings are long" {
    var t = testT();
    const a: [3000]u8 = @splat('a');
    var b: [3000]u8 = @splat('a');
    b[2999] = 'b';

    try testing.expectError(error.TestFailed, t.equal(@as([]const u8, &a), @as([]const u8, &b)));
    try testing.expect(std.mem.find(u8, t.message(), ", got ") != null);
    try testing.expect(std.mem.endsWith(u8, t.message(), "ab\""));
}

test "near accepts equal infinities and rejects NaN" {
    var t = testT();
    const inf = std.math.inf(f64);
    try t.near(inf, inf, 1);
    try testing.expectError(error.TestFailed, t.near(inf, -inf, 1));
    try testing.expectError(error.TestFailed, t.near(std.math.nan(f64), 1, 1));
}

test "suite names keep generic parameters whole" {
    const Inner = struct {};
    const name = suiteName(GenericSuite(Inner));
    try testing.expect(std.mem.startsWith(u8, name, "GenericSuite("));
    try testing.expect(std.mem.endsWith(u8, name, ")"));
}

fn GenericSuite(comptime Parameter: type) type {
    return struct {
        pub const Type = Parameter;
    };
}

const FailingHookSuite = struct {
    var after_calls: usize = 0;

    pub fn afterEach(t: *T) !void {
        after_calls += 1;
        return t.fail("hook failed", .{});
    }

    pub fn passes(t: *T) !void {
        _ = t;
    }

    pub fn fails(t: *T) !void {
        return t.fail("test failed", .{});
    }

    pub fn skips(t: *T) !void {
        return t.skip("not ready");
    }
};

fn runFailingHook(filter: []const u8, report: *Io.Writer.Allocating) !Summary {
    FailingHookSuite.after_calls = 0;
    return runSuites(testing.io, &report.writer, FailingHookSuite, .{ .filter = filter, .traces = false });
}

test "a failing afterEach runs once and fails a passing test" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runFailingHook("passes", &report);
    try testing.expectEqual(1, summary.failed);
    try testing.expectEqual(1, FailingHookSuite.after_calls);
    try testing.expect(std.mem.find(u8, report.written(), "hook failed") != null);
}

test "a failing afterEach does not replace the test's failure" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runFailingHook("fails", &report);
    try testing.expectEqual(1, summary.failed);
    try testing.expectEqual(1, FailingHookSuite.after_calls);
    try testing.expect(std.mem.find(u8, report.written(), "test failed") != null);
    try testing.expect(std.mem.find(u8, report.written(), "hook failed") == null);
}

test "a failing afterEach fails a skipped test" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runFailingHook("skips", &report);
    try testing.expectEqual(1, summary.failed);
    try testing.expectEqual(0, summary.skipped);
    try testing.expect(std.mem.find(u8, report.written(), "hook failed") != null);
}

const CaughtFailureSuite = struct {
    pub fn catchesAssertion(t: *T) !void {
        t.equal(1, @as(i32, 2)) catch {};
    }
};

test "a passing test does not print a caught assertion" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();

    const summary = try runSuites(testing.io, &report.writer, CaughtFailureSuite, .{ .traces = false });
    try testing.expectEqual(1, summary.passed);
    try testing.expect(std.mem.find(u8, report.written(), "expected 1") == null);
}
