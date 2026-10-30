//! `ztest` command-line entry point.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("cli.zig");
const config = @import("core/config.zig");
const Context = @import("core/context.zig").Context;
const ExitCode = @import("core/errors.zig").ExitCode;
const Logger = @import("core/log.zig").Logger;

test {
    _ = cli;
    _ = config;
    _ = @import("core/log.zig");
}

pub fn main(init: std.process.Init) void {
    const stderr = Io.File.stderr();
    var buffer: [1024]u8 = undefined;
    var writer = stderr.writerStreaming(init.io, &buffer);
    var log: Logger = .{ .out = &writer.interface, .color = wantsColor(init, stderr) };

    const code = run(init, &log) catch |err| blk: {
        log.err("internal error: {s}", .{@errorName(err)});
        break :blk ExitCode.internal_error;
    };
    std.process.exit(@intFromEnum(code));
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
    const options = cli.parse(args[1..], &bad_arg) catch |err| {
        switch (err) {
            error.UnknownArgument => log.err("unknown argument '{s}'", .{bad_arg}),
            error.ConflictingFlags => log.err("'{s}' conflicts with an earlier flag", .{bad_arg}),
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

    const context: Context = .{ .arena = arena, .io = init.io, .log = log, .config = settings };
    return execute(context, options.command);
}

fn execute(context: Context, command: cli.Command) !ExitCode {
    var buffer: [1024]u8 = undefined;
    // Streaming, because a positional writer overwrites a redirected file.
    var writer = Io.File.stdout().writerStreaming(context.io, &buffer);
    const out = &writer.interface;

    context.log.debug("running command '{s}'", .{@tagName(command)});
    switch (command) {
        .help => try out.writeAll(cli.help),
        .version => try out.print("ztest {s}\n", .{build_options.version}),
    }
    try out.flush();
    return .success;
}
