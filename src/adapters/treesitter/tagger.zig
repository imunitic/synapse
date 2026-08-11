//! Runs a grammar's own `queries/tags.scm` and turns the captures into `Tag`s.
//!
//! This is the part the `tree-sitter` CLI used to do, and it is far smaller
//! than the CLI's Rust implementation because the expensive half of that
//! implementation is not reachable from these queries: predicate evaluation
//! and `locals.scm` scope tracking. Verified against the registry's grammars
//! -- java, python and kotlin all use pure structural patterns, no `#eq?`, no
//! `#match?`, no `#is-not? local`, and none of them ships a `locals.scm`.
//!
//! Since that is a property of the queries rather than a guarantee, a query
//! that does use a predicate is refused outright. A silently wrong tag is
//! worse than an absent grammar: absent is visible and recoverable, wrong
//! quietly poisons the cache, `_refs.tsv`, and every `callers` answer taken
//! from it.
//!
//! The convention the captures follow: `@name` marks the identifier, and a
//! sibling `@definition.<kind>` or `@reference.<kind>` capture supplies the
//! role and the kind. `definition.class` is `def`/`class`, `reference.call` is
//! `ref`/`call`. The reported position is the `@name` node's row -- not the
//! enclosing declaration's -- and the expression is the whole source line that
//! row sits on.

const std = @import("std");
const model = @import("model");
const root = @import("root.zig");

const c = root.c;
const Allocator = std.mem.Allocator;

pub const Error = error{
    QueryInvalid,
    /// The query uses a predicate. See the header: refused rather than
    /// silently evaluated as always-true.
    PredicateUnsupported,
    ParseFailed,
};

pub const Tagger = struct {
    query: *c.TSQuery,
    parser: *c.TSParser,

    pub fn init(lang: *const c.TSLanguage, scm: []const u8) !Tagger {
        var err_off: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const query = c.ts_query_new(lang, scm.ptr, @intCast(scm.len), &err_off, &err_type) orelse
            return Error.QueryInvalid;
        errdefer c.ts_query_delete(query);

        // Refuse before parsing anything, so an unsupported grammar fails at
        // load rather than producing a plausible-looking partial answer.
        const patterns = c.ts_query_pattern_count(query);
        var i: u32 = 0;
        while (i < patterns) : (i += 1) {
            var count: u32 = 0;
            _ = c.ts_query_predicates_for_pattern(query, i, &count);
            if (count != 0) return Error.PredicateUnsupported;
        }

        const parser = c.ts_parser_new() orelse return Error.ParseFailed;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, lang)) return Error.ParseFailed;

        return .{ .query = query, .parser = parser };
    }

    pub fn deinit(self: *Tagger) void {
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
    }

    /// Tags for one file, each with the span the CLI reports.
    ///
    /// The span is here rather than on `model.Tag` because only one consumer
    /// needs it -- the transitional text renderer -- while `Tag` is what the
    /// cache and `_refs.tsv` are built from, and neither of those records a
    /// column. Putting it on `Tag` would mean a field the tree-sitter path
    /// fills and the `_refs.tsv` parser cannot, which is a worse trap than an
    /// extra return field. It dies with the shim.
    ///
    /// Every string in the result is owned by the caller:
    /// the names and expressions point into `source` while the query runs, and
    /// `source` routinely outlives nothing at all -- it is read per file and
    /// dropped -- so they are copied rather than borrowed.
    pub fn tagFile(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
        const tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len)) orelse
            return Error.ParseFailed;
        defer c.ts_tree_delete(tree);

        const cursor = c.ts_query_cursor_new() orelse return Error.ParseFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, self.query, c.ts_tree_root_node(tree));

        var out: std.ArrayListUnmanaged(Tagged) = .empty;
        errdefer {
            for (out.items) |t| freeTag(gpa, t.tag);
            out.deinit(gpa);
        }

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            var name_node: ?c.TSNode = null;
            var role: ?model.Role = null;
            var kind: []const u8 = "";

            for (match.captures[0..match.capture_count]) |cap| {
                var len: u32 = 0;
                const raw = c.ts_query_capture_name_for_id(self.query, cap.index, &len);
                const cname = raw[0..len];
                if (std.mem.eql(u8, cname, "name")) {
                    name_node = cap.node;
                } else if (std.mem.startsWith(u8, cname, "definition.")) {
                    role = .def;
                    kind = cname["definition.".len..];
                } else if (std.mem.startsWith(u8, cname, "reference.")) {
                    role = .ref;
                    kind = cname["reference.".len..];
                }
            }

            // A pattern with no @name, or none of the role captures, is not a
            // tag. tags.scm files legitimately contain such patterns.
            const node = name_node orelse continue;
            const r = role orelse continue;

            const start_byte = c.ts_node_start_byte(node);
            const end_byte = c.ts_node_end_byte(node);
            if (start_byte > source.len or end_byte > source.len) continue;

            const start = c.ts_node_start_point(node);
            const end = c.ts_node_end_point(node);
            try out.append(gpa, .{
                .tag = .{
                    .name = try gpa.dupe(u8, source[start_byte..end_byte]),
                    .role = r,
                    .kind = try gpa.dupe(u8, kind),
                    .line = start.row,
                    .expression = try gpa.dupe(u8, lineAt(source, start_byte)),
                },
                .span = .{
                    .start_row = start.row,
                    .start_col = start.column,
                    .end_row = end.row,
                    .end_col = end.column,
                },
            });
        }

        return out.toOwnedSlice(gpa);
    }
};

