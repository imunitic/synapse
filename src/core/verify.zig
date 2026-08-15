//! Tier-2 verification: whether a node still describes the tree it claims.
//!
//! Two questions: `stale` asks whether a node's *sources* still hash to what
//! was recorded (yes/no about the file set); `grounding` asks whether the
//! specific *lines* a sentence rests on are still those lines, distinguishing
//! a moved range ("re-point this") from a changed one ("re-read this").
//!
//! Everything here is a pure function of bytes -- the caller reads files and
//! runs `git`, so these decisions are testable without a repository.

const std = @import("std");
const node_mod = @import("node.zig");

/// A git blob hash: `sha1("blob " ++ decimal-length ++ "\0" ++ content)`.
/// Computed directly rather than shelling out to `git hash-object`; tests
/// check it against real `git hash-object` output. 40 lowercase hex chars,
/// the form a node stores.
pub fn blobHash(content: []const u8) [40]u8 {
    const raw = blobHashRaw(content);
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return hex;
}

/// The same hash as 20 raw bytes, how the tags cache stores it -- avoids a
/// hex round trip at call sites needing both forms.
pub fn blobHashRaw(content: []const u8) [20]u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    var header: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "blob {d}\x00", .{content.len}) catch unreachable;
    sha.update(h);
    sha.update(content);
    var raw: [20]u8 = undefined;
    sha.final(&raw);
    return raw;
}

/// Why a node is stale, or that it is not. Distinctions are load-bearing:
/// "no sources_digest" needs a rebuild (pre-dates the field), "content
/// changed" needs a regeneration (files moved on) -- collapsing them would
/// make the first look like the second forever.
pub const Staleness = union(enum) {
    /// Every reporting subcommand relies on empty output meaning exactly this.
    clean,
    node_file_missing,
    no_digest,
    no_sources,
    /// Recorded files no longer on disk -- `git hash-object` would fail the
    /// whole batch on one, so these are found and named first.
    sources_gone: []const []const u8,
    hashing_failed,
    content_changed,

    /// `sources_gone` needs the allocator; every other variant is static.
    pub fn reason(self: Staleness, gpa: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .clean => "",
            .node_file_missing => "node file missing from the vault",
            .no_digest => "no sources_digest (built before the digest existed)",
            .no_sources => "no sources listed",
            .hashing_failed => "hashing failed",
            .content_changed => "content changed",
            .sources_gone => |paths| blk: {
                var out: std.Io.Writer.Allocating = .init(gpa);
                errdefer out.deinit();
                try out.writer.writeAll("source files gone: ");
                for (paths, 0..) |p, i| {
                    if (i > 0) try out.writer.writeAll(" ");
                    try out.writer.writeAll(p);
                }
                break :blk out.toOwnedSlice();
            },
        };
    }
};

/// What a node's recorded state and its files' current hashes add up to.
/// `hashes` is parallel to `paths`; `missing` names paths that had none.
pub fn staleness(
    gpa: std.mem.Allocator,
    present: bool,
    stored_digest: ?[]const u8,
    paths: []const []const u8,
    missing: []const []const u8,
    hashes: []const []const u8,
) !Staleness {
    // Order matters: each check would answer the next question wrongly.
    if (!present) return .node_file_missing;
    const stored = stored_digest orelse return .no_digest;
    if (stored.len == 0) return .no_digest;
    if (paths.len == 0) return .no_sources;
    if (missing.len != 0) return .{ .sources_gone = missing };
    if (hashes.len != paths.len) return .hashing_failed;

    var sources = try gpa.alloc(node_mod.Source, paths.len);
    defer gpa.free(sources);
    for (paths, hashes, 0..) |p, h, i| sources[i] = .{ .path = p, .hash = h };

    const current = try node_mod.sourcesDigest(gpa, sources);
    return if (std.mem.eql(u8, &current, stored)) .clean else .content_changed;
}

/// A 1-based inclusive line range. Named, not anonymous -- two functions
/// return it and `@TypeOf` won't unify distinct anonymous struct types.
pub const Range = struct { start: usize, end: usize };

/// One `grounded_in` entry: the lines a claim rests on, and their digest.
pub const Grounding = struct {
    path: []const u8,
    /// As recorded, `start-end`, 1-based and inclusive.
    lines: []const u8,
    /// sha256 over those lines as `sed -n 'start,endp'` emits them. Key is
    /// `digest:`, not `hash:` -- `sources:` entries use `hash:`, so don't
    /// confuse the two.
    digest: []const u8,

    pub fn range(self: Grounding) ?Range {
        const dash = std.mem.indexOfScalar(u8, self.lines, '-') orelse return null;
        const start = std.fmt.parseInt(usize, self.lines[0..dash], 10) catch return null;
        const end = std.fmt.parseInt(usize, self.lines[dash + 1 ..], 10) catch return null;
        if (start == 0 or end < start) return null;
        return .{ .start = start, .end = end };
    }
};

