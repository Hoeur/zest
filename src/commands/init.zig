//! `ztest init`: writes a starter `ztest.json` and suite, so a new project can
//! run `ztest run tests/` straight away. Existing files are never replaced.

const std = @import("std");
const Io = std.Io;
const Context = @import("../core/context.zig").Context;
const ExitCode = @import("../core/errors.zig").ExitCode;
const config = @import("../core/config.zig");
const parser = @import("../core/parser/parser.zig");

pub const config_template =
    \\{
    \\  "variables": {
    \\    "baseUrl": "https://httpbin.org"
    \\  },
    \\  "environments": {
    \\    "local": {
    \\      "baseUrl": "http://localhost:8080"
    \\    },
    \\    "staging": {
    \\      "baseUrl": "https://staging.example.com",
    \\      "apiKey": { "env": "STAGING_API_KEY" }
    \\    }
    \\  }
    \\}
    \\
;

pub const suite_template =
    \\# A first suite. Run it with: ztest run tests/
    \\# The format is described in docs/TEST_FORMAT.md of the ZTest repository.
    \\suite "Example"
    \\
    \\test "GET returns JSON"
    \\  GET {{baseUrl}}/get?name=ztest
    \\  header Accept application/json
    \\  expect status == 200
    \\  expect response_time < 5s
    \\  expect header.content-type contains "application/json"
    \\  expect body.args.name == "ztest"
    \\end
    \\
    \\test "POST echoes a JSON body"
    \\  POST {{baseUrl}}/post
    \\  body { "user": "ada", "id": 7 }
    \\  expect status == 200
    \\  expect body.json.user == "ada"
    \\  expect body.json.id == 7
    \\  extract user = body.json.user
    \\end
    \\
    \\test "An extracted value reaches later requests"
    \\  GET {{baseUrl}}/anything/{{user}}
    \\  expect status == 200
    \\  expect body.url ends_with "/anything/ada"
    \\end
    \\
;

const File = struct { path: []const u8, data: []const u8 };
const files = [_]File{
    .{ .path = config.file_name, .data = config_template },
    .{ .path = "tests/example.ztest", .data = suite_template },
};

pub fn run(context: Context, out: *Io.Writer, directory: []const u8) !ExitCode {
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(context.io, directory) catch |err| {
        context.log.err("cannot create {s}: {s}", .{ directory, @errorName(err) });
        return .config_error;
    };
    var dir = cwd.openDir(context.io, directory, .{}) catch |err| {
        context.log.err("cannot open {s}: {s}", .{ directory, @errorName(err) });
        return .config_error;
    };
    defer dir.close(context.io);

    for (files) |file| {
        const created = create(context.io, dir, file) catch |err| {
            context.log.err("cannot write {s}: {s}", .{ file.path, @errorName(err) });
            return .config_error;
        };
        try out.print("{s} {s}\n", .{ if (created) "created" else "kept   ", file.path });
    }
    try out.writeAll("\nNext: ");
    if (!std.mem.eql(u8, directory, ".")) try out.print("cd {s} && ", .{directory});
    try out.writeAll("ztest run tests/\n");
    return .success;
}

/// False when the file already exists, which is left as it is.
fn create(io: Io, dir: Io.Dir, file: File) !bool {
    if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
    var handle = dir.createFile(io, file.path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    defer handle.close(io);
    try handle.writeStreamingAll(io, file.data);
    return true;
}

const testing = std.testing;

test "the templates are valid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const settings = try config.parse(arena.allocator(), config_template);
    try testing.expectEqual(2, settings.environments.items.len);
    var diagnostic: parser.Diagnostic = .{};
    const suite = try parser.parse(arena.allocator(), suite_template, &diagnostic);
    try testing.expectEqual(3, suite.tests.len);
}

test "init creates files once and keeps existing ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try testing.expect(try create(io, tmp.dir, files[1]));
    try tmp.dir.writeFile(io, .{ .sub_path = config.file_name, .data = "{}" });
    try testing.expect(!try create(io, tmp.dir, files[0]));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("{}", try tmp.dir.readFile(io, config.file_name, &buffer));
}
