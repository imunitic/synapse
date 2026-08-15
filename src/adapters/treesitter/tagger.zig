//! Runs a grammar's own `queries/tags.scm` and turns the captures into `Tag`s.
//!
//! This is the part the `tree-sitter` CLI used to do, and it is smaller than
//! the CLI's Rust implementation because half of what that implementation
//! carries is not reachable from these queries: `locals.scm` scope tracking,
//! and regex matching.
//!
//! ## Predicates, and the one rule that governs them
//!
//! **A tag that the query did not sanction is worse than no tag at all.**
//! Absent is visible and recoverable. Wrong quietly poisons the tags cache,
//! `_refs.tsv`, and every `callers` answer taken from them. Everything below
//! follows from that.
//!
//! Predicates decide which matches count, so ignoring one lets through every
//! match it was written to exclude. Measured on a real OCaml repository:
//! evaluating them yields 9,991 call references, ignoring them yields 10,114,
//! and the extra 123 are things like `^` string concatenation and `@` list
//! append reported as function calls.
//!
//! So the string-comparison family is evaluated -- `#eq?`, `#not-eq?`,
//! `#any-of?`, `#not-any-of?` -- which is a byte comparison against a capture's
//! text and nothing more. `#match?` needs a regex engine that the standard
//! library does not have, so a pattern using it is *disabled* rather than
//! ignored, and never matches. Unknown predicate names are treated the same
//! way, because assuming something filters costs a missing tag while assuming
//! it does not costs a false one.
//!
//! Directives are not predicates and are skipped: `#strip!` and `#set!` rewrite
//! a capture without changing which nodes matched. The distinction is
//! tree-sitter's own convention -- `?` asks, `!` orders -- and it matters,
//! because an earlier version refused any query carrying either and so shut out
//! every grammar that annotates doc comments.
//!
//! The convention the captures follow: `@name` marks the identifier, and a
//! sibling `@definition.<kind>` or `@reference.<kind>` capture supplies the
//! role and the kind. `definition.class` is `def`/`class`, `reference.call` is
//! `ref`/`call`. The reported position is the `@name` node's row -- not the
//! enclosing declaration's -- and the expression is the whole source line that
//! row sits on.

const std = @import("std");
const model = @import("model");
const core = @import("core");
const root = @import("root.zig");
const node_types = @import("node_types.zig");

const c = root.c;
const Allocator = std.mem.Allocator;

pub const Error = error{
    QueryInvalid,
    /// Every pattern in the query was disabled for asking something that cannot
    /// be evaluated, so the query matches nothing. Reported rather than
    /// returning no tags, which would read as "this file has no symbols".
    PredicateUnsupported,
    ParseFailed,
};

