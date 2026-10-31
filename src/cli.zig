//! Command-line parsing. Holds no I/O so every case can be unit tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assertion = @import("core/assertions/assertion.zig");
const Assertion = assertion.Assertion;
const Level = @import("core/log.zig").Level;
const request_model = @import("core/http/request.zig");
const Auth = request_model.Auth;
const Header = request_model.Header;
const Method = request_model.Method;
const Param = request_model.Param;
const Request = request_model.Request;
const default_timeout_ms = request_model.default_timeout_ms;

pub const help =
    \\Usage: ztest [options]
    \\       ztest api <method> <url> [api options]
    \\       ztest run <file or directory>... [run options]
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  -v, --verbose    Show debug messages
    \\  -q, --quiet      Only show errors
    \\      --no-color   Disable colored output
    \\
    \\API options:
    \\  -H, --header <name: value>   Add a request header
    \\      --query <name=value>     Add a query parameter
    \\      --json <text>            Send a JSON body
    \\      --body <text>            Send a raw body
    \\      --timeout <ms>           Time limit, 0 for none (default 30000)
    \\      --auth <kind:...>        basic:user:password, bearer:token,
    \\                               header:name:key or query:name:key
    \\      --assert <expression>    Check the response, repeatable, such as
    \\                               "status == 200" or "body.user.id exists"
    \\      --raw                    Print only the response body
    \\
    \\Run options:
    \\      --fail-fast              Stop after the first failure
    \\  -e, --env <name>             Use an environment from ztest.json
    \\
;

pub const Command = enum { help, version, api, run };

pub const Options = struct {
    command: Command = .help,
    /// Null when no flag was given, leaving the config value in charge.
    level: ?Level = null,
    no_color: bool = false,
    /// Set when `command` is `api`.
    request: ?Request = null,
    raw: bool = false,
    assertions: []const Assertion = &.{},
    /// Set when `command` is `run`.
    paths: []const []const u8 = &.{},
    fail_fast: bool = false,
    environment: ?[]const u8 = null,
};

pub const ParseError = Allocator.Error || error{
    UnknownArgument,
    ConflictingFlags,
    MissingValue,
    InvalidValue,
    MissingArgument,
    InvalidAssertion,
};

/// `args` excludes the program name. On error, `bad_arg` names the cause.
/// Allocations are not freed individually, so pass an arena.
pub fn parse(arena: Allocator, args: []const [:0]const u8, bad_arg: *[]const u8) ParseError!Options {
    var options: Options = .{};
    var api: ApiArgs = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h", "--help")) {
            options.command = .help;
        } else if (is(arg, "-V", "--version")) {
            options.command = .version;
        } else if (is(arg, "-v", "--verbose") or is(arg, "-q", "--quiet")) {
            const level: Level = if (is(arg, "-v", "--verbose")) .verbose else .quiet;
            if (options.level != null and options.level != level) {
                bad_arg.* = arg;
                return error.ConflictingFlags;
            }
            options.level = level;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            options.no_color = true;
        } else if (options.command == .api) {
            bad_arg.* = arg;
            if (std.mem.eql(u8, arg, "--raw")) {
                options.raw = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                i += 1;
                if (!isApiFlag(arg)) return error.UnknownArgument;
                if (i == args.len) return error.MissingValue;
                try api.flag(arena, arg, args[i], bad_arg);
            } else {
                try api.positional(arg);
            }
        } else if (options.command == .run) {
            bad_arg.* = arg;
            if (std.mem.eql(u8, arg, "--fail-fast")) {
                options.fail_fast = true;
            } else if (is(arg, "-e", "--env")) {
                i += 1;
                if (i == args.len) return error.MissingValue;
                options.environment = args[i];
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.UnknownArgument;
            } else {
                try paths.append(arena, arg);
            }
        } else if (std.mem.eql(u8, arg, "api")) {
            options.command = .api;
        } else if (std.mem.eql(u8, arg, "run")) {
            options.command = .run;
        } else {
            bad_arg.* = arg;
            return error.UnknownArgument;
        }
    }
    if (options.command == .api) {
        options.request = try api.finish(bad_arg);
        options.assertions = api.assertions.items;
    }
    if (options.command == .run) {
        bad_arg.* = "a file or directory";
        if (paths.items.len == 0) return error.MissingArgument;
        options.paths = paths.items;
    }
    return options;
}

