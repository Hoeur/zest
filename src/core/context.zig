//! What a command needs from the application, passed explicitly.

const std = @import("std");
const Config = @import("config.zig").Config;
const Logger = @import("log.zig").Logger;

pub const Context = struct {
    /// Freed when the process exits, so commands need not free from it.
    arena: std.mem.Allocator,
    io: std.Io,
    log: *Logger,
    config: Config,
};
