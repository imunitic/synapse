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

    /// Tags for one file. Every string in the result is owned by the caller:
    /// the names and expressions point into `source` while the query runs, and
    /// `source` routinely outlives nothing at all -- it is read per file and
    /// dropped -- so they are copied rather than borrowed.
    pub fn tagFile(self: *Tagger, gpa: Allocator, source: []const u8) ![]model.Tag {
        const tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len)) orelse
            return Error.ParseFailed;
        defer c.ts_tree_delete(tree);

        const cursor = c.ts_query_cursor_new() orelse return Error.ParseFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, self.query, c.ts_tree_root_node(tree));

        var out: std.ArrayListUnmanaged(model.Tag) = .empty;
        errdefer {
            for (out.items) |t| freeTag(gpa, t);
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

            const tag: model.Tag = .{
                .name = try gpa.dupe(u8, source[start_byte..end_byte]),
                .role = r,
                .kind = try gpa.dupe(u8, kind),
                .line = c.ts_node_start_point(node).row,
                .expression = try gpa.dupe(u8, lineAt(source, start_byte)),
            };
            try out.append(gpa, tag);
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

pub fn freeTag(gpa: Allocator, t: model.Tag) void {
    gpa.free(t.name);
    gpa.free(t.kind);
    gpa.free(t.expression);
}

pub fn freeTags(gpa: Allocator, tags: []model.Tag) void {
    for (tags) |t| freeTag(gpa, t);
    gpa.free(tags);
}

const testing = std.testing;

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
