//! Command-line parsing. Holds no I/O so every case can be unit tested.

const std = @import("std");
const Level = @import("core/log.zig").Level;

pub const help =
    \\Usage: ztest [options]
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  -v, --verbose    Show debug messages
    \\  -q, --quiet      Only show errors
    \\      --no-color   Disable colored output
    \\
;

pub const Command = enum { help, version };

pub const Options = struct {
    command: Command = .help,
    /// Null when no flag was given, leaving the config value in charge.
    level: ?Level = null,
    no_color: bool = false,
};

pub const ParseError = error{ UnknownArgument, ConflictingFlags };

/// `args` excludes the program name. On error, `bad_arg` names the cause.
pub fn parse(args: []const [:0]const u8, bad_arg: *[]const u8) ParseError!Options {
    var options: Options = .{};
    for (args) |arg| {
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
        } else {
            bad_arg.* = arg;
            return error.UnknownArgument;
        }
    }
    return options;
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

const testing = std.testing;

fn parseArgs(args: []const [:0]const u8) ParseError!Options {
    var bad_arg: []const u8 = "";
    return parse(args, &bad_arg);
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
    try testing.expectError(error.UnknownArgument, parse(&.{"--nope"}, &bad_arg));
    try testing.expectEqualStrings("--nope", bad_arg);

    try testing.expectError(error.ConflictingFlags, parse(&.{ "-v", "-q" }, &bad_arg));
    try testing.expectEqualStrings("-q", bad_arg);
}
