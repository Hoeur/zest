//! What a `.ztest` file says. Every slice is owned by the arena passed to
//! `parser.parse`, and `line` is 1-based for error reports.

const std = @import("std");
const assertion = @import("../assertions/assertion.zig");
const request = @import("../http/request.zig");

pub const Suite = struct {
    name: []const u8,
    variables: []const Variable,
    setup: ?Case,
    teardown: ?Case,
    tests: []const Case,
};

pub const Mode = enum {
    run,
    /// Not run, and counted as skipped.
    skip,
    /// Not run or counted.
    disabled,
};

/// A test, or a suite's setup or teardown.
pub const Case = struct {
    name: []const u8,
    line: usize,
    mode: Mode = .run,
    timeout_ms: ?u64 = null,
    variables: []const Variable,
    request: Request,
    expects: []const Expect,
    extracts: []const Extract,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    /// 0 when the value comes from `ztest.json`.
    line: usize,
    secret: bool = false,
};

/// Text may hold `{{variables}}`, so it is only valid once they are replaced.
pub const Request = struct {
    method: request.Method,
    url: []const u8,
    headers: []const request.Header,
    body: Body,
    line: usize,
};

pub const Body = union(enum) {
    none,
    raw: []const u8,
    json: []const u8,
};

pub const Expect = struct {
    assertion: assertion.Assertion,
    line: usize,
};

pub const Extract = struct {
    name: []const u8,
    source: assertion.Target,
    /// The text that names `source`, shown when it cannot be read.
    source_text: []const u8,
    line: usize,
    secret: bool = false,
};

/// Letters, digits and `_`, so `{{name}}` is never ambiguous.
pub fn isVariableName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}
