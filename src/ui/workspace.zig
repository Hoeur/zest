//! What the desktop app works on beside the request itself: the `ztest.json`
//! environments, the chosen environment, and the `.ztest` file being edited.
//! Holds no Win32 code, so it is tested with the CLI tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("../core/config.zig");
const environment = @import("../core/environment.zig");
const ast = @import("../core/parser/ast.zig");
const parser = @import("../core/parser/parser.zig");
const writer = @import("../core/parser/writer.zig");
const draft = @import("../core/http/draft.zig");
const redact = @import("../core/redact.zig");

const max_file_size: Io.Limit = .limited(16 * 1024 * 1024);

/// A variable as the environment panel shows it.
pub const Shown = struct {
    name: []const u8,
    /// `********` for a secret.
    value: []const u8,
    /// `ztest.json`, the environment's name, or the file's name.
    source: []const u8,
    secret: bool = false,
    /// The unmasked value, shown only when the user asks to reveal it.
    raw: []const u8 = "",
    /// Where it comes from: 0 global, 1 environment, 2 file.
    origin: u8 = 0,
};

pub const File = struct {
    path: []const u8,
    suite: ast.Suite,
    /// The test the editor shows, which saving replaces.
    test_index: usize,
};

pub const Workspace = struct {
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    config_arena: std.heap.ArenaAllocator,
    file_arena: std.heap.ArenaAllocator,
    settings: config.Config = .{},
    /// Why `ztest.json` could not be read, shown in place of its variables.
    config_problem: ?[]const u8 = null,
    /// The folder `ztest.json` was read from, or would be. Suites, history and
    /// reports are found relative to it.
    root: []const u8 = ".",
    /// Index into `settings.environments`, or null for global values only.
    selected: ?usize = null,
    file: ?File = null,
    message_buffer: [512]u8 = undefined,
    /// The outcome of the last open or save, for the status line.
    message: []const u8 = "",

    pub fn init(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map) Workspace {
        return .{ .gpa = gpa, .io = io, .environ = environ, .config_arena = .init(gpa), .file_arena = .init(gpa) };
    }

    pub fn deinit(w: *Workspace) void {
        w.config_arena.deinit();
        w.file_arena.deinit();
    }

    /// Reads `ztest.json` from `dir_path`. A missing file means no variables.
    /// The chosen environment is kept when the new file has one of that name.
    pub fn loadConfig(w: *Workspace, dir_path: []const u8) void {
        const previous = if (w.selected) |i| w.settings.environments.items[i].name else null;
        var previous_buffer: [128]u8 = undefined;
        const kept_name: ?[]const u8 = if (previous) |name| (if (name.len <= previous_buffer.len) blk: {
            @memcpy(previous_buffer[0..name.len], name);
            break :blk previous_buffer[0..name.len];
        } else null) else null;

        _ = w.config_arena.reset(.retain_capacity);
        w.settings = .{};
        w.config_problem = null;
        w.selected = null;
        const arena = w.config_arena.allocator();
        w.root = arena.dupe(u8, dir_path) catch ".";
        var dir = Io.Dir.cwd().openDir(w.io, dir_path, .{}) catch |err| {
            w.config_problem = std.fmt.allocPrint(arena, "Cannot open {s}: {s}", .{ dir_path, @errorName(err) }) catch "Cannot open the folder";
            return;
        };
        defer dir.close(w.io);
        w.settings = config.load(arena, w.io, dir) catch |err| {
            w.config_problem = std.fmt.allocPrint(arena, "{s} is not valid: {s}", .{ config.file_name, @errorName(err) }) catch "ztest.json is not valid";
            return;
        };
        if (kept_name) |name| {
            for (w.settings.environments.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.name, name)) w.selected = i;
            }
        }
    }

    /// Loads the `ztest.json` in the file's folder or the nearest parent, as
    /// suites often live in a `tests/` folder beside it. Without one, the
    /// file's own folder is used, which means no environments.
    pub fn loadConfigNear(w: *Workspace, file_path: []const u8) void {
        var dir: ?[]const u8 = std.fs.path.dirname(file_path) orelse ".";
        while (dir) |path| : (dir = std.fs.path.dirname(path)) {
            var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buffer, "{s}{c}{s}", .{ path, std.fs.path.sep, config.file_name }) catch break;
            if (Io.Dir.cwd().access(w.io, candidate, .{})) |_| {
                w.loadConfig(path);
                return;
            } else |_| {}
        }
        w.loadConfig(std.fs.path.dirname(file_path) orelse ".");
    }

    /// The chosen environment's name, or null for global values only.
    pub fn selectedName(w: *const Workspace) ?[]const u8 {
        const i = w.selected orelse return null;
        return w.settings.environments.items[i].name;
    }

    pub fn environmentName(w: *const Workspace) []const u8 {
        const i = w.selected orelse return if (w.settings.environments.items.len == 0) "No environments" else "Global only";
        return w.settings.environments.items[i].name;
    }

    /// Global only, then each environment in file order, then back.
    pub fn cycleEnvironment(w: *Workspace) void {
        const count = w.settings.environments.items.len;
        if (count == 0) {
            w.selected = null;
            return;
        }
        w.selected = if (w.selected) |i| (if (i + 1 < count) i + 1 else null) else 0;
    }

    /// Values for `{{name}}`, lowest priority first: `ztest.json`, the chosen
    /// environment, the open file's suite, then its test. On
    /// `error.InvalidEnvironment`, `problem` says why, such as an unset
    /// `{ "env": ... }` value.
    pub fn variables(w: *const Workspace, arena: Allocator, problem: *[]const u8) environment.Error![]const ast.Variable {
        if (w.config_problem) |text| {
            problem.* = text;
            return error.InvalidEnvironment;
        }
        const name = if (w.selected) |i| w.settings.environments.items[i].name else null;
        const base = try environment.resolve(arena, w.settings, w.environ, name, problem);
        var out: std.ArrayList(ast.Variable) = .empty;
        try out.appendSlice(arena, base);
        if (w.file) |file| {
            try out.appendSlice(arena, file.suite.variables);
            try out.appendSlice(arena, file.suite.tests[file.test_index].variables);
        }
        return out.items;
    }

    /// Every name the panel lists, with secrets hidden. A later definition of
    /// a name replaces the earlier row, as it does when sending.
    pub fn shownVariables(w: *const Workspace, arena: Allocator) Allocator.Error![]const Shown {
        var out: std.ArrayList(Shown) = .empty;
        try addShown(arena, &out, w.settings.variables, config.file_name, w.environ, 0);
        if (w.selected) |i| {
            const env = w.settings.environments.items[i];
            try addShown(arena, &out, env.variables, env.name, w.environ, 1);
        }
        if (w.file) |file| {
            const source = std.fs.path.basename(file.path);
            for ([_][]const ast.Variable{ file.suite.variables, file.suite.tests[file.test_index].variables }) |list| {
                for (list) |variable| try putShown(arena, &out, .{
                    .name = variable.name,
                    .value = if (variable.secret) redact.mask else variable.value,
                    .source = source,
                    .secret = variable.secret,
                    .raw = variable.value,
                    .origin = 2,
                });
            }
        }
        return out.items;
    }

    pub fn title(w: *const Workspace) []const u8 {
        const file = w.file orelse return "Untitled";
        return file.suite.tests[file.test_index].name;
    }

    pub fn fileName(w: *const Workspace) ?[]const u8 {
        const file = w.file orelse return null;
        return std.fs.path.basename(file.path);
    }

    /// Reads a `.ztest` file and returns its first test as a draft, owned by
    /// the workspace until the next open. Also reads the `ztest.json` beside it.
    pub fn open(w: *Workspace, path: []const u8) !draft.Draft {
        var next: std.heap.ArenaAllocator = .init(w.gpa);
        errdefer next.deinit();
        const arena = next.allocator();
        const owned_path = try arena.dupe(u8, path);
        const source = Io.Dir.cwd().readFileAlloc(w.io, owned_path, arena, max_file_size) catch |err| {
            w.setMessage("Cannot open {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return err;
        };
        var diagnostic: parser.Diagnostic = .{};
        const suite = parser.parse(arena, source, &diagnostic) catch |err| {
            if (err == error.SyntaxError) {
                w.setMessage("{s}:{d}: {s}", .{ std.fs.path.basename(path), diagnostic.line, diagnostic.message });
            }
            return err;
        };
        const result = try draft.fromCase(arena, suite.tests[0]);

        w.file_arena.deinit();
        w.file_arena = next;
        w.file = .{ .path = owned_path, .suite = suite, .test_index = 0 };
        w.loadConfigNear(owned_path);
        if (suite.tests.len > 1) {
            w.setMessage("Opened the first of {d} tests in {s}", .{ suite.tests.len, std.fs.path.basename(path) });
        } else {
            w.setMessage("Opened {s}", .{std.fs.path.basename(path)});
        }
        return result;
    }

    /// Opens `path` showing the test called `name`, or the first test.
    pub fn openAt(w: *Workspace, path: []const u8, name: []const u8) !draft.Draft {
        const first = try w.open(path);
        const file = &w.file.?;
        for (file.suite.tests, 0..) |case, i| {
            if (!std.mem.eql(u8, case.name, name)) continue;
            file.test_index = i;
            w.setMessage("Opened {s} from {s}", .{ case.name, std.fs.path.basename(path) });
            return draft.fromCase(w.file_arena.allocator(), case);
        }
        return first;
    }

    /// Writes `source` as the test being edited. Saving over the open file
    /// keeps its other tests, hooks and variables; a new path gets a suite of
    /// its own, named after the file.
    pub fn save(w: *Workspace, path: []const u8, source: draft.Draft) !void {
        var scratch: std.heap.ArenaAllocator = .init(w.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const same_file = if (w.file) |file| std.mem.eql(u8, file.path, path) else false;
        const stem = std.fs.path.stem(path);
        const test_name = if (same_file) w.title() else if (stem.len > 0) stem else "Request";

        var diagnostic: draft.Diagnostic = .{};
        var case = draft.toCase(arena, source, test_name, &diagnostic) catch |err| {
            const text = draft.message(arena, err, diagnostic) catch draft.describe(err);
            w.setMessage("Not saved. {s}", .{text});
            return err;
        };

        var suite: ast.Suite = .{ .name = if (stem.len > 0) stem else "Requests", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{} };
        var index: usize = 0;
        if (same_file) {
            const file = w.file.?;
            suite = file.suite;
            index = file.test_index;
            const old = file.suite.tests[index];
            // The editor shows neither of these, so they are kept as they were.
            case.mode = old.mode;
            case.timeout_ms = old.timeout_ms;
            case.variables = old.variables;
            case.extracts = old.extracts;
            const tests = try arena.dupe(ast.Case, file.suite.tests);
            tests[index] = case;
            suite.tests = tests;
        } else {
            suite.tests = try arena.dupe(ast.Case, &.{case});
        }

        var out: Io.Writer.Allocating = .init(arena);
        var write_diagnostic: writer.Diagnostic = .{};
        writer.write(&out.writer, suite, &write_diagnostic) catch |err| {
            if (err == error.Unrepresentable) w.setMessage("Not saved. {f}", .{write_diagnostic});
            return err;
        };
        // Validate the serialized suite before replacing the destination.
        var reopened: std.heap.ArenaAllocator = .init(w.gpa);
        errdefer reopened.deinit();
        const owned = reopened.allocator();
        const text = try owned.dupe(u8, out.written());
        var parse_diagnostic: parser.Diagnostic = .{};
        const parsed = parser.parse(owned, text, &parse_diagnostic) catch |err| {
            w.setMessage("Cannot save {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return err;
        };
        const owned_path = try owned.dupe(u8, path);
        writeSuite(w.io, owned_path, text) catch |err| {
            w.setMessage("Cannot write {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return err;
        };
        w.file_arena.deinit();
        w.file_arena = reopened;
        w.file = .{ .path = owned_path, .suite = parsed, .test_index = index };
        if (!same_file) w.loadConfigNear(owned_path);
        w.setMessage("Saved {s}", .{std.fs.path.basename(path)});
    }

    fn writeSuite(io: Io, path: []const u8, text: []const u8) !void {
        var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, text);
        try atomic.replace(io);
    }

    pub fn testCount(w: *const Workspace) usize {
        const file = w.file orelse return 0;
        return file.suite.tests.len;
    }

    /// Keeps the editor's `current` text for the test being shown, in memory,
    /// then returns the next test to show. Saving writes every test, edited
    /// or not. Fails, keeping the current test, when `current` cannot be
    /// written to the format; `message` says why.
    pub fn nextTest(w: *Workspace, current: draft.Draft, step: isize) !draft.Draft {
        const file = &(w.file orelse return error.NoFile);
        const arena = w.file_arena.allocator();
        try w.keep(current);
        const count: isize = @intCast(file.suite.tests.len);
        const index: usize = @intCast(@mod(@as(isize, @intCast(file.test_index)) + step, count));
        file.test_index = index;
        w.setMessage("Test {d} of {d}. Edits to other tests are kept until you save.", .{ index + 1, file.suite.tests.len });
        return draft.fromCase(arena, file.suite.tests[index]);
    }

    /// Replaces the shown test in the open suite, in memory only.
    fn keep(w: *Workspace, current: draft.Draft) !void {
        const file = &(w.file orelse return);
        const arena = w.file_arena.allocator();
        const old = file.suite.tests[file.test_index];
        var diagnostic: draft.Diagnostic = .{};
        var case = draft.toCase(arena, current, old.name, &diagnostic) catch |err| {
            const text = draft.message(arena, err, diagnostic) catch draft.describe(err);
            w.setMessage("Fix this test first. {s}", .{text});
            return err;
        };
        case.mode = old.mode;
        case.timeout_ms = old.timeout_ms;
        case.variables = old.variables;
        case.extracts = old.extracts;
        case.line = old.line;
        // Checked now, so a test is never kept that the save would refuse.
        var scratch: std.heap.ArenaAllocator = .init(w.gpa);
        defer scratch.deinit();
        var sink: Io.Writer.Allocating = .init(scratch.allocator());
        var write_diagnostic: writer.Diagnostic = .{};
        writer.write(&sink.writer, .{ .name = "check", .variables = &.{}, .setup = null, .teardown = null, .tests = &.{case} }, &write_diagnostic) catch |err| {
            if (err == error.Unrepresentable) w.setMessage("Fix this test first. {f}", .{write_diagnostic});
            return err;
        };
        const tests = try arena.dupe(ast.Case, file.suite.tests);
        tests[file.test_index] = case;
        file.suite.tests = tests;
    }

    /// Starts a new, unsaved request. Environments stay loaded.
    pub fn close(w: *Workspace) void {
        _ = w.file_arena.reset(.retain_capacity);
        w.file = null;
        w.message = "";
    }

    fn setMessage(w: *Workspace, comptime fmt: []const u8, args: anytype) void {
        w.message = std.fmt.bufPrint(&w.message_buffer, fmt, args) catch blk: {
            const end = "...";
            @memcpy(w.message_buffer[w.message_buffer.len - end.len ..], end);
            break :blk &w.message_buffer;
        };
    }
};

fn addShown(arena: Allocator, out: *std.ArrayList(Shown), list: config.Variables, source: []const u8, environ: *const std.process.Environ.Map, origin: u8) Allocator.Error!void {
    for (list.items) |variable| try putShown(arena, out, .{
        .name = variable.name,
        .value = switch (variable.source) {
            .text => |text| text,
            .env => |key| if (envValue(environ, key).len == 0)
                try std.fmt.allocPrint(arena, "${s} is not set", .{key})
            else
                redact.mask,
        },
        .source = source,
        .secret = variable.source == .env and envValue(environ, variable.source.env).len > 0,
        .raw = switch (variable.source) {
            .text => |text| text,
            .env => |key| envValue(environ, key),
        },
        .origin = origin,
    });
}

fn envValue(environ: *const std.process.Environ.Map, key: []const u8) []const u8 {
    const value: []const u8 = environ.get(key) orelse "";
    return value;
}

fn putShown(arena: Allocator, out: *std.ArrayList(Shown), item: Shown) Allocator.Error!void {
    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.name, item.name)) {
            existing.* = item;
            return;
        }
    }
    try out.append(arena, item);
}

