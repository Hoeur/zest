//! Replaces `{{name}}` in text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../parser/ast.zig");

/// Values read from responses, which outrank every `var`.
pub const Runtime = std.StringHashMapUnmanaged([]const u8);

pub const Scope = struct {
    runtime: *const Runtime,
    case: []const ast.Variable,
    suite: []const ast.Variable,
    /// Global and environment values, the lowest priority.
    base: []const ast.Variable = &.{},

    pub fn get(s: Scope, name: []const u8) ?[]const u8 {
        if (s.runtime.get(name)) |value| return value;
        return latest(s.case, name) orelse latest(s.suite, name) orelse latest(s.base, name);
    }
};

/// A name defined twice keeps its last value.
fn latest(variables: []const ast.Variable, name: []const u8) ?[]const u8 {
    var i = variables.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, variables[i].name, name)) return variables[i].value;
    }
    return null;
}

pub const Error = Allocator.Error || error{MissingVariable};

/// On `error.MissingVariable`, `missing` is the name. Braces around anything
/// else stay as they are, so `{{` in a JSON string needs no escape. A value is
/// never replaced again, so a response cannot inject a variable.
pub fn interpolate(arena: Allocator, text: []const u8, scope: Scope, missing: *[]const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    var search: usize = 0;
    while (std.mem.findPos(u8, text, search, "{{")) |open| {
        const close = std.mem.findPos(u8, text, open + 2, "}}") orelse break;
        const name = text[open + 2 .. close];
        if (!ast.isVariableName(name)) {
            search = open + 1;
            continue;
        }
        const value = scope.get(name) orelse {
            missing.* = name;
            return error.MissingVariable;
        };
        try out.appendSlice(arena, text[start..open]);
        try out.appendSlice(arena, value);
        start = close + 2;
        search = start;
    }
    if (start == 0) return text;
    try out.appendSlice(arena, text[start..]);
    return out.items;
}

const testing = std.testing;

const empty_runtime: Runtime = .empty;
const sample: Scope = .{
    .runtime = &empty_runtime,
    .case = &.{.{ .name = "id", .value = "7", .line = 1 }},
    .suite = &.{
        .{ .name = "id", .value = "1", .line = 1 },
        .{ .name = "base", .value = "http://a.test", .line = 2 },
        .{ .name = "loop", .value = "{{base}}", .line = 3 },
    },
};

fn expectText(expected: []const u8, text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var missing: []const u8 = "";
    try testing.expectEqualStrings(expected, try interpolate(arena.allocator(), text, sample, &missing));
}

test "variables are replaced and a test's value wins" {
    try expectText("http://a.test/users/7", "{{base}}/users/{{id}}");
    try expectText("77", "{{id}}{{id}}");
    try expectText("no variables", "no variables");
}

test "braces around anything else are left alone" {
    try expectText("{{ id }}", "{{ id }}");
    try expectText("{{}}", "{{}}");
    try expectText("{{open", "{{open");
    try expectText("{\"a\":{\"b\":1}}", "{\"a\":{\"b\":1}}");
    try expectText("{7}", "{{{id}}}");
    try expectText("{{a b}} 7", "{{a b}} {{id}}");
}

test "a value is not replaced again" {
    try expectText("{{base}}", "{{loop}}");
}

test "a missing variable is named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var missing: []const u8 = "";
    try testing.expectError(error.MissingVariable, interpolate(arena.allocator(), "a {{token}}", sample, &missing));
    try testing.expectEqualStrings("token", missing);
}

test "a suite's value outranks the base values" {
    var scope = sample;
    scope.base = &.{
        .{ .name = "id", .value = "2", .line = 0 },
        .{ .name = "region", .value = "eu", .line = 0 },
        .{ .name = "region", .value = "us", .line = 0 },
    };
    try testing.expectEqualStrings("7", scope.get("id").?);
    try testing.expectEqualStrings("us", scope.get("region").?);
}

test "runtime values outrank every var" {
    var runtime: Runtime = .empty;
    defer runtime.deinit(testing.allocator);
    try runtime.put(testing.allocator, "id", "9");

    var scope = sample;
    scope.runtime = &runtime;
    try testing.expectEqualStrings("9", scope.get("id").?);
}
