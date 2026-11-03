//! Test Suites page data: the `.ztest` files in the workspace, and one suite
//! run on a background task. No Win32 code, so it is tested with the CLI.
//!
//! The worker publishes each finished case by writing it into a preallocated
//! slot and then raising `published`, so the UI thread reads finished cases
//! without a lock. Only the worker allocates while a run is going.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Atomic = std.atomic.Value;
const ast = @import("../core/parser/ast.zig");
const parser = @import("../core/parser/parser.zig");
const runner = @import("../core/runner/runner.zig");
const http = @import("../core/http/client.zig");
const request_model = @import("../core/http/request.zig");
const redact = @import("../core/redact.zig").redact;
const history = @import("../core/history.zig");
const report = @import("../core/report/report.zig");

const extension = ".ztest";
const max_file_size: Io.Limit = .limited(16 * 1024 * 1024);
/// How much of a request or response a case keeps for the details view.
const preview_limit = 8 * 1024;

pub const SuiteFile = struct {
    /// Relative to the workspace root, with `/` separators.
    path: []const u8,
    name: []const u8,
    tests: usize,
    skipped: usize,
    /// Why the file cannot be run, or null.
    problem: ?[]const u8 = null,
};

/// The suites under a folder, sorted by path. Hidden folders and `zig-out`
/// are skipped.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    suites: []SuiteFile = &.{},
    root: []const u8 = ".",

    pub fn init(gpa: Allocator) Catalog {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Catalog) void {
        c.arena.deinit();
    }

    pub fn scan(c: *Catalog, io: Io, root: []const u8) !void {
        _ = c.arena.reset(.retain_capacity);
        const arena = c.arena.allocator();
        c.root = try arena.dupe(u8, root);
        c.suites = &.{};
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var found: std.ArrayList(SuiteFile) = .empty;
        try walk(arena, io, dir, "", &found, 0);
        std.mem.sort(SuiteFile, found.items, {}, struct {
            fn lessThan(_: void, a: SuiteFile, b: SuiteFile) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
        for (found.items) |*suite| describe(arena, io, dir, suite);
        c.suites = found.items;
    }

    /// The full path of `suite`, for opening it.
    pub fn fullPath(c: *const Catalog, buffer: []u8, suite: SuiteFile) ![]const u8 {
        if (std.mem.eql(u8, c.root, ".")) return std.fmt.bufPrint(buffer, "{s}", .{suite.path});
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ c.root, suite.path });
    }
};

fn walk(arena: Allocator, io: Io, dir: Io.Dir, prefix: []const u8, found: *std.ArrayList(SuiteFile), depth: usize) !void {
    if (depth > 8) return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        const path = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "node_modules")) continue;
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                try walk(arena, io, child, path, found, depth + 1);
            },
            .file => if (std.mem.endsWith(u8, entry.name, extension)) {
                try found.append(arena, .{ .path = path, .name = std.fs.path.stem(entry.name), .tests = 0, .skipped = 0 });
            },
            else => {},
        }
    }
}

fn describe(arena: Allocator, io: Io, dir: Io.Dir, suite: *SuiteFile) void {
    const source = dir.readFileAlloc(io, suite.path, arena, max_file_size) catch |err| {
        suite.problem = @errorName(err);
        return;
    };
    var diagnostic: parser.Diagnostic = .{};
    const parsed = parser.parse(arena, source, &diagnostic) catch {
        suite.problem = std.fmt.allocPrint(arena, "line {d}: {s}", .{ diagnostic.line, diagnostic.message }) catch "syntax error";
        return;
    };
    suite.name = parsed.name;
    for (parsed.tests) |case| switch (case.mode) {
        .run => suite.tests += 1,
        .skip => {
            suite.tests += 1;
            suite.skipped += 1;
        },
        .disabled => {},
    };
}

pub const Kind = enum { @"test", setup, teardown };

pub const AssertionView = struct {
    text: []const u8,
    actual: []const u8,
    passed: bool,
};

/// One finished case, owned by the run's arena. Every text is masked.
pub const CaseView = struct {
    name: []const u8,
    line: usize = 0,
    failure_line: usize = 0,
    kind: Kind,
    status: runner.Status,
    duration_ms: u64,
    method: []const u8,
    /// As written in the file, with `{{variables}}`.
    url: []const u8,
    failure: ?[]const u8,
    assertions: []const AssertionView,
    status_code: ?u16,
    request_text: []const u8,
    response_text: []const u8,
    log_text: []const u8,
};