const testing = std.testing;

const sample_config =
    \\{
    \\  "variables": { "baseUrl": "http://global", "version": "v1" },
    \\  "environments": {
    \\    "staging": { "baseUrl": "http://staging", "apiKey": { "env": "ZTEST_DESKTOP_KEY" } },
    \\    "local": { "baseUrl": "http://localhost" }
    \\  }
    \\}
;

fn tmpPath(arena: Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

test "environments cycle and resolve with secrets hidden in the panel" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = sample_config });

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("ZTEST_DESKTOP_KEY", "s3cret");

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    w.loadConfig(try tmpPath(arena, &tmp, ""));
    try testing.expectEqual(null, w.config_problem);
    try testing.expectEqualStrings("Global only", w.environmentName());

    w.cycleEnvironment();
    try testing.expectEqualStrings("staging", w.environmentName());
    var problem: []const u8 = "";
    const values = try w.variables(arena, &problem);
    try testing.expectEqualStrings("http://staging", values[values.len - 2].value);
    try testing.expect(values[values.len - 1].secret);

    const shown = try w.shownVariables(arena);
    try testing.expectEqual(3, shown.len);
    try testing.expectEqualStrings("http://staging", shown[0].value);
    try testing.expectEqualStrings("staging", shown[0].source);
    try testing.expectEqualStrings(redact.mask, shown[2].value);

    w.cycleEnvironment();
    try testing.expectEqualStrings("local", w.environmentName());
    w.cycleEnvironment();
    try testing.expectEqualStrings("Global only", w.environmentName());
}

