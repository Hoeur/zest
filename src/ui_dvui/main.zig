//! Minimal request editor for evaluating dvui on desktop.

const std = @import("std");
const dvui = @import("dvui");
const SDL = @import("sdl3");
const api = @import("../ui/api_request.zig");
const Workspace = @import("../ui/workspace.zig").Workspace;

const max_url_bytes = 16 * 1024;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.ExpectedOneSuitePath;
    const measure_startup = init.environ_map.get("ZTEST_SPIKE_TIMING") != null;
    const scale_override = if (init.environ_map.get("ZTEST_SPIKE_SCALE")) |value|
        try parseScale(value)
    else
        null;

    var workspace = Workspace.init(init.gpa, init.io, init.environ_map);
    defer workspace.deinit();
    const initial = if (args.len == 2) try workspace.open(args[1]) else blank: {
        workspace.loadConfig(".");
        break :blank api.draft.Draft{ .url = "" };
    };
    if (initial.url.len > max_url_bytes or initial.body.len > api.draft.max_body_size) {
        return error.RequestExceedsEditorLimit;
    }

    var session = api.Session.init(init.gpa, init.io);
    defer session.deinit();
    const arena = init.arena.allocator();
    const url_buffer = try arena.alloc(u8, max_url_bytes);
    const body_buffer = try arena.alloc(u8, api.draft.max_body_size);
    url_buffer[0] = 0;
    body_buffer[0] = 0;
    var editor = Editor{
        .initial = initial,
        .method = initial.method,
        .body_kind = initial.body_kind,
        .url_buffer = url_buffer,
        .body_buffer = body_buffer,
    };

    var backend = try SDL.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 1100, .h = 760 },
        .min_size = .{ .w = 680, .h = 520 },
        .vsync = true,
        .org = "ZTest",
        .app = "ZTest dvui spike",
        .title = "ZTest | dvui prototype",
        .persist_window_geometry = false,
    });
    defer backend.deinit();

    var open = true;
    var window = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
        .open_flag = &open,
    });
    defer window.deinit();
    if (scale_override) |scale| window.content_scale = scale / backend.contentScale();

    var interrupted = false;
    while (open) {
        try window.begin(window.beginWait(interrupted));
        try backend.addAllEvents(&window);
        _ = session.poll();
        editor.draw(&workspace, &session);
        const end_us = try window.end(.{});
        if (measure_startup) {
            std.log.info("first frame presented", .{});
            break;
        }
        if (!open) break;
        const wait_us = window.waitTime(end_us);
        interrupted = try backend.waitEventTimeout(if (session.busy()) @min(wait_us, 16_000) else wait_us);
    }
}

fn parseScale(value: []const u8) !f32 {
    const percent = try std.fmt.parseInt(u16, value, 10);
    if (percent < 100 or percent > 200) return error.InvalidPrototypeScale;
    return @as(f32, @floatFromInt(percent)) / 100;
}

const Editor = struct {
    initial: api.draft.Draft,
    method: @FieldType(api.draft.Draft, "method"),
    body_kind: api.draft.BodyKind,
    url_buffer: []u8,
    body_buffer: []u8,
    problem: []const u8 = "",

    fn draw(editor: *Editor, workspace: *Workspace, session: *api.Session) void {
        var frame = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .style = .window,
            .background = true,
        });
        defer frame.deinit();
        sidebar();

        var panel = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(12) });
        defer panel.deinit();
        dvui.label(@src(), "{s}", .{workspace.title()}, .{ .font = .theme(.title) });
        if (dvui.button(@src(), workspace.environmentName(), .{}, .{})) {
            workspace.cycleEnvironment();
        }

        var source = editor.initial;
        const submit = editor.requestLine(&source, session.busy());
        dvui.label(@src(), "Request body", .{}, .{});
        _ = dvui.dropdownEnum(@src(), api.draft.BodyKind, .{ .choice = &editor.body_kind }, .{}, .{});
        source.body_kind = editor.body_kind;
        const body_height = std.math.clamp(dvui.windowRect().h * 0.35, 80, 220);
        source.body = edit(@src(), editor.initial.body, "Request body", editor.body_buffer, body_height);
        if (submit) {
            if (session.busy()) session.cancel() else editor.send(workspace, session, source);
        }

        dvui.label(@src(), "{s}", .{if (editor.problem.len > 0) editor.problem else session.message()}, .{});
        if (editor.problem.len == 0 and session.phase == .completed) {
            dvui.label(@src(), "HTTP {d}", .{session.response.?.status}, .{});
            if (session.assertionCounts()) |counts| {
                dvui.label(@src(), "Assertions: {d} passed, {d} failed", .{ counts.passed, counts.failed }, .{});
            }
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();
            const preview = session.preview(dvui.currentWindow().arena(), .body) catch "Could not render response";
            var layout = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer layout.deinit();
            layout.addText(preview, .{});
        }
    }

    fn requestLine(editor: *Editor, source: *api.draft.Draft, busy: bool) bool {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.dropdownEnum(@src(), @TypeOf(editor.method), .{ .choice = &editor.method }, .{}, .{});
        source.method = editor.method;
        source.url = edit(@src(), editor.initial.url, "Request URL", editor.url_buffer, null);
        return dvui.button(@src(), if (busy) "Cancel" else "Send", .{}, .{});
    }

    fn send(editor: *Editor, workspace: *Workspace, session: *api.Session, draft: api.draft.Draft) void {
        editor.problem = "";
        var source = draft;
        var detail: []const u8 = "";
        source.variables = workspace.variables(dvui.currentWindow().arena(), &detail) catch {
            editor.problem = "Could not resolve workspace variables";
            return;
        };
        session.startDraft(source, 30_000) catch {};
    }
};

fn sidebar() void {
    var nav = dvui.box(@src(), .{}, .{
        .expand = .vertical,
        .min_size_content = .{ .w = 145 },
        .style = .content,
        .background = true,
        .padding = .all(12),
    });
    defer nav.deinit();
    dvui.label(@src(), "ZTest", .{}, .{ .font = .theme(.title) });
    dvui.label(@src(), "API Tests", .{}, .{ .font = .theme(.heading) });
    dvui.label(@src(), "Desktop prototype", .{}, .{});
}

/// Use stable storage across frames, including after a select-all deletion.
fn edit(src: std.builtin.SourceLocation, initial: []const u8, placeholder: []const u8, buffer: []u8, height: ?f32) []const u8 {
    var entry = dvui.textEntry(src, .{
        .text = .{ .buffer = buffer },
        .text_initial = initial,
        .placeholder = placeholder,
        .multiline = height != null,
    }, .{
        .expand = .horizontal,
        .min_size_content = if (height) |h| .{ .h = h } else null,
        .max_size_content = if (height) |h| .height(h) else null,
    });
    defer entry.deinit();
    return entry.textGet();
}
