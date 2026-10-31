//! Hides secret values in text meant for people.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const mask = "********";

/// Matches exact bytes, so an encoded secret, such as in Basic auth, stays as
/// it is. Returns `text` itself when there is nothing to hide.
pub fn redact(arena: Allocator, text: []const u8, secrets: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const length = longestAt(text[i..], secrets);
        if (length == 0) {
            i += 1;
            continue;
        }
        try out.appendSlice(arena, text[start..i]);
        try out.appendSlice(arena, mask);
        i += length;
        start = i;
    }
    if (start == 0) return text;
    try out.appendSlice(arena, text[start..]);
    return out.items;
}

/// The longest wins, so a secret inside another leaves no tail behind. An empty
/// secret has length 0, which matches nothing.
fn longestAt(text: []const u8, secrets: []const []const u8) usize {
    var longest: usize = 0;
    for (secrets) |secret| {
        if (secret.len > longest and std.mem.startsWith(u8, text, secret)) longest = secret.len;
    }
    return longest;
}

const testing = std.testing;

fn expectRedacted(expected: []const u8, text: []const u8, secrets: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try redact(arena.allocator(), text, secrets));
}

test "every copy of a secret is hidden" {
    try expectRedacted("a ******** b ********", "a key b key", &.{"key"});
    try expectRedacted("********", "key", &.{"key"});
    try expectRedacted("nothing here", "nothing here", &.{"key"});
    try expectRedacted("", "", &.{"key"});
}

test "the longest secret wins" {
    try expectRedacted("********!", "abcdef!", &.{ "abc", "abcdef" });
}

test "an empty secret hides nothing" {
    try expectRedacted("text", "text", &.{""});
    try expectRedacted("text", "text", &.{});
}
