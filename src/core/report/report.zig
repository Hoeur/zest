//! What a run produced, kept for reports written after it ends. A `Collector`
//! copies each case as the runner finishes it, because `CaseResult` slices only
//! live until `caseFinished` returns. Messages are already redacted by the
//! runner, so nothing here can show a secret.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const runner = @import("../runner/runner.zig");

pub const Format = enum {
    json,
    junit,
    html,

    pub fn defaultPath(f: Format) []const u8 {
        return switch (f) {
            .json => "ztest-report.json",
            .junit => "ztest-report.xml",
            .html => "ztest-report.html",
        };
    }
};

/// One `--report` request: a format and where to write it.
pub const Target = struct {
    format: Format,
    path: []const u8,
};

/// Reads `json`, `junit`, `html`, or any of them followed by `=path`.
pub fn parseTarget(text: []const u8) ?Target {
    const equals = std.mem.findScalar(u8, text, '=');
    const name = text[0 .. equals orelse text.len];
    const format = std.meta.stringToEnum(Format, name) orelse return null;
    const path = if (equals) |i| text[i + 1 ..] else format.defaultPath();
    if (path.len == 0) return null;
    return .{ .format = format, .path = path };
}

pub const Kind = enum { @"test", setup, teardown };

pub const Assertion = struct {
    line: usize,
    expected: []const u8,
    actual: []const u8,
    passed: bool,
};

pub const Case = struct {
    name: []const u8,
    kind: Kind,
    line: usize,
    status: runner.Status,
    duration_ms: u64,
    /// A problem that is not a failed assertion, such as a missing variable.
    failure: ?[]const u8 = null,
    failure_line: ?usize = null,
    assertions: []const Assertion = &.{},

    pub fn failedAssertions(c: Case) usize {
        var n: usize = 0;
        for (c.assertions) |a| {
            if (!a.passed) n += 1;
        }
        return n;
    }
};

pub const Suite = struct {
    path: []const u8,
    name: []const u8,
    cases: []const Case,
    duration_ms: u64 = 0,
};

pub const Summary = struct {
    passed: usize,
    failed: usize,
    skipped: usize,
    not_run: usize,
    interrupted: bool,
};

pub const Run = struct {
    tool: []const u8 = "ztest",
    version: []const u8,
    /// UTC, such as `2026-11-03T02:52:00Z`.
    started_at: []const u8,
    environment: ?[]const u8,
    duration_ms: u64,
    summary: Summary,
    suites: []const Suite,
};

/// Listens to a runner and keeps owned copies of each case in `arena`.
pub const Collector = struct {
    arena: Allocator,
    suites: std.ArrayList(Suite) = .empty,
    cases: std.ArrayList(Case) = .empty,
    current_path: []const u8 = "",
    current_name: []const u8 = "",
    current_ms: u64 = 0,

    /// Starts a new suite. Call `endSuite` when the runner is done with it.
    pub fn beginSuite(c: *Collector, path: []const u8, name: []const u8) void {
        c.current_path = path;
        c.current_name = name;
        c.current_ms = 0;
        c.cases = .empty;
    }

    pub fn endSuite(c: *Collector) Allocator.Error!void {
        try c.suites.append(c.arena, .{
            .path = c.current_path,
            .name = c.current_name,
            .cases = c.cases.items,
            .duration_ms = c.current_ms,
        });
        c.cases = .empty;
    }

    pub fn caseFinished(c: *Collector, result: runner.CaseResult) Allocator.Error!void {
        const arena = c.arena;
        const assertions = try arena.alloc(Assertion, result.assertions.len);
        for (assertions, result.assertions, 0..) |*out, item, i| {
            out.* = .{
                .line = if (i < result.case.expects.len) result.case.expects[i].line else 0,
                .expected = try arena.dupe(u8, item.assertion.text),
                .actual = try arena.dupe(u8, item.actual),
                .passed = item.passed,
            };
        }
        const kind: Kind = if (!result.is_hook)
            .@"test"
        else if (std.mem.eql(u8, result.case.name, "setup"))
            .setup
        else
            .teardown;
        const ms = result.duration_ns / std.time.ns_per_ms;
        c.current_ms += ms;
        try c.cases.append(arena, .{
            .name = try arena.dupe(u8, result.case.name),
            .kind = kind,
            .line = result.case.line,
            .status = result.status,
            .duration_ms = ms,
            .failure = if (result.failure) |f| try arena.dupe(u8, f.message) else null,
            .failure_line = if (result.failure) |f| f.line else null,
            .assertions = assertions,
        });
    }

    pub fn finish(c: *Collector, version: []const u8, started_at: []const u8, environment: ?[]const u8, duration_ms: u64, summary: runner.Summary) Run {
        return .{
            .version = version,
            .started_at = started_at,
            .environment = environment,
            .duration_ms = duration_ms,
            .summary = .{
                .passed = summary.passed,
                .failed = summary.failed,
                .skipped = summary.skipped,
                .not_run = summary.not_run,
                .interrupted = summary.interrupted,
            },
            .suites = c.suites.items,
        };
    }
};

