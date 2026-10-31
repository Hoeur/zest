//! `ztest run`: runs `.ztest` files and prints a report.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("../core/context.zig").Context;
const ExitCode = @import("../core/errors.zig").ExitCode;
const http = @import("../core/http/client.zig");
const environment = @import("../core/environment.zig");
const ast = @import("../core/parser/ast.zig");
const parser = @import("../core/parser/parser.zig");
const runner = @import("../core/runner/runner.zig");

const extension = ".ztest";
const max_file_size: Io.Limit = .limited(16 * 1024 * 1024);

const File = struct {
    path: []const u8,
    suite: ast.Suite,
};

pub fn run(context: Context, out: *Io.Writer, paths: []const []const u8, environment_name: ?[]const u8, options: runner.Options) !ExitCode {
    // Everything is read first, so a typo in the last file sends no requests.
    const files = try loadFiles(context, paths) orelse return .config_error;
    var problem: []const u8 = "";
    const variables = environment.resolve(context.arena, context.config, context.environ, environment_name, &problem) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidEnvironment => {
            context.log.err("{s}", .{problem});
            return .config_error;
        },
    };

    var client: http.Client = .init(context.gpa, context.io);
    defer client.deinit();
    var engine: runner.Runner = .{ .gpa = context.gpa, .arena = context.arena, .client = &client, .options = options, .variables = variables };
    var report: Report = .{ .out = out, .color = stdoutColor(context) };

    if (environment_name) |name| try out.print("Environment: {s}\n", .{name});
    const start: Io.Timestamp = .now(context.io, .awake);
    for (files) |*file| {
        try out.print("{s}: {s}\n", .{ file.path, file.suite.name });
        report.path = file.path;
        try engine.runSuite(&file.suite, &report);
    }
    const summary = engine.summary;
    try printSummary(out, summary, @intCast(start.untilNow(context.io, .awake).toNanoseconds()));

    if (summary.interrupted) return .interrupted;
    if (summary.failed > 0) return .test_failure;
    // A run where every test is disabled would otherwise pass in CI.
    if (summary.total() == 0) {
        context.log.err("no tests ran: every test is disabled", .{});
        return .config_error;
    }
    return .success;
}

/// Color is decided per stream, because stdout may be a file when stderr is not.
fn stdoutColor(context: Context) bool {
    if (!context.log.color) return false;
    return Io.File.stdout().supportsAnsiEscapeCodes(context.io) catch false;
}

/// Null when the problem has been reported.
fn loadFiles(context: Context, paths: []const []const u8) !?[]const File {
    const arena = context.arena;
    const cwd = Io.Dir.cwd();

    var found: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        addPath(arena, context.io, cwd, path, &found) catch |err| {
            if (err == error.OutOfMemory) return err;
            context.log.err("cannot read {s}: {s}", .{ path, @errorName(err) });
            return null;
        };
    }
    if (found.items.len == 0) {
        context.log.err("no {s} files found", .{extension});
        return null;
    }

    const files = try arena.alloc(File, found.items.len);
    for (files, found.items) |*file, path| {
        const source = cwd.readFileAlloc(context.io, path, arena, max_file_size) catch |err| {
            if (err == error.OutOfMemory) return err;
            context.log.err("cannot read {s}: {s}", .{ path, @errorName(err) });
            return null;
        };
        var diagnostic: parser.Diagnostic = .{};
        const suite = parser.parse(arena, source, &diagnostic) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.SyntaxError => {
                context.log.err("{s}:{d}: {s}", .{ path, diagnostic.line, diagnostic.message });
                return null;
            },
        };
        file.* = .{ .path = path, .suite = suite };
    }
    return files;
}

/// A named file is used whatever it is called. A directory adds its `.ztest`
/// files, sorted so that a run's order does not depend on the file system.
fn addPath(arena: Allocator, io: Io, cwd: Io.Dir, path: []const u8, found: *std.ArrayList([]const u8)) !void {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return found.append(arena, path),
        else => return err,
    };
    defer dir.close(io);

    const first = found.items.len;
    try addDirectory(arena, io, dir, path, found);
    std.mem.sort([]const u8, found.items[first..], {}, lessThan);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Hidden directories are left out, so `ztest run .` skips `.git` and caches.
/// Links are not followed, so a loop of them cannot run forever.
fn addDirectory(arena: Allocator, io: Io, dir: Io.Dir, path: []const u8, found: *std.ArrayList([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try addDirectory(arena, io, child, try childPath(arena, path, entry.name), found);
            },
            .file => if (std.mem.endsWith(u8, entry.name, extension)) {
                try found.append(arena, try childPath(arena, path, entry.name));
            },
            else => {},
        }
    }
}

/// Always `/`, which every platform accepts, so reports read the same on each.
fn childPath(arena: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, path, "/\\"), name });
}