pub const Phase = enum { idle, running, stopping, done, failed };

pub const SuiteRun = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    phase: Phase = .idle,
    /// Why the run could not start, for the page.
    problem: []const u8 = "",
    path: []const u8 = "",
    suite: ast.Suite = undefined,
    environment: []const u8 = "",
    fail_fast: bool = false,
    cases: []CaseView = &.{},
    published: Atomic(usize) = .init(0),
    finished: Atomic(bool) = .init(false),
    cancel: Atomic(bool) = .init(false),
    future: ?Io.Future(void) = null,
    summary: runner.Summary = .{},
    started_unix: i64 = 0,
    started_ns: i96 = 0,
    duration_ms: u64 = 0,
    /// Worker state, never read by the UI while running.
    client: http.Client = undefined,
    engine: runner.Runner = undefined,
    variables: []const ast.Variable = &.{},

    pub fn init(gpa: Allocator, io: Io) SuiteRun {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    /// Cancels and joins any run before freeing it.
    pub fn deinit(r: *SuiteRun) void {
        r.stop();
        if (r.future) |*future| future.await(r.io);
        r.arena.deinit();
    }

    pub fn busy(r: *const SuiteRun) bool {
        return r.future != null;
    }

    /// Reads and parses `path`, then runs it on a background task with
    /// `variables` from `ztest.json` (lowest priority first). Keep the run at a
    /// stable address until `deinit`.
    pub fn start(r: *SuiteRun, path: []const u8, variables: []const ast.Variable, environment: ?[]const u8, fail_fast: bool) !void {
        if (r.busy()) return error.Busy;
        _ = r.arena.reset(.retain_capacity);
        const arena = r.arena.allocator();
        r.problem = "";
        r.cases = &.{};
        r.summary = .{};
        r.published.store(0, .release);
        r.finished.store(false, .release);
        r.cancel.store(false, .release);
        r.path = try arena.dupe(u8, path);
        r.environment = try arena.dupe(u8, environment orelse "");
        r.fail_fast = fail_fast;
        errdefer r.phase = .failed;

        const source = Io.Dir.cwd().readFileAlloc(r.io, r.path, arena, max_file_size) catch |err| {
            r.problem = try std.fmt.allocPrint(arena, "Cannot read {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return err;
        };
        var diagnostic: parser.Diagnostic = .{};
        r.suite = parser.parse(arena, source, &diagnostic) catch |err| {
            if (err == error.SyntaxError) r.problem = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ std.fs.path.basename(path), diagnostic.line, diagnostic.message });
            return err;
        };
        // Every case can finish at most once: setup, each test, teardown.
        r.cases = try arena.alloc(CaseView, r.suite.tests.len + 2);
        r.variables = try arena.dupe(ast.Variable, variables);
        r.started_unix = Io.Timestamp.now(r.io, .real).toSeconds();
        r.started_ns = Io.Timestamp.now(r.io, .awake).toNanoseconds();
        r.duration_ms = 0;
        r.phase = .running;
        r.future = r.io.concurrent(work, .{r}) catch |err| {
            r.problem = "Could not start the run";
            return err;
        };
    }

    /// Nonblocking: the request in flight is cancelled and the rest not run.
    pub fn stop(r: *SuiteRun) void {
        if (!r.busy()) return;
        r.cancel.store(true, .release);
        r.phase = .stopping;
    }

    /// Joins the worker once it is done. True when the phase changed.
    pub fn poll(r: *SuiteRun) bool {
        if (!r.busy() or !r.finished.load(.acquire)) return false;
        r.future.?.await(r.io);
        r.future = null;
        r.phase = if (r.problem.len > 0) .failed else .done;
        return true;
    }

    /// Cases finished so far, safe to read from the UI thread.
    pub fn finishedCases(r: *const SuiteRun) []const CaseView {
        return r.cases[0..r.published.load(.acquire)];
    }

    /// Tests that will run, for the progress bar.
    pub fn plannedTests(r: *const SuiteRun) usize {
        if (r.phase == .idle) return 0;
        var n: usize = 0;
        for (r.suite.tests) |case| {
            if (case.mode != .disabled) n += 1;
        }
        return n;
    }

    pub fn elapsedMs(r: *const SuiteRun) u64 {
        if (r.busy()) return @intCast(@divTrunc(@max(0, Io.Timestamp.now(r.io, .awake).toNanoseconds() - r.started_ns), std.time.ns_per_ms));
        return r.duration_ms;
    }

    /// The run and its tests for the history file. Call after `poll` says done.
    pub fn historyEntries(r: *const SuiteRun, arena: Allocator) ![]history.Entry {
        var out: std.ArrayList(history.Entry) = .empty;
        const s = r.summary;
        try out.append(arena, .{
            .kind = .suite,
            .unix = r.started_unix,
            .outcome = if (s.failed > 0) .failed else if (s.interrupted) .not_run else .passed,
            .name = r.suite.name,
            .suite = r.path,
            .environment = r.environment,
            .duration_ms = r.duration_ms,
            .passed = @intCast(s.passed),
            .failed = @intCast(s.failed),
            .skipped = @intCast(s.skipped),
        });
        for (r.finishedCases()) |case| {
            if (case.kind != .@"test") continue;
            try out.append(arena, .{
                .kind = .@"test",
                .unix = r.started_unix,
                .outcome = switch (case.status) {
                    .passed => .passed,
                    .failed => .failed,
                    .skipped => .skipped,
                    .not_run => .not_run,
                },
                .name = case.name,
                .suite = r.suite.name,
                .environment = r.environment,
                .method = case.method,
                .duration_ms = case.duration_ms,
            });
        }
        return out.items;
    }

    /// The finished run as a report, for Export Report. Owned by `arena`.
    pub fn toReport(r: *const SuiteRun, arena: Allocator, version: []const u8, started_at: []const u8) !report.Run {
        const finished = r.finishedCases();
        const cases = try arena.alloc(report.Case, finished.len);
        for (cases, finished) |*out, case| {
            const assertions = try arena.alloc(report.Assertion, case.assertions.len);
            for (assertions, case.assertions) |*a, item| a.* = .{ .line = case.line, .expected = item.text, .actual = item.actual, .passed = item.passed };
            out.* = .{
                .name = case.name,
                .kind = switch (case.kind) {
                    .@"test" => .@"test",
                    .setup => .setup,
                    .teardown => .teardown,
                },
                .line = case.line,
                .status = case.status,
                .duration_ms = case.duration_ms,
                .failure = case.failure,
                .failure_line = if (case.failure != null) case.failure_line else null,
                .assertions = assertions,
            };
        }
        const s = r.summary;
        return .{
            .version = version,
            .started_at = started_at,
            .environment = if (r.environment.len > 0) r.environment else null,
            .duration_ms = r.duration_ms,
            .summary = .{ .passed = s.passed, .failed = s.failed, .skipped = s.skipped, .not_run = s.not_run, .interrupted = s.interrupted },
            .suites = try arena.dupe(report.Suite, &.{.{ .path = r.path, .name = r.suite.name, .cases = cases, .duration_ms = r.duration_ms }}),
        };
    }

    fn work(r: *SuiteRun) void {
        defer r.finished.store(true, .release);
        const arena = r.arena.allocator();
        r.client = .init(r.gpa, r.io);
        defer r.client.deinit();
        r.engine = .{
            .gpa = r.gpa,
            .arena = arena,
            .client = &r.client,
            .options = .{ .fail_fast = r.fail_fast },
            .variables = r.variables,
            .cancel = &r.cancel,
        };
        var listener: Listener = .{ .run = r };
        r.engine.runSuite(&r.suite, &listener) catch {
            r.problem = "The run stopped: out of memory";
        };
        r.summary = r.engine.summary;
        r.duration_ms = @intCast(@divTrunc(@max(0, Io.Timestamp.now(r.io, .awake).toNanoseconds() - r.started_ns), std.time.ns_per_ms));
    }
};

