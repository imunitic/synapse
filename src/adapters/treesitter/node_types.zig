//! Tier 2: guessing which node types in a grammar's own
//! `node-types.json` are declaration-shaped, and which field holds the name
//! -- a heuristic classifier (Graft's generic-tier shape: a suffix/prefix
//! test on the type name, a literal `name` field for the identifier), not a
//! schema reader, since `node-types.json` says nothing about meaning.
//!
//! Tree-sitter-C-API-free -- reads JSON only, still no parsing/tagging here.
//! `kind_rules` is consulted, not just applied after the fact: a rule can
//! also force-classify a type the suffix/prefix heuristic missed entirely
//! (confirmed needed against `tree-sitter-ada`'s `subprogram_body`, which
//! names a full function-with-implementation but has no `_declaration`/
//! `_definition`/`decl`/`def` suffix at all -- a relabel-only override could
//! never rescue it, since it never became a `Guess` to relabel). The other
//! half of tier 2, the bounded tree-walk for a type with no `name` field,
//! needs a real parsed tree and lives in `tagger.zig`.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RuleList = core.kind_synonyms.RuleList;

/// One node type judged declaration-shaped, and how to find its name.
pub const Guess = struct {
    /// The grammar's own node type name, e.g. `function_declaration`.
    type_name: []const u8,
    /// `Tag.kind`'s vocabulary, from whichever heuristic matched.
    kind: []const u8,
    /// Whether `type_name` declares a `name` field: true means `buildQuery`
    /// covers it; false means only `tagger.zig`'s bounded walk can.
    has_name_field: bool,
};

/// Owned together with the `Guess` slice -- every `Guess` string borrows
/// `parsed`'s arena, like `core.kind_synonyms.RuleList`.
pub const Classification = struct {
    parsed: std.json.Parsed(std.json.Value),
    gpa: Allocator,
    guesses: []Guess,

    pub fn deinit(self: *Classification) void {
        self.parsed.deinit();
        self.gpa.free(self.guesses);
    }
};

/// `{grammar}/src/node-types.json`, classified. `error.FileNotFound`
/// propagates rather than opening empty the way `core.namespace.Registry`/
/// `core.kind_synonyms.RuleList` do for an absent user config -- a missing
/// `node-types.json` means tier 2 has no schema to guess from at all.
pub fn classify(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    kind_rules: RuleList,
    scope: []const u8,
) !Classification {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    return .{
        .parsed = parsed,
        .gpa = gpa,
        .guesses = try classifyValue(gpa, parsed.value, kind_rules, scope),
    };
}

/// Type names ending in one of these are declaration-shaped -- Graft's own
/// suffix regex, as a fixed literal-suffix list (no regex engine here, same
/// reason `tagger.zig` has no `#match?` support). Matched case-insensitively
/// (see `hasDeclarationSuffix`), so both the snake_case spelling
/// (`_decl`) and the PascalCase one (`VarDecl`) hit the same entry --
/// confirmed against `maxxnino/tree-sitter-zig`, which names every
/// declaration-shaped node `*Decl`/`*Def` with no underscore at all.
const declaration_suffixes = [_][]const u8{
    "declaration", "definition", "_item", "_specifier", "decl", "def", "_binding",
};

/// A type name starting with one of these (at a boundary -- `_`, a
/// following capital letter, or the type name simply ending there) is also
/// declaration-shaped, and the matched word doubles as its `Tag.kind`. The
/// second column of each new entry below is not invented: it's the kind
/// `tree-sitter-odin`'s own real `locals.scm` already uses for the matching
/// node (`package_declaration`/`import_declaration` -> `namespace`,
/// `const_declaration` -> `constant`, `variable_declaration` -> `var`,
/// `parameter` -> `parameter`), reused here for consistency rather than
/// picked ad hoc. `test`/`container`/`error` have no such precedent to
/// borrow (confirmed only against `maxxnino/tree-sitter-zig`'s
/// `TestDecl`/`ContainerDecl`/`ErrorSetDecl`) -- mapped to the closest
/// existing label rather than inventing a new one.
const prefix_kinds = [_][]const u8{
    "class",     "struct", "enum",      "interface", "trait", "module",
    "namespace", "const",  "var",       "variable",  "param", "parameter",
    "package",   "import", "container", "error",     "test",
};

