//! Release packaging, run by `zig build release`.
//!
//! Writes `.zip` and `.tar.gz` archives and a `SHA256SUMS` file with nothing
//! but the Zig standard library, so packaging works the same on every
//! developer machine and CI runner.
//!
//! ```text
//! package archive <zip|tar.gz> <out> <root> <mtime> (<mode> <name> <path>)...
//! package checksums <out> <path>...
//! package notes <CHANGELOG.md> <version> <out>
//! ```
//!
//! `notes` copies one version's section of the changelog for the release
//! page, and fails unless that section exists and carries a release date.
//!
//! Every archive entry sits under the `<root>` folder and carries `<mtime>`
//! (Unix seconds), so the same inputs give the same bytes. `<mode>` is an
//! octal Unix mode such as `755`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// 1980-01-01T00:00:00Z, the earliest time a zip file can record.
pub const default_mtime: u64 = 315532800;

pub const Format = enum {
    zip,
    tar_gz,

    pub fn parse(text: []const u8) ?Format {
        if (std.mem.eql(u8, text, "zip")) return .zip;
        if (std.mem.eql(u8, text, "tar.gz")) return .tar_gz;
        return null;
    }
};

/// One file in an archive. `name` uses `/` separators and is relative to the root folder.
pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    run(arena, init.io, args[1..]) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        switch (err) {
            error.MissingCommand, error.UnknownCommand, error.BadArguments, error.UnknownFormat => {},
            else => std.process.exit(1),
        }
        std.log.info(
            \\usage: package archive <zip|tar.gz> <out> <root> <mtime> (<mode> <name> <path>)...
            \\       package checksums <out> <path>...
            \\       package notes <CHANGELOG.md> <version> <out>
        , .{});
        std.process.exit(1);
    };
}

fn run(arena: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingCommand;
    const cwd = Io.Dir.cwd();
    if (std.mem.eql(u8, args[0], "archive")) {
        if (args.len < 5 or (args.len - 5) % 3 != 0) return error.BadArguments;
        const format = Format.parse(args[1]) orelse return error.UnknownFormat;
        const mtime = try std.fmt.parseInt(u64, args[4], 10);
        var entries: std.ArrayList(Entry) = .empty;
        var i: usize = 5;
        while (i < args.len) : (i += 3) {
            try entries.append(arena, .{
                .mode = try std.fmt.parseInt(u32, args[i], 8),
                .name = args[i + 1],
                .data = try cwd.readFileAlloc(io, args[i + 2], arena, .unlimited),
            });
        }
        var out: Io.Writer.Allocating = try .initCapacity(arena, 1 << 16);
        try write(arena, &out.writer, format, args[3], entries.items, mtime);
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
    } else if (std.mem.eql(u8, args[0], "checksums")) {
        if (args.len < 2) return error.BadArguments;
        var out: Io.Writer.Allocating = .init(arena);
        for (args[2..]) |path| {
            const data = try cwd.readFileAlloc(io, path, arena, .unlimited);
            try checksumLine(&out.writer, std.fs.path.basename(path), data);
        }
        try cwd.writeFile(io, .{ .sub_path = args[1], .data = out.written() });
    } else if (std.mem.eql(u8, args[0], "notes")) {
        if (args.len != 4) return error.BadArguments;
        const changelog = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 20));
        const notes = releaseNotes(changelog, args[2]) catch |err| {
            std.log.err("{s} has no dated '## [{s}] - YYYY-MM-DD' section", .{ args[1], args[2] });
            return err;
        };
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = notes });
    } else return error.UnknownCommand;
}