const Listener = struct {
    run: *SuiteRun,

    pub fn caseFinished(l: *Listener, result: runner.CaseResult) !void {
        const r = l.run;
        const arena = r.arena.allocator();
        const secrets = r.engine.secrets.items;
        const index = r.published.load(.monotonic);
        if (index >= r.cases.len) return;

        const assertions = try arena.alloc(AssertionView, result.assertions.len);
        for (assertions, result.assertions) |*out, item| out.* = .{
            .text = try arena.dupe(u8, item.assertion.text),
            .actual = try arena.dupe(u8, item.actual),
            .passed = item.passed,
        };
        const kind: Kind = if (!result.is_hook) .@"test" else if (std.mem.eql(u8, result.case.name, "setup")) .setup else .teardown;
        r.cases[index] = .{
            .name = try arena.dupe(u8, result.case.name),
            .line = result.case.line,
            .failure_line = if (result.failure) |f| f.line else 0,
            .kind = kind,
            .status = result.status,
            .duration_ms = result.duration_ns / std.time.ns_per_ms,
            .method = @tagName(result.case.request.method),
            .url = try arena.dupe(u8, result.case.request.url),
            .failure = if (result.failure) |f| try arena.dupe(u8, f.message) else null,
            .assertions = assertions,
            .status_code = if (result.response) |response| response.status else null,
            .request_text = if (result.request) |request| try redact(arena, try requestText(arena, request, secrets), secrets) else "",
            .response_text = if (result.response) |response| try redact(arena, try responseText(arena, response), secrets) else "",
            .log_text = try redact(arena, try logText(arena, result), secrets),
        };
        r.published.store(index + 1, .release);
    }
};

