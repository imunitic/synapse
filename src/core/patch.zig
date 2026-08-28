//! Targeted partial-update composition over three target kinds
//! (`heading`/`block`/`frontmatter`), built once over `ports.Store`'s plain
//! `read`/`write` -- not a new `Store` method, and not per-backend, since
//! the splice logic is identical no matter which backend the bytes came
//! from. `read` the node, splice the requested target against the fetched
//! body in memory, `write` the whole result back.
//!
//! The `frontmatter` target delegates entirely to `core.frontmatter.set`,
//! already byte-preserving and already tested -- this module only adds the
//! `heading`/`block` splicing `frontmatter.zig` never needed.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");

const Allocator = std.mem.Allocator;

pub const Target = union(enum) {
    /// The path of heading texts from the top down, e.g. `&.{"Notes"}` or
    /// `&.{ "Notes", "Implementation" }` -- disambiguates a heading nested
    /// under a same-named parent from any other heading with that name.
    heading: []const []const u8,
    /// A bare block id, without the leading `^`.
    block: []const u8,
    /// A frontmatter key.
    frontmatter: []const u8,
};

pub const Operation = enum { append, prepend, replace };

pub const Error = error{
    /// The target wasn't found and `create_if_missing` was false.
    TargetNotFound,
    /// A `frontmatter` target on a note with no frontmatter block at all.
    NoFrontmatter,
    /// Surfaced from `core.frontmatter.set`'s internal `std.Io.Writer` use.
    WriteFailed,
} || Allocator.Error;

/// Applies `op` with `content` at `target` inside `body`, returning the
/// whole new document. `create_if_missing` only affects `heading` (a
/// missing frontmatter key is always inserted, matching
/// `core.frontmatter.set`'s own behavior; a missing block cannot be
/// created -- there is no sensible place to put an id no content already
/// carries).
pub fn apply(
    gpa: Allocator,
    body: []const u8,
    target: Target,
    op: Operation,
    content: []const u8,
    create_if_missing: bool,
) Error![]u8 {
    return switch (target) {
        .frontmatter => |key| frontmatter.set(gpa, body, key, .{ .scalar = content }) catch |e| switch (e) {
            error.NoFrontmatter => Error.NoFrontmatter,
            else => |other| other,
        },
        .heading => |path| applyHeading(gpa, body, path, op, content, create_if_missing),
        .block => |id| applyBlock(gpa, body, id, op, content),
    };
}

const Heading = struct {
    level: u8,
    text: []const u8,
    /// Start of the heading's own line (the `#` character).
    line_start: usize,
    /// Start of the heading's content -- the byte right after the heading
    /// line's trailing newline (or `body.len` if the heading is the last
    /// line in the document with no trailing newline).
    content_start: usize,
};

