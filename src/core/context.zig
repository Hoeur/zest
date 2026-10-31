//! What a command needs from the application, passed explicitly.

const std = @import("std");
const Config = @import("config.zig").Config;
const Logger = @import("log.zig").Logger;

pub const Context = struct {
    /// For long-lived state that frees its own memory.
    gpa: std.mem.Allocator,
    /// Freed when the process exits, so commands need not free from it.
    arena: std.mem.Allocator,
    io: std.Io,
    log: *Logger,
    config: Config,
    /// The process environment, which `{"env": "NAME"}` values read from.
    environ: *const std.process.Environ.Map,
};