test "an unset environment value stops sending with a reason" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = sample_config });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    w.loadConfig(try tmpPath(arena, &tmp, ""));
    w.cycleEnvironment();
    var problem: []const u8 = "";
    try testing.expectError(error.InvalidEnvironment, w.variables(arena, &problem));
    try testing.expect(std.mem.find(u8, problem, "ZTEST_DESKTOP_KEY") != null);
    const shown = try w.shownVariables(arena);
    try testing.expectEqualStrings("$ZTEST_DESKTOP_KEY is not set", shown[2].value);
}

test "saving a new file and reopening it gives back the draft" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    const path = try tmpPath(arena, &tmp, "create-user.ztest");
    try w.save(path, .{
        .method = .POST,
        .url = "{{baseUrl}}/users",
        .headers = "Accept: application/json\r\n",
        .auth = .{ .kind = .bearer, .value = "{{token}}" },
        .body_kind = .json,
        .body = "{ \"name\": \"Ada\" }",
        .assertions = "status == 201\r\n",
    });
    try testing.expectEqualStrings("Saved create-user.ztest", w.message);
    try testing.expectEqualStrings("create-user", w.title());

    var buffer: [1024]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "create-user.ztest", &buffer);
    try testing.expect(std.mem.startsWith(u8, text, "suite \"create-user\"\n"));
    try testing.expect(std.mem.find(u8, text, "  auth bearer {{token}}\n") != null);

    w.close();
    const reopened = try w.open(path);
    try testing.expectEqual(@import("../core/http/request.zig").Method.POST, reopened.method);
    try testing.expectEqualStrings("{{baseUrl}}/users", reopened.url);
    try testing.expectEqualStrings("status == 201\r\n", reopened.assertions);
    try testing.expectEqual(draft.AuthKind.bearer, reopened.auth.kind);
}