/// The `grounded_in:` block of a node's frontmatter. Separate from
/// `sources()` deliberately -- both are `- path:` lists in the same
/// frontmatter, and conflating them false-positives "content changed"
/// on every grounded node.
pub fn groundings(
    gpa: std.mem.Allocator,
    text: []const u8,
) !std.ArrayListUnmanaged(Grounding) {
    var out: std.ArrayListUnmanaged(Grounding) = .empty;
    errdefer out.deinit(gpa);

    var in_block = false;
    var current: ?Grounding = null;
    var it = @import("query.zig").FrontmatterIterator.init(text);
    while (it.next()) |line| {
        if (line.len != 0 and (std.ascii.isAlphabetic(line[0]) or line[0] == '_')) {
            if (current) |g| {
                try out.append(gpa, g);
                current = null;
            }
            in_block = std.mem.eql(u8, line, "grounded_in:");
            continue;
        }
        if (!in_block) continue;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (current) |g| try out.append(gpa, g);
            current = .{ .path = "", .lines = "", .digest = "" };
            const rest = std.mem.trimStart(u8, trimmed[2..], " \t");
            if (fieldValue(rest, "path")) |v| current.?.path = v;
        } else if (current != null) {
            if (fieldValue(trimmed, "path")) |v| current.?.path = v;
            if (fieldValue(trimmed, "lines")) |v| current.?.lines = v;
            if (fieldValue(trimmed, "digest")) |v| current.?.digest = v;
        }
    }
    if (current) |g| try out.append(gpa, g);
    return out;
}

fn fieldValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, std.mem.trimStart(u8, line[key.len + 1 ..], " \t"), "\"");
}

/// Lines `start..end` of `content`, 1-based and inclusive, as
/// `sed -n 'start,endp'` emits them: each line keeps its terminating
/// newline; a final line with none gets none added.
pub fn slice(content: []const u8, start: usize, end: usize) ?[]const u8 {
    if (start == 0 or end < start) return null;
    var line: usize = 1;
    var at: usize = 0;
    var from: ?usize = null;
    while (at <= content.len) {
        if (line == start and from == null) from = at;
        const nl = std.mem.indexOfScalarPos(u8, content, at, '\n');
        const line_end = nl orelse content.len;
        if (line == end) {
            const stop = if (nl) |n| n + 1 else content.len;
            return content[(from orelse return null)..stop];
        }
        if (nl == null) break;
        at = line_end + 1;
        line += 1;
    }
    // Ran past the end of the file -- null, not a short slice that would
    // hash wrong for an unrelated reason.
    return null;
}

pub fn sha256Hex(content: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &raw, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return hex;
}

/// Where a recorded range's content is now, if anywhere -- a same-length
/// window slid through the file until a candidate span's hash matches.
/// O(lines), and only run after the direct check already failed.
pub fn findMoved(content: []const u8, span: usize, digest: []const u8) ?Range {
    if (span == 0) return null;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |_| total += 1;
    // A trailing newline doesn't add a line (matches `wc -l`).
    if (content.len != 0 and content[content.len - 1] == '\n') total -= 1;

    var start: usize = 1;
    while (start + span - 1 <= total) : (start += 1) {
        const candidate = slice(content, start, start + span - 1) orelse continue;
        if (std.mem.eql(u8, &sha256Hex(candidate), digest))
            return .{ .start = start, .end = start + span - 1 };
    }
    return null;
}

const testing = std.testing;

test "blobHash is git's object hash, header included" {
    // sha1("blob 0\0") -- git's hash of an empty blob.
    try testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        &blobHash(""),
    );
    // sha1("blob 12\0hello world\n")
    try testing.expectEqualStrings(
        "3b18e512dba79e4c8300dd08aeb37f8e728b8dad",
        &blobHash("hello world\n"),
    );
}

test "staleness checks in the order that makes each answer meaningful" {
    const gpa = testing.allocator;
    try testing.expectEqual(Staleness.node_file_missing, try staleness(gpa, false, null, &.{}, &.{}, &.{}));
    try testing.expectEqual(Staleness.no_digest, try staleness(gpa, true, null, &.{"a"}, &.{}, &.{}));
    try testing.expectEqual(Staleness.no_digest, try staleness(gpa, true, "", &.{"a"}, &.{}, &.{}));
    try testing.expectEqual(Staleness.no_sources, try staleness(gpa, true, "d", &.{}, &.{}, &.{}));
}