/// Every `#`-`######` heading in `body`, in document order. A line inside a
/// fenced code block would be misread as a heading by this scan -- an
/// accepted simplification, matching the same "no fenced-code awareness"
/// scope every other line-oriented scan in this codebase already has
/// (`core.query.field`, `frontmatter.zig`'s own `findKeyLine`).
fn scanHeadings(gpa: Allocator, body: []const u8) ![]Heading {
    var out: std.ArrayListUnmanaged(Heading) = .empty;
    errdefer out.deinit(gpa);

    var idx: usize = 0;
    while (idx < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, idx, '\n');
        const line_end = nl orelse body.len;
        const line = body[idx..line_end];

        var level: u8 = 0;
        while (level < line.len and level < 6 and line[level] == '#') level += 1;
        if (level > 0 and level < line.len and line[level] == ' ') {
            const text = std.mem.trim(u8, line[level + 1 ..], " \t\r");
            try out.append(gpa, .{
                .level = level,
                .text = text,
                .line_start = idx,
                .content_start = if (nl) |n| n + 1 else body.len,
            });
        }

        if (nl == null) break;
        idx = line_end + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The index into `headings` of the next heading at or above `level`,
/// starting the scan at `from` -- the boundary that ends a section. Returns
/// `headings.len` when nothing shallower-or-equal follows.
fn sectionEnd(headings: []const Heading, from: usize, level: u8) usize {
    var i = from;
    while (i < headings.len) : (i += 1) {
        if (headings[i].level <= level) return i;
    }
    return i;
}

/// Walks `path` down the heading tree. Each segment after the first is
/// searched only within the immediately preceding match's own section
/// (its index range up to `sectionEnd`), so a name repeated under two
/// different parents resolves to the right one. The first occurrence wins
/// on a duplicate within the same scope -- disambiguating further would
/// need a marker-suffix key scheme, out of scope here.
fn findHeadingPath(headings: []const Heading, path: []const []const u8) ?usize {
    var search_start: usize = 0;
    var search_end: usize = headings.len;
    var found: ?usize = null;

    for (path) |seg| {
        var idx: ?usize = null;
        var i = search_start;
        while (i < search_end) : (i += 1) {
            if (std.mem.eql(u8, headings[i].text, seg)) {
                idx = i;
                break;
            }
        }
        const at = idx orelse return null;
        found = at;
        search_start = at + 1;
        search_end = sectionEnd(headings, at + 1, headings[at].level);
    }
    return found;
}

fn applyHeading(
    gpa: Allocator,
    body: []const u8,
    path: []const []const u8,
    op: Operation,
    content: []const u8,
    create_if_missing: bool,
) Error![]u8 {
    const headings = try scanHeadings(gpa, body);
    defer gpa.free(headings);

    if (findHeadingPath(headings, path)) |at| {
        const h = headings[at];
        const end_idx = sectionEnd(headings, at + 1, h.level);
        const content_end = if (end_idx < headings.len) headings[end_idx].line_start else body.len;
        const touched_end = trimOneTrailingBlankLine(body, h.content_start, content_end);
        return spliceRange(gpa, body, h.content_start, touched_end, op, content);
    }

    if (!create_if_missing) return Error.TargetNotFound;
    return createHeadingPath(gpa, body, headings, path, content);
}

/// A section's own blank-line separator from the next heading (e.g. the
/// empty line between `Discussing\n` and `## Problem`) is part of the
/// document's structure, not part of the section's content -- `replace`ing
/// or `append`ing must never consume it, or the separator silently
/// disappears from the result. Strips exactly one trailing blank line
/// (`"\n\n"` right at `end`) from the touched range when present; more than
/// one blank line in a row is left as-is past the first, an edge case no
/// convention in this codebase's own notes actually produces.
fn trimOneTrailingBlankLine(body: []const u8, start: usize, end: usize) usize {
    if (end >= start + 2 and body[end - 1] == '\n' and body[end - 2] == '\n') return end - 1;
    return end;
}

/// Replaces, prepends to, or appends within `[start, end)`. `append`/
/// `prepend` insert `content` verbatim at the boundary, so the caller
/// supplies its own leading/trailing newline -- this function has no
/// opinion about spacing beyond where the insertion point is.
fn spliceRange(gpa: Allocator, body: []const u8, start: usize, end: usize, op: Operation, content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (op) {
        .replace => {
            try out.appendSlice(gpa, body[0..start]);
            try out.appendSlice(gpa, content);
            try out.appendSlice(gpa, body[end..]);
        },
        .prepend => {
            try out.appendSlice(gpa, body[0..start]);
            try out.appendSlice(gpa, content);
            try out.appendSlice(gpa, body[start..]);
        },
        .append => {
            try out.appendSlice(gpa, body[0..end]);
            try out.appendSlice(gpa, content);
            try out.appendSlice(gpa, body[end..]);
        },
    }
    return out.toOwnedSlice(gpa);
}

/// Creates whatever prefix of `path` doesn't already exist, deepest-first
/// append at the end of the document (no existing prefix matched) or at the
/// end of the deepest matching ancestor's own section. Every newly created
/// segment past the first gets one level deeper than its parent.
fn createHeadingPath(gpa: Allocator, body: []const u8, headings: []const Heading, path: []const []const u8, content: []const u8) Error![]u8 {
    // Find the deepest existing prefix of `path`, if any.
    var matched: usize = 0; // number of leading path segments that already exist
    var anchor: ?usize = null; // heading index of the deepest match
    var search_start: usize = 0;
    var search_end: usize = headings.len;
    while (matched < path.len) {
        var idx: ?usize = null;
        var i = search_start;
        while (i < search_end) : (i += 1) {
            if (std.mem.eql(u8, headings[i].text, path[matched])) {
                idx = i;
                break;
            }
        }
        const at = idx orelse break;
        anchor = at;
        matched += 1;
        search_start = at + 1;
        search_end = sectionEnd(headings, at + 1, headings[at].level);
    }

    var new_section: std.Io.Writer.Allocating = .init(gpa);
    defer new_section.deinit();
    const base_level: u8 = if (anchor) |a| headings[a].level else 1;
    for (path[matched..], 0..) |seg, offset| {
        const level: u8 = @intCast(@min(6, base_level + offset + 1));
        for (0..level) |_| try new_section.writer.writeByte('#');
        try new_section.writer.print(" {s}\n", .{seg});
    }
    try new_section.writer.writeAll(content);
    const section_text = new_section.writer.buffered();

    if (anchor) |a| {
        const h = headings[a];
        const end_idx = sectionEnd(headings, a + 1, h.level);
        const boundary = if (end_idx < headings.len) headings[end_idx].line_start else body.len;
        const insert_at = trimOneTrailingBlankLine(body, h.content_start, boundary);
        return spliceRange(gpa, body, insert_at, insert_at, .append, section_text);
    }

    // No prefix matched at all: append at the very end of the document,
    // with a separating blank line when the document doesn't already end
    // in one.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, body);
    if (body.len != 0 and !std.mem.endsWith(u8, body, "\n\n")) {
        try out.appendSlice(gpa, if (std.mem.endsWith(u8, body, "\n")) "\n" else "\n\n");
    }
    try out.appendSlice(gpa, section_text);
    return out.toOwnedSlice(gpa);
}

/// A block reference is a line ending in ` ^{id}` (a space, then the caret,
/// then the id, then end of line). Scoped to single-line blocks, the
/// overwhelmingly common real shape (one
/// paragraph or list item); a multi-line block would need real paragraph
/// boundary detection this doesn't attempt.
fn findBlockLine(body: []const u8, id: []const u8) ?struct { line_start: usize, text_end: usize, line_end: usize } {
    var idx: usize = 0;
    while (idx < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, idx, '\n');
        const line_end = nl orelse body.len;
        const line = body[idx..line_end];

        const suffix_len = 2 + id.len; // " ^" + id
        if (line.len >= suffix_len) {
            const suffix = line[line.len - suffix_len ..];
            if (suffix[0] == ' ' and suffix[1] == '^' and std.mem.eql(u8, suffix[2..], id)) {
                return .{ .line_start = idx, .text_end = line_end - suffix_len, .line_end = line_end };
            }
        }

        if (nl == null) break;
        idx = line_end + 1;
    }
    return null;
}

