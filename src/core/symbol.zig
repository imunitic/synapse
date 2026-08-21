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
const model = @import("model");

/// What the cache knows about one requested path.
pub const Outcome = union(enum) {
    /// Not seen at all; a backfill fixes this.
    not_cached,
    /// Seen but never parsed (no grammar/compiler); backfilling won't help.
    unsupported,
    /// Parsed. The raw encoded payload, for `matches` to walk. Empty is
    /// real: a file with no tags was still checked.
    checked: []const u8,
};

pub fn outcomeFor(entry: ?tags_cache.Entry) Outcome {
    const e = entry orelse return .not_cached;
    if (e.unsupported) return .unsupported;
    return .{ .checked = e.tags };
}

/// Tags in `tags` whose name is exactly `name` (already trimmed -- `Tag.name`
/// never carries tree-sitter's own table padding). Exact, not prefix: a
/// prefix match would answer a `Token` query with every `Tokenizer` too.
pub fn matches(tags: []const u8, name: []const u8) MatchIterator {
    return .{ .tags = tags_cache.payload.iterate(tags), .name = name };
}

pub const MatchIterator = struct {
    tags: tags_cache.payload.Iterator,
    name: []const u8,

    /// Yields the matching `Tag` itself, not a rendered line -- what a
    /// match looks like on screen is the caller's decision, not this one's.
    pub fn next(self: *MatchIterator) ?model.Tag {
        while (self.tags.next()) |tag| {
            if (std.mem.eql(u8, tag.name, self.name)) return tag;
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

/// The payload bytes `matches` walks, encoded from the same three tags the
/// old rendered-text fixture held: two `Token`s (a def and a ref) and one
/// `Tokenizer` def, so a prefix match has something real to fail against.
fn sampleTags(gpa: std.mem.Allocator) ![]u8 {
    return tags_cache.payload.encode(gpa, &.{
        .{ .name = "Token", .role = .def, .kind = "class", .line = 15, .expression = "public class Token {" },
        .{ .name = "Tokenizer", .role = .def, .kind = "class", .line = 20, .expression = "class Tokenizer {" },
        .{ .name = "Token", .role = .ref, .kind = "method", .line = 31, .expression = "new Token();" },
    });
}

test "a match yields the tag itself, every field intact" {
    const gpa = testing.allocator;
    const tags = try sampleTags(gpa);
    defer gpa.free(tags);

    var it = matches(tags, "Token");
    const first = it.next().?;
    try testing.expectEqual(model.Role.def, first.role);
    try testing.expectEqual(@as(u32, 15), first.line);
    try testing.expectEqualStrings("public class Token {", first.expression);
    // Both hits, in cache order: def and ref are two answers, not one.
    const second = it.next().?;
    try testing.expectEqual(model.Role.ref, second.role);
    try testing.expectEqual(@as(u32, 31), second.line);
    try testing.expectEqual(@as(?model.Tag, null), it.next());
}

test "the name matches exactly, so a longer symbol is not a hit" {
    const gpa = testing.allocator;
    const tags = try sampleTags(gpa);
    defer gpa.free(tags);

    var it = matches(tags, "Token");
    while (it.next()) |tag| {
        try testing.expect(!std.mem.eql(u8, tag.name, "Tokenizer"));
    }
    // A prefix of a real name matches nothing.
    var none = matches(tags, "Tokeniz");
    try testing.expectEqual(@as(?model.Tag, null), none.next());
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
