//! One background request for the desktop. Drawing and Win32 stay elsewhere.

const std = @import("std");
const Io = std.Io;
const http = @import("../core/http/client.zig");
const model = @import("../core/http/request.zig");
const Response = @import("../core/http/response.zig").Response;
const Assertion = @import("../core/assertions/assertion.zig").Assertion;
pub const evaluate = @import("../core/assertions/evaluate.zig");
const redact = @import("../core/redact.zig").redact;
pub const draft = @import("../core/http/draft.zig");

pub const methods = [_]model.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS };
pub const Phase = enum { idle, running, canceling, completed, failed, canceled };
pub const View = enum { body, headers, cookies, raw };
pub const preview_limit = 64 * 1024;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: http.Client,
    phase: Phase = .idle,
    // Only the worker writes these while pending. poll acquires done before reading.
    response: ?Response = null,
    failure: ?http.Error = null,
    input_message: ?[]const u8 = null,
    arena: ?std.heap.ArenaAllocator = null,
    request: model.Request = .{ .url = "" },
    assertions: []const Assertion = &.{},
    /// Checked by the worker against the response. Empty without assertions.
    results: []const evaluate.Result = &.{},
    /// Hidden in previews, messages and assertion results.
    secrets: []const []const u8 = &.{},
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
        return s.startDraft(.{ .method = method, .url = url }, timeout_ms);
    }

    /// Validates and owns all editor text before a worker can send anything.
    pub fn startDraft(s: *Session, source: draft.Draft, timeout_ms: u64) !void {
        if (s.busy()) return error.Busy;
        // Manual requests may be minutes apart. Start a new pool rather than
        // reusing an idle socket the server has closed, or retrying a POST.
        s.client.deinit();
        s.client = .init(s.gpa, s.io);
        s.response = null;
        s.failure = null;
        s.input_message = null;
        s.results = &.{};
        s.assertions = &.{};
        s.secrets = &.{};
        s.phase = .idle;
        if (s.arena) |*arena| arena.deinit();
        s.arena = .init(s.gpa);
        errdefer s.phase = .failed;
        const allocator = s.arena.?.allocator();
        var diagnostic: draft.Diagnostic = .{};
        const prepared = draft.prepareAll(allocator, source, &diagnostic) catch |err| {
            s.input_message = draft.message(allocator, err, diagnostic) catch draft.describe(err);
            return err;
        };
        s.request = prepared.request;
        s.assertions = prepared.assertions;
        s.secrets = prepared.secrets;
        s.request.timeout_ms = timeout_ms;
        s.request.max_response_size = 4 * 1024 * 1024;
        s.done.store(false, .release);
        s.canceled.store(false, .release);
        s.future = s.io.concurrent(work, .{s}) catch |err| {
            s.failure = if (err == error.OutOfMemory) error.OutOfMemory else error.RequestFailed;
            return err;
        };
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
        const allocator = s.arena.?.allocator();
        const response = s.client.sendCancelable(allocator, s.request, &s.canceled) catch |err| {
            s.failure = err;
            return;
        };
        if (s.assertions.len > 0) {
            s.results = evaluate.evaluate(allocator, response, s.assertions, s.secrets) catch &.{};
        }
        s.response = response;
    }

    /// Counts for the Assertions panel, or null before a response.
    pub fn assertionCounts(s: *const Session) ?struct { passed: usize, failed: usize } {
        if (s.phase != .completed or s.results.len == 0) return null;
        const failed = evaluate.countFailed(s.results);
        return .{ .passed = s.results.len - failed, .failed = failed };
    }

    pub fn message(s: *const Session) []const u8 {
        return switch (s.phase) {
            .idle => "Enter a URL and send a request.",
            .running => "Sending request...",
            .canceling => "Canceling request...",
            .completed => "Response received",
            .canceled => "Request canceled",
            .failed => s.input_message orelse if (s.failure) |err| http.describe(err) else "Could not start the request",
        };
    }

    /// The caller owns the preview. Bound text passed to the native edit control,
    /// normalize newlines, and replace embedded control characters safely.
    pub fn preview(s: *const Session, allocator: std.mem.Allocator, view: View) ![]const u8 {
        return s.previewFormatted(allocator, view, false);
    }

    /// `pretty` indents a JSON body; other views and other bodies are as
    /// they came.
    pub fn previewFormatted(s: *const Session, allocator: std.mem.Allocator, view: View, pretty: bool) ![]const u8 {
        // Secrets from the environment can come back in a response, such as
        // an echoed token, so they are hidden from every view.
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        const text = try s.previewText(scratch.allocator(), view, pretty);
        if (s.secrets.len == 0) return allocator.dupe(u8, text);
        return allocator.dupe(u8, try redact(scratch.allocator(), text, s.secrets));
    }

    fn previewText(s: *const Session, allocator: std.mem.Allocator, view: View, pretty: bool) ![]const u8 {
        if (s.phase != .completed) return allocator.dupe(u8, s.message());
        const response = s.response.?;
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        switch (view) {
            .body, .raw => {
                if (view == .raw) {
                    try out.writer.print("HTTP {d} {s}\r\n", .{ response.status, response.status_text });
                    for (response.headers) |header| {
                        if (out.written().len >= preview_limit) break;
                        try writePreview(&out.writer, header.name);
                        try out.writer.writeAll(": ");
                        try writePreview(&out.writer, header.value);
                        try out.writer.writeAll("\r\n");
                    }
                    try out.writer.writeAll("\r\n");
                }
                if (response.body.len == 0 and view == .body) return allocator.dupe(u8, "(empty response body)");
                const body = if (pretty and view == .body) indented(allocator, response.body) orelse response.body else response.body;
                try writePreview(&out.writer, body);
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
            .cookies => {
                if (response.cookies.len == 0) return allocator.dupe(u8, "(no response cookies)");
                for (response.cookies) |cookie| {
                    if (out.written().len >= preview_limit) break;
                    try writePreview(&out.writer, cookie.name);
                    try out.writer.writeAll(" = ");
                    try writePreview(&out.writer, cookie.value);
                    try out.writer.writeAll("\r\n");
                }
            },
        }
        return allocator.dupe(u8, out.written());
    }
};

/// The body indented when it is JSON, with numbers kept exactly. Null when
/// it is not JSON or is too large to bother.
fn indented(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    if (body.len > preview_limit) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{ .parse_numbers = false }) catch return null;
    if (value != .object and value != .array) return null;
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }) catch null;
}

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
