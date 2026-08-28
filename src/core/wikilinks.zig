//! Pure `[[wikilink]]` target extraction -- no resolution, no I/O. Shared by
//! any `Store`/`LinkGraph` that has to find link targets in a note's raw
//! text itself, rather than asking a live external app for them.

const std = @import("std");

/// Every `[[...]]` occurrence in `body`, in order, each reduced to its raw
/// target text -- the part before a `|` alias if present, trimmed of
/// surrounding whitespace. An unterminated `[[` (no matching `]]` before the
/// end of `body`) stops extraction rather than erroring: prose is arbitrary
/// text, not a format this owns. Caller-owned: free every string and the
/// outer slice.
pub fn extract(gpa: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t);
        out.deinit(gpa);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "[[")) |start| {
        const inner_start = start + 2;
        const end = std.mem.indexOfPos(u8, body, inner_start, "]]") orelse break;
        const inner = body[inner_start..end];
        pos = end + 2;

        const raw = if (std.mem.indexOfScalar(u8, inner, '|')) |bar| inner[0..bar] else inner;
        const target = std.mem.trim(u8, raw, " \t\r\n");
        if (target.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, target));
    }
    return out.toOwnedSlice(gpa);
}

/// Rewrites every `[[Target]]`/`[[Target|Display]]` in `body` whose target
/// case-insensitively equals `old_target` so its target becomes
/// `new_target` -- an alias's `|Display` text, and everything else in
/// `body`, is copied through untouched. An unterminated `[[` copies the
/// remainder of `body` verbatim and stops, same "prose isn't a format this
/// owns" rule `extract` follows. Caller-owned.
pub fn renameTarget(gpa: std.mem.Allocator, body: []const u8, old_target: []const u8, new_target: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "[[")) |start| {
        try out.appendSlice(gpa, body[pos..start]);

        const inner_start = start + 2;
        const end = std.mem.indexOfPos(u8, body, inner_start, "]]") orelse {
            try out.appendSlice(gpa, body[start..]);
            pos = body.len;
            break;
        };
        const inner = body[inner_start..end];
        const bar = std.mem.indexOfScalar(u8, inner, '|');
        const raw = if (bar) |b| inner[0..b] else inner;
        const target = std.mem.trim(u8, raw, " \t\r\n");

        if (target.len != 0 and std.ascii.eqlIgnoreCase(target, old_target)) {
            try out.appendSlice(gpa, "[[");
            try out.appendSlice(gpa, new_target);
            if (bar) |b| try out.appendSlice(gpa, inner[b..]);
            try out.appendSlice(gpa, "]]");
        } else {
            try out.appendSlice(gpa, body[start .. end + 2]);
        }
        pos = end + 2;
    }
    try out.appendSlice(gpa, body[pos..]);
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn freeAll(gpa: std.mem.Allocator, s: []const []const u8) void {
    for (s) |t| gpa.free(t);
    gpa.free(s);
}

test "extract finds a bare wikilink target" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "see [[Some Note]] for details");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("Some Note", out[0]);
}

test "extract reduces an aliased wikilink to its pre-pipe target" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "see [[Some Note|a nicer label]] for details");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("Some Note", out[0]);
}

test "extract trims whitespace around the target" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "[[  Some Note  ]]");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("Some Note", out[0]);
}

test "extract finds every occurrence, in order" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "[[A]] and [[B|display]] and [[C]]");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("A", out[0]);
    try testing.expectEqualStrings("B", out[1]);
    try testing.expectEqualStrings("C", out[2]);
}

test "extract skips an unterminated wikilink instead of erroring" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "[[A]] then a broken [[B with no close");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("A", out[0]);
}

test "extract skips an empty target" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "[[]] and [[A]]");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("A", out[0]);
}

test "extract on text with no wikilinks returns an empty slice" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "plain prose, nothing bracketed");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "renameTarget rewrites a bare matching wikilink" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "see [[Old Name]] here", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("see [[New Name]] here", out);
}

test "renameTarget preserves an alias's display text" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "see [[Old Name|a nicer label]] here", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("see [[New Name|a nicer label]] here", out);
}

test "renameTarget matches case-insensitively" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "[[old name]]", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("[[New Name]]", out);
}

test "renameTarget leaves a non-matching wikilink untouched" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "[[Something Else]]", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("[[Something Else]]", out);
}

test "renameTarget rewrites every matching occurrence, leaving others alone" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "[[Old Name]] and [[Other]] and [[Old Name|again]]", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("[[New Name]] and [[Other]] and [[New Name|again]]", out);
}

test "renameTarget copies an unterminated wikilink through verbatim" {
    const gpa = testing.allocator;
    const out = try renameTarget(gpa, "[[Old Name]] then [[broken with no close", "Old Name", "New Name");
    defer gpa.free(out);
    try testing.expectEqualStrings("[[New Name]] then [[broken with no close", out);
}
