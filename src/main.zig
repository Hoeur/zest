//! `ztest` command-line entry point.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("cli.zig");
const api = @import("commands/api.zig");
const run_command = @import("commands/run.zig");
const config = @import("core/config.zig");
const Context = @import("core/context.zig").Context;
const ExitCode = @import("core/errors.zig").ExitCode;
const Logger = @import("core/log.zig").Logger;
const shutdown = @import("core/shutdown.zig");

test {
    _ = @import("ui/api_request_test.zig");
    _ = cli;
    _ = api;
    _ = run_command;
    _ = config;
    _ = @import("core/environment.zig");
    _ = @import("core/log.zig");
    _ = @import("core/redact.zig");
    _ = @import("core/assertions/assertion.zig");
    _ = @import("core/assertions/evaluate.zig");
    _ = @import("core/parser/lexer.zig");
    _ = @import("core/parser/parser.zig");
    _ = @import("core/runner/variables.zig");
    _ = @import("core/runner/runner_test.zig");
    _ = @import("core/http/request.zig");
    _ = @import("core/http/response.zig");
    _ = @import("core/http/client_test.zig");
}

pub fn main(init: std.process.Init) void {
    const stderr = Io.File.stderr();
    var buffer: [1024]u8 = undefined;
    var writer = stderr.writerStreaming(init.io, &buffer);
    var log: Logger = .{ .out = &writer.interface, .color = wantsColor(init, stderr) };

    shutdown.install();
    const code = run(init, &log) catch |err| blk: {
        log.err("internal error: {s}", .{@errorName(err)});
        break :blk ExitCode.internal_error;
    };
    std.process.exit(@backingInt(code));
}

fn wantsColor(init: std.process.Init, file: Io.File) bool {
    if (init.environ_map.get("NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    const supported = file.supportsAnsiEscapeCodes(init.io) catch return false;
    if (!supported) return false;
    file.enableAnsiEscapeCodes(init.io) catch return false;
    return true;
}

fn run(init: std.process.Init, log: *Logger) !ExitCode {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var bad_arg: []const u8 = "";
    const options = cli.parse(arena, args[1..], &bad_arg) catch |err| {
        switch (err) {
            error.OutOfMemory => |e| return e,
            error.UnknownArgument => log.err("unknown argument '{s}'", .{bad_arg}),
            error.ConflictingFlags => log.err("'{s}' conflicts with an earlier flag", .{bad_arg}),
            error.MissingValue => log.err("'{s}' needs a value", .{bad_arg}),
            error.InvalidValue => log.err("invalid value '{s}'", .{bad_arg}),
            error.MissingArgument => log.err("{s} is required", .{bad_arg}),
            error.InvalidAssertion => log.err("invalid assertion {s}", .{bad_arg}),
        }
        log.info("Run 'ztest --help' for usage.", .{});
        return .config_error;
    };

    const settings = config.load(arena, init.io, Io.Dir.cwd()) catch |err| {
        log.err("cannot load {s}: {s}", .{ config.file_name, @errorName(err) });
        return .config_error;
    };
    log.level = options.level orelse settings.log_level;
    log.color = log.color and settings.color and !options.no_color;

    const context: Context = .{ .gpa = init.gpa, .arena = arena, .io = init.io, .log = log, .config = settings, .environ = init.environ_map };
    return execute(context, options);
}

fn execute(context: Context, options: cli.Options) !ExitCode {
    var buffer: [1024]u8 = undefined;
    // Streaming, because a positional writer overwrites a redirected file.
    var writer = Io.File.stdout().writerStreaming(context.io, &buffer);
    const out = &writer.interface;

    context.log.debug("running command '{s}'", .{@tagName(options.command)});
    const code: ExitCode = switch (options.command) {
        .help => help: {
            try out.writeAll(cli.help);
            break :help .success;
        },
        .version => version: {
            try out.print("ztest {s}\n", .{build_options.version});
            break :version .success;
        },
        .api => try api.run(context, out, options.request.?, options.assertions, options.raw),
        .run => try run_command.run(context, out, options.paths, options.environment, .{ .fail_fast = options.fail_fast }),
    };
    try out.flush();
    return code;
}
