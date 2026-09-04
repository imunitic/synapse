//! Small, pure, case-insensitive text-search primitives -- no `Store`, no
//! I/O, nothing domain-specific. Shared by every `Store` implementation
//! whose `search` is a plain full-text scan (`DiskStore`, `BardGraphStore`)
//! rather than a backend with its own relevance search to call out to.

const std = @import("std");
const unicode_norm = @import("unicode_norm.zig");

/// The first line in `body` containing `query`, case-insensitive -- the
/// one-line-of-context a search hit shows alongside its score.
pub fn firstMatchingLine(body: []const u8, query: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (unicode_norm.containsCaseFold(line, query)) return line;
    }
    return null;
}

/// Case-insensitive occurrence count -- `std.mem.count` has no ignore-case
/// form of its own, and a search score needs one.
pub fn countIgnoreCase(haystack: []const u8, needle: []const u8) usize {
    return unicode_norm.countCaseFold(haystack, needle);
}

const testing = std.testing;

test "firstMatchingLine finds the first line containing query, case-insensitive" {
    const body = "one\nTwo Widget\nthree widget\n";
    try testing.expectEqualStrings("Two Widget", firstMatchingLine(body, "widget").?);
}

test "firstMatchingLine returns null when nothing matches" {
    try testing.expectEqual(@as(?[]const u8, null), firstMatchingLine("one\ntwo\n", "gadget"));
}

test "countIgnoreCase counts every occurrence regardless of case" {
    try testing.expectEqual(@as(usize, 3), countIgnoreCase("Widget widget WIDGET gadget", "widget"));
}

test "countIgnoreCase with an empty needle is zero, not every position" {
    try testing.expectEqual(@as(usize, 0), countIgnoreCase("anything", ""));
}

test "firstMatchingLine and countIgnoreCase work on non-Latin text too" {
    const body = "one\nгород МОСКВА\nтри\n";
    try testing.expectEqualStrings("город МОСКВА", firstMatchingLine(body, "москва").?);
    try testing.expectEqual(@as(usize, 2), countIgnoreCase("Москва москва", "МОСКВА"));
}