/// The whole source line containing `offset`, trimmed of leading and trailing
/// whitespace -- which is what the CLI prints between its backticks.
fn lineAt(source: []const u8, offset: usize) []const u8 {
    var start = offset;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var end = offset;
    while (end < source.len and source[end] != '\n') end += 1;
    return std.mem.trim(u8, source[start..end], " \t\r");
}

/// Re-render a tag in the exact bytes `tree-sitter tags` prints.
///
/// Needed only for the transition: `synapse-vocab.sh` and `synapse-rank.sh`
/// still parse this text, and a shim that changed it by one byte would break
/// them silently. It disappears when they are ported, since nothing else in
/// the Zig path ever turns a `Tag` back into a line.
///
/// The shape, verified byte for byte against the CLI:
///
///     Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`
///
/// Name is left-aligned to 10 columns, kind to 8, and neither is truncated
/// when it is longer -- `IllegalArgumentException` runs straight into its tab.
pub fn renderCliLine(w: *std.Io.Writer, t: model.Tag, span: Span) !void {
    // The CLI caps the expression at 180 characters, which is not documented
    // anywhere and was found by byte-comparing real output: 174 of 2,749 lines
    // from a 60-file sample sat exactly at 180 and none went past it. Without
    // the cap the rendered text diverges on every long declaration.
    // Truncated *then* trimmed: a cut landing mid-gap otherwise leaves a
    // trailing space the CLI does not print. Found by byte-comparison, one
    // character wide, on 2 lines out of 2,749.
    const capped = if (t.expression.len > expr_max) t.expression[0..expr_max] else t.expression;
    const expr = std.mem.trimEnd(u8, capped, " \t");
    try w.print("{s: <10}\t | {s: <8}\t{s} ({d}, {d}) - ({d}, {d}) `{s}`\n", .{
        t.name,      t.kind,       t.role.text(),
        span.start_row, span.start_col, span.end_row,
        span.end_col,   expr,
    });
}

pub const expr_max = 180;

pub const Tagged = struct {
    tag: model.Tag,
    span: Span,
};

/// The `@name` node's span, which is what the CLI reports -- not the enclosing
/// declaration's, despite the output reading like it might be.
pub const Span = struct {
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
};

pub fn freeTag(gpa: Allocator, t: model.Tag) void {
    gpa.free(t.name);
    gpa.free(t.kind);
    gpa.free(t.expression);
}

pub fn freeTags(gpa: Allocator, tags: []model.Tag) void {
    for (tags) |t| freeTag(gpa, t);
    gpa.free(tags);
}

pub fn freeTagged(gpa: Allocator, tagged: []Tagged) void {
    for (tagged) |t| freeTag(gpa, t.tag);
    gpa.free(tagged);
}

const testing = std.testing;

test "a rendered line is the CLI's bytes exactly" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderCliLine(&out.writer, .{
        .name = "Token",
        .role = .def,
        .kind = "class",
        .line = 15,
        .expression = "public class Token {",
    }, .{ .start_row = 15, .start_col = 13, .end_row = 15, .end_col = 18 });
    try testing.expectEqualStrings(
        "Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`\n",
        out.written(),
    );
}

test "an expression longer than 180 characters is truncated, as the CLI does" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 250);
    defer gpa.free(long);
    @memset(long, 'x');

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderCliLine(&out.writer, .{
        .name = "f",
        .role = .def,
        .kind = "method",
        .line = 1,
        .expression = long,
    }, .{ .start_row = 1, .start_col = 0, .end_row = 1, .end_col = 1 });

    const written = out.written();
    const open_tick = std.mem.indexOfScalar(u8, written, '`').?;
    const close_tick = std.mem.lastIndexOfScalar(u8, written, '`').?;
    try testing.expectEqual(@as(usize, expr_max), close_tick - open_tick - 1);
}

test "a name longer than the pad width is not truncated" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderCliLine(&out.writer, .{
        .name = "IllegalArgumentException",
        .role = .ref,
        .kind = "class",
        .line = 30,
        .expression = "throw new IllegalArgumentException(x);",
    }, .{ .start_row = 30, .start_col = 19, .end_row = 30, .end_col = 43 });
    try testing.expectEqualStrings(
        "IllegalArgumentException\t | class   \tref (30, 19) - (30, 43) `throw new IllegalArgumentException(x);`\n",
        out.written(),
    );
}

test "lineAt returns the trimmed line an offset sits on" {
    const src = "first\n    second line  \nthird\n";
    const idx = std.mem.indexOf(u8, src, "second").?;
    try testing.expectEqualStrings("second line", lineAt(src, idx));
    try testing.expectEqualStrings("first", lineAt(src, 0));
    try testing.expectEqualStrings("third", lineAt(src, std.mem.indexOf(u8, src, "third").?));
}

test "lineAt copes with a file that has no trailing newline" {
    const src = "only line";
    try testing.expectEqualStrings("only line", lineAt(src, 4));
}
