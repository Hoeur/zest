//! Turns the `ztest.json` variables for a run into plain values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const config = @import("config.zig");
const Config = config.Config;
const ast = @import("parser/ast.zig");

pub const Error = Allocator.Error || error{InvalidEnvironment};

/// Global values, then the named environment's, so that a later name wins. On
/// `error.InvalidEnvironment`, `problem` says what is wrong.
pub fn resolve(arena: Allocator, settings: Config, environ: *const Environ.Map, name: ?[]const u8, problem: *[]const u8) Error![]const ast.Variable {
    var out: std.ArrayList(ast.Variable) = .empty;
    try addAll(arena, &out, settings.variables, environ, problem);
    if (name) |wanted| {
        const environment = find(settings, wanted) orelse {
            problem.* = try unknownEnvironment(arena, settings, wanted);
            return error.InvalidEnvironment;
        };
        try addAll(arena, &out, environment.variables, environ, problem);
    }
    return out.items;
}

fn find(settings: Config, name: []const u8) ?config.Environment {
    for (settings.environments.items) |environment| {
        if (std.mem.eql(u8, environment.name, name)) return environment;
    }
    return null;
}

fn unknownEnvironment(arena: Allocator, settings: Config, name: []const u8) Allocator.Error![]const u8 {
    var known: std.ArrayList(u8) = .empty;
    for (settings.environments.items, 0..) |environment, i| {
        if (i > 0) try known.appendSlice(arena, ", ");
        try known.appendSlice(arena, environment.name);
    }
    if (known.items.len == 0) {
        return std.fmt.allocPrint(arena, "unknown environment '{s}': {s} defines none", .{ name, config.file_name });
    }
    return std.fmt.allocPrint(arena, "unknown environment '{s}', expected one of: {s}", .{ name, known.items });
}

fn addAll(arena: Allocator, out: *std.ArrayList(ast.Variable), variables: config.Variables, environ: *const Environ.Map, problem: *[]const u8) Error!void {
    for (variables.items) |variable| {
        // Such a name could never be used, so it is a mistake in the file.
        if (!ast.isVariableName(variable.name)) {
            problem.* = try std.fmt.allocPrint(arena, "'{s}' in {s} is not a variable name: use letters, digits and _", .{ variable.name, config.file_name });
            return error.InvalidEnvironment;
        }
        try out.append(arena, switch (variable.source) {
            .text => |text| .{ .name = variable.name, .value = text, .line = 0 },
            .env => |key| .{ .name = variable.name, .value = try readEnv(arena, environ, variable.name, key, problem), .line = 0, .secret = true },
        });
    }
}

/// An empty value counts as unset, because a blank key only fails later, as a
/// confusing response from the server.
fn readEnv(arena: Allocator, environ: *const Environ.Map, name: []const u8, key: []const u8, problem: *[]const u8) Error![]const u8 {
    const value = environ.get(key) orelse "";
    if (value.len == 0) {
        problem.* = try std.fmt.allocPrint(arena, "{s} needs the environment variable {s}, which is not set", .{ name, key });
        return error.InvalidEnvironment;
    }
    return value;
}

const testing = std.testing;

const sample =
    \\{
    \\  "variables": { "region": "eu", "url": "global" },
    \\  "environments": {
    \\    "staging": { "url": "staging", "key": { "env": "ZTEST_KEY" } },
    \\    "broken": { "not-a-name": 1 }
    \\  }
    \\}
;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    environ: Environ.Map,
    problem: []const u8 = "",

    fn init() Fixture {
        return .{ .arena = .init(testing.allocator), .environ = .init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.environ.deinit();
        f.arena.deinit();
    }

    fn resolve_(f: *Fixture, name: ?[]const u8) Error![]const ast.Variable {
        const arena = f.arena.allocator();
        const settings = config.parse(arena, sample) catch unreachable;
        return resolve(arena, settings, &f.environ, name, &f.problem);
    }
};

test "without a name only global values are used" {
    var f: Fixture = .init();
    defer f.deinit();

    const variables = try f.resolve_(null);
    try testing.expectEqual(2, variables.len);
    try testing.expectEqualStrings("eu", variables[0].value);
}

test "an environment follows the global values and its env values are secret" {
    var f: Fixture = .init();
    defer f.deinit();
    try f.environ.put("ZTEST_KEY", "abc");

    const variables = try f.resolve_("staging");
    try testing.expectEqual(4, variables.len);
    try testing.expectEqualStrings("url", variables[2].name);
    try testing.expectEqualStrings("staging", variables[2].value);
    try testing.expect(!variables[2].secret);
    try testing.expectEqualStrings("abc", variables[3].value);
    try testing.expect(variables[3].secret);
}

test "problems are explained" {
    var f: Fixture = .init();
    defer f.deinit();

    try testing.expectError(error.InvalidEnvironment, f.resolve_("prod"));
    try testing.expectEqualStrings("unknown environment 'prod', expected one of: staging, broken", f.problem);

    try testing.expectError(error.InvalidEnvironment, f.resolve_("staging"));
    try testing.expectEqualStrings("key needs the environment variable ZTEST_KEY, which is not set", f.problem);

    try f.environ.put("ZTEST_KEY", "");
    try testing.expectError(error.InvalidEnvironment, f.resolve_("staging"));

    try testing.expectError(error.InvalidEnvironment, f.resolve_("broken"));
    try testing.expectEqualStrings("'not-a-name' in ztest.json is not a variable name: use letters, digits and _", f.problem);
}

test "a file with no environments says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var problem: []const u8 = "";
    try testing.expectError(error.InvalidEnvironment, resolve(arena.allocator(), .{}, &environ, "prod", &problem));
    try testing.expectEqualStrings("unknown environment 'prod': ztest.json defines none", problem);
}