pub const Tagger = struct {
    query: *c.TSQuery,
    parser: *c.TSParser,
    /// Which convention `scm` follows -- sb-012. Decides whether `tagFile`
    /// reads it the `tags.scm` way (`@name` + a sibling `@definition.<kind>`
    /// / `@reference.<kind>`) or the `locals.scm` way (one
    /// `@local.definition.<kind>` capture is both the name and the role).
    query_source: root.QuerySource,
    /// Only consulted by the `locals.scm` reading, for normalizing a raw
    /// `@local.definition.<kind>` suffix onto `Tag.kind`'s own vocabulary.
    /// Unused, and fine to leave null, for every other `query_source`.
    kind_rules: ?core.kind_synonyms.RuleList,
    /// This grammar's own tree-sitter scope (e.g. `source.ocaml`), for a
    /// scoped kind-synonym rule. Unused outside the `locals.scm` reading.
    grammar_scope: []const u8,
    /// Tier 3's own guesses from `node-types.json`, owned by this `Tagger`
    /// (unlike `kind_rules`, which is global and caller-owned) since a
    /// classification is specific to the one grammar this `Tagger` was
    /// built for. `query` above already covers every `has_name_field`
    /// guess (`node_types.buildQuery` put them there); this is what
    /// `tagFileWalk` reads for the rest. Null for every `query_source`
    /// but `.generated`.
    classification: ?node_types.Classification,

    pub fn init(
        lang: *const c.TSLanguage,
        scm: []const u8,
        query_source: root.QuerySource,
        kind_rules: ?core.kind_synonyms.RuleList,
        grammar_scope: []const u8,
        classification: ?node_types.Classification,
    ) !Tagger {
        var err_off: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const query = c.ts_query_new(lang, scm.ptr, @intCast(scm.len), &err_off, &err_type) orelse
            return Error.QueryInvalid;
        errdefer c.ts_query_delete(query);

        // Decided before parsing anything, so an unsupported grammar fails at
        // load rather than producing a plausible-looking partial answer.
        const patterns = c.ts_query_pattern_count(query);
        var disabled: u32 = 0;
        var i: u32 = 0;
        while (i < patterns) : (i += 1) {
            if (patternIsUnevaluable(query, i)) {
                c.ts_query_disable_pattern(query, i);
                disabled += 1;
            }
        }
        // Every pattern gone is the same outcome the blanket refusal used to
        // give, and it has to stay an error: a query that matches nothing would
        // otherwise report a file as having no symbols at all.
        if (patterns != 0 and disabled == patterns) return Error.PredicateUnsupported;

        const parser = c.ts_parser_new() orelse return Error.ParseFailed;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, lang)) return Error.ParseFailed;

        return .{
            .query = query,
            .parser = parser,
            .query_source = query_source,
            .kind_rules = kind_rules,
            .grammar_scope = grammar_scope,
            .classification = classification,
        };
    }

    pub fn deinit(self: *Tagger) void {
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
        if (self.classification) |*cl| cl.deinit();
    }

    /// What a query can ask of a match, and whether this code can answer it.
    ///
    /// tree-sitter hands back predicates and directives in one list. They do
    /// different jobs, and the distinction is its own convention: a name ending
    /// in `?` asks a question and filters on the answer; a name ending in `!`
    /// gives an order that rewrites a capture and changes nothing about which
    /// nodes matched.
    pub const Predicate = enum {
        /// `#strip!`, `#set!`. Rewrites a capture for the caller's benefit. The
        /// only captures read here are `@name` and the role captures, and no
        /// shipped directive touches those, so ignoring them is safe.
        directive,
        /// Compares a capture's text against literals or another capture, which
        /// is a byte comparison and nothing more.
        eq,
        not_eq,
        any_of,
        not_any_of,
        /// `#match?` and anything unrecognised. `#match?` needs a regex engine,
        /// which the standard library does not have. Unknown names land here
        /// deliberately: guessing that something filters costs a missing tag,
        /// and guessing that it does not costs a false one.
        unevaluable,

        fn parse(name: []const u8) Predicate {
            if (name.len == 0) return .unevaluable;
            if (name[name.len - 1] == '!') return .directive;
            if (std.mem.eql(u8, name, "eq?")) return .eq;
            if (std.mem.eql(u8, name, "not-eq?")) return .not_eq;
            if (std.mem.eql(u8, name, "any-of?")) return .any_of;
            if (std.mem.eql(u8, name, "not-any-of?")) return .not_any_of;
            return .unevaluable;
        }
    };

    /// Whether the pattern asks something this code cannot answer, in which case
    /// it is disabled and never matches.
    ///
    /// Disabling rather than ignoring is the whole safety property: an
    /// unevaluated `#match?` would let through every match it was written to
    /// exclude, and those go into the tags cache, `_refs.tsv` and every
    /// `callers` answer taken from them. A missing tag is visible and
    /// recoverable; a false one is neither.
    fn patternIsUnevaluable(query: *c.TSQuery, pattern: u32) bool {
        var count: u32 = 0;
        const steps = c.ts_query_predicates_for_pattern(query, pattern, &count);
        var s: u32 = 0;
        while (s < count) : (s += 1) {
            if (nameAt(query, steps, count, s)) |name| {
                if (Predicate.parse(name) == .unevaluable) return true;
            }
        }
        return false;
    }

    /// The predicate name at step `s`, or null if that step is an argument.
    ///
    /// Steps run `name, arg, arg, ..., Done` and repeat, so a name is the first
    /// step of the list and the first after every `Done`.
    fn nameAt(query: *c.TSQuery, steps: [*c]const c.TSQueryPredicateStep, count: u32, s: u32) ?[]const u8 {
        if (s != 0 and steps[s - 1].type != c.TSQueryPredicateStepTypeDone) return null;
        if (s >= count) return null;
        if (steps[s].type != c.TSQueryPredicateStepTypeString) return null;
        var len: u32 = 0;
        const ptr = c.ts_query_string_value_for_id(query, steps[s].value_id, &len) orelse return null;
        return ptr[0..len];
    }

    /// Whether every predicate on this match holds.
    ///
    /// Called per match rather than per pattern, because the answer depends on
    /// the text the captures landed on. A pattern reaching here has already been
    /// checked at load: everything it asks is answerable.
    fn predicatesHold(self: *const Tagger, match: c.TSQueryMatch, source: []const u8) bool {
        var count: u32 = 0;
        const steps = c.ts_query_predicates_for_pattern(self.query, match.pattern_index, &count);
        if (count == 0) return true;

        var s: u32 = 0;
        while (s < count) {
            const name = nameAt(self.query, steps, count, s) orelse {
                s += 1;
                continue;
            };
            const kind = Predicate.parse(name);

            // The arguments run until the sentinel.
            var end = s + 1;
            while (end < count and steps[end].type != c.TSQueryPredicateStepTypeDone) end += 1;
            const args = steps[s + 1 .. end];
            s = end + 1;

            if (kind == .directive) continue;
            if (!self.holds(kind, args, match, source)) return false;
        }
        return true;
    }

    fn holds(
        self: *const Tagger,
        kind: Predicate,
        args: []const c.TSQueryPredicateStep,
        match: c.TSQueryMatch,
        source: []const u8,
    ) bool {
        if (args.len < 2) return true;
        // The first argument is always the capture under test. A predicate whose
        // first argument is a literal is malformed, and letting the match
        // through is the wrong direction, so it fails.
        if (args[0].type != c.TSQueryPredicateStepTypeCapture) return false;
        const lhs = self.captureText(args[0].value_id, match, source) orelse return false;

        switch (kind) {
            .eq, .not_eq => {
                const rhs = switch (args[1].type) {
                    c.TSQueryPredicateStepTypeCapture => self.captureText(args[1].value_id, match, source) orelse return false,
                    else => self.stringValue(args[1].value_id) orelse return false,
                };
                const same = std.mem.eql(u8, lhs, rhs);
                return if (kind == .eq) same else !same;
            },
            .any_of, .not_any_of => {
                var found = false;
                for (args[1..]) |a| {
                    const v = self.stringValue(a.value_id) orelse continue;
                    if (std.mem.eql(u8, lhs, v)) found = true;
                }
                return if (kind == .any_of) found else !found;
            },
            else => return true,
        }
    }

    /// The source text a capture landed on, or null when the capture is absent
    /// from this match or its bytes fall outside the source.
    fn captureText(self: *const Tagger, capture_id: u32, match: c.TSQueryMatch, source: []const u8) ?[]const u8 {
        _ = self;
        for (match.captures[0..match.capture_count]) |cap| {
            if (cap.index != capture_id) continue;
            const start = c.ts_node_start_byte(cap.node);
            const end = c.ts_node_end_byte(cap.node);
            if (start > end or end > source.len) return null;
            return source[start..end];
        }
        return null;
    }

    fn stringValue(self: *const Tagger, value_id: u32) ?[]const u8 {
        var len: u32 = 0;
        const ptr = c.ts_query_string_value_for_id(self.query, value_id, &len) orelse return null;
        return ptr[0..len];
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
    /// Dispatches on `query_source` -- see `Tagger`'s own doc comment on that
    /// field. Every `query_source` produces the identical `Tagged` shape;
    /// only how a match is read into one differs.
    pub fn tagFile(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
        return switch (self.query_source) {
            // `.override` is a human-authored file with no convention of
            // its own mandated, and `tags.scm`'s is the sensible default --
            // see `$SYNAPSE_GRAMMARS_QUERY_PATH`'s own doc comment.
            .tags, .override => self.tagFileTags(gpa, source),
            .locals => self.tagFileLocals(gpa, source),
            // Tier 3 is two sources at once, not a single reading: `query`
            // already covers every `has_name_field` guess in the
            // `tags.scm` shape (`node_types.buildQuery` built it that way),
            // and `classification`'s walk-only guesses need the bounded
            // tree-walk `tagFileTags` cannot do. `tagFileGenerated` runs
            // both and combines them.
            .generated => self.tagFileGenerated(gpa, source),
        };
    }

    /// The `tags.scm` convention: `@name` marks the identifier, and a
    /// sibling `@definition.<kind>`/`@reference.<kind>` supplies the role
    /// and the kind. Named for its convention now that a second reading
    /// exists; unchanged in every other respect.
    fn tagFileTags(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
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
            if (!self.predicatesHold(match, source)) continue;

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

    /// The `locals.scm` convention: one `@local.definition.<kind>` capture
    /// is both the identifier and the role signal -- there is no separate
    /// `@name` sibling the way `tags.scm` has one. Definitions only, per
    /// the design's own constraint: `@local.reference` (and anything else,
    /// `@local.scope` included) is read and ignored, never turned into a
    /// tag, so it can never reach `_refs.tsv`'s reference rows.
    ///
    /// A raw kind suffix is normalized through `kind_rules` before it
    /// becomes a tag; an unmapped one is dropped, not guessed -- see
    /// `core.kind_synonyms.RuleList.kindFor`'s own doc comment for why a
    /// missing mapping and "no rule list at all" are the same outcome here.
    fn tagFileLocals(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
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

        const definition_prefix = "local.definition";

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!self.predicatesHold(match, source)) continue;

            for (match.captures[0..match.capture_count]) |cap| {
                var len: u32 = 0;
                const raw = c.ts_query_capture_name_for_id(self.query, cap.index, &len);
                const cname = raw[0..len];
                if (!std.mem.startsWith(u8, cname, definition_prefix)) continue;
                const rest = cname[definition_prefix.len..];
                // `@local.definition` bare (no kind at all -- real grammars
                // do this, `tree-sitter-ocaml`'s own `locals.scm` among
                // them) and `@local.definition.<kind>` are both this
                // convention; `@local.definitions_list` or similar is not,
                // and must not be swept in by a prefix match alone.
                const raw_kind = if (rest.len == 0)
                    rest
                else if (rest[0] == '.')
                    rest[1..]
                else
                    continue;

                // An empty spelling is still a real spelling, not a reason
                // to skip matching -- a human can map "no kind at all" onto
                // a `Tag.kind` the same way as any other, via a rule whose
                // `match` is `""`. Absence of such a rule drops it, same as
                // any other unmapped spelling; nothing here treats blank
                // specially.
                const rules = self.kind_rules orelse continue;
                const kind = rules.kindFor(raw_kind, self.grammar_scope) orelse continue;

                const node = cap.node;
                const start_byte = c.ts_node_start_byte(node);
                const end_byte = c.ts_node_end_byte(node);
                if (start_byte > source.len or end_byte > source.len) continue;

                const start = c.ts_node_start_point(node);
                const end = c.ts_node_end_point(node);
                try out.append(gpa, .{
                    .tag = .{
                        .name = try gpa.dupe(u8, source[start_byte..end_byte]),
                        .role = .def,
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
        }

        return out.toOwnedSlice(gpa);
    }

    /// Tier 3 (sb-012): the emitted-query pass (`tagFileTags`, reused
    /// unchanged) plus the bounded tree-walk for whatever `node_types`
    /// judged declaration-shaped but with no `name` field to query for --
    /// combined into one result, since nothing downstream needs to know
    /// which of the two produced a given tag.
    fn tagFileGenerated(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
        const from_query = try self.tagFileTags(gpa, source);
        errdefer freeTagged(gpa, from_query);

        const cl = self.classification orelse return from_query;
        const from_walk = try self.tagFileWalk(gpa, source, cl.guesses);
        errdefer freeTagged(gpa, from_walk);
        if (from_walk.len == 0) {
            gpa.free(from_walk);
            return from_query;
        }
        if (from_query.len == 0) {
            gpa.free(from_query);
            return from_walk;
        }

        // Both non-empty: combine into one slice. Each `Tagged`'s owned
        // strings move by value (a `[]const u8` field is a pointer+len
        // pair, and copying the struct copies that pair, not the bytes it
        // points to), so only the two now-empty backing arrays are freed
        // here, never their contents.
        const combined = try gpa.alloc(Tagged, from_query.len + from_walk.len);
        @memcpy(combined[0..from_query.len], from_query);
        @memcpy(combined[from_query.len..], from_walk);
        gpa.free(from_query);
        gpa.free(from_walk);
        return combined;
    }

    /// The bounded tree-walk: every node in the tree whose type matches one
    /// of `guesses`' `has_name_field == false` entries becomes a tag, named
    /// by the nearest single-line `identifier`/`name` descendant within
    /// depth 3 -- Graft's own fallback shape, see `node_types.zig`'s own
    /// docstring. A `has_name_field == true` guess is skipped here; `query`
    /// already covers it.
    fn tagFileWalk(self: *Tagger, gpa: Allocator, source: []const u8, guesses: []const node_types.Guess) ![]Tagged {
        var any_walkable = false;
        for (guesses) |g| {
            if (!g.has_name_field) {
                any_walkable = true;
                break;
            }
        }
        if (!any_walkable) return &.{};

        const tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len)) orelse
            return Error.ParseFailed;
        defer c.ts_tree_delete(tree);

        var out: std.ArrayListUnmanaged(Tagged) = .empty;
        errdefer {
            for (out.items) |t| freeTag(gpa, t.tag);
            out.deinit(gpa);
        }

        try walkNode(gpa, c.ts_tree_root_node(tree), source, guesses, &out);
        return out.toOwnedSlice(gpa);
    }
};

/// Depth-first over the whole tree (unbounded -- this walks every
/// declaration in the file, not just the first), matching `guesses`'
/// `type_name` at each node and, on a match, running the bounded
/// name-search below on that node's own children. Recurses into a
/// matched node's children too: a declaration can nest inside another (a
/// method inside a class, a function inside a module), and one match must
/// not hide the ones below it.
fn walkNode(
    gpa: Allocator,
    node: c.TSNode,
    source: []const u8,
    guesses: []const node_types.Guess,
    out: *std.ArrayListUnmanaged(Tagged),
) !void {
    const type_name = std.mem.span(c.ts_node_type(node));
    for (guesses) |g| {
        if (g.has_name_field) continue;
        if (!std.mem.eql(u8, g.type_name, type_name)) continue;
        const found = (try findNameDescendant(gpa, node, source)) orelse break;

        const start_byte = c.ts_node_start_byte(found);
        const end_byte = c.ts_node_end_byte(found);
        if (start_byte > source.len or end_byte > source.len) break;
        const start = c.ts_node_start_point(found);
        const end = c.ts_node_end_point(found);
        try out.append(gpa, .{
            .tag = .{
                .name = try gpa.dupe(u8, source[start_byte..end_byte]),
                .role = .def,
                .kind = try gpa.dupe(u8, g.kind),
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
        break; // one guess per node is enough; a type matches at most one entry
    }

    const count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try walkNode(gpa, c.ts_node_named_child(node, i), source, guesses, out);
    }
}

/// Breadth-first, depth capped at 3, for the nearest `identifier`/`name`
/// descendant whose text is a single line -- Graft's own bounded fallback,
/// not a value-type heuristic: a queue rather than plain recursion, so
/// every depth-1 descendant is checked before any depth-2 one, which is
/// what "nearest" actually means. `node` itself is never a candidate, only
/// its descendants.
fn findNameDescendant(gpa: Allocator, node: c.TSNode, source: []const u8) !?c.TSNode {
    const Item = struct { node: c.TSNode, depth: u32 };
    var queue: std.ArrayListUnmanaged(Item) = .empty;
    defer queue.deinit(gpa);

    try queue.append(gpa, .{ .node = node, .depth = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        if (item.depth > 0) {
            const type_name = std.mem.span(c.ts_node_type(item.node));
            if (std.mem.eql(u8, type_name, "identifier") or std.mem.eql(u8, type_name, "name")) {
                const start = c.ts_node_start_byte(item.node);
                const end = c.ts_node_end_byte(item.node);
                if (start <= end and end <= source.len and isSingleLine(source[start..end])) {
                    return item.node;
                }
            }
        }
        if (item.depth >= 3) continue;
        const count = c.ts_node_named_child_count(item.node);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try queue.append(gpa, .{ .node = c.ts_node_named_child(item.node, i), .depth = item.depth + 1 });
        }
    }
    return null;
}

fn isSingleLine(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '\n') == null;
}

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

test "predicates are classified into skip, evaluate, and refuse" {
    const P = Tagger.Predicate;

    // Directives rewrite a capture and change nothing about which nodes
    // matched, so they are skipped. Refusing these shut out every grammar that
    // annotates doc comments, which is most of them.
    try testing.expectEqual(P.directive, P.parse("strip!"));
    try testing.expectEqual(P.directive, P.parse("set!"));

    // Byte comparisons against a capture's text. Nothing else is needed.
    try testing.expectEqual(P.eq, P.parse("eq?"));
    try testing.expectEqual(P.not_eq, P.parse("not-eq?"));
    try testing.expectEqual(P.any_of, P.parse("any-of?"));
    try testing.expectEqual(P.not_any_of, P.parse("not-any-of?"));

    // Needs a regex engine the standard library does not have.
    try testing.expectEqual(P.unevaluable, P.parse("match?"));

    // Unknown names refuse rather than pass. A pattern this code cannot
    // evaluate is disabled, so the error is a missing tag; letting it through
    // would put a tag the query never sanctioned into every `callers` answer.
    try testing.expectEqual(P.unevaluable, P.parse("is-not?"));
    try testing.expectEqual(P.unevaluable, P.parse("something-new"));
    try testing.expectEqual(P.unevaluable, P.parse(""));
}

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
