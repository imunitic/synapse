//! `query symbol <name> <node>`: is this symbol still in the node's sources?
//!
//! The answer comes from the tags cache, never from a fresh parse -- and reading
//! that cache is the whole performance story. The version before it ran `jq` once
//! per source path, so cost was `node_sources x cache_bytes` rather than
//! `cache_bytes`, and a 159-file node against a large repo's 800 MB cache did not
//! finish in 600 seconds. The bash then fixed that with one `synapse tags-cache
//! --dump` and an `awk` join over the projection.
//!
//! In process there is no projection to join: `tags_cache.Cache.get` is the lookup
//! the dump was standing in for. So what lives here is the part that was never
//! about transport -- which tag lines match a name, what the three possible answers
//! about a path are, and whose order the output follows.
//!
//! ## Three answers, and only one of them is silence
//!
//! A path can be absent from the cache, present but unparseable, or checked. Only
//! the third produces stdout, and only when the name actually matched -- "checked,
//! symbol not present" is silence, like every other reporting subcommand. The first
//! two are diagnostics, and they are reported *distinctly*: conflating "I did not
//! look" with "I looked and it is gone" is how a caller comes to trust an empty
//! answer it should have distrusted.

const std = @import("std");
const tags_cache = @import("tags_cache.zig");

/// What the cache knows about one requested path.
pub const Outcome = union(enum) {
    /// No entry at all. The cache has not seen this file, which a backfill fixes.
    not_cached,
    /// Cached, but no grammar, no tree-sitter, or no C compiler, so it was never
    /// parsed. Distinct from `not_cached` because backfilling will not help.
    unsupported,
    /// Parsed. Carries the entry's whole tag text, for `matches` to walk. Empty is
    /// a real value: a file with no tags at all was still checked.
    checked: []const u8,
};

pub fn outcomeFor(entry: ?tags_cache.Entry) Outcome {
    const e = entry orelse return .not_cached;
    if (e.unsupported) return .unsupported;
    return .{ .checked = e.tags };
}

/// The tag lines in `tags` whose name is exactly `name`.
///
/// The name is the line's own first tab-separated field, space-padded by
/// tree-sitter's table output, so it is compared trimmed. Exactly, not by prefix:
/// a prefix match would answer a query about `Token` with every `Tokenizer` in
/// the file, and the whole point of this lookup is that it is exact.
pub fn matches(tags: []const u8, name: []const u8) MatchIterator {
    return .{ .lines = std.mem.splitScalar(u8, tags, '\n'), .name = name };
}

pub const MatchIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    name: []const u8,

    /// Yields the matching line verbatim -- padding, kind and span included. The
    /// caller prints what tree-sitter wrote rather than a re-rendered version of
    /// it, because a re-rendered tag line is a second format to keep in step.
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

/// The requested paths, in the order the node listed them.
///
/// Output order comes from the node's own source list and never from the cache,
/// which is sorted by path -- a report that silently reorders is a report a human
/// cannot diff against the node. Empty lines are skipped rather than reported as
/// uncached paths.
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

/// Tag text as the cache stores it: newline-joined lines, each one tree-sitter's
/// own, with the padding and internal tabs it really emits.
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
    // Both hits, in cache order: a def and a ref are two answers, not one.
    try testing.expect(std.mem.indexOf(u8, it.next().?, "ref (31, 4)") != null);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "the name matches exactly, so a longer symbol is not a hit" {
    var it = matches(sample_tags, "Token");
    while (it.next()) |line| {
        try testing.expect(std.mem.indexOf(u8, line, "Tokenizer") == null);
    }
    // And the converse: a prefix of a real name matches nothing.
    var none = matches(sample_tags, "Tokeniz");
    try testing.expectEqual(@as(?[]const u8, null), none.next());
}

test "a tag line with no tab is still matchable by its whole text" {
    // Not a shape tree-sitter emits, but a cache holds whatever was written to it,
    // and a reader that indexed field 2 unconditionally would fail here rather
    // than simply not matching.
    var it = matches("bare\n", "bare");
    try testing.expectEqualStrings("bare", it.next().?);
}

test "the three answers stay distinct" {
    try testing.expectEqual(Outcome.not_cached, outcomeFor(null));
    try testing.expectEqual(
        Outcome.unsupported,
        outcomeFor(.{ .hash = @splat(0), .tags = "", .unsupported = true }),
    );
    // Checked with no tags is not the same as not checked: the file was parsed and
    // has nothing, which is silence rather than a diagnostic.
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