fn requestText(arena: Allocator, request: request_model.Request, secrets: []const []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var preview = request;
    const query = try arena.dupe(request_model.Param, request.query);
    for (query) |*param| {
        param.name = try redact(arena, param.name, secrets);
        param.value = try redact(arena, param.value, secrets);
    }
    preview.query = query;
    if (preview.auth == .api_key_query) preview.auth.api_key_query.value = "********";
    try w.print("{s} {s}\n", .{ @tagName(request.method), try request_model.fullUrl(arena, preview) });
    for (request.headers) |h| try w.print("{s}: {s}\n", .{ h.name, h.value });
    switch (request.auth) {
        .none => {},
        .basic => try w.writeAll("Authorization: Basic ********\n"),
        .bearer => try w.writeAll("Authorization: Bearer ********\n"),
        .api_key_header => |h| try w.print("{s}: ********\n", .{h.name}),
        .api_key_query => {},
    }
    switch (request.body) {
        .raw, .json => |text| try w.print("\n{s}\n", .{clip(text)}),
        else => {},
    }
    return out.written();
}

fn responseText(arena: Allocator, response: @import("../core/http/response.zig").Response) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("HTTP {d} {s}  ({d} ms, {d} bytes)\n", .{ response.status, response.status_text, response.duration_ns / std.time.ns_per_ms, response.body.len });
    for (response.headers) |h| try w.print("{s}: {s}\n", .{ h.name, h.value });
    if (response.body.len > 0) {
        const body = clip(response.body);
        try w.print("\n{s}{s}\n", .{ if (std.unicode.utf8ValidateSlice(body)) body else "[binary content]", if (body.len < response.body.len) "\n[cut at 8 KiB]" else "" });
    }
    return out.written();
}

fn logText(arena: Allocator, result: runner.CaseResult) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (result.request) |request| try w.print("INFO  Sending {s} {s}\n", .{ @tagName(request.method), request.url });
    if (result.response) |response| try w.print("INFO  Received {d} {s} in {d} ms\n", .{ response.status, response.status_text, response.duration_ns / std.time.ns_per_ms });
    for (result.assertions) |a| {
        if (a.passed) {
            try w.print("PASS  {s}\n", .{a.assertion.text});
        } else {
            try w.print("ERROR {s}, but {s}\n", .{ a.assertion.text, a.actual });
        }
    }
    if (result.failure) |f| try w.print("ERROR line {d}: {s}\n", .{ f.line, f.message });
    switch (result.status) {
        .skipped => try w.writeAll("INFO  Skipped\n"),
        .not_run => try w.writeAll("INFO  Not run after an earlier failure or a stop\n"),
        else => {},
    }
    return out.written();
}

