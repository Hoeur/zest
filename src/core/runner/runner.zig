//! Runs parsed suites and reports each case to a listener. Holds no output
//! code, so the CLI and the UI can share it.
//!
//! A listener is any pointer with `fn caseFinished(self, CaseResult) !void`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Assertion = @import("../assertions/assertion.zig").Assertion;
const evaluate = @import("../assertions/evaluate.zig");
const http = @import("../http/client.zig");
const request_model = @import("../http/request.zig");
const Header = request_model.Header;
const Request = request_model.Request;
const Response = @import("../http/response.zig").Response;
const ast = @import("../parser/ast.zig");
const redact = @import("../redact.zig").redact;
const variables = @import("variables.zig");

pub const Status = enum {
    passed,
    failed,
    skipped,
    /// Stopped by an earlier failure, a failed setup or Ctrl-C.
    not_run,
};

/// A problem that is not a failed assertion.
pub const Failure = struct {
    line: usize,
    message: []const u8,
};

/// Slices only live until `caseFinished` returns.
pub const CaseResult = struct {
    case: *const ast.Case,
    is_hook: bool,
    status: Status,
    duration_ns: u64 = 0,
    /// Parallel to `case.expects`, and empty if the request did not finish.
    assertions: []const evaluate.Result = &.{},
    failure: ?Failure = null,
};

/// Counts tests. A failed hook also counts as failed, so it cannot pass a run.
pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    not_run: usize = 0,
    interrupted: bool = false,

    pub fn total(s: Summary) usize {
        return s.passed + s.failed + s.skipped + s.not_run;
    }
};

pub const Options = struct {
    /// Stop after the first failure. The default is to continue.
    fail_fast: bool = false,
};

/// Holds what carries from one suite to the next, including open connections.
pub const Runner = struct {
    gpa: Allocator,
    /// Outlives every suite, for secrets.
    arena: Allocator,
    client: *http.Client,
    options: Options = .{},
    /// Global then environment values, so a later name wins.
    variables: []const ast.Variable = &.{},
    /// Hidden from every later result, in any suite, unlike variables, because
    /// a value does not stop being secret when its suite ends.
    secrets: std.ArrayList([]const u8) = .empty,
    summary: Summary = .{},
    /// Later tests are not run, though a started suite's teardown still is.
    stopped: bool = false,

    /// Tests run in file order. A failed setup stops that suite's tests, and
    /// teardown follows even then, because setup may have created something.
    pub fn runSuite(r: *Runner, suite: *const ast.Suite, listener: anytype) !void {
        var suite_arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer suite_arena.deinit();
        var state: SuiteState = .{ .runner = r, .suite = suite, .arena = suite_arena.allocator() };
        try r.collectSecrets(suite);

        // Hooks exist for tests, so they do not run when no test will.
        const starts = !r.stopped and hasRunnableTest(suite);
        var blocked = !starts;
        if (starts) if (suite.setup) |*setup| {
            blocked = try r.runCase(setup, true, &state, listener) != .passed;
        };

        for (suite.tests) |*case| switch (case.mode) {
            .disabled => {},
            .skip => try r.finish(.{ .case = case, .is_hook = false, .status = .skipped }, listener),
            .run => if (blocked or r.stopped) {
                try r.finish(.{ .case = case, .is_hook = false, .status = .not_run }, listener);
            } else {
                _ = try r.runCase(case, false, &state, listener);
            },
        };

        // Ctrl-C asked to leave, and any request sent now would be cancelled.
        if (starts and !r.summary.interrupted) if (suite.teardown) |*teardown| {
            _ = try r.runCase(teardown, true, &state, listener);
        };
    }

    /// A response can be large, so each case gets an arena of its own.
    fn runCase(r: *Runner, case: *const ast.Case, is_hook: bool, state: *SuiteState, listener: anytype) !Status {
        var case_arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer case_arena.deinit();

        var result: CaseResult = .{ .case = case, .is_hook = is_hook, .status = .passed };
        var run: CaseRun = .{
            .client = r.client,
            .arena = case_arena.allocator(),
            .case = case,
            .state = state,
            .result = &result,
        };
        const io = r.client.io;
        const start: Io.Timestamp = .now(io, .awake);
        try run.execute();
        result.duration_ns = @intCast(start.untilNow(io, .awake).toNanoseconds());

        if (result.status == .not_run) {
            r.summary.interrupted = true;
            r.stopped = true;
        } else if (result.failure != null or evaluate.countFailed(result.assertions) > 0) {
            result.status = .failed;
        }
        try r.finish(result, listener);
        return result.status;
    }

    /// Takes every test's values, so none shows up in another test's result.
    fn collectSecrets(r: *Runner, suite: *const ast.Suite) Allocator.Error!void {
        try r.addSecrets(r.variables);
        try r.addSecrets(suite.variables);
        if (suite.setup) |setup| try r.addSecrets(setup.variables);
        if (suite.teardown) |teardown| try r.addSecrets(teardown.variables);
        for (suite.tests) |case| try r.addSecrets(case.variables);
    }

    fn addSecrets(r: *Runner, list: []const ast.Variable) Allocator.Error!void {
        for (list) |variable| {
            if (variable.secret) try r.addSecret(variable.value);
        }
    }

    /// Repeats are dropped, because every suite and login adds the same values.
    fn addSecret(r: *Runner, value: []const u8) Allocator.Error!void {
        for (r.secrets.items) |secret| {
            if (std.mem.eql(u8, secret, value)) return;
        }
        try r.secrets.append(r.arena, try r.arena.dupe(u8, value));
    }

    fn finish(r: *Runner, result: CaseResult, listener: anytype) !void {
        switch (result.status) {
            .passed => if (!result.is_hook) {
                r.summary.passed += 1;
            },
            .failed => {
                r.summary.failed += 1;
                if (r.options.fail_fast) r.stopped = true;
            },
            .skipped => r.summary.skipped += 1,
            .not_run => if (!result.is_hook) {
                r.summary.not_run += 1;
            },
        }
        try listener.caseFinished(result);
    }
};

