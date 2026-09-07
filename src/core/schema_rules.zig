//! Converts a parsed schema-YAML rule (`schema_yaml.Value`) into the
//! `std.json.Value` tree `jsonlogic.evaluate()` operates on, once at
//! schema-load time -- not a per-evaluation cost, and `jsonlogic.zig`
//! itself never sees `schema_yaml.Value` at all.
//!
//! Also renames JsonLogic's symbolic operators to word aliases along the
//! way: `schema_yaml.zig`'s `validKey` requires a mapping key to start with
//! a letter or `_` and stay alphanumeric/`_`/`-` after that, so `==`, `!=`,
//! `<`, `<=`, `>`, `>=`, and `!` can never be written as a schema-YAML key
//! at all -- `eq`/`ne`/`lt`/`lte`/`gt`/`gte`/`not` (MongoDB's own
//! query-operator naming convention) are the only way to spell them in a
//! schema document, renamed back to the canonical symbols here so
//! `jsonlogic.zig` never has to know the word forms exist.
//!
//! A map's key gets renamed only when the map has exactly one entry --
//! the same "operator-shaped" test `evaluate()` itself applies
//! (`obj.count() != 1` is a literal object, keys untouched). A multi-key
//! map is real data, not an operator dispatch, and renaming its keys would
//! corrupt it.

const std = @import("std");
const schema_yaml = @import("schema_yaml.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const YamlValue = schema_yaml.Value;

pub const Error = error{
    /// A bare `null` (schema_yaml's `.tombstone`) is only ever valid inside
    /// a schema *override* document, where it deletes a key from the merged
    /// result. It can never legitimately appear inside an ordinary
    /// `checks:`/`lints:` rule.
    StrayTombstone,
} || Allocator.Error;

const alias_table = [_]struct { word: []const u8, symbol: []const u8 }{
    .{ .word = "eq", .symbol = "==" },
    .{ .word = "ne", .symbol = "!=" },
    .{ .word = "lt", .symbol = "<" },
    .{ .word = "lte", .symbol = "<=" },
    .{ .word = "gt", .symbol = ">" },
    .{ .word = "gte", .symbol = ">=" },
    .{ .word = "not", .symbol = "!" },
};

fn renameOperator(key: []const u8) []const u8 {
    for (alias_table) |pair| {
        if (std.mem.eql(u8, key, pair.word)) return pair.symbol;
    }
    return key;
}

/// Converts one `checks:`/`lints:` list entry (or any sub-rule within it)
/// into the tree `jsonlogic.evaluate()` expects.
pub fn toRule(gpa: Allocator, value: *const YamlValue) Error!JsonValue {
    return switch (value.*) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .boolean => |b| .{ .bool = b },
        .tombstone => Error.StrayTombstone,
        .list => |items| blk: {
            var arr: std.json.Array = .init(gpa);
            for (items) |item| try arr.append(try toRule(gpa, item));
            break :blk .{ .array = arr };
        },
        .map => |entries| blk: {
            var obj: std.json.ObjectMap = .empty;
            const rename = entries.len == 1;
            for (entries) |entry| {
                const key = if (rename) renameOperator(entry.key) else entry.key;
                try obj.put(gpa, key, try toRule(gpa, entry.value));
            }
            break :blk .{ .object = obj };
        },
    };
}

