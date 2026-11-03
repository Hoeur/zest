//! The Assertions panel's rows, made from the Tests editor's text: one row
//! per switched-on line, described in words, with edits that rewrite the text.
//! Pure functions, so they are tested on any platform.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assertion = @import("../core/assertions/assertion.zig");
const Operator = assertion.Operator;

pub const Row = struct {
    /// 0-based line in the Tests text.
    line: usize,
    text: []const u8,
    /// Null when the line is not a valid assertion.
    parsed: ?assertion.Assertion,
    label: []const u8,
    operator: []const u8,
    /// What the value box shows: the expected value, or the path for exists.
    value: []const u8,
    /// `ms` or `s` for response times.
    unit: []const u8 = "",
    /// Why the line is invalid, when it is.
    problem: []const u8 = "",
};

/// Every switched-on, non-blank line. Slices point into `text` or `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 0;
    while (it.next()) |raw| : (line += 1) {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const parsed = assertion.parse(arena, trimmed) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try rows.append(arena, .{ .line = line, .text = trimmed, .parsed = null, .label = "Invalid", .operator = "", .value = trimmed, .problem = assertion.describe(err) });
            continue;
        };
        try rows.append(arena, try describeRow(arena, line, trimmed, parsed));
    }
    return rows.items;
}

fn describeRow(arena: Allocator, line: usize, text: []const u8, a: assertion.Assertion) Allocator.Error!Row {
    var row: Row = .{ .line = line, .text = text, .parsed = a, .label = labelOf(a.target), .operator = word(a.op), .value = "" };
    if (a.op == .exists or a.op == .not_exists) {
        row.value = a.name;
        return row;
    }
    row.value = switch (a.expected) {
        .none => "",
        .null => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| n,
        .string => |s| try std.fmt.allocPrint(arena, "\"{s}\"", .{s}),
        .duration_ns => |ns| blk: {
            if (ns % std.time.ns_per_s == 0 and ns >= std.time.ns_per_s) {
                row.unit = "s";
                break :blk try std.fmt.allocPrint(arena, "{d}", .{ns / std.time.ns_per_s});
            }
            row.unit = "ms";
            break :blk try std.fmt.allocPrint(arena, "{d}", .{ns / std.time.ns_per_ms});
        },
    };
    if (a.target == .response_time and row.unit.len == 0) row.unit = "ms";
    if (a.target == .header) row.label = "Header";
    return row;
}

pub fn labelOf(target: assertion.Target) []const u8 {
    return switch (target) {
        .status => "Status code",
        .response_time => "Response time",
        .body => |path| if (path.len == 0) "Body" else "Body property",
        .header => "Header",
    };
}

pub fn word(op: Operator) []const u8 {
    return switch (op) {
        .eq => "equals",
        .ne => "not equals",
        .gt => "greater than",
        .lt => "less than",
        .ge => "at least",
        .le => "at most",
        .exists => "exists",
        .not_exists => "does not exist",
        .contains => "contains",
        .starts_with => "starts with",
        .ends_with => "ends with",
    };
}

/// One sentence under the row, such as "Expected response status code to be 200."
pub fn sentence(buffer: []u8, row: Row) []const u8 {
    const a = row.parsed orelse return std.fmt.bufPrint(buffer, "{s}", .{row.problem}) catch "";
    const phrase: []const u8 = switch (a.op) {
        .eq => "be",
        .ne => "not be",
        .gt => "be greater than",
        .lt => "be less than",
        .ge => "be at least",
        .le => "be at most",
        .contains => "contain",
        .starts_with => "start with",
        .ends_with => "end with",
        .exists, .not_exists => "",
    };
    const space: []const u8 = if (row.unit.len > 0) " " else "";
    return switch (a.target) {
        .status => std.fmt.bufPrint(buffer, "Expected response status code to {s} {s}.", .{ phrase, row.value }),
        .response_time => std.fmt.bufPrint(buffer, "Expected response time to {s} {s}{s}{s}.", .{ phrase, row.value, space, row.unit }),
        .header => |name| if (a.op == .exists or a.op == .not_exists)
            std.fmt.bufPrint(buffer, "Expected response {s} header {s}.", .{ if (a.op == .exists) "to have" else "not to have", name })
        else
            std.fmt.bufPrint(buffer, "Expected header {s} to {s} {s}.", .{ name, phrase, row.value }),
        .body => if (a.op == .exists or a.op == .not_exists)
            std.fmt.bufPrint(buffer, "Expected response {s} property {s}.", .{ if (a.op == .exists) "to have" else "not to have", a.name })
        else
            std.fmt.bufPrint(buffer, "Expected {s} to {s} {s}.", .{ a.name, phrase, row.value }),
    } catch "";
}

/// Operators that make sense for a row's target, in menu order.
pub fn operatorsFor(target: assertion.Target) []const Operator {
    return switch (target) {
        .status, .response_time => &.{ .eq, .ne, .lt, .le, .gt, .ge },
        .header, .body => &.{ .eq, .ne, .contains, .starts_with, .ends_with, .exists, .not_exists, .lt, .gt },
    };
}

