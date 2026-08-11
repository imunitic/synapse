//! The tag-line codec: tree-sitter's batch output in, `Tag` out, `_refs.tsv`
//! rows back out again.
//!
//! This is a reimplementation of the awk program in
//! `claude/lib/synapse/synapse-build-refs.sh`, and its job is to be
//! byte-identical to it rather than to be a better parser. Where that awk has
//! a quirk, the quirk is reproduced here on purpose and labelled -- `_refs.tsv`
//! is binary-searched with `look`, so a row that differs by one byte is a row
//! that cannot be found.
//!
//! The line tree-sitter emits, tab-separated:
//!
//!     Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`
//!
//! Field 1 is the name, space-padded. Field 2 is the kind behind a ` | `
//! prefix. Field 3 opens with the role, carries a (row, col) - (row, col)
//! span, and ends with the source line between backticks.

const std = @import("std");
const model = @import("model.zig");

const Tag = model.Tag;
const Role = model.Role;

/// Leading spaces, tabs and pipes; trailing spaces and tabs. Matches the awk
/// `gsub(/^[ \t|]+|[ \t]+$/, "")`, which is why the ` | ` in front of the kind
/// disappears without a separate step.
fn trim(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, s, " \t|"), " \t");
}

/// Parse one line of tree-sitter batch output. Returns null for every line the
/// awk would have skipped with `next`: too few fields, a role that is neither
/// def nor ref, a span whose row is missing or non-numeric, or an empty name.
/// A skipped line is not an error -- batch output legitimately contains lines
/// that are not tags.
pub fn parse(line: []const u8) ?Tag {
    var it = std.mem.splitScalar(u8, line, '\t');
    const raw_name = it.next() orelse return null;
    const raw_kind = it.next() orelse return null;
    // `rest = $4` under `-F'\t'` stops at the next tab, so a source line
    // containing a tab is truncated here and loses its closing backtick. That
    // is what the bash does today and what `_refs.tsv` already contains;
    // widening it would rewrite rows that `look` is currently finding.
    const rest = it.next() orelse return null;

    const role_text = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    const role = Role.parse(role_text) orelse return null;

    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const after_open = rest[open + 1 ..];
    const comma = std.mem.indexOfScalar(u8, after_open, ',') orelse return null;
    const row_text = std.mem.trim(u8, after_open[0..comma], " \t");
    if (row_text.len == 0) return null;
    const row = std.fmt.parseInt(u32, row_text, 10) catch return null;

    const name = trim(raw_name);
    if (name.len == 0) return null;

    return .{
        .name = name,
        .role = role,
        .kind = trim(raw_kind),
        .line = row,
        .expression = expression(rest),
    };
}

/// Everything between the first backtick and the last one. With a single
/// backtick the awk's backward scan finds nothing to close against and leaves
/// the whole remainder in place, so that is what happens here too.
fn expression(rest: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, rest, '`') orelse return "";
    const tail = rest[first + 1 ..];
    const last = std.mem.lastIndexOfScalar(u8, tail, '`') orelse return tail;
    return tail[0..last];
}

/// One `_refs.tsv` row: name, role, kind, path:line, expression.
///
/// The file this feeds is `LC_ALL=C sort`ed and binary-searched by
/// `synapse-callers` with `look`, which compares raw bytes. The column order
/// and the single-tab separators are a contract with that search, not a
/// formatting choice.
pub fn writeRefsRow(w: *std.Io.Writer, path: []const u8, tag: Tag) !void {
    try w.print("{s}\t{s}\t{s}\t{s}:{d}\t{s}\n", .{
        tag.name,
        tag.role.text(),
        tag.kind,
        path,
        tag.line,
        tag.expression,
    });
}

const testing = std.testing;

test "a real def line" {
    const tag = parse("Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`").?;
    try testing.expectEqualStrings("Token", tag.name);
    try testing.expectEqual(Role.def, tag.role);
    try testing.expectEqualStrings("class", tag.kind);
    try testing.expectEqual(@as(u32, 15), tag.line);
    try testing.expectEqualStrings("public class Token {", tag.expression);
}

test "a real ref line, expression containing an apostrophe" {
    const tag = parse("IllegalArgumentException\t | class   \tref (30, 19) - (30, 43) " ++
        "`throw new IllegalArgumentException(\"can't parse token:\" + string_token);`").?;
    try testing.expectEqualStrings("IllegalArgumentException", tag.name);
    try testing.expectEqual(Role.ref, tag.role);
    try testing.expectEqualStrings("throw new IllegalArgumentException(\"can't parse token:\" + string_token);", tag.expression);
}

test "the space-padded name is trimmed, or exact-match lookup finds nothing" {
    try testing.expectEqualStrings("execute", parse("execute   \t | call    \tref (7, 1) - (7, 8) `execute();`").?.name);
}

test "skipped lines: not a tag, bad role, no span, non-numeric row, empty name" {
    try testing.expectEqual(@as(?Tag, null), parse("no tabs here at all"));
    try testing.expectEqual(@as(?Tag, null), parse("name\t | kind\tdefinition (1, 2) - (1, 3) `x`"));
    try testing.expectEqual(@as(?Tag, null), parse("name\t | kind\tdef no span here `x`"));
    try testing.expectEqual(@as(?Tag, null), parse("name\t | kind\tdef (x, 2) - (1, 3) `x`"));
    try testing.expectEqual(@as(?Tag, null), parse("   \t | kind\tdef (1, 2) - (1, 3) `x`"));
}

test "an unterminated backtick keeps the remainder, matching the awk's backward scan" {
    const tag = parse("f\t | call    \tref (2, 0) - (2, 1) `unterminated").?;
    try testing.expectEqualStrings("unterminated", tag.expression);
}

test "no backtick at all yields an empty expression, not a skip" {
    const tag = parse("f\t | call    \tref (2, 0) - (2, 1) ").?;
    try testing.expectEqualStrings("", tag.expression);
}

test "a refs row is tab-separated in the order look expects" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const tag = parse("Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`").?;
    try writeRefsRow(&out.writer, "src/Token.java", tag);
    try testing.expectEqualStrings(
        "Token\tdef\tclass\tsrc/Token.java:15\tpublic class Token {\n",
        out.written(),
    );
}
