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

/// An inclusive range of 1-based line numbers.
pub const LineRange = struct { start: usize, end: usize };

/// Every line of `text` containing any of `terms`, case-insensitive, as
/// ranges numbered from `first_line` (the line number of `text`'s own first
/// line, so a slice taken after a frontmatter block still reports file
/// lines). Consecutive matching lines merge into one range. Caller-owned.
pub fn matchRanges(
    gpa: std.mem.Allocator,
    text: []const u8,
    first_line: usize,
    terms: []const []const u8,
) ![]LineRange {
    var out: std.ArrayListUnmanaged(LineRange) = .empty;
    errdefer out.deinit(gpa);
    var n = first_line;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (n += 1) {
        for (terms) |t| {
            if (!unicode_norm.containsCaseFold(line, t)) continue;
            if (out.items.len != 0 and out.items[out.items.len - 1].end + 1 == n) {
                out.items[out.items.len - 1].end = n;
            } else {
                try out.append(gpa, .{ .start = n, .end = n });
            }
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `12-14,40-41,88`: comma-separated, a one-line range written as its bare
/// number. The same spelling `parseLineRanges` in `query.zig` reads back.
pub fn writeRanges(w: *std.Io.Writer, ranges: []const LineRange) !void {
    for (ranges, 0..) |r, i| {
        if (i != 0) try w.writeAll(",");
        if (r.start == r.end) {
            try w.print("{d}", .{r.start});
        } else {
            try w.print("{d}-{d}", .{ r.start, r.end });
        }
    }
}

const testing = std.testing;

test "matchRanges merges consecutive matching lines and keeps separate runs apart" {
    const text = "alpha widget\nwidget again\nplain\nplain\nthe Widget\n";
    const got = try matchRanges(testing.allocator, text, 1, &.{"widget"});
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(LineRange{ .start = 1, .end = 2 }, got[0]);
    try testing.expectEqual(LineRange{ .start = 5, .end = 5 }, got[1]);
}

test "matchRanges numbers from first_line, so a slice after the frontmatter reports file lines" {
    const got = try matchRanges(testing.allocator, "no\nyes widget\n", 20, &.{"widget"});
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(LineRange{ .start = 21, .end = 21 }, got[0]);
}

test "matchRanges matches a line on any one of several terms" {
    const got = try matchRanges(testing.allocator, "one gadget\ntwo\nthree widget\n", 1, &.{ "widget", "gadget" });
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "writeRanges spells a one-line range as a bare number" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeRanges(&w, &.{ .{ .start = 12, .end = 14 }, .{ .start = 40, .end = 41 }, .{ .start = 88, .end = 88 } });
    try testing.expectEqualStrings("12-14,40-41,88", w.buffered());
}

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