/// Formats Unix seconds as an ISO 8601 UTC time.
pub fn formatTimestamp(buffer: *[20]u8, unix_seconds: i64) []const u8 {
    const epoch = std.time.epoch;
    const secs: u64 = @intCast(@max(0, unix_seconds));
    const es: epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = es.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable;
}

pub fn write(out: *Io.Writer, format: Format, run: Run) Io.Writer.Error!void {
    switch (format) {
        .json => try writeJson(out, run),
        .junit => try writeJunit(out, run),
        .html => try writeHtml(out, run),
    }
}

// JSON ---------------------------------------------------------------------

pub fn writeJson(out: *Io.Writer, run: Run) Io.Writer.Error!void {
    try std.json.Stringify.value(run, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

// JUnit --------------------------------------------------------------------

/// The layout Jenkins, GitLab, GitHub and Azure DevOps read: one `testsuite`
/// per file. Hooks only appear when they fail, as a test case of their own,
/// so a failed setup is visible without inflating the counts of a good run.
pub fn writeJunit(out: *Io.Writer, run: Run) Io.Writer.Error!void {
    try out.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    const totals = junitCounts(run.suites);
    try out.print("<testsuites name=\"ztest\" tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"", .{ totals.tests, totals.failures, totals.skipped });
    try seconds(out, run.duration_ms);
    try out.print("\" timestamp=\"{s}\">\n", .{run.started_at});
    for (run.suites) |suite| {
        const counts = junitCounts(&.{suite});
        try out.writeAll("  <testsuite name=\"");
        try xml(out, suite.name);
        try out.print("\" tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"", .{ counts.tests, counts.failures, counts.skipped });
        try seconds(out, suite.duration_ms);
        try out.writeAll("\" file=\"");
        try xml(out, suite.path);
        try out.print("\" timestamp=\"{s}\">\n", .{run.started_at});
        for (suite.cases) |case| {
            if (!countsInJunit(case)) continue;
            try out.writeAll("    <testcase name=\"");
            try xml(out, case.name);
            try out.writeAll("\" classname=\"");
            try xml(out, suite.name);
            try out.writeAll("\" file=\"");
            try xml(out, suite.path);
            try out.print("\" line=\"{d}\" time=\"", .{case.line});
            try seconds(out, case.duration_ms);
            try out.writeAll("\"");
            switch (case.status) {
                .passed => try out.writeAll("/>\n"),
                .skipped => try out.writeAll(">\n      <skipped/>\n    </testcase>\n"),
                .not_run => try out.writeAll(">\n      <skipped message=\"not run after an earlier failure\"/>\n    </testcase>\n"),
                .failed => {
                    try out.writeAll(">\n      <failure message=\"");
                    try xml(out, failureSummary(case));
                    try out.writeAll("\">");
                    try failureDetail(out, suite.path, case);
                    try out.writeAll("</failure>\n    </testcase>\n");
                },
            }
        }
        try out.writeAll("  </testsuite>\n");
    }
    try out.writeAll("</testsuites>\n");
}

fn countsInJunit(case: Case) bool {
    return case.kind == .@"test" or case.status == .failed;
}

const JunitCounts = struct { tests: usize = 0, failures: usize = 0, skipped: usize = 0 };

fn junitCounts(suites: []const Suite) JunitCounts {
    var counts: JunitCounts = .{};
    for (suites) |suite| for (suite.cases) |case| {
        if (!countsInJunit(case)) continue;
        counts.tests += 1;
        switch (case.status) {
            .failed => counts.failures += 1,
            .skipped, .not_run => counts.skipped += 1,
            .passed => {},
        }
    };
    return counts;
}

fn failureSummary(case: Case) []const u8 {
    if (case.failure) |message| return message;
    for (case.assertions) |a| {
        if (!a.passed) return a.expected;
    }
    return "failed";
}

fn failureDetail(out: *Io.Writer, path: []const u8, case: Case) Io.Writer.Error!void {
    if (case.failure) |message| {
        try xml(out, path);
        try out.print(":{d}: ", .{case.failure_line orelse case.line});
        try xml(out, message);
        try out.writeByte('\n');
    }
    for (case.assertions) |a| {
        if (a.passed) continue;
        try xml(out, path);
        try out.print(":{d}\nExpected: ", .{a.line});
        try xml(out, a.expected);
        try out.writeAll("\nActual:   ");
        try xml(out, a.actual);
        try out.writeByte('\n');
    }
}

fn seconds(out: *Io.Writer, ms: u64) Io.Writer.Error!void {
    try out.print("{d}.{d:0>3}", .{ ms / 1000, ms % 1000 });
}

/// Escapes text for an XML attribute or element, and drops control characters
/// that XML 1.0 cannot hold at all.
pub fn xml(out: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        '\'' => try out.writeAll("&#39;"),
        '\t', '\n', '\r' => try out.writeByte(c),
        0...8, 11, 12, 14...31 => try out.writeAll("\u{FFFD}"),
        else => try out.writeByte(c),
    };
}

// HTML ---------------------------------------------------------------------

/// A single file with no scripts or external assets, so it opens anywhere,
/// including as a CI artifact.
pub fn writeHtml(out: *Io.Writer, run: Run) Io.Writer.Error!void {
    const s = run.summary;
    const ok = s.failed == 0 and !s.interrupted;
    try out.writeAll(
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>ZTest report</title>
        \\<style>
        \\:root{--bg:#0f1115;--panel:#171a21;--line:#272b35;--text:#e6e8ee;--muted:#9aa1b2;--pass:#3fb950;--fail:#f85149;--skip:#d29922;--accent:#f5a524}
        \\@media (prefers-color-scheme: light){:root{--bg:#f7f7f8;--panel:#fff;--line:#e3e5ea;--text:#16181d;--muted:#5d6475}}
        \\*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,Segoe UI,sans-serif}
        \\main{max-width:1000px;margin:0 auto;padding:24px 16px}
        \\h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:0}
        \\.meta{color:var(--muted);margin-bottom:20px}
        \\.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin-bottom:24px}
        \\.tile{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px}
        \\.tile b{display:block;font-size:22px}.tile span{color:var(--muted);font-size:12px}
        \\section{background:var(--panel);border:1px solid var(--line);border-radius:8px;margin-bottom:16px;overflow:hidden}
        \\section header{padding:12px 14px;border-bottom:1px solid var(--line)}section header small{color:var(--muted)}
        \\table{width:100%;border-collapse:collapse}td{padding:8px 14px;border-top:1px solid var(--line);vertical-align:top}
        \\tr:first-child td{border-top:0}td.t{width:90px;color:var(--muted);text-align:right;white-space:nowrap}
        \\.badge{display:inline-block;min-width:44px;text-align:center;font-size:11px;font-weight:700;border-radius:4px;padding:1px 6px;margin-right:8px}
        \\.passed{background:color-mix(in srgb,var(--pass) 20%,transparent);color:var(--pass)}
        \\.failed{background:color-mix(in srgb,var(--fail) 20%,transparent);color:var(--fail)}
        \\.skipped,.not_run{background:color-mix(in srgb,var(--skip) 20%,transparent);color:var(--skip)}
        \\pre{margin:6px 0 0;padding:8px 10px;background:var(--bg);border-radius:6px;white-space:pre-wrap;word-break:break-word;font:12px/1.5 Consolas,ui-monospace,monospace}
        \\</style></head><body><main>
        \\
    );
    try out.print("<h1>ZTest report: <span class=\"badge {s}\">{s}</span></h1>\n", .{
        if (ok) "passed" else "failed",
        if (ok) "PASSED" else "FAILED",
    });
    try out.writeAll("<div class=\"meta\">");
    try xml(out, run.started_at);
    try out.writeAll(" &middot; ztest ");
    try xml(out, run.version);
    if (run.environment) |name| {
        try out.writeAll(" &middot; environment ");
        try xml(out, name);
    }
    try out.writeAll("</div>\n<div class=\"tiles\">");
    try tile(out, "Passed", s.passed);
    try tile(out, "Failed", s.failed);
    try tile(out, "Skipped", s.skipped);
    if (s.not_run > 0) try tile(out, "Not run", s.not_run);
    try out.writeAll("<div class=\"tile\"><b>");
    try seconds(out, run.duration_ms);
    try out.writeAll("s</b><span>Duration</span></div></div>\n");

    for (run.suites) |suite| {
        try out.writeAll("<section><header><h2>");
        try xml(out, suite.name);
        try out.writeAll("</h2><small>");
        try xml(out, suite.path);
        try out.writeAll("</small></header><table>\n");
        for (suite.cases) |case| {
            if (case.kind != .@"test" and case.status != .failed) continue;
            try out.print("<tr><td><span class=\"badge {s}\">{s}</span>", .{ @tagName(case.status), statusLabel(case.status) });
            if (case.kind != .@"test") try out.print("[{s}] ", .{@tagName(case.kind)});
            try xml(out, case.name);
            if (case.status == .failed) {
                try out.writeAll("<pre>");
                try failureDetail(out, suite.path, case);
                try out.writeAll("</pre>");
            }
            if (case.duration_ms == 0 and case.status != .skipped and case.status != .not_run) {
                try out.writeAll("</td><td class=\"t\">&lt;1 ms</td></tr>\n");
            } else {
                try out.print("</td><td class=\"t\">{d} ms</td></tr>\n", .{case.duration_ms});
            }
        }
        try out.writeAll("</table></section>\n");
    }
    try out.writeAll("</main></body></html>\n");
}

fn tile(out: *Io.Writer, label: []const u8, value: usize) Io.Writer.Error!void {
    try out.print("<div class=\"tile\"><b>{d}</b><span>{s}</span></div>", .{ value, label });
}

fn statusLabel(status: runner.Status) []const u8 {
    return switch (status) {
        .passed => "PASS",
        .failed => "FAIL",
        .skipped => "SKIP",
        .not_run => "STOP",
    };
}

// Tests --------------------------------------------------------------------

const testing = std.testing;

fn sampleRun() Run {
    const cases: []const Case = &.{
        .{ .name = "Lists users", .kind = .@"test", .line = 4, .status = .passed, .duration_ms = 12 },
        .{ .name = "Rejects <bad> & \"odd\"", .kind = .@"test", .line = 9, .status = .failed, .duration_ms = 1500, .assertions = &.{
            .{ .line = 11, .expected = "status == 200", .actual = "status == 500", .passed = false },
            .{ .line = 12, .expected = "body.id exists", .actual = "body.id == 1", .passed = true },
        } },
        .{ .name = "Later", .kind = .@"test", .line = 14, .status = .skipped, .duration_ms = 0 },
        .{ .name = "teardown", .kind = .teardown, .line = 20, .status = .passed, .duration_ms = 3 },
    };
    return .{
        .version = "0.1.0",
        .started_at = "2026-11-03T02:52:00Z",
        .environment = "staging",
        .duration_ms = 1515,
        .summary = .{ .passed = 1, .failed = 1, .skipped = 1, .not_run = 0, .interrupted = false },
        .suites = &.{.{ .path = "tests/users.ztest", .name = "Users", .cases = cases, .duration_ms = 1515 }},
    };
}

test "report targets take a format and an optional path" {
    try testing.expectEqualStrings("ztest-report.xml", parseTarget("junit").?.path);
    const t = parseTarget("json=out/run.json").?;
    try testing.expectEqual(Format.json, t.format);
    try testing.expectEqualStrings("out/run.json", t.path);
    try testing.expectEqual(null, parseTarget("xml"));
    try testing.expectEqual(null, parseTarget("json="));
}

test "timestamps are ISO 8601 in UTC" {
    var buffer: [20]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatTimestamp(&buffer, 0));
    try testing.expectEqualStrings("2026-11-03T02:52:07Z", formatTimestamp(&buffer, 1793674327));
}

test "JUnit counts tests, escapes text and reports failures" {
    var buffer: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try writeJunit(&out, sampleRun());
    const text = out.buffered();
    try testing.expect(std.mem.find(u8, text, "<testsuites name=\"ztest\" tests=\"3\" failures=\"1\" skipped=\"1\" time=\"1.515\"") != null);
    try testing.expect(std.mem.find(u8, text, "name=\"Rejects &lt;bad&gt; &amp; &quot;odd&quot;\"") != null);
    try testing.expect(std.mem.find(u8, text, "<failure message=\"status == 200\">tests/users.ztest:11\nExpected: status == 200\nActual:   status == 500\n</failure>") != null);
    try testing.expect(std.mem.find(u8, text, "<skipped/>") != null);
    // A passing hook is not a test case.
    try testing.expect(std.mem.find(u8, text, "teardown") == null);
}

test "JSON holds the summary and every case" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try writeJson(&out, sampleRun());
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("staging", root.get("environment").?.string);
    try testing.expectEqual(1, root.get("summary").?.object.get("failed").?.integer);
    const cases = root.get("suites").?.array.items[0].object.get("cases").?.array.items;
    try testing.expectEqual(4, cases.len);
    try testing.expectEqualStrings("failed", cases[1].object.get("status").?.string);
}

test "HTML escapes names and shows failures" {
    var buffer: [8192]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try writeHtml(&out, sampleRun());
    const text = out.buffered();
    try testing.expect(std.mem.find(u8, text, "Rejects &lt;bad&gt;") != null);
    try testing.expect(std.mem.find(u8, text, "Actual:   status == 500") != null);
    try testing.expect(std.mem.find(u8, text, "<script") == null);
}

test "XML escaping drops control characters" {
    var buffer: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try xml(&out, "a\x01b<");
    try testing.expectEqualStrings("a\u{FFFD}b&lt;", out.buffered());
}