const prefix_kind_overrides = std.StaticStringMap([]const u8).initComptime(.{
    .{ "const", "constant" },
    .{ "variable", "var" },
    .{ "param", "parameter" },
    .{ "package", "namespace" },
    .{ "import", "namespace" },
    .{ "container", "type" },
    .{ "error", "type" },
});

/// Default kind for a declaration-suffix match with no prefix keyword.
const generic_kind = "function";

fn classifyValue(
    gpa: Allocator,
    value: std.json.Value,
    kind_rules: RuleList,
    scope: []const u8,
) ![]Guess {
    const arr = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayListUnmanaged(Guess) = .empty;
    errdefer out.deinit(gpa);
    for (arr.items) |item| {
        if (try classifyOne(item, kind_rules, scope)) |g| try out.append(gpa, g);
    }
    return out.toOwnedSlice(gpa);
}

/// One `node-types.json` entry, judged. Null when not declaration-shaped
/// -- the common, expected outcome for most entries.
fn classifyOne(item: std.json.Value, kind_rules: RuleList, scope: []const u8) !?Guess {
    const obj = switch (item) {
        .object => |o| o,
        else => return null,
    };
    // Anonymous types (punctuation, literal keywords) are never declarations.
    const named = obj.get("named") orelse return null;
    if (named != .bool or !named.bool) return null;

    const type_v = obj.get("type") orelse return null;
    if (type_v != .string or type_v.string.len == 0) return null;
    const type_name = type_v.string;

    // `synapse-kind-synonyms.conf` can force-classify a type the generic
    // heuristic missed entirely, not just relabel one it already caught --
    // `subprogram_body` above is exactly that case, and a relabel-only rule
    // could never reach it. A bare prefix-keyword match alone is still too
    // permissive on its own: `struct` (a type expression/literal, not a
    // declaration) matches the keyword "struct" with no suffix at all --
    // confirmed on tree-sitter-odin, where it fabricated a definition out
    // of a struct literal (`Vec2{x=1,y=2}`). The suffix (or an explicit
    // rule) is the declaration-shape signal; the prefix only ever picks
    // which kind label to use when no rule already decided one.
    const override_kind = kind_rules.kindFor(type_name, scope);
    if (override_kind == null and !hasDeclarationSuffix(type_name)) return null;
    const kind = override_kind orelse (matchedPrefixKind(type_name) orelse generic_kind);

    const has_name_field = blk: {
        const fields_v = obj.get("fields") orelse break :blk false;
        const fields = switch (fields_v) {
            .object => |o| o,
            else => break :blk false,
        };
        break :blk fields.contains("name");
    };

    return .{ .type_name = type_name, .kind = kind, .has_name_field = has_name_field };
}

/// Case-insensitive so `Struct_decl`/`STRUCT_DECL` also match. Boundary
/// after the prefix word is `_`, the string simply ending there, or a
/// capital letter -- a PascalCase word transition (`ParamDecl`), confirmed
/// needed against `maxxnino/tree-sitter-zig`, whose declaration nodes are
/// all PascalCase with no separator at all. A lowercase continuation still
/// correctly rejects (`structure` does not match `struct`).
fn matchedPrefixKind(type_name: []const u8) ?[]const u8 {
    for (prefix_kinds) |kw| {
        if (type_name.len < kw.len) continue;
        if (!std.ascii.eqlIgnoreCase(type_name[0..kw.len], kw)) continue;
        if (type_name.len == kw.len or type_name[kw.len] == '_' or
            std.ascii.isUpper(type_name[kw.len]))
        {
            return prefix_kind_overrides.get(kw) orelse kw;
        }
    }
    return null;
}

/// Case-insensitive: `_decl`/`_def`'s PascalCase spelling (`VarDecl`,
/// `TestDef`) carries the same signal with no underscore at all.
fn hasDeclarationSuffix(type_name: []const u8) bool {
    for (declaration_suffixes) |suf| {
        if (type_name.len < suf.len) continue;
        if (std.ascii.eqlIgnoreCase(type_name[type_name.len - suf.len ..], suf)) return true;
    }
    return false;
}

