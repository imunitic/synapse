//! Pure `[[wikilink]]` target extraction -- no resolution, no I/O. Shared by
//! any `Store`/`LinkGraph` that has to find link targets in a note's raw
//! text itself, rather than asking a live external app for them.

const std = @import("std");
const unicode_norm = @import("unicode_norm.zig");

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

/// Splits a raw wikilink target into the note-identifying part and an
/// optional `#`-anchor suffix (the leading `#` included). `[[Note#Heading]]`
/// names the same note as `[[Note]]`, scoped to one of its headings -- the
/// anchor plays no part in which note the link resolves to, only in
/// `renameTarget`'s job of carrying it through a rewrite unchanged.
fn splitAnchor(target: []const u8) struct { base: []const u8, anchor: []const u8 } {
    const i = std.mem.indexOfScalar(u8, target, '#') orelse return .{ .base = target, .anchor = "" };
    return .{ .base = target[0..i], .anchor = target[i..] };
}

/// A raw `[[...]]` target reduced to the same shape a bare title is: any
/// leading path (`some/dir/Foo` -> `Foo`), a `#`-anchor suffix
/// (`Foo#Heading` -> `Foo`), and a trailing `.md` (`Foo.md` -> `Foo`)
/// stripped. `[[Foo]]`, `[[Foo.md]]`, `[[some/dir/Foo.md]]`, and
/// `[[Foo#Heading]]` all name the same note in Obsidian, but only the
/// bare-title spelling used to resolve or survive a rename here -- this is
/// the one place that gap closes, shared by every caller matching a
/// wikilink target against a title (`resolveCandidates`, `renameTarget`
/// below) rather than each re-implementing its own slice of the same
/// normalization.
pub fn normalizeTarget(target: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, target, '/')) |i| target[i + 1 ..] else target;
    const without_anchor = splitAnchor(base).base;
    return if (std.mem.endsWith(u8, without_anchor, ".md")) without_anchor[0 .. without_anchor.len - 3] else without_anchor;
}

/// Whether a raw wikilink `target` names the same note as `old_target`:
/// both stripped to a bare title (`normalizeTarget`), both NFC-normalized
/// (a precomposed vs. decomposed spelling of the same text must still
/// match), then compared by Unicode simple case fold rather than
/// `std.ascii.eqlIgnoreCase` -- a non-Latin title deserves the same
/// case-insensitive match an ASCII one already gets. An empty `target`
/// never matches, regardless of `old_target`.
fn targetMatches(gpa: std.mem.Allocator, target: []const u8, old_target: []const u8) !bool {
    if (target.len == 0) return false;
    const a = try unicode_norm.normalizeNfc(gpa, normalizeTarget(target));
    defer gpa.free(a);
    const b = try unicode_norm.normalizeNfc(gpa, normalizeTarget(old_target));
    defer gpa.free(b);
    return unicode_norm.eqlCaseFold(a, b);
}

