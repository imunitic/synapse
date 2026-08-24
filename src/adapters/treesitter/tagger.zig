//! Runs a grammar's own `queries/tags.scm` and turns the captures into `Tag`s
//! -- the part the `tree-sitter` CLI used to do, minus `locals.scm` scope
//! tracking and regex matching.
//!
//! **A tag the query didn't sanction is worse than no tag at all** -- it
//! poisons the tags cache and every `callers` answer built from it. So
//! predicates are evaluated, not ignored: on a real OCaml repo, ignoring
//! them added 123 false call references out of ~10k. The string-comparison
//! family (`#eq?`, `#not-eq?`, `#any-of?`, `#not-any-of?`) is evaluated;
//! `#match?` and anything unrecognised is *disabled* rather than ignored,
//! since assuming a filter passes costs a false tag, assuming it fails only
//! costs a missing one. Directives (`#strip!`, `#set!`) are skipped, not
//! refused -- they rewrite a capture, not which nodes matched.
//!
//! Captures follow tags.scm's own convention: `@name` marks the identifier,
//! a sibling `@definition.<kind>`/`@reference.<kind>` supplies role and
//! kind. Reported position is the `@name` node's row, not the enclosing
//! declaration's.

const std = @import("std");
const model = @import("model");
const core = @import("core");
const root = @import("root.zig");
const node_types = @import("node_types.zig");
const grammar = @import("grammar.zig");

const c = root.c;
const Allocator = std.mem.Allocator;

pub const Error = error{
    QueryInvalid,
    /// Every pattern disabled: the query matches nothing, and that has to
    /// stay an error rather than read as "this file has no symbols".
    PredicateUnsupported,
    ParseFailed,
};

