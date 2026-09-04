//! Frontmatter mutation: a single-key, byte-preserving write to a note's
//! YAML frontmatter block. The safe alternative to `vault_patch`'s
//! `frontmatter` target, which re-serializes the entire block and silently
//! turns an array value into a quoted string -- `tags: '["a", "b"]'`
//! instead of a real flow sequence. This module never touches a byte
//! outside the one line it's asked to change.
//!
//! Scoped to flat `key: value` and `key: [a, b]` lines. A block-style value
//! (`sources:` with nested `- path:` entries) is out of scope -- `set` only
//! ever replaces the single line matching `key`, never a whole block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const query = @import("query.zig");
const emit = @import("emit.zig");

pub const Value = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
};

/// Sets one frontmatter key to `value`, preserving every other byte of
/// `note_bytes` -- quoting, ordering, and whitespace on every other line
/// included. Inserts a fresh line just before the closing `---` when `key`
/// isn't already present.
pub fn set(gpa: Allocator, note_bytes: []const u8, key: []const u8, value: Value) ![]u8 {
    const close = frontmatterEnd(note_bytes) orelse return error.NoFrontmatter;

    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try line.writer.print("{s}: ", .{key});
    try writeValue(&line.writer, value);
    const new_line = line.writer.buffered();

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(gpa);

    if (findKeyLine(note_bytes, close, key)) |span| {
        try result.appendSlice(gpa, note_bytes[0..span.start]);
        try result.appendSlice(gpa, new_line);
        try result.appendSlice(gpa, note_bytes[span.end..]);
    } else {
        try result.appendSlice(gpa, note_bytes[0..close]);
        try result.appendSlice(gpa, new_line);
        try result.append(gpa, '\n');
        try result.appendSlice(gpa, note_bytes[close..]);
    }

    return result.toOwnedSlice(gpa);
}

/// Adds `tag` to the `tags` list if it isn't already there. A no-op copy
/// (same bytes, freshly allocated) if it is.
pub fn addTag(gpa: Allocator, note_bytes: []const u8, tag: []const u8) ![]u8 {
    const current = try parseTags(gpa, note_bytes);
    defer gpa.free(current);
    for (current) |t| {
        if (std.mem.eql(u8, t, tag)) return gpa.dupe(u8, note_bytes);
    }

    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next.deinit(gpa);
    try next.appendSlice(gpa, current);
    try next.append(gpa, tag);
    return set(gpa, note_bytes, "tags", .{ .list = next.items });
}

/// Removes `tag` from the `tags` list. A missing entry (or a missing
/// `tags` field) is a no-op, not an error. The field survives an
/// empty-after-removal list as `tags: []`, never deleted outright.
pub fn removeTag(gpa: Allocator, note_bytes: []const u8, tag: []const u8) ![]u8 {
    const current = try parseTags(gpa, note_bytes);
    defer gpa.free(current);

    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next.deinit(gpa);
    var changed = false;
    for (current) |t| {
        if (std.mem.eql(u8, t, tag)) {
            changed = true;
            continue;
        }
        try next.append(gpa, t);
    }
    if (!changed) return gpa.dupe(u8, note_bytes);
    return set(gpa, note_bytes, "tags", .{ .list = next.items });
}

/// The byte offset where the frontmatter's closing `---` line begins, or
/// null when `text` has no frontmatter at all -- same opening check
/// `query.FrontmatterIterator` uses.
fn frontmatterEnd(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, "---\n")) return null;
    var idx: usize = 4;
    while (idx < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, idx, '\n') orelse return null;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, text[idx..nl], "\r"), "---")) return idx;
        idx = nl + 1;
    }
    return null;
}

/// The `[start, end)` byte span of the line whose key anchor-matches `key`,
/// scanning only inside the frontmatter (`[4, close)`). `end` excludes the
/// line's trailing newline, so the caller decides what replaces it.
fn findKeyLine(text: []const u8, close: usize, key: []const u8) ?struct { start: usize, end: usize } {
    var idx: usize = 4;
    while (idx < close) {
        const nl = std.mem.indexOfScalarPos(u8, text, idx, '\n') orelse close;
        const line_end = @min(nl, close);
        if (query.isKeyLine(text[idx..line_end], key)) return .{ .start = idx, .end = line_end };
        if (nl >= close) break;
        idx = nl + 1;
    }
    return null;
}

fn writeValue(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .scalar => |s| try writeScalar(w, s),
        .list => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writeScalar(w, item);
            }
            try w.writeByte(']');
        },
    }
}

fn writeScalar(w: *std.Io.Writer, s: []const u8) !void {
    if (!needsQuoting(s)) return w.writeAll(s);
    try w.writeByte('"');
    try emit.writeYamlQuoted(w, s);
    try w.writeByte('"');
}