/// Rewrites every `[[Target]]`/`[[Target#Heading]]`/`[[Target|Display]]` in
/// `body` whose target matches `old_target` (see `targetMatches`) so its
/// target becomes `new_target` -- a `#`-anchor suffix and an alias's
/// `|Display` text both carry through unchanged, and everything else in
/// `body` is copied through untouched. An unterminated `[[` copies the
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

        const matches = try targetMatches(gpa, target, old_target);
        if (matches) {
            try out.appendSlice(gpa, "[[");
            try out.appendSlice(gpa, new_target);
            try out.appendSlice(gpa, splitAnchor(target).anchor);
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

/// Rewrites every `[[Target]]`/`[[Target#Heading]]`/`[[Target|Display]]` in
/// `body` whose target matches `old_target` (see `targetMatches`) into plain
/// text, so the sentence around it stays readable once the note it pointed
/// to is gone rather than losing those words outright: an alias's
/// `|Display` text when present, otherwise `old_target`'s bare title with
/// any `#`-anchor/leading path/`.md` suffix dropped -- they named a place
/// inside a note that no longer exists, so carrying them into plain prose
/// would misquote it rather than describe it. Everything else in `body` is
/// copied through untouched, same "prose isn't a format this owns" rule
/// `renameTarget` follows for an unterminated `[[`. Caller-owned.
pub fn unlinkTarget(gpa: std.mem.Allocator, body: []const u8, old_target: []const u8) ![]u8 {
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

        const matches = try targetMatches(gpa, target, old_target);
        if (matches) {
            if (bar) |b| {
                try out.appendSlice(gpa, std.mem.trim(u8, inner[b + 1 ..], " \t\r\n"));
            } else {
                try out.appendSlice(gpa, normalizeTarget(target));
            }
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

test "extract keeps a heading anchor as part of the raw target" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "see [[Some Note#A Heading]] for details");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("Some Note#A Heading", out[0]);
}

test "extract on text with no wikilinks returns an empty slice" {
    const gpa = testing.allocator;
    const out = try extract(gpa, "plain prose, nothing bracketed");
    defer freeAll(gpa, out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "renameTarget" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, in: []const u8, old: []const u8, new: []const u8, want: []const u8 }{
        .{ .name = "rewrites a bare matching wikilink", .in = "see [[Old Name]] here", .old = "Old Name", .new = "New Name", .want = "see [[New Name]] here" },
        .{ .name = "preserves an alias's display text", .in = "see [[Old Name|a nicer label]] here", .old = "Old Name", .new = "New Name", .want = "see [[New Name|a nicer label]] here" },
        .{ .name = "matches case-insensitively", .in = "[[old name]]", .old = "Old Name", .new = "New Name", .want = "[[New Name]]" },
        .{ .name = "matches a heading-anchored link and carries the anchor through", .in = "see [[Old Name#Some Heading]] here", .old = "Old Name", .new = "New Name", .want = "see [[New Name#Some Heading]] here" },
        .{ .name = "carries a heading anchor through alongside an alias", .in = "[[Old Name#Some Heading|a nicer label]]", .old = "Old Name", .new = "New Name", .want = "[[New Name#Some Heading|a nicer label]]" },
        .{ .name = "leaves a non-matching wikilink untouched", .in = "[[Something Else]]", .old = "Old Name", .new = "New Name", .want = "[[Something Else]]" },
        .{ .name = "rewrites every matching occurrence, leaving others alone", .in = "[[Old Name]] and [[Other]] and [[Old Name|again]]", .old = "Old Name", .new = "New Name", .want = "[[New Name]] and [[Other]] and [[New Name|again]]" },
        .{ .name = "copies an unterminated wikilink through verbatim", .in = "[[Old Name]] then [[broken with no close", .old = "Old Name", .new = "New Name", .want = "[[New Name]] then [[broken with no close" },
        .{ .name = "matches a non-Latin title regardless of case", .in = "see [[МОСКВА]] here", .old = "Москва", .new = "Санкт-Петербург", .want = "see [[Санкт-Петербург]] here" },
        // か (U+304B) + combining dakuten (U+3099), decomposed -- names the
        // same title as precomposed が (U+304C).
        .{ .name = "matches a target regardless of NFC composition", .in = "see [[\u{304B}\u{3099}]] here", .old = "\u{304C}", .new = "New Name", .want = "see [[New Name]] here" },
        .{ .name = "rewrites a .md-suffixed wikilink", .in = "[[Old Name.md]]", .old = "Old Name", .new = "New Name", .want = "[[New Name]]" },
        .{ .name = "rewrites a path-qualified wikilink", .in = "[[tasks/synapse/Old Name.md]]", .old = "Old Name", .new = "New Name", .want = "[[New Name]]" },
    };
    for (cases) |c| {
        const out = try renameTarget(gpa, c.in, c.old, c.new);
        defer gpa.free(out);
        testing.expectEqualStrings(c.want, out) catch |err| {
            std.debug.print("renameTarget case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

test "unlinkTarget" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, in: []const u8, old: []const u8, want: []const u8 }{
        .{ .name = "replaces a bare matching wikilink with its bare title", .in = "see [[Old Name]] here", .old = "Old Name", .want = "see Old Name here" },
        .{ .name = "replaces an aliased wikilink with its display text", .in = "see [[Old Name|a nicer label]] here", .old = "Old Name", .want = "see a nicer label here" },
        .{ .name = "matches case-insensitively, keeping the case as typed", .in = "[[old name]]", .old = "Old Name", .want = "old name" },
        .{ .name = "drops a heading anchor from the unlinked bare title", .in = "see [[Old Name#Some Heading]] here", .old = "Old Name", .want = "see Old Name here" },
        .{ .name = "drops a heading anchor even alongside an alias, keeping only the display text", .in = "[[Old Name#Some Heading|a nicer label]]", .old = "Old Name", .want = "a nicer label" },
        .{ .name = "leaves a non-matching wikilink untouched", .in = "[[Something Else]]", .old = "Old Name", .want = "[[Something Else]]" },
        .{ .name = "unlinks every matching occurrence, leaving others alone", .in = "[[Old Name]] and [[Other]] and [[Old Name|again]]", .old = "Old Name", .want = "Old Name and [[Other]] and again" },
        .{ .name = "copies an unterminated wikilink through verbatim", .in = "[[Old Name]] then [[broken with no close", .old = "Old Name", .want = "Old Name then [[broken with no close" },
        .{ .name = "unlinks a .md-suffixed wikilink to its bare title", .in = "[[Old Name.md]]", .old = "Old Name", .want = "Old Name" },
        .{ .name = "unlinks a path-qualified wikilink to its bare title", .in = "[[tasks/synapse/Old Name.md]]", .old = "Old Name", .want = "Old Name" },
    };
    for (cases) |c| {
        const out = try unlinkTarget(gpa, c.in, c.old);
        defer gpa.free(out);
        testing.expectEqualStrings(c.want, out) catch |err| {
            std.debug.print("unlinkTarget case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

test "normalizeTarget strips a heading anchor alongside path and extension" {
    try testing.expectEqualStrings("Foo", normalizeTarget("Foo#Heading"));
    try testing.expectEqualStrings("Foo", normalizeTarget("some/dir/Foo.md#Heading"));
}

test "normalizeTarget strips a trailing .md" {
    try testing.expectEqualStrings("Foo", normalizeTarget("Foo.md"));
}

test "normalizeTarget strips a leading path" {
    try testing.expectEqualStrings("Foo", normalizeTarget("some/dir/Foo"));
}

test "normalizeTarget strips both a leading path and a trailing .md" {
    try testing.expectEqualStrings("Foo", normalizeTarget("some/dir/Foo.md"));
}

test "normalizeTarget leaves a bare title untouched" {
    try testing.expectEqualStrings("Foo", normalizeTarget("Foo"));
}