const ApiArgs = struct {
    method: ?Method = null,
    url: ?[]const u8 = null,
    headers: std.ArrayList(Header) = .empty,
    query: std.ArrayList(Param) = .empty,
    body: request_model.Body = .none,
    auth: Auth = .none,
    timeout_ms: ?u64 = default_timeout_ms,
    assertions: std.ArrayList(Assertion) = .empty,

    fn positional(a: *ApiArgs, arg: []const u8) ParseError!void {
        if (a.method == null) {
            a.method = parseMethod(arg) orelse return error.InvalidValue;
        } else if (a.url == null) {
            a.url = arg;
        } else {
            return error.UnknownArgument;
        }
    }

    fn flag(a: *ApiArgs, arena: Allocator, name: []const u8, value: []const u8, bad_arg: *[]const u8) ParseError!void {
        bad_arg.* = value;
        if (is(name, "-H", "--header")) {
            const colon = std.mem.findScalar(u8, value, ':') orelse return error.InvalidValue;
            try a.headers.append(arena, .{
                .name = std.mem.trim(u8, value[0..colon], " "),
                .value = std.mem.trim(u8, value[colon + 1 ..], " "),
            });
        } else if (std.mem.eql(u8, name, "--query")) {
            const equals = std.mem.findScalar(u8, value, '=') orelse return error.InvalidValue;
            try a.query.append(arena, .{ .name = value[0..equals], .value = value[equals + 1 ..] });
        } else if (std.mem.eql(u8, name, "--timeout")) {
            const ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
            a.timeout_ms = if (ms == 0) null else ms;
        } else if (std.mem.eql(u8, name, "--auth")) {
            a.auth = parseAuth(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "--assert")) {
            const parsed = assertion.parse(arena, value) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                bad_arg.* = try std.fmt.allocPrint(arena, "'{s}': {s}", .{ value, assertion.describe(err) });
                return error.InvalidAssertion;
            };
            try a.assertions.append(arena, parsed);
        } else {
            bad_arg.* = name;
            if (a.body != .none) return error.ConflictingFlags;
            a.body = if (std.mem.eql(u8, name, "--json")) .{ .json = value } else .{ .raw = value };
        }
    }

    fn finish(a: *ApiArgs, bad_arg: *[]const u8) ParseError!Request {
        bad_arg.* = if (a.method == null) "a method" else "a URL";
        return .{
            .method = a.method orelse return error.MissingArgument,
            .url = a.url orelse return error.MissingArgument,
            .query = a.query.items,
            .headers = a.headers.items,
            .body = a.body,
            .auth = a.auth,
            .timeout_ms = a.timeout_ms,
        };
    }
};

fn isApiFlag(arg: []const u8) bool {
    const flags = [_][]const u8{ "-H", "--header", "--query", "--json", "--body", "--timeout", "--auth", "--assert" };
    for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn parseMethod(text: []const u8) ?Method {
    for (std.enums.values(Method)) |method| {
        if (std.ascii.eqlIgnoreCase(text, @tagName(method))) return method;
    }
    return null;
}

fn parseAuth(text: []const u8) ?Auth {
    const colon = std.mem.findScalar(u8, text, ':') orelse return null;
    const kind = text[0..colon];
    const rest = text[colon + 1 ..];
    if (std.mem.eql(u8, kind, "bearer")) return .{ .bearer = rest };

    const split = std.mem.findScalar(u8, rest, ':') orelse return null;
    const first = rest[0..split];
    const second = rest[split + 1 ..];
    if (std.mem.eql(u8, kind, "basic")) return .{ .basic = .{ .user = first, .password = second } };
    if (std.mem.eql(u8, kind, "header")) return .{ .api_key_header = .{ .name = first, .value = second } };
    if (std.mem.eql(u8, kind, "query")) return .{ .api_key_query = .{ .name = first, .value = second } };
    return null;
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

const testing = std.testing;

fn parseArgs(args: []const [:0]const u8) ParseError!Options {
    var bad_arg: []const u8 = "";
    return parse(testing.allocator, args, &bad_arg);
}

/// Runs `check` on parsed `api` arguments, with an arena for the lists.
fn expectApi(args: []const [:0]const u8, check: *const fn (Options) anyerror!void) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad_arg: []const u8 = "";
    try check(try parse(arena.allocator(), args, &bad_arg));
}

test "no arguments shows help" {
    try testing.expectEqual(Options{}, try parseArgs(&.{}));
}

test "short and long flags are parsed" {
    try testing.expectEqual(Command.version, (try parseArgs(&.{"--version"})).command);
    try testing.expectEqual(Command.version, (try parseArgs(&.{"-V"})).command);
    try testing.expectEqual(Command.help, (try parseArgs(&.{"-h"})).command);

    const options = try parseArgs(&.{ "-v", "--no-color", "--version" });
    try testing.expectEqual(Level.verbose, options.level.?);
    try testing.expect(options.no_color);
    try testing.expectEqual(Level.quiet, (try parseArgs(&.{"--quiet"})).level.?);
}

test "repeating a level flag is allowed" {
    try testing.expectEqual(Level.verbose, (try parseArgs(&.{ "-v", "--verbose" })).level.?);
}

test "bad arguments are named" {
    var bad_arg: []const u8 = "";
    try testing.expectError(error.UnknownArgument, parse(testing.allocator, &.{"--nope"}, &bad_arg));
    try testing.expectEqualStrings("--nope", bad_arg);

    try testing.expectError(error.ConflictingFlags, parse(testing.allocator, &.{ "-v", "-q" }, &bad_arg));
    try testing.expectEqualStrings("-q", bad_arg);
}

test "api reads the method and URL" {
    try expectApi(&.{ "api", "get", "https://example.com" }, struct {
        fn check(options: Options) !void {
            try testing.expectEqual(Command.api, options.command);
            try testing.expectEqual(Method.GET, options.request.?.method);
            try testing.expectEqualStrings("https://example.com", options.request.?.url);
            try testing.expectEqual(default_timeout_ms, options.request.?.timeout_ms.?);
        }
    }.check);
}

test "api reads its flags" {
    try expectApi(&.{
        "api",        "POST", "http://a.test", "-H", "X-Id: 1:2", "--query",       "q=a=b",
        "--json",     "{}",   "--timeout",     "0",  "--auth",    "basic:ada:p:w", "--raw",
        "--no-color",
    }, struct {
        fn check(options: Options) !void {
            const request = options.request.?;
            try testing.expectEqualStrings("X-Id", request.headers[0].name);
            try testing.expectEqualStrings("1:2", request.headers[0].value);
            try testing.expectEqualStrings("a=b", request.query[0].value);
            try testing.expectEqualStrings("{}", request.body.json);
            try testing.expectEqual(null, request.timeout_ms);
            try testing.expectEqualStrings("ada", request.auth.basic.user);
            try testing.expectEqualStrings("p:w", request.auth.basic.password);
            try testing.expect(options.raw);
            try testing.expect(options.no_color);
        }
    }.check);
}

test "auth kinds are parsed" {
    try testing.expectEqualStrings("a:b", parseAuth("bearer:a:b").?.bearer);
    try testing.expectEqualStrings("X-Key", parseAuth("header:X-Key:s").?.api_key_header.name);
    try testing.expectEqualStrings("s", parseAuth("query:key:s").?.api_key_query.value);
    try testing.expectEqual(null, parseAuth("token"));
    try testing.expectEqual(null, parseAuth("other:a:b"));
}

test "api collects assertions in order" {
    try expectApi(&.{ "api", "GET", "u", "--assert", "status == 200", "--assert", "body.id exists" }, struct {
        fn check(options: Options) !void {
            try testing.expectEqual(2, options.assertions.len);
            try testing.expectEqualStrings("status == 200", options.assertions[0].text);
            try testing.expectEqualStrings("body.id", options.assertions[1].name);
        }
    }.check);
}

test "a bad assertion explains itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad_arg: []const u8 = "";

    try testing.expectError(
        error.InvalidAssertion,
        parse(arena.allocator(), &.{ "api", "GET", "u", "--assert", "status" }, &bad_arg),
    );
    try testing.expectEqualStrings("'status': expected <target> <operator> [value]", bad_arg);
}