fn applyBlock(gpa: Allocator, body: []const u8, id: []const u8, op: Operation, content: []const u8) Error![]u8 {
    const found = findBlockLine(body, id) orelse return Error.TargetNotFound;
    return switch (op) {
        .replace => blk: {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, body[0..found.line_start]);
            try out.appendSlice(gpa, content);
            try out.appendSlice(gpa, body[found.text_end..]); // keeps " ^id"
            break :blk out.toOwnedSlice(gpa);
        },
        .prepend => spliceRange(gpa, body, found.line_start, found.line_start, .append, content),
        .append => spliceRange(gpa, body, found.text_end, found.text_end, .append, content),
    };
}

pub const DocumentMap = struct {
    /// `::`-joined heading paths, in document order -- each usable verbatim
    /// as a `--heading` target on its own.
    headings: []const []const u8,
    /// Bare block ids (no leading `^`), in document order.
    blocks: []const []const u8,
    /// Root-level frontmatter keys, in document order.
    frontmatter_keys: []const []const u8,

    pub fn deinit(self: *DocumentMap, gpa: Allocator) void {
        for (self.headings) |h| gpa.free(h);
        gpa.free(self.headings);
        for (self.blocks) |b| gpa.free(b);
        gpa.free(self.blocks);
        for (self.frontmatter_keys) |k| gpa.free(k);
        gpa.free(self.frontmatter_keys);
    }
};