/// Returns the body of the changelog section headed `## [version] - YYYY-MM-DD`,
/// trimmed, up to the next `## ` heading or link definitions.
pub fn releaseNotes(changelog: []const u8, version: []const u8) error{ MissingSection, Undated }![]const u8 {
    var lines = std.mem.splitScalar(u8, changelog, '\n');
    var start: ?usize = null;
    var end: usize = changelog.len;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const line_start = @intFromPtr(raw.ptr) - @intFromPtr(changelog.ptr);
        if (start == null) {
            if (!std.mem.startsWith(u8, line, "## [")) continue;
            const rest = line["## [".len..];
            if (!std.mem.startsWith(u8, rest, version) or !std.mem.startsWith(u8, rest[version.len..], "]")) continue;
            const date = std.mem.trim(u8, rest[version.len + 1 ..], " ");
            if (!isDated(date)) return error.Undated;
            start = line_start + raw.len + 1;
        } else if (std.mem.startsWith(u8, line, "## ") or
            (std.mem.startsWith(u8, line, "[") and std.mem.indexOf(u8, line, "]: ") != null))
        {
            end = line_start;
            break;
        }
    }
    const from = @min(start orelse return error.MissingSection, changelog.len);
    return std.mem.trim(u8, changelog[from..end], " \r\n");
}

/// True for `- YYYY-MM-DD`.
fn isDated(text: []const u8) bool {
    if (text.len != 12 or !std.mem.startsWith(u8, text, "- ")) return false;
    for (text[2..], 0..) |ch, i| {
        const ok = if (i == 4 or i == 7) ch == '-' else std.ascii.isDigit(ch);
        if (!ok) return false;
    }
    return true;
}

/// Writes one `sha256sum`-compatible line: the hex digest, two spaces, the name.
pub fn checksumLine(w: *Io.Writer, name: []const u8, data: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    try w.print("{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), name });
}

/// Writes `entries` as one archive with every name under `root/`.
/// `w` needs a buffer of more than 8 bytes, which the compressor requires.
pub fn write(
    gpa: Allocator,
    w: *Io.Writer,
    format: Format,
    root: []const u8,
    entries: []const Entry,
    mtime: u64,
) !void {
    switch (format) {
        .zip => try writeZip(gpa, w, root, entries, mtime),
        .tar_gz => try writeTarGz(w, root, entries, mtime),
    }
}

fn writeTarGz(w: *Io.Writer, root: []const u8, entries: []const Entry, mtime: u64) !void {
    var window: [flate.max_window_len]u8 = undefined;
    var gzip: flate.Compress = try .init(w, &window, .gzip, .best);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    try tar.writeDir(root, .{ .mode = 0o755, .mtime = mtime });
    tar.prefix = root;
    for (entries) |entry| {
        try tar.writeFileBytes(entry.name, entry.data, .{ .mode = entry.mode, .mtime = mtime });
    }
    try tar.finishPedantically();
    try gzip.finish();
    try w.flush();
}

const CentralRecord = struct {
    name: []const u8,
    crc: u32,
    compressed: u32,
    size: u32,
    offset: u32,
    mode: u32,
};

fn writeZip(gpa: Allocator, w: *Io.Writer, root: []const u8, entries: []const Entry, mtime: u64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dos = dosTime(mtime);
    var records: std.ArrayList(CentralRecord) = .empty;
    var offset: u64 = 0;

    const dir_name = try std.fmt.allocPrint(arena, "{s}/", .{root});
    try records.append(arena, .{ .name = dir_name, .crc = 0, .compressed = 0, .size = 0, .offset = 0, .mode = 0o40755 });
    offset += try writeLocal(w, dir_name, dos, 0, 0, 0, "");

    for (entries) |entry| {
        const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name });
        var deflated: Io.Writer.Allocating = try .initCapacity(arena, entry.data.len / 2 + 64);
        var window: [flate.max_window_len]u8 = undefined;
        var deflate: flate.Compress = try .init(&deflated.writer, &window, .raw, .best);
        try deflate.writer.writeAll(entry.data);
        try deflate.finish();

        const size = std.math.cast(u32, entry.data.len) orelse return error.FileTooBig;
        const compressed = std.math.cast(u32, deflated.written().len) orelse return error.FileTooBig;
        const record: CentralRecord = .{
            .name = name,
            .crc = std.hash.Crc32.hash(entry.data),
            .compressed = compressed,
            .size = size,
            .offset = std.math.cast(u32, offset) orelse return error.FileTooBig,
            .mode = 0o100000 | entry.mode,
        };
        try records.append(arena, record);
        offset += try writeLocal(w, name, dos, record.crc, compressed, size, deflated.written());
    }

    const central_start = std.math.cast(u32, offset) orelse return error.FileTooBig;
    var central_size: u32 = 0;
    for (records.items) |r| {
        const is_dir = std.mem.endsWith(u8, r.name, "/");
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, (3 << 8) | 20, .little); // made by Unix, zip 2.0
        try w.writeInt(u16, 20, .little); // needed to extract
        try w.writeInt(u16, 0x0800, .little); // names are UTF-8
        try w.writeInt(u16, if (is_dir) 0 else 8, .little); // stored or deflated
        try w.writeInt(u16, dos.time, .little);
        try w.writeInt(u16, dos.date, .little);
        try w.writeInt(u32, r.crc, .little);
        try w.writeInt(u32, r.compressed, .little);
        try w.writeInt(u32, r.size, .little);
        try w.writeInt(u16, @intCast(r.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        // Unix mode in the high half; 0x10 is the MS-DOS directory flag.
        try w.writeInt(u32, (r.mode << 16) | @as(u32, if (is_dir) 0x10 else 0), .little);
        try w.writeInt(u32, r.offset, .little);
        try w.writeAll(r.name);
        central_size += 46 + @as(u32, @intCast(r.name.len));
    }

    const count: u16 = std.math.cast(u16, records.items.len) orelse return error.TooManyFiles;
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, central_size, .little);
    try w.writeInt(u32, central_start, .little);
    try w.writeInt(u16, 0, .little);
    try w.flush();
}

