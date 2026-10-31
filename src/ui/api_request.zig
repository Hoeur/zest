//! One background request for the desktop. Drawing and Win32 stay elsewhere.

const std = @import("std");
const Io = std.Io;
const http = @import("../core/http/client.zig");
const model = @import("../core/http/request.zig");
const Response = @import("../core/http/response.zig").Response;

pub const methods = [_]model.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS };
pub const Phase = enum { idle, running, canceling, completed, failed, canceled };
pub const View = enum { body, headers };
pub const preview_limit = 64 * 1024;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: http.Client,
    phase: Phase = .idle,
    // Only the worker writes these while pending. poll acquires done before reading.
    response: ?Response = null,
    failure: ?http.Error = null,
    arena: ?std.heap.ArenaAllocator = null,
    request: model.Request = .{ .url = "" },
    future: ?Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    canceled: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: Io) Session {
        return .{ .gpa = gpa, .io = io, .client = .init(gpa, io) };
    }

    /// Joins the worker before releasing its request, response, or client.
    pub fn deinit(s: *Session) void {
        s.cancel();
        if (s.future) |*future| future.await(s.io);
        if (s.arena) |*arena| arena.deinit();
        s.client.deinit();
    }

    pub fn busy(s: *const Session) bool {
        return s.future != null;
    }

    /// Snapshots the draft: input edits cannot race with the worker. Keep this
    /// Session at a stable address until deinit, and call start/poll on one thread.
    pub fn start(s: *Session, method: model.Method, url: []const u8, timeout_ms: u64) !void {
        if (s.busy()) return error.Busy;
        // Manual requests may be minutes apart. Start a new pool rather than
        // reusing an idle socket the server has closed, or retrying a POST.
        s.client.deinit();
        s.client = .init(s.gpa, s.io);
        s.response = null;
        s.failure = null;
        s.phase = .idle;
        if (s.arena) |*arena| arena.deinit();
        s.arena = .init(s.gpa);
        errdefer s.phase = .failed;
        s.request = .{
            .method = method,
            .url = try s.arena.?.allocator().dupe(u8, std.mem.trim(u8, url, " \r\n\t")),
            .timeout_ms = timeout_ms,
            .max_response_size = 4 * 1024 * 1024,
        };
        s.done.store(false, .release);
        s.canceled.store(false, .release);
        s.future = try s.io.concurrent(work, .{s});
        s.phase = .running;
    }

    /// Nonblocking: the worker observes the flag within its HTTP polling loop.
    pub fn cancel(s: *Session) void {
        if (!s.busy()) return;
        s.canceled.store(true, .release);
        s.phase = .canceling;
    }

    /// Publishes results on the UI thread once the worker has finished.
    pub fn poll(s: *Session) bool {
        if (!s.busy() or !s.done.load(.acquire)) return false;
        s.future.?.await(s.io);
        s.future = null;
        if (s.canceled.load(.acquire)) {
            s.response = null;
            s.phase = .canceled;
        } else {
            s.phase = if (s.failure != null) .failed else .completed;
        }
        return true;
    }

    fn work(s: *Session) void {
        defer s.done.store(true, .release);
        s.response = s.client.sendCancelable(s.arena.?.allocator(), s.request, &s.canceled) catch |err| {
            s.failure = err;
            return;
        };
    }

    pub fn message(s: *const Session) []const u8 {
        return switch (s.phase) {
            .idle => "Enter a URL and send a request.",
            .running => "Sending request...",
            .canceling => "Canceling request...",
            .completed => "Response received",
            .canceled => "Request canceled",
            .failed => if (s.failure) |err| http.describe(err) else "Could not start the request",
        };
    }

    /// The caller owns the preview. Bound text passed to the native edit control,
    /// normalize newlines, and replace embedded control characters safely.
    pub fn preview(s: *const Session, allocator: std.mem.Allocator, view: View) ![]const u8 {
        if (s.phase != .completed) return allocator.dupe(u8, s.message());
        const response = s.response.?;
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        switch (view) {
            .body => {
                if (response.body.len == 0) return allocator.dupe(u8, "(empty response body)");
                try writePreview(&out.writer, response.body);
            },
            .headers => {
                for (response.headers) |header| {
                    if (out.written().len >= preview_limit) {
                        try out.writer.writeAll("\r\n[Preview truncated]\r\n");
                        break;
                    }
                    try writePreview(&out.writer, header.name);
                    try out.writer.writeAll(": ");
                    try writePreview(&out.writer, header.value);
                    try out.writer.writeAll("\r\n");
                }
            },
        }
        return allocator.dupe(u8, out.written());
    }
};

fn writePreview(out: *Io.Writer, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        try out.writeAll("[Binary or invalid UTF-8 content]");
        return;
    }
    var end = @min(text.len, preview_limit);
    // Do not cut a multibyte character at the preview boundary.
    while (end < text.len and end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    for (text[0..end], 0..) |byte, i| {
        if (byte == '\n') {
            if (i == 0 or text[i - 1] != '\r') try out.writeByte('\r');
            try out.writeByte('\n');
        } else {
            try out.writeByte(if ((byte < 32 and byte != '\r' and byte != '\t') or byte == 127) '?' else byte);
        }
    }
    if (end < text.len) try out.writeAll("\r\n[Preview truncated at 64 KiB]\r\n");
}
