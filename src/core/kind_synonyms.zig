//! The kind-synonym rule list: `locals.scm`'s `@local.definition.<kind>`
//! capture suffix, normalized onto `Tag.kind` -- sb-012, tier 2's own step.
//!
//! `tags.scm` across grammars converges on one shared kind vocabulary
//! (`class`, `method`, `call`, ...) because every grammar author hand-wrote
//! their captures against it. `locals.scm` was never written against that
//! vocabulary -- it exists for a different consumer (nvim-treesitter's scope
//! tracking), so its own kind spellings (`ctor`, `func`, ...) are whatever a
//! grammar author happened to pick. This is the same "no vocabulary in
//! common" problem the Locals.scm design's own Problem section names for
//! definitions and references generally, one level down: at the kind level.
//!
//! ## An ordered rule list, not a flat table
//!
//! Firewall-shaped, deliberately: rules are tried top to bottom, first match
//! wins, and an unmapped spelling is dropped -- the same outcome a trailing
//! `{match: "*", kind: reject}` rule would give, without literally needing
//! one in the data (see `kindFor`'s own doc comment). A rule may optionally
//! scope itself to one grammar (`scope`, a tree-sitter scope like
//! `source.ocaml`); an unscoped rule matches any grammar. This is what lets
//! two grammars use the same spelling for two different things without one
//! overwriting the other's mapping: the second grammar gets its own rule,
//! placed ahead of the general one, rather than a shared table entry being
//! edited out from under the first grammar. See the design note's own
//! "Pitfalls" discussion for why a flat table was rejected in favor of this.
//!
//! ## Why a list and not `core.namespace.Registry`'s keyed-object shape
//!
//! `namespace.zig`'s rules are one-per-extension -- a lookup, not a
//! precedence chain, so a JSON object keyed by extension is the right shape
//! and object-key order is never load-bearing. Here, order *is* the whole
//! mechanism (precedence), and a JSON array is what actually guarantees an
//! order a JSON object's keys do not promise to preserve. Same discovery
//! contract otherwise: absent or empty is a supported state, not an error --
//! every grammar's `locals.scm` kinds are simply unmapped, dropped rather
//! than guessed, until a human confirms a real synonym during discovery.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One rule: a `locals.scm` kind spelling, optionally scoped to one
/// grammar, mapped onto the `Tag.kind` vocabulary `tags.scm` already uses.
pub const Rule = struct {
    /// The `@local.definition.<match>` suffix this rule answers for.
    /// Empty is a real, matchable value too -- a bare `@local.definition`
    /// capture with no suffix at all, which real grammars use (confirmed
    /// against `tree-sitter-ocaml`'s own `locals.scm`).
    match: []const u8,
    /// A tree-sitter scope (e.g. `"source.ocaml"`), or null to match any
    /// grammar. A scoped rule ahead of an unscoped one for the same
    /// `match` is how two grammars keep different meanings for the same
    /// spelling -- see the module docstring.
    scope: ?[]const u8 = null,
    /// `Tag.kind`'s own vocabulary: `"class"`, `"method"`, `"call"`, ...
    kind: []const u8,
};

/// `~/.claude/synapse-kind-synonyms.conf` (`SYNAPSE_KIND_SYNONYMS_CONF`
/// overrides it, same override contract every other `synapse-*.conf`
/// already gives): a JSON array of `Rule`, in file order --
/// `[{"match": "ctor", "scope": "source.zig", "kind": "method"}, ...]`.
pub const RuleList = struct {
    parsed: std.json.Parsed(std.json.Value),
    /// The allocator `rules` itself (not the strings it borrows) was
    /// allocated with -- kept explicitly rather than reached for through
    /// `parsed`'s own internals, which are `std.json`'s to change.
    gpa: Allocator,
    /// Materialized once at load, in file order -- `kindFor` walks this,
    /// never `parsed.value` directly, so a malformed individual entry
    /// (missing `match`/`kind`, wrong type) is simply absent from this
    /// slice rather than a load-time error: the rules around it still
    /// apply, the same tolerance `namespace.zig`'s `ruleFor` already gives
    /// a malformed registry entry.
    rules: []const Rule,

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !RuleList {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, "[]"),
            else => return e,
        };
        defer gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        return .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    }

    pub fn deinit(self: *RuleList) void {
        self.parsed.deinit();
        // `rules` borrows every string from `parsed.value`; only the slice
        // itself is this type's own allocation.
        self.gpa.free(self.rules);
    }

    /// Whether the list has any rule at all -- the "nothing configured
    /// yet" signal a caller uses to skip a pass entirely rather than walk
    /// every capture to learn it has no rule.
    pub fn isEmpty(self: RuleList) bool {
        return self.rules.len == 0;
    }

    /// The first rule whose `match` equals `spelling` and whose `scope` is
    /// either absent (matches any grammar) or equal to `grammar_scope`.
    /// Null means unmapped -- the caller drops the capture rather than
    /// guessing a `Tag.kind`. This *is* "no rule matched," not a
    /// separate case: there is no trailing sentinel rule in `rules` to
    /// reach, because reaching the end of the loop without a match already
    /// means the same thing a `{match: "*", kind: reject}` rule would.
    pub fn kindFor(self: RuleList, spelling: []const u8, grammar_scope: []const u8) ?[]const u8 {
        for (self.rules) |r| {
            if (!std.mem.eql(u8, r.match, spelling)) continue;
            if (r.scope) |s| {
                if (!std.mem.eql(u8, s, grammar_scope)) continue;
            }
            return r.kind;
        }
        return null;
    }
};