fn writeLocal(w: *Io.Writer, name: []const u8, dos: DosTime, crc: u32, compressed: u32, size: u32, data: []const u8) !u64 {
    if (name.len > std.math.maxInt(u16)) return error.NameTooLong;
    const is_dir = std.mem.endsWith(u8, name, "/");
    try w.writeInt(u32, 0x04034b50, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0x0800, .little);
    try w.writeInt(u16, if (is_dir) 0 else 8, .little);
    try w.writeInt(u16, dos.time, .little);
    try w.writeInt(u16, dos.date, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, compressed, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeAll(name);
    try w.writeAll(data);
    return 30 + name.len + data.len;
}

const DosTime = struct { time: u16, date: u16 };

/// Converts Unix seconds to an MS-DOS date and time in UTC, clamped to 1980.
fn dosTime(unix: u64) DosTime {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @max(unix, default_mtime) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const secs = epoch.getDaySeconds();
    const year: u16 = @min(day.year, 2107);
    return .{
        .time = (@as(u16, secs.getHoursIntoDay()) << 11) |
            (@as(u16, secs.getMinutesIntoHour()) << 5) |
            (@as(u16, secs.getSecondsIntoMinute()) / 2),
        .date = ((year - 1980) << 9) |
            (@as(u16, month_day.month.numeric()) << 5) |
            (@as(u16, month_day.day_index) + 1),
    };
}

const testing = std.testing;

const sample_entries = [_]Entry{
    .{ .name = "ztest", .data = "\x7fELF\x00\x01\x02 binary bytes repeat, repeat, repeat, repeat", .mode = 0o755 },
    .{ .name = "LICENSE", .data = "MIT License\n" },
    .{ .name = "docs/INSTALL.md", .data = "" },
};

test "tar.gz archives hold every file under the root with its mode" {
    var out: Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer out.deinit();
    try write(testing.allocator, &out.writer, .tar_gz, "ztest-1.0-x86_64-linux", &sample_entries, default_mtime);

    var input: Io.Reader = .fixed(out.written());
    var window: [flate.max_window_len]u8 = undefined;
    var gunzip: flate.Decompress = .init(&input, .gzip, &window);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gunzip.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });

    const root = (try it.next()).?;
    try testing.expectEqual(std.tar.FileKind.directory, root.kind);
    try testing.expectEqualStrings("ztest-1.0-x86_64-linux", root.name);
    for (sample_entries) |expected| {
        const file = (try it.next()).?;
        try testing.expectEqual(std.tar.FileKind.file, file.kind);
        const name = try std.fmt.allocPrint(testing.allocator, "ztest-1.0-x86_64-linux/{s}", .{expected.name});
        defer testing.allocator.free(name);
        try testing.expectEqualStrings(name, file.name);
        try testing.expectEqual(expected.mode, file.mode);
        var content: Io.Writer.Allocating = .init(testing.allocator);
        defer content.deinit();
        try it.streamRemaining(file, &content.writer);
        try testing.expectEqualSlices(u8, expected.data, content.written());
    }
    try testing.expectEqual(null, try it.next());
}