/// Whether `s` needs a quoted scalar to round-trip as the string it is,
/// rather than something a YAML reader would parse differently. Not a full
/// YAML grammar -- just the shapes this codebase's own values ever take.
fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return true;
    if (std.mem.indexOf(u8, s, ": ") != null or std.mem.endsWith(u8, s, ":")) return true;
    if (std.mem.indexOf(u8, s, " #") != null) return true;
    if (std.mem.indexOfScalar(u8, s, '\n') != null) return true;
    switch (s[0]) {
        '"', '\'', '#', '&', '*', '!', '|', '>', '%', '@', '`', '[', ']', '{', '}', ',' => return true,
        else => {},
    }
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~")) return true;
    // An all-digit scalar reads back as a YAML integer, not a string, once
    // unquoted -- a numeric-looking title or id round-trips as the wrong type.
    if (isAllDigits(s)) return true;
    return false;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The current `tags: [a, b]` flow sequence, unquoted and split. Empty when
/// `tags` is absent, empty (`[]`), or not written as a flow sequence --
/// `set`/`addTag`/`removeTag` only ever produce the flow-sequence form, so
/// any note they've touched already reads back correctly.
fn parseTags(gpa: Allocator, note_bytes: []const u8) ![]const []const u8 {
    const raw = query.field(note_bytes, "tags") orelse return &.{};
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return &.{};
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        var t = std.mem.trim(u8, item, " \t");
        if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
        try out.append(gpa, t);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

const note =
    \\---
    \\title: "State machine"
    \\project: sb
    \\tags: [synapse, vault-infra]
    \\sources:
    \\  - path: src/main.zig
    \\    hash: 1111111111111111111111111111111111111111
    \\status: TODO
    \\---
    \\
    \\# State machine
    \\
    \\tags: fake decoy in the body
    \\
;

test "scalar set on an existing key replaces only that line" {
    const got = try set(testing.allocator, note, "status", .{ .scalar = "IN-PROGRESS" });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "status: IN-PROGRESS\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "status: TODO") == null);
    // Everything else, byte for byte.
    try testing.expect(std.mem.indexOf(u8, got, "title: \"State machine\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "tags: [synapse, vault-infra]\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  - path: src/main.zig\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "tags: fake decoy in the body\n") != null);
}

test "scalar set inserting a new key appends before the closing marker" {
    const got = try set(testing.allocator, note, "priority", .{ .scalar = "high" });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "status: TODO\npriority: high\n---\n") != null);
}

test "array set on an existing scalar key changes its type" {
    const got = try set(testing.allocator, note, "status", .{ .list = &.{ "a", "b" } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "status: [a, b]\n") != null);
}

test "array set on an absent key inserts a real flow sequence" {
    const got = try set(testing.allocator, note, "reviewers", .{ .list = &.{ "alice", "bob" } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "reviewers: [alice, bob]\n") != null);
}

test "the sb-036 regression: a tags array round-trips as a real list, never a quoted string" {
    const got = try set(testing.allocator, note, "tags", .{ .list = &.{ "synapse", "vault-infra", "architecture" } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "tags: [synapse, vault-infra, architecture]\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "tags: '[") == null);
    try testing.expect(std.mem.indexOf(u8, got, "tags: \"[") == null);
}

test "a value needing quotes is quoted, and only that value" {
    const got = try set(testing.allocator, note, "title", .{ .scalar = "a: title with a colon" });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "title: \"a: title with a colon\"\n") != null);
}

test "an all-digit scalar is quoted, so it round-trips as a string not an integer" {
    const got = try set(testing.allocator, note, "title", .{ .scalar = "123" });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "title: \"123\"\n") != null);
}

test "no frontmatter at all is an error, not a guess" {
    try testing.expectError(error.NoFrontmatter, set(testing.allocator, "# Just prose\n", "status", .{ .scalar = "x" }));
}

test "addTag on a note with no tags field creates one" {
    const bare =
        \\---
        \\title: "x"
        \\---
        \\body
        \\
    ;
    const got = try addTag(testing.allocator, bare, "synapse");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "tags: [synapse]\n") != null);
}

test "addTag appends to an existing list without duplicating an already-present tag" {
    const got1 = try addTag(testing.allocator, note, "zig");
    defer testing.allocator.free(got1);
    try testing.expect(std.mem.indexOf(u8, got1, "tags: [synapse, vault-infra, zig]\n") != null);

    const got2 = try addTag(testing.allocator, note, "synapse");
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings(note, got2);
}

test "removeTag on the only tag leaves an explicit empty list, not a deleted field" {
    const one_tag =
        \\---
        \\title: "x"
        \\tags: [synapse]
        \\---
        \\body
        \\
    ;
    const got = try removeTag(testing.allocator, one_tag, "synapse");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "tags: []\n") != null);
}

test "removeTag on an absent tag is a no-op, not an error" {
    const got = try removeTag(testing.allocator, note, "nonexistent");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(note, got);
}
