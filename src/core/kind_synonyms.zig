//! The kind-synonym rule list: `locals.scm`'s `@local.definition.<kind>`
//! capture suffix, normalized onto `Tag.kind`.
//! `tags.scm` converges on one shared kind vocabulary across grammars;
//! `locals.scm` was written for a different consumer (nvim-treesitter's
//! scope tracking), so its kind spellings are whatever the grammar author
//! picked.
//!
//! An ordered rule list, not a flat table: tried top to bottom, first match
//! wins, unmapped is dropped. A rule may scope itself to one grammar
//! (tree-sitter scope like `source.ocaml`); unscoped matches any. That's
//! what lets two grammars give the same spelling different meanings -- the
//! second grammar's rule sits ahead of the general one, instead of one
//! shared entry being edited out from under the first.
//!
//! A list, not `namespace.Registry`'s keyed-object shape, because order
//! *is* the mechanism here (precedence) -- a JSON array guarantees order, a
//! JSON object's keys don't. Absent or empty is a supported state, not an
//! error.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One rule: a `locals.scm` kind spelling, optionally scoped to one
/// grammar, mapped onto `Tag.kind`'s vocabulary.
pub const Rule = struct {
    /// The `@local.definition.<match>` suffix. Empty is a real, matchable
    /// value: a bare `@local.definition` with no suffix (tree-sitter-ocaml
    /// does this).
    match: []const u8,
    /// A tree-sitter scope, or null to match any grammar.
    scope: ?[]const u8 = null,
    /// `Tag.kind`'s vocabulary: `"class"`, `"method"`, `"call"`, ...
    kind: []const u8,
};

/// `~/.claude/synapse-kind-synonyms.conf` (`SYNAPSE_KIND_SYNONYMS_CONF`
/// overrides it): a JSON array of `Rule`, in file order.
pub const RuleList = struct {
    parsed: std.json.Parsed(std.json.Value),
    /// The allocator `rules` (not the strings it borrows) was allocated
    /// with -- kept explicitly rather than reached through `parsed`'s
    /// internals.
    gpa: Allocator,
    /// Materialized once at load. A malformed entry (missing/wrong-typed
    /// field) is simply absent, not a load-time error -- the rules around
    /// it still apply.
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
        self.gpa.free(self.rules); // borrows strings from parsed.value; only the slice is owned
    }

    /// Whether the list has any rule -- lets a caller skip a pass entirely
    /// rather than walk every capture to learn it has no rule.
    pub fn isEmpty(self: RuleList) bool {
        return self.rules.len == 0;
    }

    /// First rule whose `match` equals `spelling` and whose `scope` is
    /// absent or equals `grammar_scope`. Null means unmapped -- the caller
    /// drops the capture rather than guessing.
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
        // Empty `match` is a real, matchable spelling, not malformed --
        // only a missing or wrong-typed field is rejected.
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

    try testing.expectEqualStrings("constructor", list.kindFor("ctor", "source.zig").?);
    try testing.expectEqualStrings("method", list.kindFor("ctor", "source.ocaml").?); // scope mismatch falls through
}

test "kindFor: a general rule placed first shadows a later scoped one" {
    const gpa = testing.allocator;
    // The more specific rule is never reached; order alone decides.
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
    // tree-sitter-ocaml's locals.scm: `(value_pattern) @local.definition`, no suffix.
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