/// One pattern per `has_name_field` guess, in the exact tags.scm capture
/// shape `tagFileTags` already reads. A guess with no `name` field
/// contributes nothing -- that's `tagFileWalk`'s to find.
pub fn buildQuery(gpa: Allocator, guesses: []const Guess) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (guesses) |g| {
        if (!g.has_name_field) continue;
        try out.writer.print("({s} name: (_) @name) @definition.{s}\n", .{ g.type_name, g.kind });
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

/// No rules -- the common case every existing test wants, and consistent
/// with an absent `synapse-kind-synonyms.conf` in real use (empty, not an
/// error). `classifyJsonWithRules` below is for the force-classify tests.
fn classifyJson(gpa: Allocator, json: []const u8) !Classification {
    var rules = try RuleList.load(gpa, testing.io, "/nonexistent");
    defer rules.deinit();
    return classifyJsonWithRules(gpa, json, rules, "test-scope");
}

fn classifyJsonWithRules(gpa: Allocator, json: []const u8, rules: RuleList, scope: []const u8) !Classification {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    return .{
        .parsed = parsed,
        .gpa = gpa,
        .guesses = try classifyValue(gpa, parsed.value, rules, scope),
    };
}

test "an anonymous node type is never declaration-shaped, however it is named" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "class_declaration", "named": false}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.guesses.len);
}

test "a plain node with no declaration-shaped name is skipped" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "identifier", "named": true},
        \\ {"type": "block", "named": true}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.guesses.len);
}

test "a declaration suffix with no prefix keyword gets the generic kind" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "function_declaration", "named": true,
        \\  "fields": {"name": {}}}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.guesses.len);
    try testing.expectEqualStrings("function_declaration", c.guesses[0].type_name);
    try testing.expectEqualStrings("function", c.guesses[0].kind);
    try testing.expect(c.guesses[0].has_name_field);
}

test "a prefix keyword becomes the kind, not the generic default" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "struct_item", "named": true, "fields": {"name": {}}}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.guesses.len);
    try testing.expectEqualStrings("struct", c.guesses[0].kind);
}

test "prefix_kinds expansion: real node types from tree-sitter-odin and maxxnino/tree-sitter-zig" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "package_declaration", "named": true},
        \\ {"type": "import_declaration", "named": true},
        \\ {"type": "const_declaration", "named": true},
        \\ {"type": "variable_declaration", "named": true},
        \\ {"type": "ParamDecl", "named": true},
        \\ {"type": "VarDecl", "named": true},
        \\ {"type": "TestDecl", "named": true},
        \\ {"type": "ContainerDecl", "named": true},
        \\ {"type": "ErrorSetDecl", "named": true}]
    );
    defer c.deinit();
    const want = [_]struct { type_name: []const u8, kind: []const u8 }{
        .{ .type_name = "package_declaration", .kind = "namespace" },
        .{ .type_name = "import_declaration", .kind = "namespace" },
        .{ .type_name = "const_declaration", .kind = "constant" },
        .{ .type_name = "variable_declaration", .kind = "var" },
        .{ .type_name = "ParamDecl", .kind = "parameter" },
        .{ .type_name = "VarDecl", .kind = "var" },
        .{ .type_name = "TestDecl", .kind = "test" },
        .{ .type_name = "ContainerDecl", .kind = "type" },
        .{ .type_name = "ErrorSetDecl", .kind = "type" },
    };
    try testing.expectEqual(want.len, c.guesses.len);
    for (want, c.guesses) |w, g| {
        try testing.expectEqualStrings(w.type_name, g.type_name);
        try testing.expectEqualStrings(w.kind, g.kind);
    }
}

test "a PascalCase word boundary rejects a lowercase continuation, same as the underscore rule" {
    // Has a real declaration suffix ("Decl"), so it still classifies -- but
    // "Structure" is not "Struct" + a word boundary, so the kind must fall
    // back to generic, not wrongly become "struct". Same guard as the
    // existing `classy_thing` test, now also covering the PascalCase path.
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "StructureDecl", "named": true}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.guesses.len);
    try testing.expectEqualStrings(generic_kind, c.guesses[0].kind);
}

test "PascalCase Decl/Def suffixes match the same as snake_case _decl/_def" {
    // Confirmed live against maxxnino/tree-sitter-zig: every declaration
    // node is PascalCase (VarDecl, ParamDecl, TestDecl, ...), no underscore
    // at all. Before this, the classifier found zero guesses for that
    // grammar; case-insensitive bare decl/def recovers most of them.
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "VarDecl", "named": true},
        \\ {"type": "TestDef", "named": true},
        \\ {"type": "FnProto", "named": true}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.guesses.len);
    try testing.expectEqualStrings("VarDecl", c.guesses[0].type_name);
    try testing.expectEqualStrings("TestDef", c.guesses[1].type_name);
}

