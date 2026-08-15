//! Tier 3 (sb-012): guessing which node types are declaration-shaped from a
//! grammar's own `node-types.json`, and which of their fields holds the
//! declared name -- the mechanical half of the tier that has no `tags.scm`
//! or `locals.scm` to lean on at all.
//!
//! `node-types.json` is a `tree-sitter generate` build artifact every real
//! grammar ships, describing every node type's shape: `type`, `named`, and
//! `fields` (a map of field name to what may fill it). It says nothing about
//! *meaning* -- nothing marks a type as "this is a definition" -- so this
//! module is a heuristic classifier, not a schema reader, following Graft's
//! own generic-tier shape exactly (see the Locals.scm design note's own
//! citations): a suffix/prefix test on the type's own name decides whether
//! it looks declaration-shaped at all, and a literal `name` field, when
//! present, is where the declared identifier lives.
//!
//! This is deliberately pure and tree-sitter-C-API-free -- classification
//! reads JSON, nothing else, and is unit-tested the same way
//! `core.kind_synonyms`/`core.namespace` are. The other half of tier 3, the
//! bounded tree-walk for a type with no `name` field, needs a real parsed
//! tree and lives in `tagger.zig` instead, where the C API already is.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One node type judged declaration-shaped, and how to find its name.
pub const Guess = struct {
    /// The grammar's own node type name, e.g. `function_declaration`.
    type_name: []const u8,
    /// `Tag.kind`'s own vocabulary. Derived from whichever heuristic
    /// matched -- see `classifyOne`'s own doc comment.
    kind: []const u8,
    /// Whether `type_name` declares a `name` field -- when true, the
    /// query-emission path (`buildQuery`) covers it; when false, only the
    /// bounded tree-walk (`tagger.zig`'s `tagFileWalk`) can.
    has_name_field: bool,
};

/// A classification result, owned together with the `Guess` slice it holds
/// -- every `Guess` string borrows `parsed`'s own arena, the same shape
/// `core.kind_synonyms.RuleList` already uses for the same reason.
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
/// propagates rather than opening empty the way `core.namespace.Registry`
/// or `core.kind_synonyms.RuleList` do for an absent *user* config: a
/// missing `node-types.json` is not "nothing configured yet," it is tier 3
/// having no schema to guess from at all, and that is a real failure for a
/// tier whose whole premise is "no `tags.scm`, no `locals.scm`, but at
/// least this."
pub fn classify(gpa: Allocator, io: Io, path: []const u8) !Classification {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    return .{ .parsed = parsed, .gpa = gpa, .guesses = try classifyValue(gpa, parsed.value) };
}

/// Type names ending in one of these are declaration-shaped -- Graft's own
/// suffix regex, `/(declaration|definition|_item|_specifier|_decl|_def|_binding)$/`,
/// as a fixed literal-suffix list rather than a regex engine this codebase
/// does not have (see `tagger.zig`'s own docstring on why: no `#match?`
/// support either, same reason).
const declaration_suffixes = [_][]const u8{
    "declaration", "definition", "_item", "_specifier", "_decl", "_def", "_binding",
};

/// A type name starting with one of these (at a `_`-delimited word
/// boundary) is also declaration-shaped, and the matched word doubles as
/// its `Tag.kind` -- Graft's own "class/struct/enum/interface/trait/
/// module/namespace prefix test", the second half of `classifyKind`.
const prefix_kinds = [_][]const u8{
    "class", "struct", "enum", "interface", "trait", "module", "namespace",
};

/// The generic kind a declaration-suffix-only match gets when no prefix
/// keyword also matched -- Graft's own default for an unmapped kind (see
/// the Locals.scm design note's Tier 2 section, which already cites this
/// same fallback for the same reason: a real bucket beats an invented one).
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

/// One `node-types.json` entry, judged. Null when it is not declaration-
/// shaped at all -- most entries in a real schema are not, and that is the
/// expected, common outcome, not a warning-worthy one.
fn classifyOne(item: std.json.Value) !?Guess {
    const obj = switch (item) {
        .object => |o| o,
        else => return null,
    };
    // Anonymous node types (punctuation, literal keywords) are never a
    // declaration -- only named ones are real grammar rules.
    const named = obj.get("named") orelse return null;
    if (named != .bool or !named.bool) return null;

    const type_v = obj.get("type") orelse return null;
    if (type_v != .string or type_v.string.len == 0) return null;
    const type_name = type_v.string;

    const prefix_kind = matchedPrefixKind(type_name);
    if (prefix_kind == null and !hasDeclarationSuffix(type_name)) return null;
    const kind = prefix_kind orelse generic_kind;

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

fn matchedPrefixKind(type_name: []const u8) ?[]const u8 {
    for (prefix_kinds) |kw| {
        if (!std.mem.startsWith(u8, type_name, kw)) continue;
        if (type_name.len == kw.len or type_name[kw.len] == '_') return kw;
    }
    return null;
}

fn hasDeclarationSuffix(type_name: []const u8) bool {
    for (declaration_suffixes) |suf| {
        if (std.mem.endsWith(u8, type_name, suf)) return true;
    }
    return false;
}

/// An ordinary tree-sitter query string, one pattern per `has_name_field`
/// guess -- `(TypeName name: (_) @name) @definition.<kind>`, the exact
/// `tags.scm` capture shape `tagger.zig`'s `tagFileTags` already reads, so
/// this reuses that path unchanged rather than needing a third convention.
/// A guess with no `name` field contributes nothing here; it is
/// `tagFileWalk`'s to find, not a query's.
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

test "a prefix keyword must land on a word boundary" {
    const gpa = testing.allocator;
    // `classy_thing` starts with the letters of `class` but not the word --
    // and has no declaration suffix either, so it is not a match at all.
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
