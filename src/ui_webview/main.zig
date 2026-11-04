//! Binds a bundled HTML editor to the desktop request session and workspace.

const std = @import("std");
const api = @import("../ui/api_request.zig");
const Workspace = @import("../ui/workspace.zig").Workspace;
const Webview = *opaque {};
extern fn webview_create(debug: c_int, parent: ?*anyopaque) ?Webview;
extern fn webview_destroy(view: Webview) c_int;
extern fn webview_run(view: Webview) c_int;
extern fn webview_set_title(view: Webview, title: [*:0]const u8) c_int;
extern fn webview_set_size(view: Webview, width: c_int, height: c_int, hint: c_int) c_int;
extern fn webview_set_html(view: Webview, html: [*:0]const u8) c_int;
extern fn webview_bind(view: Webview, name: [*:0]const u8, callback: *const fn ([*:0]const u8, [*:0]const u8, *anyopaque) callconv(.c) void, context: *anyopaque) c_int;
extern fn webview_return(view: Webview, id: [*:0]const u8, status: c_int, json: [*:0]const u8) c_int;

const max_url_bytes = 16 * 1024;
const max_message_bytes = 6 * (api.draft.max_body_size + max_url_bytes) + 1024;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.ExpectedOneSuitePath;
    var workspace: Workspace = .init(init.gpa, init.io, init.environ_map);
    defer workspace.deinit();
    const initial = if (args.len == 2) try workspace.open(args[1]) else blank: {
        workspace.loadConfig(".");
        break :blank api.draft.Draft{ .url = "" };
    };
    if (initial.url.len > max_url_bytes or initial.body.len > api.draft.max_body_size) {
        return error.RequestExceedsEditorLimit;
    }

    const view = webview_create(0, null) orelse return error.WebviewUnavailable;
    defer _ = webview_destroy(view);
    var editor: Editor = .{
        .view = view,
        .workspace = &workspace,
        .session = .init(init.gpa, init.io),
        .initial = initial,
    };
    defer editor.session.deinit();
    try check(webview_set_title(view, "ZTest | system webview prototype"));
    try check(webview_set_size(view, 1100, 760, 0));
    try check(webview_bind(view, "ztest", Editor.onMessage, &editor));
    try check(webview_set_html(view, @embedFile("editor.html")));
    try check(webview_run(view));
}

fn check(code: c_int) !void {
    if (code < 0) return error.WebviewOperationFailed;
}

const Message = struct {
    action: enum { init, send, poll, cancel, cycle_environment },
    method: std.http.Method = .GET,
    url: []const u8 = "",
    mode: api.draft.BodyKind = .none,
    body: []const u8 = "",
};

const Editor = struct {
    view: Webview,
    workspace: *Workspace,
    session: api.Session,
    initial: api.draft.Draft,

    fn onMessage(id: [*:0]const u8, json: [*:0]const u8, context: *anyopaque) callconv(.c) void {
        const editor: *Editor = @ptrCast(@alignCast(context));
        editor.handle(id, std.mem.span(json)) catch {
            _ = webview_return(editor.view, id, 1, "\"Could not process the editor request\"");
        };
    }

    fn handle(editor: *Editor, id: [*:0]const u8, json: []const u8) !void {
        if (json.len > max_message_bytes) return error.RequestExceedsEditorLimit;
        var scratch: std.heap.ArenaAllocator = .init(editor.session.gpa);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        const args = try std.json.parseFromSliceLeaky([]const Message, allocator, json, .{});
        if (args.len != 1) return error.ExpectedOneMessage;
        const message = args[0];
        switch (message.action) {
            .init => return editor.reply(allocator, id, .{
                .title = editor.workspace.title(),
                .environment = editor.workspace.environmentName(),
                .method = @tagName(editor.initial.method),
                .url = editor.initial.url,
                .mode = @tagName(editor.initial.body_kind),
                .body = editor.initial.body,
            }),
            .cycle_environment => {
                editor.workspace.cycleEnvironment();
                return editor.reply(allocator, id, editor.workspace.environmentName());
            },
            .send => {
                if (message.url.len > max_url_bytes or message.body.len > api.draft.max_body_size) {
                    return editor.reply(allocator, id, .{ .busy = false, .message = "Request exceeds the editor limit" });
                }
                var source = editor.initial;
                source.method = message.method;
                source.url = message.url;
                source.body_kind = message.mode;
                source.body = message.body;
                var detail: []const u8 = "";
                source.variables = editor.workspace.variables(allocator, &detail) catch {
                    return editor.reply(allocator, id, .{ .busy = false, .message = "Could not resolve workspace variables" });
                };
                editor.session.startDraft(source, 30_000) catch {};
            },
            .cancel => editor.session.cancel(),
            .poll => _ = editor.session.poll(),
        }
        const session = &editor.session;
        const response = if (session.phase == .completed) session.response else null;
        try editor.reply(allocator, id, .{
            .busy = session.busy(),
            .message = session.message(),
            .status = if (response) |value| value.status else null,
            .assertions = session.assertionCounts(),
            .response = if (response != null) try session.preview(allocator, .body) else "",
        });
    }

    fn reply(editor: *const Editor, allocator: std.mem.Allocator, id: [*:0]const u8, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        try check(webview_return(editor.view, id, 0, try allocator.dupeSentinel(u8, json, 0)));
    }
};