test "saving over an open suite replaces only the edited test" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "suite.ztest", .data =
        \\suite "Users"
        \\var secret token = "abc"
        \\setup
        \\  POST http://a/login
        \\  extract id = body.id
        \\end
        \\test "List"
        \\  timeout 2s
        \\  GET http://a/users
        \\end
        \\test "Other"
        \\  DELETE http://a/users/1
        \\end
        \\
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    const path = try tmpPath(arena, &tmp, "suite.ztest");
    var opened = try w.open(path);
    try testing.expectEqualStrings("Opened the first of 2 tests in suite.ztest", w.message);
    try testing.expectEqualStrings("List", w.title());

    var problem: []const u8 = "";
    const values = try w.variables(arena, &problem);
    try testing.expectEqualStrings("token", values[values.len - 1].name);

    opened.url = "http://a/users?page=2";
    try w.save(path, opened);

    var buffer: [1024]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "suite.ztest", &buffer);
    try testing.expect(std.mem.find(u8, text, "var secret token = \"abc\"") != null);
    try testing.expect(std.mem.find(u8, text, "  timeout 2000ms\n  GET http://a/users?page=2\n") != null);
    try testing.expect(std.mem.find(u8, text, "test \"Other\"") != null);
    try testing.expect(std.mem.find(u8, text, "extract id = body.id") != null);
}