fn hasRunnableTest(suite: *const ast.Suite) bool {
    for (suite.tests) |test_case| {
        if (test_case.mode == .run) return true;
    }
    return false;
}

const SuiteState = struct {
    runner: *Runner,
    suite: *const ast.Suite,
    /// Outlives each case, for extracted values.
    arena: Allocator,
    runtime: variables.Runtime = .empty,
};

/// One case's request, checks and extracts. Each problem lands on `result`.
const CaseRun = struct {
    client: *http.Client,
    arena: Allocator,
    case: *const ast.Case,
    state: *SuiteState,
    result: *CaseResult,

    fn execute(c: *CaseRun) Allocator.Error!void {
        // Built first, so a mistake in the file sends nothing.
        const request = try c.buildRequest() orelse return;
        const assertions = try c.buildAssertions() orelse return;

        const response = c.client.send(c.arena, request) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Interrupted => {
                c.result.status = .not_run;
                return;
            },
            else => return c.fail(c.case.request.line, "{s}", .{http.describe(err)}),
        };

        try c.noteSecrets(response);
        c.result.assertions = try evaluate.evaluate(c.arena, response, assertions, c.state.runner.secrets.items);
        // A later request would fail on this one's mistake, not its own.
        if (evaluate.countFailed(c.result.assertions) == 0) try c.extractAll(response);
    }

    fn buildRequest(c: *CaseRun) Allocator.Error!?Request {
        const source = c.case.request;
        const headers = try c.arena.alloc(Header, source.headers.len);
        for (headers, source.headers) |*header, text| {
            header.* = .{
                .name = try c.fill(text.name, source.line) orelse return null,
                .value = try c.fill(text.value, source.line) orelse return null,
            };
        }
        return .{
            .method = source.method,
            .url = try c.fill(source.url, source.line) orelse return null,
            .headers = headers,
            .body = try c.buildBody() orelse return null,
            .timeout_ms = c.case.timeout_ms orelse request_model.default_timeout_ms,
        };
    }

    fn buildBody(c: *CaseRun) Allocator.Error!?request_model.Body {
        const line = c.case.request.line;
        switch (c.case.request.body) {
            .none => return .none,
            .raw => |text| return .{ .raw = try c.fill(text, line) orelse return null },
            .json => |text| {
                const filled = try c.fill(text, line) orelse return null;
                if (!try std.json.validate(c.arena, filled)) {
                    try c.fail(line, "the body is not valid JSON once variables are replaced", .{});
                    return null;
                }
                return .{ .json = filled };
            },
        }
    }

    fn buildAssertions(c: *CaseRun) Allocator.Error!?[]const Assertion {
        const assertions = try c.arena.alloc(Assertion, c.case.expects.len);
        for (assertions, c.case.expects) |*assertion, expect| {
            assertion.* = expect.assertion;
            if (assertion.expected == .string) {
                assertion.expected = .{ .string = try c.fill(assertion.expected.string, expect.line) orelse return null };
            }
        }
        return assertions;
    }

    /// Runs before the checks, which may print the same value, and even if they
    /// then fail, because the response has still shown it.
    fn noteSecrets(c: *CaseRun, response: Response) Allocator.Error!void {
        for (c.case.extracts) |item| {
            if (!item.secret) continue;
            switch (try evaluate.extract(c.arena, response, item.source, item.source_text)) {
                .problem => {},
                .value => |value| try c.state.runner.addSecret(value),
            }
        }
    }

    fn extractAll(c: *CaseRun, response: Response) Allocator.Error!void {
        const state = c.state;
        for (c.case.extracts) |item| {
            switch (try evaluate.extract(c.arena, response, item.source, item.source_text)) {
                .problem => |problem| return c.fail(item.line, "cannot extract {s}: {s}", .{ item.name, problem }),
                .value => |value| try state.runtime.put(state.arena, item.name, try state.arena.dupe(u8, value)),
            }
        }
    }

    /// Null when a variable is missing, which is recorded as the failure.
    fn fill(c: *CaseRun, text: []const u8, line: usize) Allocator.Error!?[]const u8 {
        const scope: variables.Scope = .{
            .runtime = &c.state.runtime,
            .case = c.case.variables,
            .suite = c.state.suite.variables,
            .base = c.state.runner.variables,
        };
        var missing: []const u8 = "";
        return variables.interpolate(c.arena, text, scope, &missing) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.MissingVariable => {
                try c.fail(line, "{{{{{s}}}}} is not defined", .{missing});
                return null;
            },
        };
    }

    fn fail(c: *CaseRun, line: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const message = try std.fmt.allocPrint(c.arena, fmt, args);
        c.result.failure = .{ .line = line, .message = try redact(c.arena, message, c.state.runner.secrets.items) };
    }
};