test "a bare prefix keyword with no declaration suffix does not qualify on its own" {
    // Confirmed live against tree-sitter-odin: a node type literally named
    // "struct" is the type-expression/composite-literal node (used at a
    // struct literal like `Vec2{x=1,y=2}`), not a declaration -- matching
    // it fabricated a fake definition out of a usage site.
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "struct", "named": true},
        \\ {"type": "struct_type", "named": true},
        \\ {"type": "struct_declaration", "named": true, "fields": {"name": {}}}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.guesses.len);
    try testing.expectEqualStrings("struct_declaration", c.guesses[0].type_name);
}

test "a prefix keyword must land on a word boundary" {
    const gpa = testing.allocator;
    // `classy_thing` isn't the word "class", and has no declaration suffix.
    var c = try classifyJson(gpa,
        \\[{"type": "classy_thing", "named": true}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.guesses.len);
}

test "no fields at all means no name field, not an error" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa,
        \\[{"type": "variable_declaration", "named": true}]
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.guesses.len);
    try testing.expect(!c.guesses[0].has_name_field);
}

test "buildQuery emits one pattern per name-field guess, skipping the rest" {
    const gpa = testing.allocator;
    const guesses = [_]Guess{
        .{ .type_name = "function_declaration", .kind = "function", .has_name_field = true },
        .{ .type_name = "variable_declaration", .kind = "function", .has_name_field = false },
        .{ .type_name = "struct_item", .kind = "struct", .has_name_field = true },
    };
    const q = try buildQuery(gpa, &guesses);
    defer gpa.free(q);
    try testing.expectEqualStrings(
        "(function_declaration name: (_) @name) @definition.function\n" ++
            "(struct_item name: (_) @name) @definition.struct\n",
        q,
    );
}

test "buildQuery on an all-walk-only list is empty, not an error" {
    const gpa = testing.allocator;
    const guesses = [_]Guess{
        .{ .type_name = "variable_declaration", .kind = "function", .has_name_field = false },
    };
    const q = try buildQuery(gpa, &guesses);
    defer gpa.free(q);
    try testing.expectEqualStrings("", q);
}

test "a non-array top level classifies to nothing, not an error" {
    const gpa = testing.allocator;
    var c = try classifyJson(gpa, "{}");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.guesses.len);
}

test "a kind_rules entry force-classifies a type the suffix/prefix heuristic misses entirely" {
    // subprogram_body: confirmed live against tree-sitter-ada -- a full
    // function-with-implementation, no "_declaration"/"_definition"/"decl"/
    // "def" suffix at all, so it never became a Guess before this fix. A
    // relabel-only override could never reach it, since there was nothing
    // to relabel.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const conf_path = try std.fmt.allocPrint(gpa, "{s}/kind-synonyms.conf", .{dir});
    defer gpa.free(conf_path);
    try tmp.dir.writeFile(io, .{
        .sub_path = "kind-synonyms.conf",
        .data =
        \\[{"match": "subprogram_body", "scope": "source.ada", "kind": "function"}]
        ,
    });

    var rules = try RuleList.load(gpa, io, conf_path);
    defer rules.deinit();

    // Without the rule (wrong scope): still nothing, exactly as before.
    var wrong_scope = try classifyJsonWithRules(gpa,
        \\[{"type": "subprogram_body", "named": true, "fields": {"name": {}}}]
    , rules, "source.zig");
    defer wrong_scope.deinit();
    try testing.expectEqual(@as(usize, 0), wrong_scope.guesses.len);

    // With the rule, scoped correctly: now classified, with the ruled kind.
    var right_scope = try classifyJsonWithRules(gpa,
        \\[{"type": "subprogram_body", "named": true, "fields": {"name": {}}}]
    , rules, "source.ada");
    defer right_scope.deinit();
    try testing.expectEqual(@as(usize, 1), right_scope.guesses.len);
    try testing.expectEqualStrings("subprogram_body", right_scope.guesses[0].type_name);
    try testing.expectEqualStrings("function", right_scope.guesses[0].kind);
    try testing.expect(right_scope.guesses[0].has_name_field);
}