fn materialize(gpa: Allocator, value: std.json.Value) ![]const Rule {
    const arr = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayListUnmanaged(Rule) = .empty;
    errdefer out.deinit(gpa);
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        // An empty `match` is a real, matchable spelling -- "no kind
        // suffix at all" is what `tagFileLocals` passes for a bare
        // `@local.definition` capture (real grammars do this; see
        // `tree-sitter-ocaml`'s own `locals.scm`), not a malformed rule.
        // Only a missing or wrong-typed field is rejected here.
        const match_v = obj.get("match") orelse continue;
        if (match_v != .string) continue;
        const kind_v = obj.get("kind") orelse continue;
        if (kind_v != .string or kind_v.string.len == 0) continue;
        const scope: ?[]const u8 = blk: {
            const v = obj.get("scope") orelse break :blk null;
            break :blk if (v == .string and v.string.len != 0) v.string else null;
        };
        try out.append(gpa, .{ .match = match_v.string, .scope = scope, .kind = kind_v.string });
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "RuleList: an absent file opens empty, not an error" {
    const gpa = testing.allocator;
    var list = try RuleList.load(gpa, testing.io, "/nonexistent/synapse-kind-synonyms.conf");
    defer list.deinit();
    try testing.expect(list.isEmpty());
    try testing.expectEqual(@as(?[]const u8, null), list.kindFor("ctor", "source.zig"));
}

test "kindFor: an unscoped rule matches any grammar" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "ctor", "kind": "method"}]
    , .{});
    var list: RuleList = .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    defer list.deinit();

    try testing.expectEqualStrings("method", list.kindFor("ctor", "source.zig").?);
    try testing.expectEqualStrings("method", list.kindFor("ctor", "source.ocaml").?);
}

test "kindFor: order decides precedence, not specificity -- a scoped rule wins only when it comes first" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "ctor", "scope": "source.zig", "kind": "constructor"},
        \\ {"match": "ctor", "kind": "method"}]
    , .{});
    var list: RuleList = .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    defer list.deinit();

    // The scoped rule is first, so it wins for the grammar it names.
    try testing.expectEqualStrings("constructor", list.kindFor("ctor", "source.zig").?);
    // A different grammar skips the scoped rule (scope mismatch) and falls
    // through to the general one.
    try testing.expectEqualStrings("method", list.kindFor("ctor", "source.ocaml").?);
}

test "kindFor: a general rule placed first shadows a later scoped one" {
    const gpa = testing.allocator;
    // Order is the only thing that decides this -- the second rule is more
    // specific but never reached, because the first already matched.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "ctor", "kind": "method"},
        \\ {"match": "ctor", "scope": "source.zig", "kind": "constructor"}]
    , .{});
    var list: RuleList = .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    defer list.deinit();

    try testing.expectEqualStrings("method", list.kindFor("ctor", "source.zig").?);
}

test "kindFor: an unmapped spelling is null, not a guess" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "ctor", "kind": "method"}]
    , .{});
    var list: RuleList = .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    defer list.deinit();

    try testing.expectEqual(@as(?[]const u8, null), list.kindFor("dtor", "source.zig"));
}

test "an empty match is a real rule, not skipped as malformed" {
    const gpa = testing.allocator;
    // `tree-sitter-ocaml`'s own locals.scm: `(value_pattern) @local.definition`,
    // no kind suffix at all -- the shape this rule maps.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "", "kind": "variable"}]
    , .{});
    var list: RuleList = .{ .parsed = parsed, .gpa = gpa, .rules = try materialize(gpa, parsed.value) };
    defer list.deinit();

    try testing.expectEqual(@as(usize, 1), list.rules.len);
    try testing.expectEqualStrings("variable", list.kindFor("", "source.ocaml").?);
}

test "materialize: a malformed entry is skipped, the rules around it still apply" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"match": "ctor", "kind": "method"},
        \\ {"match": "bad"},
        \\ {"kind": "also-bad"},
        \\ "not even an object",
        \\ {"match": "func", "kind": "function"}]
    , .{});
    defer parsed.deinit();
    const rules = try materialize(gpa, parsed.value);
    defer gpa.free(rules);

    try testing.expectEqual(@as(usize, 2), rules.len);
    try testing.expectEqualStrings("ctor", rules[0].match);
    try testing.expectEqualStrings("func", rules[1].match);
}

test "materialize: a non-array top level is empty, not an error" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer parsed.deinit();
    const rules = try materialize(gpa, parsed.value);
    defer gpa.free(rules);
    try testing.expectEqual(@as(usize, 0), rules.len);
}
