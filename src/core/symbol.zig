//! `query symbol <name> <node>`: is this symbol still in the node's sources?
//! Answered from the tags cache (`tags_cache.Cache.get`), never a fresh
//! parse -- a per-path `jq` shelled out for this used to cost
//! `node_sources x cache_bytes` and could exceed 600s on a large repo.
//!
//! Three answers about a path: absent, unsupported (no grammar/compiler,
//! backfilling won't help), or checked. Only "checked and the name matched"
//! prints; "checked, not present" is silence like every other reporting
//! subcommand. The other two are reported as distinct diagnostics --
//! conflating "didn't look" with "looked and it's gone" is how a caller
//! comes to trust an empty answer it shouldn't.

const std = @import("std");
const tags_cache = @import("tags_cache.zig");

/// What the cache knows about one requested path.
pub const Outcome = union(enum) {
    /// Not seen at all; a backfill fixes this.
    not_cached,
    /// Seen but never parsed (no grammar/compiler); backfilling won't help.
    unsupported,
    /// Parsed. Whole tag text, for `matches` to walk. Empty is real: a file
    /// with no tags was still checked.
    checked: []const u8,
};

pub fn outcomeFor(entry: ?tags_cache.Entry) Outcome {
    const e = entry orelse return .not_cached;
    if (e.unsupported) return .unsupported;
    return .{ .checked = e.tags };
}

/// Tag lines in `tags` whose name is exactly `name` (trimmed first field --
/// space-padded by tree-sitter's table output). Exact, not prefix: a prefix
/// match would answer a `Token` query with every `Tokenizer` too.
pub fn matches(tags: []const u8, name: []const u8) MatchIterator {
    return .{ .lines = std.mem.splitScalar(u8, tags, '\n'), .name = name };
}

pub const MatchIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    name: []const u8,

    /// Yields the matching line verbatim (padding, kind, span included) --
    /// prints what tree-sitter wrote, not a re-rendered copy.
    pub fn next(self: *MatchIterator) ?[]const u8 {
        while (self.lines.next()) |line| {
            if (line.len == 0) continue;
            const end = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..end], " \t"), self.name))
                return line;
        }
        return null;
    }
};

/// Requested paths, in the node's own listed order (not the cache's path
/// sort) -- so the report stays diffable against the node. Blank lines skipped.
pub fn requestedPaths(text: []const u8) PathIterator {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

pub const PathIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *PathIterator) ?[]const u8 {
        while (self.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            return line;
        }
        return null;
    }
};

const testing = std.testing;

/// Tag text as the cache stores it: newline-joined tree-sitter lines, real
/// padding and tabs included.
const sample_tags =
    "Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`\n" ++
    "Tokenizer \t | class   \tdef (20, 13) - (20, 22) `class Tokenizer {`\n" ++
    "Token     \t | method  \tref (31, 4) - (31, 9) `new Token();`";

test "a match keeps the tag line verbatim, padding and all" {
    var it = matches(sample_tags, "Token");
    try testing.expectEqualStrings(
        "Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`",
        it.next().?,
    );
    // Both hits, in cache order: def and ref are two answers, not one.
    try testing.expect(std.mem.indexOf(u8, it.next().?, "ref (31, 4)") != null);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "the name matches exactly, so a longer symbol is not a hit" {
    var it = matches(sample_tags, "Token");
    while (it.next()) |line| {
        try testing.expect(std.mem.indexOf(u8, line, "Tokenizer") == null);
    }
    // A prefix of a real name matches nothing.
    var none = matches(sample_tags, "Tokeniz");
    try testing.expectEqual(@as(?[]const u8, null), none.next());
}

test "a tag line with no tab is still matchable by its whole text" {
    // Not a shape tree-sitter emits, but the cache holds whatever was written.
    var it = matches("bare\n", "bare");
    try testing.expectEqualStrings("bare", it.next().?);
}

test "the three answers stay distinct" {
    try testing.expectEqual(Outcome.not_cached, outcomeFor(null));
    try testing.expectEqual(
        Outcome.unsupported,
        outcomeFor(.{ .hash = @splat(0), .tags = "", .unsupported = true }),
    );
    // Checked-with-no-tags is not the same as not-checked.
    const checked = outcomeFor(.{ .hash = @splat(0), .tags = "", .unsupported = false });
    try testing.expectEqualStrings("", checked.checked);
}

test "requested order is the node's order, and blank lines are not paths" {
    var it = requestedPaths("b.java\n\na.java\nc.java\n");
    try testing.expectEqualStrings("b.java", it.next().?);
    try testing.expectEqualStrings("a.java", it.next().?);
    try testing.expectEqualStrings("c.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "a path list with no trailing newline yields its last path" {
    var it = requestedPaths("only.java");
    try testing.expectEqualStrings("only.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}