/// Prints each case as it ends, so a slow suite shows progress.
const Report = struct {
    out: *Io.Writer,
    color: bool,
    path: []const u8 = "",

    pub fn caseFinished(r: *Report, result: runner.CaseResult) !void {
        const out = r.out;
        const label, const code = switch (result.status) {
            .passed => .{ "PASS", "\x1b[32m" },
            .failed => .{ "FAIL", "\x1b[31m" },
            .skipped => .{ "SKIP", "\x1b[33m" },
            .not_run => .{ "STOP", "\x1b[2m" },
        };
        try out.writeAll("  ");
        if (r.color) try out.writeAll(code);
        try out.writeAll(label);
        if (r.color) try out.writeAll("\x1b[0m");
        try out.print(" {s}", .{result.case.name});
        if (result.status == .passed or result.status == .failed) {
            try out.print(" ({d}ms)", .{result.duration_ns / std.time.ns_per_ms});
        }
        try out.writeByte('\n');

        if (result.failure) |failure| try out.print("       {s}:{d}: {s}\n", .{ r.path, failure.line, failure.message });
        for (result.assertions, 0..) |assertion, i| {
            if (assertion.passed) continue;
            try out.print("       {s}:{d}\n", .{ r.path, result.case.expects[i].line });
            try out.print("       Expected: {s}\n       Actual:   {s}\n", .{ assertion.assertion.text, assertion.actual });
        }
        try out.flush();
    }
};

fn printSummary(out: *Io.Writer, summary: runner.Summary, duration_ns: u64) Io.Writer.Error!void {
    try out.print("\nTests: {d} passed, {d} failed, {d} skipped", .{ summary.passed, summary.failed, summary.skipped });
    if (summary.not_run > 0) try out.print(", {d} not run", .{summary.not_run});
    try out.print("\nTime: {d}ms\n", .{duration_ns / std.time.ns_per_ms});
    if (summary.interrupted) try out.writeAll("Interrupted\n");
}

const testing = std.testing;

test "the summary only mentions tests that did not run when there are some" {
    var buffer: [128]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    try printSummary(&out, .{ .passed = 2, .failed = 1, .skipped = 1 }, 42 * std.time.ns_per_ms);
    try testing.expectEqualStrings("\nTests: 2 passed, 1 failed, 1 skipped\nTime: 42ms\n", out.buffered());

    out.end = 0;
    try printSummary(&out, .{ .failed = 1, .not_run = 3, .interrupted = true }, 0);
    try testing.expectEqualStrings("\nTests: 0 passed, 1 failed, 0 skipped, 3 not run\nTime: 0ms\nInterrupted\n", out.buffered());
}

test "the report shows where and why a case failed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const suite = try parseSample(arena.allocator());
    const case = &suite.tests[0];

    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var report: Report = .{ .out = &out, .color = false, .path = "a.ztest" };

    try report.caseFinished(.{
        .case = case,
        .is_hook = false,
        .status = .failed,
        .duration_ns = 12 * std.time.ns_per_ms,
        .assertions = &.{.{ .assertion = case.expects[0].assertion, .passed = false, .actual = "status == 500" }},
    });
    try testing.expectEqualStrings(
        \\  FAIL T (12ms)
        \\       a.ztest:4
        \\       Expected: status == 200
        \\       Actual:   status == 500
        \\
    , out.buffered());

    out.end = 0;
    try report.caseFinished(.{
        .case = case,
        .is_hook = false,
        .status = .failed,
        .failure = .{ .line = 3, .message = "{{id}} is not defined" },
    });
    try testing.expectEqualStrings("  FAIL T (0ms)\n       a.ztest:3: {{id}} is not defined\n", out.buffered());

    out.end = 0;
    try report.caseFinished(.{ .case = case, .is_hook = false, .status = .skipped });
    try testing.expectEqualStrings("  SKIP T\n", out.buffered());
}

fn parseSample(arena: Allocator) !ast.Suite {
    var diagnostic: parser.Diagnostic = .{};
    return parser.parse(arena, "suite \"S\"\ntest \"T\"\nGET u\nexpect status == 200\nend\n", &diagnostic);
}

test "a directory adds its .ztest files in sorted order and skips hidden ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    try tmp.dir.createDirPath(io, "suite/nested");
    try tmp.dir.createDirPath(io, "suite/.hidden");
    for ([_][]const u8{ "suite/b.ztest", "suite/a.ztest", "suite/nested/c.ztest", "suite/.hidden/d.ztest", "suite/e.txt" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }

    var found: std.ArrayList([]const u8) = .empty;
    try addPath(allocator, io, tmp.dir, "suite/", &found);
    try testing.expectEqual(3, found.items.len);
    try testing.expectEqualStrings("suite/a.ztest", found.items[0]);
    try testing.expectEqualStrings("suite/b.ztest", found.items[1]);
    try testing.expectEqualStrings("suite/nested/c.ztest", found.items[2]);
}

test "a named file is used whatever it is called, and a missing one is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "checks.txt", .data = "" });
    var found: std.ArrayList([]const u8) = .empty;
    try addPath(allocator, testing.io, tmp.dir, "checks.txt", &found);
    try testing.expectEqualStrings("checks.txt", found.items[0]);

    try testing.expectError(error.FileNotFound, addPath(allocator, testing.io, tmp.dir, "gone", &found));
}
