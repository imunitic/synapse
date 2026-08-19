//! Tier 3 (sb-012): guessing which node types in a grammar's own
//! `node-types.json` are declaration-shaped, and which field holds the name
//! -- a heuristic classifier (Graft's generic-tier shape: a suffix/prefix
//! test on the type name, a literal `name` field for the identifier), not a
//! schema reader, since `node-types.json` says nothing about meaning.
//!
//! Pure and tree-sitter-C-API-free -- reads JSON only. The other half of
//! tier 3, the bounded tree-walk for a type with no `name` field, needs a
//! real parsed tree and lives in `tagger.zig`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

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
    guesses: []const Guess,

    pub fn deinit(self: *Classification) void {
        self.parsed.deinit();
        self.gpa.free(self.guesses);
    }
};

/// `{grammar}/src/node-types.json`, classified. `error.FileNotFound`
/// propagates rather than opening empty the way `core.namespace.Registry`/
/// `core.kind_synonyms.RuleList` do for an absent user config -- a missing
/// `node-types.json` means tier 3 has no schema to guess from at all.
pub fn classify(gpa: Allocator, io: Io, path: []const u8) !Classification {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    return .{ .parsed = parsed, .gpa = gpa, .guesses = try classifyValue(gpa, parsed.value) };
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

/// A type name starting with one of these (at a `_`-boundary) is also
/// declaration-shaped, and the matched word doubles as its `Tag.kind`.
const prefix_kinds = [_][]const u8{
    "class", "struct", "enum", "interface", "trait", "module", "namespace",
};

/// Default kind for a declaration-suffix match with no prefix keyword.
const generic_kind = "function";

fn classifyValue(gpa: Allocator, value: std.json.Value) ![]const Guess {
    const arr = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayListUnmanaged(Guess) = .empty;
    errdefer out.deinit(gpa);
    for (arr.items) |item| {
        if (try classifyOne(item)) |g| try out.append(gpa, g);
    }
    return out.toOwnedSlice(gpa);
}

/// One `node-types.json` entry, judged. Null when not declaration-shaped
/// -- the common, expected outcome for most entries.
fn classifyOne(item: std.json.Value) !?Guess {
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

    // A bare prefix-keyword match alone is too permissive: `struct` (a type
    // expression/literal, not a declaration) matches the keyword "struct"
    // with no suffix at all -- confirmed on tree-sitter-odin, where it
    // fabricated a definition out of a struct literal (`Vec2{x=1,y=2}`).
    // The suffix is the actual declaration-shape signal; the prefix only
    // ever picks which kind label to use.
    if (!hasDeclarationSuffix(type_name)) return null;
    const kind = matchedPrefixKind(type_name) orelse generic_kind;

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

/// Case-insensitive so `Struct_decl`/`STRUCT_DECL` also match; the
/// underscore-or-end boundary itself is unchanged -- widening it to accept
/// a bare case transition (`StructDecl` with no underscore) is a plausible
/// next step but untested against any real grammar, so left alone for now.
fn matchedPrefixKind(type_name: []const u8) ?[]const u8 {
    for (prefix_kinds) |kw| {
        if (type_name.len < kw.len) continue;
        if (!std.ascii.eqlIgnoreCase(type_name[0..kw.len], kw)) continue;
        if (type_name.len == kw.len or type_name[kw.len] == '_') return kw;
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

fn classifyJson(gpa: Allocator, json: []const u8) !Classification {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    return .{ .parsed = parsed, .gpa = gpa, .guesses = try classifyValue(gpa, parsed.value) };
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