/// Every valid `--heading`/`--block`/`--frontmatter` target in `body` --
/// covers the three target kinds `Target` supports, so a caller can pick a
/// real target instead of guessing one. No `version`/`ifMatch`-style
/// concurrency token: that guards a window between reading the map and
/// patching against a concurrent edit landing in between, a concern
/// specific to a live external app with its own in-memory buffer --
/// `apply` always works from a `Store.read` taken immediately before it
/// runs, so no such window exists here to guard against.
pub fn documentMap(gpa: Allocator, body: []const u8) !DocumentMap {
    const headings = try scanHeadings(gpa, body);
    defer gpa.free(headings);

    var heading_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (heading_paths.items) |p| gpa.free(p);
        heading_paths.deinit(gpa);
    }
    // Ancestor stack, by index into `headings` -- popped back to the last
    // entry shallower than the current heading, the same walk
    // `findHeadingPath` does implicitly one query segment at a time.
    var stack: std.ArrayListUnmanaged(usize) = .empty;
    defer stack.deinit(gpa);
    for (headings, 0..) |h, i| {
        while (stack.items.len > 0 and headings[stack.items[stack.items.len - 1]].level >= h.level) {
            _ = stack.pop();
        }
        try stack.append(gpa, i);

        var path: std.Io.Writer.Allocating = .init(gpa);
        defer path.deinit();
        for (stack.items, 0..) |idx, seg_i| {
            if (seg_i != 0) try path.writer.writeAll("::");
            try path.writer.writeAll(headings[idx].text);
        }
        try heading_paths.append(gpa, try gpa.dupe(u8, path.writer.buffered()));
    }

    const blocks = try scanBlockIds(gpa, body);
    errdefer {
        for (blocks) |b| gpa.free(b);
        gpa.free(blocks);
    }

    var fm_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (fm_keys.items) |k| gpa.free(k);
        fm_keys.deinit(gpa);
    }
    var it = @import("query.zig").FrontmatterIterator.init(body);
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue; // nested/continuation line
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (key.len == 0) continue;
        try fm_keys.append(gpa, try gpa.dupe(u8, key));
    }

    return .{
        .headings = try heading_paths.toOwnedSlice(gpa),
        .blocks = blocks,
        .frontmatter_keys = try fm_keys.toOwnedSlice(gpa),
    };
}

/// Every single-line block id in `body`, in document order -- lines ending
/// in ` ^{id}` where `id` is letters/digits/hyphens/underscores, the same
/// charset `vault_patch`'s own block-id target already documents. Caller
/// owns the returned slice and every string in it.
fn scanBlockIds(gpa: Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |id| gpa.free(id);
        out.deinit(gpa);
    }

    var idx: usize = 0;
    while (idx < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, idx, '\n');
        const line_end = nl orelse body.len;
        if (blockIdSuffix(body[idx..line_end])) |id| try out.append(gpa, try gpa.dupe(u8, id));

        if (nl == null) break;
        idx = line_end + 1;
    }
    return out.toOwnedSlice(gpa);
}

fn blockIdSuffix(line: []const u8) ?[]const u8 {
    const caret = std.mem.lastIndexOfScalar(u8, line, '^') orelse return null;
    if (caret == 0 or line[caret - 1] != ' ') return null;
    const id = line[caret + 1 ..];
    if (id.len == 0) return null;
    for (id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return null;
    }
    return id;
}

const testing = std.testing;

test "frontmatter target delegates to core.frontmatter.set" {
    const body = "---\ntitle: \"x\"\nstatus: TODO\n---\nbody\n";
    const got = try apply(testing.allocator, body, .{ .frontmatter = "status" }, .replace, "REVIEW", false);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "status: REVIEW\n") != null);
}

test "heading replace swaps the section's content, keeping the heading line and everything after the section" {
    const body = "# Title\n\n## Status\nDiscussing\n\n## Problem\nSomething.\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{"Status"} }, .replace, "Ready\n", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Status\nReady\n\n## Problem\nSomething.\n", got);
}

test "heading append adds at the end of the section, before the next heading" {
    const body = "# Title\n\n## Notes\n- first\n\n## Other\nx\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{"Notes"} }, .append, "- second\n", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\n- first\n- second\n\n## Other\nx\n", got);
}

test "heading prepend adds right after the heading line, before existing content" {
    const body = "# Title\n\n## Notes\n- first\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{"Notes"} }, .prepend, "- zeroth\n", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\n- zeroth\n- first\n", got);
}

test "a nested path resolves the second segment within the first's own section" {
    const body = "# Title\n\n## Notes\n### Sub\nold\n\n## Other\n### Sub\nunrelated\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{ "Notes", "Sub" } }, .replace, "new\n", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\n### Sub\nnew\n\n## Other\n### Sub\nunrelated\n", got);
}