/// Every distinct stem a rule tree references via `{"var":
/// "vocabularies.<stem>"}`, appended to `out` in the order first seen, no
/// duplicates. Pure tree-walking, no I/O -- the file this names
/// (`<stem>.conf`) still has to be read by the caller before building the
/// data tree; this only says *which* files are actually needed, not every
/// vocabulary conf file that happens to exist, and not a fixed pair.
pub fn scanVocabularyStems(gpa: Allocator, rule: JsonValue, out: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    switch (rule) {
        .object => |obj| {
            if (obj.count() == 1) {
                var it = obj.iterator();
                const entry = it.next().?;
                if (std.mem.eql(u8, entry.key_ptr.*, "var") and entry.value_ptr.* == .string) {
                    const prefix = "vocabularies.";
                    const path = entry.value_ptr.*.string;
                    if (std.mem.startsWith(u8, path, prefix)) {
                        const stem = path[prefix.len..];
                        for (out.items) |seen| if (std.mem.eql(u8, seen, stem)) return;
                        try out.append(gpa, stem);
                    }
                    return;
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| try scanVocabularyStems(gpa, entry.value_ptr.*, out);
        },
        .array => |arr| for (arr.items) |item| try scanVocabularyStems(gpa, item, out),
        else => {},
    }
}

/// True iff the converted rule tree contains `{"var": path}` anywhere,
/// exact match -- used to detect whether a schema's own `checks:` actually
/// consults a given precomputed field (e.g. `id_is_unique`) before a caller
/// bothers doing the expensive work that field depends on.
pub fn referencesVar(rule: JsonValue, path: []const u8) bool {
    switch (rule) {
        .object => |obj| {
            if (obj.count() == 1) {
                var it = obj.iterator();
                const entry = it.next().?;
                if (std.mem.eql(u8, entry.key_ptr.*, "var") and entry.value_ptr.* == .string) {
                    return std.mem.eql(u8, entry.value_ptr.*.string, path);
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| if (referencesVar(entry.value_ptr.*, path)) return true;
            return false;
        },
        .array => |arr| {
            for (arr.items) |item| if (referencesVar(item, path)) return true;
            return false;
        },
        else => return false,
    }
}

const testing = std.testing;

// `toRule`'s output is a nested tree (objects can contain arrays can
// contain objects, arbitrarily deep) -- a single top-level `.deinit()`
// only frees that one container's own storage, not what it holds. Every
// test here uses an arena instead, the same convention `vault_query.zig`'s
// own tree-building helpers already use for exactly this shape of problem:
// one `deinit()` at the end frees everything built during the test, with
// no per-node bookkeeping.

test "scalars pass through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var v = schema_yaml.Value{ .string = "REVIEW" };
    const got = try toRule(gpa, &v);
    try testing.expectEqualStrings("REVIEW", got.string);

    var i = schema_yaml.Value{ .integer = 42 };
    const got_i = try toRule(gpa, &i);
    try testing.expectEqual(@as(i64, 42), got_i.integer);

    var b = schema_yaml.Value{ .boolean = true };
    const got_b = try toRule(gpa, &b);
    try testing.expect(got_b.bool);
}

test "a bare tombstone is a load-time error inside an ordinary rule" {
    const gpa = testing.allocator;
    var v: schema_yaml.Value = .tombstone;
    try testing.expectError(Error.StrayTombstone, toRule(gpa, &v));
}

test "list converts to a json array, element by element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var one = schema_yaml.Value{ .string = "a" };
    var two = schema_yaml.Value{ .string = "b" };
    var v = schema_yaml.Value{ .list = &.{ &one, &two } };
    const got = try toRule(gpa, &v);
    try testing.expectEqual(@as(usize, 2), got.array.items.len);
    try testing.expectEqualStrings("a", got.array.items[0].string);
    try testing.expectEqualStrings("b", got.array.items[1].string);
}

test "a single-entry map renames a word-alias operator key to its symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var status = schema_yaml.Value{ .string = "frontmatter.status" };
    var review = schema_yaml.Value{ .string = "REVIEW" };
    var values = schema_yaml.Value{ .list = &.{ &status, &review } };
    var v = schema_yaml.Value{ .map = &.{.{ .key = "eq", .value = &values }} };
    const got = try toRule(gpa, &v);
    try testing.expect(got.object.get("==") != null);
    try testing.expect(got.object.get("eq") == null);
}

test "an already-alpha operator key (and/or/var/...) passes through unrenamed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var inner = schema_yaml.Value{ .boolean = true };
    var v = schema_yaml.Value{ .map = &.{.{ .key = "and", .value = &inner }} };
    const got = try toRule(gpa, &v);
    try testing.expect(got.object.get("and") != null);
}

test "a multi-key map is literal data -- keys stay untouched, not renamed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a = schema_yaml.Value{ .string = "x" };
    var b = schema_yaml.Value{ .string = "y" };
    var v = schema_yaml.Value{ .map = &.{
        .{ .key = "eq", .value = &a },
        .{ .key = "not", .value = &b },
    } };
    const got = try toRule(gpa, &v);
    // Two entries: evaluate() would treat this as a literal object, not an
    // operator dispatch, so neither key gets renamed.
    try testing.expect(got.object.get("eq") != null);
    try testing.expect(got.object.get("not") != null);
    try testing.expect(got.object.get("==") == null);
    try testing.expect(got.object.get("!") == null);
}

