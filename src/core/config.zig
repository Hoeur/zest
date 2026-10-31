//! Optional `ztest.json` settings. Command-line flags override these values.
//!
//! `variables` apply to every run, and `environments` holds named sets of them:
//!
//!     {
//!       "variables": { "retries": 3 },
//!       "environments": {
//!         "staging": { "baseUrl": "https://staging.test", "apiKey": { "env": "STAGING_KEY" } }
//!       }
//!     }

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Level = @import("log.zig").Level;

pub const file_name = "ztest.json";
const max_size: Io.Limit = .limited(1024 * 1024);

pub const Config = struct {
    log_level: Level = .normal,
    color: bool = true,
    variables: Variables = .{},
    environments: Environments = .{},
};

pub const Variable = struct {
    name: []const u8,
    source: union(enum) {
        text: []const u8,
        /// The name of a process environment variable. Its value is secret.
        env: []const u8,
    },
};

const JsonError = Allocator.Error || error{UnexpectedToken};

/// Written as an object, and kept in file order.
pub const Variables = struct {
    items: []const Variable = &.{},

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Variables {
        return fromValue(allocator, try parseValue(allocator, source, options));
    }

    fn fromValue(allocator: Allocator, value: std.json.Value) JsonError!Variables {
        if (value != .object) return error.UnexpectedToken;
        const items = try allocator.alloc(Variable, value.object.count());
        for (items, value.object.keys(), value.object.values()) |*item, name, entry| {
            item.* = .{ .name = name, .source = try sourceOf(entry) };
        }
        return .{ .items = items };
    }
};

pub const Environment = struct {
    name: []const u8,
    variables: Variables,
};

/// Written as an object of `Variables`.
pub const Environments = struct {
    items: []const Environment = &.{},

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Environments {
        const value = try parseValue(allocator, source, options);
        if (value != .object) return error.UnexpectedToken;
        const items = try allocator.alloc(Environment, value.object.count());
        for (items, value.object.keys(), value.object.values()) |*item, name, entry| {
            item.* = .{ .name = name, .variables = try .fromValue(allocator, entry) };
        }
        return .{ .items = items };
    }
};

/// Numbers stay as text, so `1.50` is not turned into `1.5`.
fn parseValue(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!std.json.Value {
    var value_options = options;
    value_options.parse_numbers = false;
    return std.json.Value.jsonParse(allocator, source, value_options);
}

fn sourceOf(value: std.json.Value) error{UnexpectedToken}!@FieldType(Variable, "source") {
    return switch (value) {
        .string => |text| .{ .text = text },
        .number_string => |text| .{ .text = text },
        .bool => |boolean| .{ .text = if (boolean) "true" else "false" },
        .object => |object| {
            const name = object.get("env") orelse return error.UnexpectedToken;
            if (object.count() != 1 or name != .string) return error.UnexpectedToken;
            return .{ .env = name.string };
        },
        else => error.UnexpectedToken,
    };
}

/// Unknown fields are errors so that a misspelled setting is not ignored.
/// Allocations are not freed individually, so pass an arena.
pub fn parse(arena: Allocator, text: []const u8) !Config {
    return std.json.parseFromSliceLeaky(Config, arena, text, .{});
}

/// Returns the defaults if `dir` has no config file.
pub fn load(arena: Allocator, io: Io, dir: Io.Dir) !Config {
    const text = dir.readFileAlloc(io, file_name, arena, max_size) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

const testing = std.testing;

test "parse reads settings and keeps defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const config = try parse(arena.allocator(), "{\"log_level\": \"verbose\"}");
    try testing.expectEqual(Level.verbose, config.log_level);
    try testing.expect(config.color);
}

test "parse rejects misspelled settings and invalid json" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.UnknownField, parse(arena.allocator(), "{\"colour\": false}"));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "{]"));
}

test "parse reads variables and environments in file order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const config = try parse(arena.allocator(),
        \\{
        \\  "variables": { "b": "text", "a": 1.50, "c": true },
        \\  "environments": {
        \\    "staging": { "key": { "env": "STAGING_KEY" } },
        \\    "production": {}
        \\  }
        \\}
    );
    try testing.expectEqual(3, config.variables.items.len);
    try testing.expectEqualStrings("b", config.variables.items[0].name);
    try testing.expectEqualStrings("1.50", config.variables.items[1].source.text);
    try testing.expectEqualStrings("true", config.variables.items[2].source.text);

    try testing.expectEqual(2, config.environments.items.len);
    try testing.expectEqualStrings("staging", config.environments.items[0].name);
    try testing.expectEqualStrings("STAGING_KEY", config.environments.items[0].variables.items[0].source.env);
}

test "parse rejects values a variable cannot hold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "{\"variables\": []}",
        "{\"variables\": {\"a\": null}}",
        "{\"variables\": {\"a\": [1]}}",
        "{\"variables\": {\"a\": {\"file\": \"x\"}}}",
        "{\"variables\": {\"a\": {\"env\": 1}}}",
        "{\"variables\": {\"a\": {\"env\": \"X\", \"other\": 1}}}",
        "{\"environments\": {\"staging\": 1}}",
    }) |text| {
        try testing.expectError(error.UnexpectedToken, parse(arena.allocator(), text));
    }
}

test "load uses defaults without a file and reads one when present" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(Config{}, try load(arena.allocator(), testing.io, tmp.dir));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{\"color\": false}" });
    const config = try load(arena.allocator(), testing.io, tmp.dir);
    try testing.expect(!config.color);
}