test "a gone source is named rather than hashed" {
    const gpa = testing.allocator;
    const result = try staleness(gpa, true, "d", &.{ "a.java", "b.java" }, &.{"b.java"}, &.{});
    const text = try result.reason(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("source files gone: b.java", text);
}

test "several gone sources are space separated with no trailing space" {
    const gpa = testing.allocator;
    const result = Staleness{ .sources_gone = &.{ "a.java", "b.java", "c.java" } };
    const text = try result.reason(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("source files gone: a.java b.java c.java", text);
}

test "matching hashes are clean, and one changed hash is content changed" {
    const gpa = testing.allocator;
    const paths = [_][]const u8{ "a.java", "b.java" };
    const hashes = [_][]const u8{
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
    };
    var srcs: [2]node_mod.Source = .{
        .{ .path = paths[0], .hash = hashes[0] },
        .{ .path = paths[1], .hash = hashes[1] },
    };
    const digest = try node_mod.sourcesDigest(gpa, &srcs);

    try testing.expectEqual(
        Staleness.clean,
        try staleness(gpa, true, &digest, &paths, &.{}, &hashes),
    );

    const moved_on = [_][]const u8{
        "1111111111111111111111111111111111111111",
        "9999999999999999999999999999999999999999",
    };
    try testing.expectEqual(
        Staleness.content_changed,
        try staleness(gpa, true, &digest, &paths, &.{}, &moved_on),
    );
}

const grounded_sample =
    \\---
    \\title: "Premium"
    \\sources:
    \\  - path: lib/calc.ml
    \\    hash: 1111111111111111111111111111111111111111
    \\grounded_in:
    \\  - path: lib/calc.ml
    \\    lines: "1-2"
    \\    digest: aaaa
    \\  - path: lib/other.ml
    \\    lines: "10-12"
    \\    digest: bbbb
    \\stale: false
    \\---
    \\
    \\# Premium
    \\
;

test "groundings are read from their own block, with lines and digest" {
    const gpa = testing.allocator;
    var got = try groundings(gpa, grounded_sample);
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("lib/calc.ml", got.items[0].path);
    try testing.expectEqualStrings("1-2", got.items[0].lines);
    try testing.expectEqualStrings("aaaa", got.items[0].digest);
    try testing.expectEqualStrings("lib/other.ml", got.items[1].path);
    try testing.expectEqualStrings("10-12", got.items[1].lines);

    const r = got.items[1].range().?;
    try testing.expectEqual(@as(usize, 10), r.start);
    try testing.expectEqual(@as(usize, 12), r.end);
}

test "a node with no grounded_in block yields none" {
    const gpa = testing.allocator;
    var got = try groundings(gpa, "---\ntitle: t\nsources:\n  - path: a\n    hash: b\n---\n\n# T\n");
    defer got.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), got.items.len);
}

test "slice matches sed -n start,endp, newlines included" {
    const content = "one\ntwo\nthree\nfour\n";
    try testing.expectEqualStrings("one\ntwo\n", slice(content, 1, 2).?);
    try testing.expectEqualStrings("three\n", slice(content, 3, 3).?);
    try testing.expectEqualStrings("two\nthree\nfour\n", slice(content, 2, 4).?);
}

test "slice copes with a file whose last line has no newline" {
    const content = "one\ntwo\nthree";
    try testing.expectEqualStrings("three", slice(content, 3, 3).?);
    try testing.expectEqualStrings("two\nthree", slice(content, 2, 3).?);
}

test "a range past the end of the file is null, not a short slice" {
    try testing.expectEqual(@as(?[]const u8, null), slice("one\ntwo\n", 2, 9));
    try testing.expectEqual(@as(?[]const u8, null), slice("one\n", 0, 1));
    try testing.expectEqual(@as(?[]const u8, null), slice("one\n", 3, 2));
}

test "findMoved locates a range that shifted, and gives up when it changed" {
    const original = "alpha\nbeta\n";
    const digest = sha256Hex(original);

    // Two lines inserted above: the same content now sits at 3-4.
    const shifted = "new\nlines\nalpha\nbeta\ntail\n";
    const found = findMoved(shifted, 2, &digest).?;
    try testing.expectEqual(@as(usize, 3), found.start);
    try testing.expectEqual(@as(usize, 4), found.end);

    // Edited rather than moved: no window matches.
    const edited = "new\nlines\nalpha\nBETA\ntail\n";
    try testing.expectEqual(@as(?Range, null), findMoved(edited, 2, &digest));
}

test "findMoved finds a range still in place" {
    const content = "a\nb\nc\n";
    const digest = sha256Hex("b\n");
    const found = findMoved(content, 1, &digest).?;
    try testing.expectEqual(@as(usize, 2), found.start);
}