test "a real checks: entry converts to the exact tree the symbolic form would have produced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var status_ref = schema_yaml.Value{ .string = "frontmatter.status" };
    var status_var = schema_yaml.Value{ .map = &.{.{ .key = "var", .value = &status_ref }} };
    var review = schema_yaml.Value{ .string = "REVIEW" };
    var eq_args = schema_yaml.Value{ .list = &.{ &status_var, &review } };
    var rule = schema_yaml.Value{ .map = &.{.{ .key = "eq", .value = &eq_args }} };

    const converted = try toRule(gpa, &rule);

    const jsonlogic = @import("jsonlogic.zig");
    var data = std.json.ObjectMap.empty;
    var frontmatter = std.json.ObjectMap.empty;
    try frontmatter.put(gpa, "status", .{ .string = "REVIEW" });
    try data.put(gpa, "frontmatter", .{ .object = frontmatter });

    const result = try jsonlogic.evaluate(converted, .{ .object = data }, null, null);
    try testing.expect(result.bool);
}

test "end to end: real schema YAML, word-alias operators, through parse and evaluate" {
    var doc = try schema_yaml.parse(testing.allocator,
        \\checks:
        \\  - eq:
        \\      - var: frontmatter.status
        \\      - REVIEW
        \\  - not_a_real_key: ignored
    );
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const checks = doc.root.get("checks").?;
    const converted = try toRule(gpa, checks.list[0]);

    const jsonlogic = @import("jsonlogic.zig");
    var data = std.json.ObjectMap.empty;
    var frontmatter = std.json.ObjectMap.empty;
    try frontmatter.put(gpa, "status", .{ .string = "REVIEW" });
    try data.put(gpa, "frontmatter", .{ .object = frontmatter });

    const result = try jsonlogic.evaluate(converted, .{ .object = data }, null, null);
    try testing.expect(result.bool);
}

test "the design note's own 'named rule composed with a primitive' example parses at its deeper nesting depth" {
    var doc = try schema_yaml.parse(testing.allocator,
        \\checks:
        \\  - and:
        \\      - no_hard_wrap: body.prose
        \\      - eq:
        \\          - var: frontmatter.status
        \\          - Ready
    );
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Just confirms the deeper nesting depth (a rule composed inside `and`,
    // itself containing a rule composed inside `eq`) parses and converts
    // without error -- `no_hard_wrap` isn't registered as a custom operator
    // yet (a later checklist item), so this doesn't evaluate the rule.
    const checks = doc.root.get("checks").?;
    _ = try toRule(gpa, checks.list[0]);
}

test "scanVocabularyStems finds a vocabularies.<stem> var path nested inside all/in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var doc = try schema_yaml.parse(testing.allocator,
        \\checks:
        \\  - all:
        \\      - var: frontmatter.tags
        \\      - in:
        \\          - var: ""
        \\          - var: vocabularies.synapse-tag-vocabulary
    );
    defer doc.deinit();

    const checks = doc.root.get("checks").?;
    const converted = try toRule(gpa, checks.list[0]);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try scanVocabularyStems(gpa, converted, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("synapse-tag-vocabulary", out.items[0]);
}

test "scanVocabularyStems finds every distinct stem across the whole tree, no duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var doc = try schema_yaml.parse(testing.allocator,
        \\checks:
        \\  - or:
        \\      - in:
        \\          - var: vocabularies.a
        \\          - var: frontmatter.x
        \\      - in:
        \\          - var: vocabularies.b
        \\          - var: frontmatter.y
        \\      - in:
        \\          - var: vocabularies.a
        \\          - var: frontmatter.z
    );
    defer doc.deinit();

    const checks = doc.root.get("checks").?;
    const converted = try toRule(gpa, checks.list[0]);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try scanVocabularyStems(gpa, converted, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("a", out.items[0]);
    try testing.expectEqualStrings("b", out.items[1]);
}

test "scanVocabularyStems finds nothing when no rule references vocabularies at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var doc = try schema_yaml.parse(testing.allocator,
        \\checks:
        \\  - eq:
        \\      - var: frontmatter.status
        \\      - REVIEW
    );
    defer doc.deinit();

    const checks = doc.root.get("checks").?;
    const converted = try toRule(gpa, checks.list[0]);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try scanVocabularyStems(gpa, converted, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