test "a heading at the very end of the document has its section run to EOF" {
    const body = "# Title\n\n## Notes\nold\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{"Notes"} }, .replace, "new\n", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\nnew\n", got);
}

test "a missing heading with create_if_missing false errors, not a silent no-op" {
    const body = "# Title\n\nbody\n";
    try testing.expectError(
        error.TargetNotFound,
        apply(testing.allocator, body, .{ .heading = &.{"Nope"} }, .replace, "x", false),
    );
}

test "a missing heading with create_if_missing true appends a new section at document end" {
    const body = "# Title\n\n## Existing\nx\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{"New"} }, .replace, "content\n", true);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Existing\nx\n\n## New\ncontent\n", got);
}

test "creating a new nested section before its parent's trailing blank line preserves that separator" {
    const body = "# Title\n\n## Notes\nexisting\n\n## Other\nx\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{ "Notes", "Sub" } }, .replace, "new\n", true);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\nexisting\n### Sub\nnew\n\n## Other\nx\n", got);
}

test "a missing nested segment is created under the matching parent, one level deeper" {
    const body = "# Title\n\n## Notes\nexisting\n";
    const got = try apply(testing.allocator, body, .{ .heading = &.{ "Notes", "Sub" } }, .replace, "new\n", true);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\n## Notes\nexisting\n### Sub\nnew\n", got);
}

test "block replace swaps the line's text, keeping the ^id suffix" {
    const body = "# Title\n\nOld text ^my-block\n\nMore.\n";
    const got = try apply(testing.allocator, body, .{ .block = "my-block" }, .replace, "New text", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Title\n\nNew text ^my-block\n\nMore.\n", got);
}

test "block append inserts before the ^id suffix, on the same line" {
    const body = "Text ^my-block\n";
    const got = try apply(testing.allocator, body, .{ .block = "my-block" }, .append, " more", false);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Text more ^my-block\n", got);
}

test "a missing block id errors, never creates one out of nowhere" {
    const body = "no blocks here\n";
    try testing.expectError(
        error.TargetNotFound,
        apply(testing.allocator, body, .{ .block = "nope" }, .replace, "x", false),
    );
}

test "no frontmatter at all on a frontmatter target is its own distinct error" {
    try testing.expectError(
        error.NoFrontmatter,
        apply(testing.allocator, "# Just prose\n", .{ .frontmatter = "status" }, .replace, "x", false),
    );
}

test "documentMap lists nested heading paths, ::-joined, each a valid --heading target" {
    const body = "---\ntitle: \"x\"\nstatus: TODO\n---\n\n# Title\n\n## Notes\n### Sub\nold\n\n## Other\nx\n";
    var map = try documentMap(testing.allocator, body);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), map.headings.len);
    try testing.expectEqualStrings("Title", map.headings[0]);
    try testing.expectEqualStrings("Title::Notes", map.headings[1]);
    try testing.expectEqualStrings("Title::Notes::Sub", map.headings[2]);
    try testing.expectEqualStrings("Title::Other", map.headings[3]);

    // Each reported path round-trips as a real --heading target.
    const got = try apply(testing.allocator, body, .{ .heading = &.{ "Title", "Notes", "Sub" } }, .replace, "new\n", false);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "new\n") != null);
}

test "documentMap lists block ids and frontmatter keys, in document order" {
    const body = "---\ntitle: \"x\"\nstatus: TODO\ntags: [a, b]\n---\n\nFirst ^one\n\nSecond ^two\n";
    var map = try documentMap(testing.allocator, body);
    defer map.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), map.blocks.len);
    try testing.expectEqualStrings("one", map.blocks[0]);
    try testing.expectEqualStrings("two", map.blocks[1]);

    try testing.expectEqual(@as(usize, 3), map.frontmatter_keys.len);
    try testing.expectEqualStrings("title", map.frontmatter_keys[0]);
    try testing.expectEqualStrings("status", map.frontmatter_keys[1]);
    try testing.expectEqualStrings("tags", map.frontmatter_keys[2]);
}

test "documentMap on a note with no headings, blocks, or frontmatter reports all three empty" {
    var map = try documentMap(testing.allocator, "just prose, nothing structured\n");
    defer map.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), map.headings.len);
    try testing.expectEqual(@as(usize, 0), map.blocks.len);
    try testing.expectEqual(@as(usize, 0), map.frontmatter_keys.len);
}