pub const Tagger = struct {
    query: *c.TSQuery,
    parser: *c.TSParser,
    /// Which convention `scm` follows: tags.scm's `@name` + sibling
    /// `@definition`/`@reference`, or locals.scm's single
    /// `@local.definition.<kind>` capture as both name and role.
    query_source: root.QuerySource,
    /// Normalizes a locals.scm kind suffix onto `Tag.kind`'s vocabulary.
    /// Unused (fine null) for every other `query_source`.
    kind_rules: ?core.kind_synonyms.RuleList,
    /// This grammar's tree-sitter scope (e.g. `source.ocaml`), for a scoped
    /// kind-synonym rule. Unused outside the locals.scm reading.
    grammar_scope: []const u8,
    /// Tier 2's node-types.json guesses, owned by this `Tagger` (unlike
    /// `kind_rules`, which is global). `query` already covers every
    /// `has_name_field` guess; `tagFileWalk` reads the rest. Null except
    /// for `.generated`.
    classification: ?node_types.Classification,
    /// A second, independent query compiled from the grammar's own
    /// `locals.scm`, used only to build a per-file set of locally-bound
    /// names -- never for extraction itself. Orthogonal to `query_source`:
    /// a tier-1 grammar (real `tags.scm`) can still have a real
    /// `locals.scm` sitting unused beside it -- a function parameter,
    /// `let`-binding, or module/functor argument with zero `def` rows
    /// anywhere in `_refs.tsv` would otherwise be misread as an unresolved
    /// cross-file reference by `tags.scm` alone. Null when the grammar has
    /// no usable `locals.scm` -- local-reference filtering is then simply
    /// skipped, not refused.
    locals_query: ?*c.TSQuery,

    pub fn init(
        lang: *const c.TSLanguage,
        scm: []const u8,
        query_source: root.QuerySource,
        kind_rules: ?core.kind_synonyms.RuleList,
        grammar_scope: []const u8,
        classification: ?node_types.Classification,
        /// Raw `locals.scm` source, when the grammar ships one -- compiled
        /// independently of `scm`/`query_source` above. See `locals_query`.
        locals_scm: ?[]const u8,
    ) !Tagger {
        var err_off: u32 = 0;
        var err_type: c.TSQueryError = 0;
        const query = c.ts_query_new(lang, scm.ptr, @intCast(scm.len), &err_off, &err_type) orelse
            return Error.QueryInvalid;
        errdefer c.ts_query_delete(query);

        const patterns = c.ts_query_pattern_count(query);
        var disabled: u32 = 0;
        var i: u32 = 0;
        while (i < patterns) : (i += 1) {
            if (patternIsUnevaluable(query, i)) {
                c.ts_query_disable_pattern(query, i);
                disabled += 1;
            }
        }
        if (patterns != 0 and disabled == patterns) return Error.PredicateUnsupported;

        // Best-effort: an invalid or otherwise unusable locals.scm just
        // means no local-reference filtering for this grammar, the same
        // graceful degradation as a grammar with no locals.scm at all --
        // never refuses the whole `Tagger` over it.
        const locals_query: ?*c.TSQuery = if (locals_scm) |ls| blk: {
            var lerr_off: u32 = 0;
            var lerr_type: c.TSQueryError = 0;
            const lq = c.ts_query_new(lang, ls.ptr, @intCast(ls.len), &lerr_off, &lerr_type) orelse
                break :blk null;
            const lpatterns = c.ts_query_pattern_count(lq);
            var ldisabled: u32 = 0;
            var li: u32 = 0;
            while (li < lpatterns) : (li += 1) {
                if (patternIsUnevaluable(lq, li)) {
                    c.ts_query_disable_pattern(lq, li);
                    ldisabled += 1;
                }
            }
            if (lpatterns != 0 and ldisabled == lpatterns) {
                c.ts_query_delete(lq);
                break :blk null;
            }
            break :blk lq;
        } else null;
        errdefer if (locals_query) |lq| c.ts_query_delete(lq);

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
            .locals_query = locals_query,
        };
    }

    pub fn deinit(self: *Tagger) void {
        c.ts_query_delete(self.query);
        if (self.locals_query) |lq| c.ts_query_delete(lq);
        c.ts_parser_delete(self.parser);
        if (self.classification) |*cl| cl.deinit();
    }

    /// Whether tree-sitter's predicates/directives can be answered here.
    /// `?` asks and filters; `!` orders and rewrites without filtering.
    pub const Predicate = enum {
        /// `#strip!`, `#set!` -- rewrites a capture, doesn't filter.
        directive,
        /// Byte comparisons against a capture's text.
        eq,
        not_eq,
        any_of,
        not_any_of,
        /// `#match?` (no regex engine available) and anything unrecognised.
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

    /// Disabled rather than ignored: a false tag is worse than a missing one.
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

    /// Predicate name at step `s`, or null if `s` is an argument. Steps run
    /// name,arg,arg,...,Done and repeat.
    fn nameAt(query: *c.TSQuery, steps: [*c]const c.TSQueryPredicateStep, count: u32, s: u32) ?[]const u8 {
        if (s != 0 and steps[s - 1].type != c.TSQueryPredicateStepTypeDone) return null;
        if (s >= count) return null;
        if (steps[s].type != c.TSQueryPredicateStepTypeString) return null;
        var len: u32 = 0;
        const ptr = c.ts_query_string_value_for_id(query, steps[s].value_id, &len) orelse return null;
        return ptr[0..len];
    }

    /// Per match, not per pattern: the answer depends on the text the
    /// captures landed on. A pattern reaching here already passed at load.
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
        // First arg is always the capture under test; a literal there is
        // malformed, so it fails rather than lets the match through.
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

    /// Source text a capture landed on, or null if absent from this match
    /// or its bytes fall outside `source`.
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

    /// Tags for one file, with the span the CLI reports (only the
    /// transitional text renderer needs columns; `Tag`/the cache don't).
    /// Every string is copied, not borrowed -- `source` doesn't outlive the
    /// call. Dispatches on `query_source`; every source yields the same
    /// `Tagged` shape.
    pub fn tagFile(self: *Tagger, gpa: Allocator, source: []const u8) ![]Tagged {
        const tagged = try switch (self.query_source) {
            // `.override` is human-authored with no convention of its own;
            // tags.scm's is the default.
            .tags, .override => self.tagFileTags(gpa, source),
            .locals => self.tagFileLocals(gpa, source),
            // Two sources at once: `query` covers every has_name_field
            // guess, the bounded walk covers the rest.
            .generated => self.tagFileGenerated(gpa, source),
        };
        const lq = self.locals_query orelse return tagged;
        return self.stripLocalRefs(gpa, source, lq, tagged);
    }

    /// Every name with a `@local.definition.*` capture anywhere in `source`,
    /// via `locals_query` -- reused as a name-only set, not turned into
    /// `Tagged` entries the way `tagFileLocals`'s own defs pass does.
    /// Same-file, not same-scope: matches the design's own stated scope
    /// ("resolved against `@local.definition.*` captures within the same
    /// file"), a deliberately coarser check than real lexical-scope
    /// resolution -- cheaper, and the false-positive direction it risks
    /// (two distinct same-named locals in one file) only ever suppresses a
    /// cross-file candidate that already coincides with a local name in the
    /// same file, never fabricates one.
    fn localDefinedNames(self: *Tagger, gpa: Allocator, source: []const u8, locals_query: *c.TSQuery) !std.StringHashMapUnmanaged(void) {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        errdefer {
            var it = names.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            names.deinit(gpa);
        }

        const tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len)) orelse
            return Error.ParseFailed;
        defer c.ts_tree_delete(tree);

        const cursor = c.ts_query_cursor_new() orelse return Error.ParseFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, locals_query, c.ts_tree_root_node(tree));

        const definition_prefix = "local.definition";

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |cap| {
                var len: u32 = 0;
                const raw = c.ts_query_capture_name_for_id(locals_query, cap.index, &len);
                const cname = raw[0..len];
                if (!std.mem.startsWith(u8, cname, definition_prefix)) continue;
                const rest = cname[definition_prefix.len..];
                if (rest.len != 0 and rest[0] != '.') continue; // `.definitions_list` etc.

                const start_byte = c.ts_node_start_byte(cap.node);
                const end_byte = c.ts_node_end_byte(cap.node);
                if (start_byte > end_byte or end_byte > source.len) continue;
                const name = source[start_byte..end_byte];

                if (names.contains(name)) continue;
                try names.put(gpa, try gpa.dupe(u8, name), {});
            }
        }
        return names;
    }

    /// Drops any `.ref`-role tag whose name resolves to a same-file local
    /// binding -- answered and discarded here, before the caller ever sees
    /// it, rather than surviving into `_refs.tsv` as an unresolved global
    /// name destined for a cross-file join it was never a candidate for.
    /// `tagged`'s ownership passes in; the returned slice is what survives.
    fn stripLocalRefs(self: *Tagger, gpa: Allocator, source: []const u8, locals_query: *c.TSQuery, tagged: []Tagged) ![]Tagged {
        var locals = try self.localDefinedNames(gpa, source, locals_query);
        defer {
            var it = locals.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            locals.deinit(gpa);
        }
        if (locals.count() == 0) return tagged;

        var kept: std.ArrayListUnmanaged(Tagged) = .empty;
        errdefer {
            for (kept.items) |t| freeTag(gpa, t.tag);
            kept.deinit(gpa);
        }
        for (tagged) |t| {
            if (t.tag.role == .ref and locals.contains(t.tag.name)) {
                freeTag(gpa, t.tag);
                continue;
            }
            try kept.append(gpa, t);
        }
        gpa.free(tagged);
        return kept.toOwnedSlice(gpa);
    }

    /// tags.scm convention: `@name` + sibling `@definition.<kind>`/`@reference.<kind>`.
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

            // No @name or no role capture: not a tag (legitimate in tags.scm).
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

    /// locals.scm convention: one `@local.definition.<kind>` capture is both
    /// name and role -- no separate `@name`. Definitions only;
    /// `@local.reference`/`@local.scope` are read and ignored. A raw kind
    /// suffix is normalized through `kind_rules`; unmapped drops silently.
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
                // Bare `@local.definition` and `.definition.<kind>` both
                // count; `.definitions_list` must not.
                const raw_kind = if (rest.len == 0)
                    rest
                else if (rest[0] == '.')
                    rest[1..]
                else
                    continue;

                // Empty is a real spelling too, mappable via a `match: ""`
                // rule; dropped like any other unmapped one otherwise.
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

    /// Tier 2: `tagFileTags` (query path) plus the bounded walk
    /// (declaration-shaped types with no name field), combined.
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

        // Both non-empty: concatenate. Struct fields copy by value, so only
        // the two backing arrays are freed here, never their contents.
        const combined = try gpa.alloc(Tagged, from_query.len + from_walk.len);
        @memcpy(combined[0..from_query.len], from_query);
        @memcpy(combined[from_query.len..], from_walk);
        gpa.free(from_query);
        gpa.free(from_walk);
        return combined;
    }

    /// Bounded walk: every node matching a `has_name_field == false` guess
    /// becomes a tag, named by the nearest identifier/name within depth 3
    /// (Graft's fallback shape). `has_name_field == true` is skipped --
    /// `query` already covers it.
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

        // Keyed by the found identifier's byte span: a nested declaration
        // wrapper (`Decl` around `VarDecl`, both guessed) walks to the same
        // nearest identifier from two different starting nodes otherwise --
        // one real grammar shows this as real defs double-counted rather
        // than fabricated, but a duplicate all the same.
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(gpa);

        try walkNode(gpa, c.ts_tree_root_node(tree), source, guesses, &seen, &out);
        return out.toOwnedSlice(gpa);
    }
};