test "a file the format cannot hold is not written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();

    const path = try tmpPath(arena, &tmp, "bad.ztest");
    try testing.expectError(error.Unrepresentable, w.save(path, .{ .url = "http://a", .headers = "X-Empty:" }));
    try testing.expectEqualStrings("Not saved. A header value is empty", w.message);
    try testing.expectError(error.InvalidAssertion, w.save(path, .{ .url = "http://a", .assertions = "status" }));
    try testing.expect(std.mem.startsWith(u8, w.message, "Not saved. Assertion line 1:"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bad.ztest", .{}));
}

test "the nearest ztest.json above a suite is used" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = sample_config });
    try tmp.dir.createDirPath(testing.io, "tests/deeper");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/deeper/a.ztest", .data = "suite \"S\"\ntest \"T\"\nGET {{baseUrl}}\nend\n" });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    _ = try w.open(try tmpPath(arena, &tmp, "tests/deeper/a.ztest"));
    try testing.expectEqual(2, w.settings.environments.items.len);
}

test "stepping through tests keeps edits for the save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.ztest", .data = "suite \"S\"\ntest \"A\"\nGET http://a\nend\ntest \"B\"\nGET http://b\nend\n" });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var w: Workspace = .init(testing.allocator, testing.io, &environ);
    defer w.deinit();
    const path = try tmpPath(arena, &tmp, "two.ztest");
    var first = try w.open(path);
    first.url = "http://a/edited";
    var second = try w.nextTest(first, 1);
    try testing.expectEqualStrings("http://b", second.url);
    try testing.expectEqualStrings("B", w.title());

    // A test the format cannot hold stays on screen.
    second.headers = "X-Empty:";
    try testing.expectError(error.Unrepresentable, w.nextTest(second, 1));
    try testing.expectEqualStrings("B", w.title());

    second.headers = "";
    second.url = "http://b/edited";
    const back = try w.nextTest(second, -1);
    try testing.expectEqualStrings("http://a/edited", back.url);
    try w.save(path, back);

    var buffer: [512]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "two.ztest", &buffer);
    try testing.expect(std.mem.find(u8, text, "GET http://a/edited") != null);
    try testing.expect(std.mem.find(u8, text, "GET http://b/edited") != null);
}
