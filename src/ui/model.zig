//! Everything the pages show that is not layout state: the request session,
//! workspace, suites, load test and history. Owned by `main.zig`, read by the
//! screens through `Ui.m`.

const std = @import("std");
const Io = std.Io;
const Session = @import("api_request.zig").Session;
const Workspace = @import("workspace.zig").Workspace;
const suite_run = @import("suite_run.zig");
const LoadRun = @import("load_run.zig").LoadRun;
const History = @import("../core/history.zig").History;
const ast = @import("../core/parser/ast.zig");
const parser = @import("../core/parser/parser.zig");

/// A text area's visible lines, for painting line numbers beside it.
pub const Gutter = struct {
    first: usize = 0,
    /// Each visible line's top, in logical pixels from the editor's top.
    tops: [64]f32 = undefined,
    count: usize = 0,
};

pub const Model = struct {
    io: Io,
    api: Session,
    workspace: Workspace,
    catalog: suite_run.Catalog,
    suites: suite_run.SuiteRun,
    load: LoadRun,
    history: History,
    /// Unix seconds, refreshed before each frame.
    now: i64 = 0,
    /// The Tests editor's text, kept in step for the Assertions panel.
    tests_text: std.ArrayList(u8) = .empty,
    /// Edits since the last open or save.
    dirty: bool = false,
    saved_unix: ?i64 = null,
    response_unix: i64 = 0,
    /// Secret rows the user chose to show, by row index.
    revealed: u64 = 0,
    /// Pretty JSON, or the body as it came.
    pretty: bool = true,
    response_expanded: bool = false,
    body_gutter: Gutter = .{},
    response_gutter: Gutter = .{},
    /// Variable rows to list: 0 all, 1 environment, 2 file, 3 secrets.
    variable_filter: u8 = 0,
    /// A short note shown for a moment, such as "Copied".
    toast: []const u8 = "",
    toast_until: i64 = 0,
    gpa: std.mem.Allocator,
    /// ZTest's own CPU percent and memory, sampled with each load sample.
    cpu: std.ArrayList(f32) = .empty,
    memory_mb: std.ArrayList(f32) = .empty,
    /// Text of the search fields, kept by the window.
    search_buffer: [256]u8 = undefined,
    search_text: []const u8 = "",
    suite_search_buffer: [256]u8 = undefined,
    suite_search_text: []const u8 = "",
    /// Test Suites: stop at the first failure.
    fail_fast: bool = false,
    /// The selected suite, parsed for its Test Cases and Configuration tabs.
    selected_arena: ?std.heap.ArenaAllocator = null,
    selected_path: []const u8 = "",
    selected_suite: ?ast.Suite = null,
    /// Reports exported this session.
    artifacts: std.ArrayList([]const u8) = .empty,
    artifact_arena: ?std.heap.ArenaAllocator = null,
    /// Dashboard: Recent Test Runs of one suite, or all when empty.
    runs_suite_buffer: [128]u8 = undefined,
    runs_suite: []const u8 = "",
    /// Run All: suites left to run after the current one, and in total.
    run_all_left: usize = 0,
    run_all_total: usize = 0,
    /// The native field with the keyboard focus, if any.
    focused_field: ?@import("fields.zig").Id = null,
    /// Text a copy button asked for, copied by the window.
    copy_request: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) Model {
        return .{
            .gpa = gpa,
            .io = io,
            .api = .init(gpa, io),
            .workspace = .init(gpa, io, environ),
            .catalog = .init(gpa),
            .suites = .init(gpa, io),
            .load = .init(gpa, io),
            .history = .init(gpa),
        };
    }

    pub fn deinit(m: *Model) void {
        m.api.deinit();
        m.suites.deinit();
        m.load.deinit();
        m.catalog.deinit();
        m.history.deinit();
        m.workspace.deinit();
        m.tests_text.deinit(m.gpa);
        m.cpu.deinit(m.gpa);
        m.memory_mb.deinit(m.gpa);
        m.artifacts.deinit(m.gpa);
        if (m.artifact_arena) |*a| a.deinit();
        if (m.selected_arena) |*a| a.deinit();
    }

    /// Parses the suite at catalog `index`, when it changed.
    pub fn selectSuite(m: *Model, index: usize) void {
        if (index >= m.catalog.suites.len) return;
        const suite = m.catalog.suites[index];
        if (m.selected_suite != null and std.mem.eql(u8, m.selected_path, suite.path)) return;
        if (m.selected_arena) |*a| a.deinit();
        m.selected_arena = .init(m.gpa);
        const arena = m.selected_arena.?.allocator();
        m.selected_suite = null;
        m.selected_path = arena.dupe(u8, suite.path) catch "";
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = m.catalog.fullPath(&buffer, suite) catch return;
        const source = Io.Dir.cwd().readFileAlloc(m.io, path, arena, .limited(16 * 1024 * 1024)) catch return;
        var diagnostic: parser.Diagnostic = .{};
        m.selected_suite = parser.parse(arena, source, &diagnostic) catch null;
    }

    pub fn addArtifact(m: *Model, path: []const u8) void {
        if (m.artifact_arena == null) m.artifact_arena = .init(m.gpa);
        const owned = m.artifact_arena.?.allocator().dupe(u8, path) catch return;
        m.artifacts.append(m.gpa, owned) catch {};
    }

    /// Rereads the suites and history under the workspace's folder.
    pub fn refresh(m: *Model) void {
        m.catalog.scan(m.io, m.workspace.root) catch {};
        m.selected_suite = null;
        var dir = Io.Dir.cwd().openDir(m.io, m.workspace.root, .{}) catch return;
        defer dir.close(m.io);
        m.history.load(m.io, dir) catch {};
    }

    pub fn record(m: *Model, entries: []const @import("../core/history.zig").Entry) void {
        var dir = Io.Dir.cwd().openDir(m.io, m.workspace.root, .{}) catch return;
        defer dir.close(m.io);
        m.history.append(m.io, dir, entries) catch {};
    }

    pub fn setTests(m: *Model, text: []const u8) void {
        m.tests_text.clearRetainingCapacity();
        m.tests_text.appendSlice(m.gpa, text) catch {};
    }

    pub fn notify(m: *Model, text: []const u8) void {
        m.toast = text;
        m.toast_until = m.now + 2;
    }
};