/// Depth-first, unbounded, over the whole tree. Recurses into a matched
/// node's children too -- a declaration can nest inside another (a method
/// inside a class), and one match must not hide the ones below it.
fn walkNode(
    gpa: Allocator,
    node: c.TSNode,
    source: []const u8,
    guesses: []const node_types.Guess,
    seen: *std.AutoHashMapUnmanaged(u64, void),
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

        // Two different guessed ancestors landing on the same identifier
        // is a duplicate, not a second definition -- skip the append, but
        // still stop trying further guesses on this node (one match found).
        const key = (@as(u64, start_byte) << 32) | end_byte;
        if (seen.contains(key)) break;
        try seen.put(gpa, key, {});

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
        break; // one guess per node; a type matches at most one entry
    }

    const count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try walkNode(gpa, c.ts_node_named_child(node, i), source, guesses, seen, out);
    }
}

/// BFS, depth capped at 3, for the nearest single-line identifier/name
/// descendant -- a queue so depth-1 is checked before depth-2. `node`
/// itself is never a candidate.
fn findNameDescendant(gpa: Allocator, node: c.TSNode, source: []const u8) !?c.TSNode {
    const Item = struct { node: c.TSNode, depth: u32 };
    var queue: std.ArrayListUnmanaged(Item) = .empty;
    defer queue.deinit(gpa);

    try queue.append(gpa, .{ .node = node, .depth = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        if (item.depth > 0) {
            // Case-insensitive: some grammars name their identifier leaf
            // in caps (`IDENTIFIER`), not the lowercase `identifier`/`name`
            // convention most others use.
            const type_name = std.mem.span(c.ts_node_type(item.node));
            if (std.ascii.eqlIgnoreCase(type_name, "identifier") or std.ascii.eqlIgnoreCase(type_name, "name")) {
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

/// The whole source line containing `offset`, trimmed -- what the CLI
/// prints between its backticks.
fn lineAt(source: []const u8, offset: usize) []const u8 {
    var start = offset;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var end = offset;
    while (end < source.len and source[end] != '\n') end += 1;
    return std.mem.trim(u8, source[start..end], " \t\r");
}

/// Re-renders a tag as `tree-sitter tags` prints it -- needed only until
/// `synapse-vocab.sh`/`synapse-rank.sh` (which still parse this text) are
/// ported.
///
///     Token     \t | class   \tdef (15, 13) - (15, 18) `public class Token {`
///
/// Name padded to 10 columns, kind to 8, neither truncated when longer.
pub fn renderCliLine(w: *std.Io.Writer, t: model.Tag, span: Span) !void {
    // 180-char cap, undocumented by the CLI -- found by byte-comparison
    // (174/2,749 sample lines sat exactly at it). Trimmed after truncating,
    // not before, or a cut mid-gap leaves a trailing space the CLI omits.
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

/// The `@name` node's span -- not the enclosing declaration's.
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

    try testing.expectEqual(P.directive, P.parse("strip!"));
    try testing.expectEqual(P.directive, P.parse("set!"));

    try testing.expectEqual(P.eq, P.parse("eq?"));
    try testing.expectEqual(P.not_eq, P.parse("not-eq?"));
    try testing.expectEqual(P.any_of, P.parse("any-of?"));
    try testing.expectEqual(P.not_any_of, P.parse("not-any-of?"));

    try testing.expectEqual(P.unevaluable, P.parse("match?")); // no regex engine

    // Unknown names refuse rather than pass.
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

/// A tiny real grammar (generated once with `tree-sitter generate`,
/// checked in under `testdata/fake3_grammar`) -- `synapse-fake` can't stand
/// in here since it never builds a real `Tagger`/`TSLanguage`.
/// `function_declaration` has a `name` field (query path); `struct_item`
/// doesn't (walk path) -- distinct kinds make which path fired legible.
fn writeFake3Fixture(io: std.Io, tmp_dir: std.Io.Dir) !void {
    try tmp_dir.createDirPath(io, "src/tree_sitter");
    try tmp_dir.writeFile(io, .{ .sub_path = "src/parser.c", .data = @embedFile("testdata/fake3_grammar/src/parser.c") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/node-types.json", .data = @embedFile("testdata/fake3_grammar/src/node-types.json") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/parser.h", .data = @embedFile("testdata/fake3_grammar/src/tree_sitter/parser.h") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/alloc.h", .data = @embedFile("testdata/fake3_grammar/src/tree_sitter/alloc.h") });
    try tmp_dir.writeFile(io, .{ .sub_path = "src/tree_sitter/array.h", .data = @embedFile("testdata/fake3_grammar/src/tree_sitter/array.h") });
}

fn tagOne(tagged: []const Tagged, i: usize) struct { name: []const u8, kind: []const u8, role: model.Role } {
    return .{ .name = tagged[i].tag.name, .kind = tagged[i].tag.kind, .role = tagged[i].tag.role };
}

test "tagFileGenerated combines the query path and the walk path, in every emptiness combination" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try writeFake3Fixture(io, tmp.dir);

    const lib = try std.fmt.allocPrint(gpa, "{s}/fake3.{s}", .{ dir, grammar.sharedLibExt() });
    defer gpa.free(lib);
    try grammar.build(io, gpa, dir, lib, grammar.default_lock_tries);
    const lang = try grammar.load(gpa, lib, "tree_sitter_fake3");

    const node_types_path = try std.fs.path.join(gpa, &.{ dir, "src", "node-types.json" });
    defer gpa.free(node_types_path);
    var no_rules = try core.kind_synonyms.RuleList.load(gpa, io, "/nonexistent");
    defer no_rules.deinit();
    const classification = try node_types.classify(gpa, io, node_types_path, no_rules, "test");

    const query = try node_types.buildQuery(gpa, classification.guesses);
    defer gpa.free(query);

    var tagger = try Tagger.init(lang, query, .generated, null, "test", classification, null);
    defer tagger.deinit(); // frees `classification` too

    // Both empty: no function_declaration, no struct_item.
    {
        const tagged = try tagger.tagFile(gpa, "");
        defer freeTagged(gpa, tagged);
        try testing.expectEqual(@as(usize, 0), tagged.len);
    }

    // Query path only.
    {
        const tagged = try tagger.tagFile(gpa, "fn foo()");
        defer freeTagged(gpa, tagged);
        try testing.expectEqual(@as(usize, 1), tagged.len);
        const t = tagOne(tagged, 0);
        try testing.expectEqualStrings("foo", t.name);
        try testing.expectEqualStrings("function", t.kind);
        try testing.expectEqual(model.Role.def, t.role);
    }

    // Walk path only.
    {
        const tagged = try tagger.tagFile(gpa, "struct Bar{}");
        defer freeTagged(gpa, tagged);
        try testing.expectEqual(@as(usize, 1), tagged.len);
        const t = tagOne(tagged, 0);
        try testing.expectEqualStrings("Bar", t.name);
        try testing.expectEqualStrings("struct", t.kind);
        try testing.expectEqual(model.Role.def, t.role);
    }

    // Both non-empty: combined, query results first.
    {
        const tagged = try tagger.tagFile(gpa, "fn foo()\nstruct Bar{}");
        defer freeTagged(gpa, tagged);
        try testing.expectEqual(@as(usize, 2), tagged.len);
        const first = tagOne(tagged, 0);
        const second = tagOne(tagged, 1);
        try testing.expectEqualStrings("foo", first.name);
        try testing.expectEqualStrings("function", first.kind);
        try testing.expectEqualStrings("Bar", second.name);
        try testing.expectEqualStrings("struct", second.kind);
    }
}

/// A hand-built `tags.scm`/`locals.scm` pair over the fake3 grammar, purely
/// to drive `stripLocalRefs` end to end: `struct_item`'s identifier stands
/// in for a `.ref` (real tags.scm files would never call a struct name a
/// reference -- the point here is only to exercise the filtering mechanism
/// against a real compiled query and a real parse, not to model any real
/// language). `function_declaration`'s identifier stands in for
/// `@local.definition.function`.
const fake_ref_query = "(struct_item (identifier) @name) @reference.type";
const fake_locals_query = "(function_declaration name: (identifier) @local.definition.function)";

fn buildFake3Tagger(gpa: Allocator, io: std.Io, dir: []const u8, locals_scm: ?[]const u8) !Tagger {
    const lib = try std.fmt.allocPrint(gpa, "{s}/fake3.{s}", .{ dir, grammar.sharedLibExt() });
    defer gpa.free(lib);
    try grammar.build(io, gpa, dir, lib, grammar.default_lock_tries);
    const lang = try grammar.load(gpa, lib, "tree_sitter_fake3");
    return Tagger.init(lang, fake_ref_query, .tags, null, "test", null, locals_scm);
}

test "a reference whose name matches a same-file local definition is stripped, never reaches the caller" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFake3Fixture(io, tmp.dir);

    var tagger = try buildFake3Tagger(gpa, io, dir, fake_locals_query);
    defer tagger.deinit();

    // "foo" is both the struct name (the fake .ref) and the function name
    // (the fake local def) -- same-file, same name, must resolve locally.
    const tagged = try tagger.tagFile(gpa, "fn foo()\nstruct foo{}");
    defer freeTagged(gpa, tagged);
    try testing.expectEqual(@as(usize, 0), tagged.len);
}

test "a reference whose name matches no local definition survives unfiltered" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFake3Fixture(io, tmp.dir);

    var tagger = try buildFake3Tagger(gpa, io, dir, fake_locals_query);
    defer tagger.deinit();

    // "other" (the local def) and "foo" (the ref) don't share a name --
    // stays a candidate for cross-file resolution, same as today.
    const tagged = try tagger.tagFile(gpa, "fn other()\nstruct foo{}");
    defer freeTagged(gpa, tagged);
    try testing.expectEqual(@as(usize, 1), tagged.len);
    try testing.expectEqualStrings("foo", tagged[0].tag.name);
    try testing.expectEqual(model.Role.ref, tagged[0].tag.role);
}

test "a grammar with no locals.scm at all keeps every reference unfiltered -- graceful degradation" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFake3Fixture(io, tmp.dir);

    var tagger = try buildFake3Tagger(gpa, io, dir, null);
    defer tagger.deinit();

    // Same source as the matching case above, but no locals_query at all --
    // must not filter anything, not even accidentally.
    const tagged = try tagger.tagFile(gpa, "fn foo()\nstruct foo{}");
    defer freeTagged(gpa, tagged);
    try testing.expectEqual(@as(usize, 1), tagged.len);
    try testing.expectEqualStrings("foo", tagged[0].tag.name);
}

test "an invalid locals.scm degrades gracefully instead of refusing the whole Tagger" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFake3Fixture(io, tmp.dir);

    var tagger = try buildFake3Tagger(gpa, io, dir, "(this is not valid tree-sitter query syntax");
    defer tagger.deinit();
    try testing.expect(tagger.locals_query == null);

    const tagged = try tagger.tagFile(gpa, "fn foo()\nstruct foo{}");
    defer freeTagged(gpa, tagged);
    try testing.expectEqual(@as(usize, 1), tagged.len);
}
