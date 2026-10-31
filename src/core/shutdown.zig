//! Ctrl-C handling. The first press asks running work to stop; the second ends
//! the process, in case that work is stuck.

const std = @import("std");
const builtin = @import("builtin");
const ExitCode = @import("errors.zig").ExitCode;

/// Checked by long-running work. Handlers may only touch this atomic.
var requested: std.atomic.Value(bool) = .init(false);

pub fn isRequested() bool {
    return requested.load(.acquire);
}

fn request() void {
    if (requested.swap(true, .acq_rel)) std.process.exit(@backingInt(ExitCode.interrupted));
}

/// Does nothing on targets without Ctrl-C.
pub fn install() void {
    switch (builtin.os.tag) {
        .windows => _ = SetConsoleCtrlHandler(&onConsoleEvent, 1),
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = onSignal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &action, null);
            std.posix.sigaction(.TERM, &action, null);
        },
        else => {},
    }
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    request();
}

const ctrl_c_event = 0;
const ctrl_break_event = 1;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) i32,
    add: i32,
) callconv(.winapi) i32;

fn onConsoleEvent(event: u32) callconv(.winapi) i32 {
    if (event != ctrl_c_event and event != ctrl_break_event) return 0;
    request();
    return 1;
}