/// Ready-made assertions for the Templates and Add Assertion menus.
pub const templates = [_]struct { label: []const u8, text: []const u8 }{
    .{ .label = "Status code equals 200", .text = "status == 200" },
    .{ .label = "Response time less than 500 ms", .text = "response_time < 500ms" },
    .{ .label = "Body property exists", .text = "body.id exists" },
    .{ .label = "Header contains JSON content type", .text = "header.content-type contains \"json\"" },
    .{ .label = "Body contains text", .text = "body contains \"ok\"" },
    .{ .label = "Status code is not a server error", .text = "status < 500" },
};

/// The first template whose target the text does not check yet.
pub fn suggested(rows: []const Row) []const u8 {
    for (templates) |t| {
        const target = t.text[0 .. std.mem.findScalar(u8, t.text, ' ') orelse t.text.len];
        const taken = for (rows) |row| {
            if (std.mem.startsWith(u8, row.text, target)) break true;
        } else false;
        if (!taken) return t.text;
    }
    return templates[0].text;
}

/// `text` with `line` replaced by `with`, or removed when `with` is null.
/// Line endings stay as they were.
pub fn replaceLine(allocator: Allocator, text: []const u8, line: usize, with: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    var first = true;
    while (it.next()) |raw| : (index += 1) {
        if (index == line) {
            const replacement = with orelse continue;
            if (!first) try out.append(allocator, '\n');
            try out.appendSlice(allocator, replacement);
            if (std.mem.endsWith(u8, raw, "\r")) try out.append(allocator, '\r');
        } else {
            if (!first) try out.append(allocator, '\n');
            try out.appendSlice(allocator, raw);
        }
        first = false;
    }
    return out.items;
}

/// `text` with `line` added at the end, on a line of its own.
pub fn appendLine(allocator: Allocator, text: []const u8, line: []const u8) Allocator.Error![]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(allocator, "{s}\r\n", .{line});
    return std.fmt.allocPrint(allocator, "{s}\r\n{s}\r\n", .{ trimmed, line });
}

/// The row's line rewritten with `op`, keeping its target and value where
/// the new operator takes one.
pub fn withOperator(allocator: Allocator, row: Row, op: Operator) Allocator.Error![]const u8 {
    const a = row.parsed orelse return allocator.dupe(u8, row.text);
    if (op == .exists or op == .not_exists) return std.fmt.allocPrint(allocator, "{s} {s}", .{ a.name, op.symbol() });
    const old_value = std.mem.trim(u8, row.text[@min(row.text.len, a.name.len)..], " ");
    const after_op = std.mem.trim(u8, old_value[@min(old_value.len, a.op.symbol().len)..], " ");
    const value = if (after_op.len > 0) after_op else switch (a.target) {
        .status => "200",
        .response_time => "500ms",
        else => "\"\"",
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ a.name, op.symbol(), value });
}

const testing = std.testing;

test "lines become described rows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "status == 200\r\n\r\n# off\r\nresponse_time < 500ms\r\nbody.token exists\r\nheader.content-type contains \"json\"\r\nstatus\r\n");
    try testing.expectEqual(5, rows.len);
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("Status code", rows[0].label);
    try testing.expectEqualStrings("equals", rows[0].operator);
    try testing.expectEqualStrings("Expected response status code to be 200.", sentence(&buffer, rows[0]));
    try testing.expectEqual(3, rows[1].line);
    try testing.expectEqualStrings("ms", rows[1].unit);
    try testing.expectEqualStrings("Expected response time to be less than 500 ms.", sentence(&buffer, rows[1]));
    try testing.expectEqualStrings("body.token", rows[2].value);
    try testing.expectEqualStrings("Expected response to have property body.token.", sentence(&buffer, rows[2]));
    try testing.expectEqualStrings("Header", rows[3].label);
    try testing.expect(rows[4].parsed == null);
    try testing.expectEqualStrings("response_time < 500ms", suggested(rows[0..1]));
}

test "edits rewrite only their line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "status == 200\r\nbody.id exists\r\n";
    try testing.expectEqualStrings("status == 200\r\n", try replaceLine(a, text, 1, null));
    try testing.expectEqualStrings("status != 200\r\nbody.id exists\r\n", try replaceLine(a, text, 0, "status != 200"));
    try testing.expectEqualStrings("status == 200\r\nbody.id exists\r\nstatus < 500\r\n", try appendLine(a, text, "status < 500"));
    try testing.expectEqualStrings("x\r\n", try appendLine(a, "", "x"));

    const rows = try parse(a, text);
    try testing.expectEqualStrings("status < 200", try withOperator(a, rows[0], .lt));
    try testing.expectEqualStrings("body.id == \"\"", try withOperator(a, rows[1], .eq));
    try testing.expectEqualStrings("status exists", try withOperator(a, rows[0], .exists));
}