test "run reads its paths and flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad_arg: []const u8 = "";

    const options = try parse(arena.allocator(), &.{ "run", "tests/", "--fail-fast", "-e", "staging", "a.ztest" }, &bad_arg);
    try testing.expectEqual(Command.run, options.command);
    try testing.expect(options.fail_fast);
    try testing.expectEqualStrings("staging", options.environment.?);
    try testing.expectEqual(2, options.paths.len);
    try testing.expectEqualStrings("a.ztest", options.paths[1]);
}

test "run mistakes are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad_arg: []const u8 = "";

    try testing.expectError(error.MissingArgument, parse(arena.allocator(), &.{"run"}, &bad_arg));
    try testing.expectEqualStrings("a file or directory", bad_arg);
    try testing.expectError(error.UnknownArgument, parse(arena.allocator(), &.{ "run", "a", "--nope" }, &bad_arg));
    try testing.expectEqualStrings("--nope", bad_arg);
    try testing.expectError(error.MissingValue, parse(arena.allocator(), &.{ "run", "a", "--env" }, &bad_arg));
    try testing.expectEqualStrings("--env", bad_arg);
}

test "api mistakes are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var bad_arg: []const u8 = "";

    try testing.expectError(error.MissingArgument, parse(allocator, &.{"api"}, &bad_arg));
    try testing.expectEqualStrings("a method", bad_arg);
    try testing.expectError(error.MissingArgument, parse(allocator, &.{ "api", "GET" }, &bad_arg));
    try testing.expectEqualStrings("a URL", bad_arg);

    try testing.expectError(error.InvalidValue, parse(allocator, &.{ "api", "FETCH", "u" }, &bad_arg));
    try testing.expectEqualStrings("FETCH", bad_arg);
    try testing.expectError(error.MissingValue, parse(allocator, &.{ "api", "GET", "u", "--json" }, &bad_arg));
    try testing.expectError(error.UnknownArgument, parse(allocator, &.{ "api", "GET", "u", "--nope", "x" }, &bad_arg));
    try testing.expectError(error.UnknownArgument, parse(allocator, &.{ "api", "GET", "u", "extra" }, &bad_arg));
    try testing.expectError(error.InvalidValue, parse(allocator, &.{ "api", "GET", "u", "--timeout", "soon" }, &bad_arg));
    try testing.expectError(
        error.ConflictingFlags,
        parse(allocator, &.{ "api", "POST", "u", "--json", "{}", "--body", "x" }, &bad_arg),
    );
}
