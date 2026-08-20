//! The tag-line codec: tree-sitter's batch output in, `Tag` out, `_refs.tsv`
//! rows back out again.
//!
//! Reimplements the awk in `claude/lib/synapse/synapse-build-refs.sh`
//! byte-identically, quirks included and labelled -- `_refs.tsv` is
//! binary-searched with `look`, so a row that differs by one byte is unfindable.
//!
//! The line tree-sitter emits, tab-separated:
//!
//!     Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`
//!
//! Field 1 is the name, space-padded. Field 2 is the kind behind a ` | `
//! prefix. Field 3 opens with the role, carries a (row, col) - (row, col)
//! span, and ends with the source line between backticks.

const std = @import("std");
const model = @import("model");

const Tag = model.Tag;
const Role = model.Role;

/// Leading spaces/tabs/pipes, trailing spaces/tabs -- matches the awk
/// `gsub(/^[ \t|]+|[ \t]+$/, "")`.
fn trim(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, s, " \t|"), " \t");
}

/// Parses one line of tree-sitter batch output. Null for whatever the awk
/// skipped: too few fields, a bad role, a missing/non-numeric row, an empty
/// name -- not an error, batch output legitimately has non-tag lines.
pub fn parse(line: []const u8) ?Tag {
    var it = std.mem.splitScalar(u8, line, '\t');
    const raw_name = it.next() orelse return null;
    const raw_kind = it.next() orelse return null;
    // Stops at the next tab, same as the awk's `-F'\t'` -- a source line
    // with a tab truncates and loses its closing backtick, matching what
    // `_refs.tsv` already contains.
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

/// Everything between the first backtick and the last. A single backtick
/// leaves the whole remainder in place, matching the awk's backward scan.
fn expression(rest: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, rest, '`') orelse return "";
    const tail = rest[first + 1 ..];
    const last = std.mem.lastIndexOfScalar(u8, tail, '`') orelse return tail;
    return tail[0..last];
}

/// One `_refs.tsv` row: name, role, kind, path:line, expression. Column
/// order and single-tab separators are a contract with `look`'s raw-byte
/// binary search over the `LC_ALL=C sort`ed file, not just formatting.
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

test "parse never crashes on arbitrary bytes, tabs and backticks included" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 80, 0));
            var buf: [80]u8 = undefined;
            smith.bytesWithHash(buf[0..len], 1);
            // A crash (not a `null`) is the only failure mode this property
            // checks -- `parse` is meant to skip anything malformed, never
            // panic on it, since batch tree-sitter output legitimately
            // contains non-tag lines this codec has never seen the shape of.
            _ = parse(buf[0..len]);
        }
    }.testOne, .{});
}

test "parse: an expression's embedded backticks never break the first/last-backtick recovery" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const name_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 1, 10, 0));
            var name_buf: [10]u8 = undefined;
            for (name_buf[0..name_len], 0..) |*c, i|
                c.* = smith.valueRangeAtMostWithHash(u8, 'a', 'z', @intCast(i + 1));

            const is_def = smith.valueWithHash(bool, 11);
            const role_text: []const u8 = if (is_def) "def" else "ref";
            const row = smith.valueRangeAtMostWithHash(u32, 0, 10_000_000, 12);

            // The expression: arbitrary printable bytes, backticks freely
            // included, tabs excluded -- an embedded tab would split fields
            // differently, a separate, already-documented behavior, not
            // what this property checks.
            const expr_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 60, 13));
            var expr_buf: [60]u8 = undefined;
            for (expr_buf[0..expr_len], 0..) |*c, i|
                c.* = smith.valueRangeAtMostWithHash(u8, '!', '~', @intCast(i + 14));
            const expr = expr_buf[0..expr_len];

            var line_buf: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &line_buf,
                "{s}\t | kind\t{s} ({d}, 0) - ({d}, 1) `{s}`",
                .{ name_buf[0..name_len], role_text, row, row, expr },
            );

            const tag = parse(line) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(name_buf[0..name_len], tag.name);
            try testing.expectEqual(row, tag.line);
            try testing.expectEqual(if (is_def) Role.def else Role.ref, tag.role);
            try testing.expectEqualStrings(expr, tag.expression);
        }
    }.testOne, .{});
}
