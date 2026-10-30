//! Optional `ztest.json` settings. Command-line flags override these values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Level = @import("log.zig").Level;

pub const file_name = "ztest.json";
const max_size: Io.Limit = .limited(1024 * 1024);

pub const Config = struct {
    log_level: Level = .normal,
    color: bool = true,
};

/// Unknown fields are errors so that a misspelled setting is not ignored.
/// Allocations are not freed individually, so pass an arena.
pub fn parse(arena: Allocator, text: []const u8) !Config {
    return std.json.parseFromSliceLeaky(Config, arena, text, .{});
}

/// Returns the defaults if `dir` has no config file.
pub fn load(arena: Allocator, io: Io, dir: Io.Dir) !Config {
    const text = dir.readFileAlloc(io, file_name, arena, max_size) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

const testing = std.testing;

test "parse reads settings and keeps defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const config = try parse(arena.allocator(), "{\"log_level\": \"verbose\"}");
    try testing.expectEqual(Level.verbose, config.log_level);
    try testing.expect(config.color);
}

test "parse rejects misspelled settings and invalid json" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.UnknownField, parse(arena.allocator(), "{\"colour\": false}"));
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "{]"));
}

test "load uses defaults without a file and reads one when present" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(Config{}, try load(arena.allocator(), testing.io, tmp.dir));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{\"color\": false}" });
    const config = try load(arena.allocator(), testing.io, tmp.dir);
    try testing.expect(!config.color);
}