test "zip archives extract with the standard library" {
    var out: Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer out.deinit();
    try write(testing.allocator, &out.writer, .zip, "ztest-1.0-x86_64-windows", &sample_entries, 1793750400);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out.zip", .data = out.written() });
    const file = try tmp.dir.openFile(testing.io, "out.zip", .{});
    defer file.close(testing.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);
    try tmp.dir.createDirPath(testing.io, "x");
    const dest = try tmp.dir.openDir(testing.io, "x", .{});
    try std.zip.extract(dest, &reader, .{});

    for (sample_entries) |expected| {
        const path = try std.fmt.allocPrint(testing.allocator, "ztest-1.0-x86_64-windows/{s}", .{expected.name});
        defer testing.allocator.free(path);
        const data = try dest.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, expected.data, data);
    }
}

test "archives are byte-for-byte reproducible" {
    for ([_]Format{ .zip, .tar_gz }) |format| {
        var a: Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
        defer a.deinit();
        var b: Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
        defer b.deinit();
        try write(testing.allocator, &a.writer, format, "r", &sample_entries, default_mtime);
        try write(testing.allocator, &b.writer, format, "r", &sample_entries, default_mtime);
        try testing.expectEqualSlices(u8, a.written(), b.written());
    }
}

test "checksum lines match sha256sum" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try checksumLine(&out.writer, "a.zip", "abc");
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a.zip\n",
        out.written(),
    );
}

test "MS-DOS timestamps" {
    // 2026-11-04T00:00:00Z
    const t = dosTime(1793750400);
    try testing.expectEqual(@as(u16, ((2026 - 1980) << 9) | (11 << 5) | 4), t.date);
    try testing.expectEqual(@as(u16, 0), t.time);
    try testing.expectEqual(DosTime{ .time = 0, .date = (1 << 5) | 1 }, dosTime(0));
}

test "release notes come from the dated section of the changelog" {
    const changelog =
        \\# Changelog
        \\
        \\## [Unreleased]
        \\
        \\## [1.1.0] - 2026-12-01
        \\
        \\### Added
        \\
        \\- Proxies.
        \\
        \\## [1.1.0-rc.1] - 2026-11-20
        \\
        \\- Candidate.
        \\
        \\## [1.0.0] - Unreleased
        \\
        \\- First.
        \\
        \\[1.1.0]: https://example.com
        \\
    ;
    try testing.expectEqualStrings("### Added\n\n- Proxies.", try releaseNotes(changelog, "1.1.0"));
    try testing.expectEqualStrings("- Candidate.", try releaseNotes(changelog, "1.1.0-rc.1"));
    try testing.expectError(error.Undated, releaseNotes(changelog, "1.0.0"));
    try testing.expectError(error.MissingSection, releaseNotes(changelog, "2.0.0"));
    try testing.expectError(error.MissingSection, releaseNotes(changelog, "1.1"));
    try testing.expectEqualStrings("", try releaseNotes("## [3.0.0] - 2027-01-01\r\n", "3.0.0"));
}

test "format names" {
    try testing.expectEqual(Format.zip, Format.parse("zip").?);
    try testing.expectEqual(Format.tar_gz, Format.parse("tar.gz").?);
    try testing.expectEqual(null, Format.parse("7z"));
}