fn clip(text: []const u8) []const u8 {
    if (text.len <= preview_limit) return text;
    var end: usize = preview_limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;
const Server = @import("../core/http/client_test.zig").Server;

test "the catalog finds suites, reads their names and skips hidden folders" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "tests/nested");
    try tmp.dir.createDirPath(io, ".ztest");
    try tmp.dir.writeFile(io, .{ .sub_path = "tests/b.ztest", .data = "suite \"Bee\"\ntest \"one\"\nGET u\nend\ntest \"two\"\nskip\nGET u\nend\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tests/nested/a.ztest", .data = "suite \"Ay\"\ntest \"one\"\nGET u\nend\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tests/bad.ztest", .data = "suite \"Bad\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ztest/hidden.ztest", .data = "" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var catalog: Catalog = .init(testing.allocator);
    defer catalog.deinit();
    try catalog.scan(io, root);
    try testing.expectEqual(3, catalog.suites.len);
    try testing.expectEqualStrings("tests/b.ztest", catalog.suites[0].path);
    try testing.expectEqualStrings("Bee", catalog.suites[0].name);
    try testing.expectEqual(2, catalog.suites[0].tests);
    try testing.expectEqual(1, catalog.suites[0].skipped);
    try testing.expect(catalog.suites[1].problem != null);
    try testing.expectEqualStrings("Ay", catalog.suites[2].name);
}

test "a suite runs in the background and publishes masked cases" {
    var server = try Server.listen(&.{
        "HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"token\":\"s3cr\"}",
        "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n",
    });
    defer server.listener.deinit(testing.io);
    var task = try testing.io.concurrent(Server.serve, .{&server});
    defer task.cancel(testing.io) catch {};

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.fmt.allocPrint(a,
        \\suite "Run"
        \\test "login"
        \\  GET http://127.0.0.1:{d}/login
        \\  expect status == 200
        \\  extract secret token = body.token
        \\end
        \\test "use"
        \\  GET http://127.0.0.1:{d}/use
        \\  header Authorization Bearer {{{{token}}}}
        \\  auth query key literal-key
        \\  expect status == 200
        \\end
        \\test "later"
        \\  skip
        \\  GET http://127.0.0.1:{d}/x
        \\end
        \\
    , .{ server.port(), server.port(), server.port() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "run.ztest", .data = source });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/run.ztest", .{&tmp.sub_path});

    var run: SuiteRun = .init(testing.allocator, testing.io);
    defer run.deinit();
    try run.start(path, &.{}, "local", false);
    const begin = Io.Timestamp.now(testing.io, .awake);
    while (!run.poll()) {
        if (begin.untilNow(testing.io, .awake).toMilliseconds() > 5000) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    try testing.expectEqual(Phase.done, run.phase);
    const cases = run.finishedCases();
    try testing.expectEqual(3, cases.len);
    try testing.expectEqual(runner.Status.passed, cases[0].status);
    try testing.expectEqual(runner.Status.failed, cases[1].status);
    try testing.expectEqual(@as(?u16, 500), cases[1].status_code);
    try testing.expectEqual(runner.Status.skipped, cases[2].status);
    // The extracted secret is hidden in what the page shows.
    try testing.expect(std.mem.find(u8, cases[0].response_text, "s3cr") == null);
    try testing.expect(std.mem.find(u8, cases[1].request_text, "s3cr") == null);
    try testing.expect(std.mem.find(u8, cases[1].request_text, "literal-key") == null);
    try testing.expect(std.mem.find(u8, cases[1].log_text, "ERROR status == 200") != null);
    try testing.expectEqual(1, run.summary.passed);
    try testing.expectEqual(1, run.summary.failed);

    const exported = try run.toReport(a, "test", "2026-11-03T00:00:00Z");
    try testing.expectEqual(3, exported.suites[0].cases.len);
    try testing.expectEqualStrings("local", exported.environment.?);
    var html: [16 * 1024]u8 = undefined;
    var out: Io.Writer = .fixed(&html);
    try report.writeHtml(&out, exported);
    try testing.expect(std.mem.find(u8, out.buffered(), "s3cr") == null);

    const entries = try run.historyEntries(a);
    try testing.expectEqual(4, entries.len);
    try testing.expectEqual(history.Outcome.failed, entries[0].outcome);
    try testing.expectEqualStrings("local", entries[0].environment);
}

test "a run that cannot start explains why" {
    var run: SuiteRun = .init(testing.allocator, testing.io);
    defer run.deinit();
    try testing.expectError(error.FileNotFound, run.start("no/such.ztest", &.{}, null, false));
    try testing.expectEqual(Phase.failed, run.phase);
    try testing.expect(std.mem.startsWith(u8, run.problem, "Cannot read such.ztest"));
}
