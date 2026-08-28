//! Structured (JsonLogic) querying over a `ports.Store`, built once here as
//! `list` + `read` each candidate + `core.jsonlogic.evaluate`, not a new
//! `Store` method and not per-backend, since the filtering logic is
//! identical regardless of what backend the rows came from. A result row is
//! a small, explicit projection (the note's path plus only the caller-named
//! fields), never the full body as a side effect of filtering: a thin
//! id-plus-snippet shape is too little to answer a real question without a
//! further full read per match, and a full-text-dump mode is the opposite
//! failure (933K characters for one plain-sentence query, measured
//! elsewhere) -- this sits between those two, field-level and bounded
//! either way.
//!
//! Scoped to what a query in this vault actually filters on: `path`,
//! `content`, `frontmatter.*`, `tags`. `stat`/`links`/`backlinks`/
//! `unresolvedLinks` are out of scope here -- `links`/`backlinks`
//! specifically would need a whole-vault cross-reference index, a real
//! feature nothing here needs yet.

const std = @import("std");
const ports = @import("ports");
const jsonlogic = @import("jsonlogic.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const Value = std.json.Value;

/// One matching note: its path, plus one evaluated value per requested
/// field, in the same order as `fields`. Every string here is freshly
/// allocated with the caller's `gpa` -- safe to outlive the `Store` read
/// that produced it, unlike `noteData`'s own tree (arena-scoped, freed
/// before this is returned).
pub const Row = struct {
    path: []const u8,
    values: []Value,

    pub fn deinit(self: Row, gpa: Allocator) void {
        gpa.free(self.path);
        for (self.values) |v| freeValueDeep(gpa, v);
        gpa.free(self.values);
    }
};

/// Runs `filter` against every node `store.list` returns, in list order.
/// A note whose evaluated filter is falsy (JsonLogic truthiness) is
/// skipped. For each match, evaluates `{"var": field}` once per entry in
/// `fields` against that note's data tree and copies the result into the
/// row -- `fields` may be empty, giving just the path. Caller frees the
/// returned slice and each `Row` (`Row.deinit`).
pub fn query(gpa: Allocator, io: Io, store: Store, filter: Value, fields: []const []const u8) !([]Row) {
    const names = try store.list(gpa, io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    var out: std.ArrayListUnmanaged(Row) = .empty;
    errdefer {
        for (out.items) |r| r.deinit(gpa);
        out.deinit(gpa);
    }

    for (names) |name| {
        const body_text = (try store.read(gpa, io, name)) orelse continue;
        defer gpa.free(body_text);

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const data = try noteData(arena, name, body_text);
        const matched = jsonlogic.evaluate(filter, data) catch continue; // an unknown operator: this row just doesn't match
        if (!jsonlogic.truthy(matched)) continue;

        const values = try gpa.alloc(Value, fields.len);
        errdefer gpa.free(values);
        var filled: usize = 0;
        errdefer for (values[0..filled]) |v| freeValueDeep(gpa, v);
        for (fields) |f| {
            const var_rule: Value = .{ .object = blk: {
                var m: std.json.ObjectMap = .empty;
                try m.put(arena, "var", .{ .string = f });
                break :blk m;
            } };
            const field_value = jsonlogic.evaluate(var_rule, data) catch .null;
            values[filled] = try deepCopyValue(gpa, field_value);
            filled += 1;
        }

        try out.append(gpa, .{ .path = try gpa.dupe(u8, name), .values = values });
    }

    return out.toOwnedSlice(gpa);
}

/// `{path, content, frontmatter, tags}` for one note -- everything a real
/// `search_query` filter in this vault has ever actually matched on.
/// Arena-scoped: every string here borrows `body`/`path` directly, no
/// copying, since the caller discards the arena once it's done evaluating
/// this one note.
fn noteData(arena: Allocator, path: []const u8, body: []const u8) !Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "path", .{ .string = path });
    try root.put(arena, "content", .{ .string = body });
    try root.put(arena, "frontmatter", try frontmatterAsJson(arena, body));
    try root.put(arena, "tags", try tagsAsJson(arena, body));
    return .{ .object = root };
}

/// Root-level (column-0) `key: value` and `key: [a, b]` lines only --
/// the same scope `core.frontmatter.set` already documents as this
/// codebase's own limit on what it treats as structured frontmatter. A
/// nested block-style value (`sources:` with indented `- path:` entries)
/// is skipped for that key, not guessed at.
fn frontmatterAsJson(arena: Allocator, body: []const u8) !Value {
    var obj: std.json.ObjectMap = .empty;
    var it = @import("query.zig").FrontmatterIterator.init(body);
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue; // a nested/continuation line
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (key.len == 0) continue;
        const raw_value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try obj.put(arena, key, try parseScalarOrList(arena, raw_value));
    }
    return .{ .object = obj };
}

fn parseScalarOrList(arena: Allocator, raw: []const u8) !Value {
    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
        const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " ");
        if (inner.len == 0) return .{ .array = .init(arena) };
        var items: std.json.Array = .init(arena);
        var parts = std.mem.splitScalar(u8, inner, ',');
        while (parts.next()) |part| {
            try items.append(.{ .string = unquote(std.mem.trim(u8, part, " ")) });
        }
        return .{ .array = items };
    }
    return .{ .string = unquote(raw) };
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

/// `frontmatter.tags`'s flow sequence, surfaced separately at the top level
/// too -- matching the real `NoteJson` shape (`tags` is its own field,
/// alongside `frontmatter`, not something a caller has to reach into
/// `frontmatter.tags` for).
fn tagsAsJson(arena: Allocator, body: []const u8) !Value {
    const fm = try frontmatterAsJson(arena, body);
    return fm.object.get("tags") orelse .{ .array = .init(arena) };
}

fn deepCopyValue(gpa: Allocator, v: Value) !Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try gpa.dupe(u8, s) },
        .string => |s| .{ .string = try gpa.dupe(u8, s) },
        .array => |a| blk: {
            var out: std.json.Array = .init(gpa);
            errdefer out.deinit();
            for (a.items) |item| try out.append(try deepCopyValue(gpa, item));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            errdefer out.deinit(gpa);
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = try gpa.dupe(u8, entry.key_ptr.*);
                try out.put(gpa, key, try deepCopyValue(gpa, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

fn freeValueDeep(gpa: Allocator, v: Value) void {
    switch (v) {
        .null, .bool, .integer, .float => {},
        .number_string => |s| gpa.free(s),
        .string => |s| gpa.free(s),
        .array => |a| {
            for (a.items) |item| freeValueDeep(gpa, item);
            var mut = a;
            mut.deinit();
        },
        .object => |o| {
            var mut = o;
            var it = mut.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                freeValueDeep(gpa, entry.value_ptr.*);
            }
            mut.deinit(gpa);
        },
    }
}

const testing = std.testing;

/// A minimal in-memory `Store`, local to this file's tests. `core` cannot
/// import `adapters.fakes.FakeStore` (adapters depends on core, never the
/// reverse), so this is its own small copy of the same idea, insertion
/// order preserved via a plain list rather than a hash map, since a couple
/// of these tests care that `list`'s own order matches write order.
const TestStore = struct {
    gpa: Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    bodies: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(gpa: Allocator) TestStore {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *TestStore) void {
        for (self.names.items) |n| self.gpa.free(n);
        for (self.bodies.items) |b| self.gpa.free(b);
        self.names.deinit(self.gpa);
        self.bodies.deinit(self.gpa);
    }

    fn set(self: *TestStore, name: []const u8, body: []const u8) !void {
        try self.names.append(self.gpa, try self.gpa.dupe(u8, name));
        try self.bodies.append(self.gpa, try self.gpa.dupe(u8, body));
    }

    fn store(self: *TestStore) Store {
        return Store.from(TestStore, self);
    }

    pub fn read(self: *TestStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        _ = io;
        for (self.names.items, self.bodies.items) |n, b| {
            if (std.mem.eql(u8, n, node)) return try gpa.dupe(u8, b);
        }
        return null;
    }

    pub fn write(self: *TestStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        _ = .{ self, io, node, body };
        return .{ .accepted = true };
    }

    pub fn list(self: *TestStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        _ = io;
        const out = try gpa.alloc([]const u8, self.names.items.len);
        for (self.names.items, 0..) |n, i| out[i] = try gpa.dupe(u8, n);
        return out;
    }

    pub fn search(self: *TestStore, gpa: Allocator, io: Io, q: []const u8) anyerror![]const Store.Hit {
        _ = .{ self, gpa, io, q };
        return &.{};
    }
};

test "query filters by frontmatter status and projects the requested field" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("a.md", "---\nstatus: TODO\n---\nbody a\n");
    try fs.set("b.md", "---\nstatus: DONE\n---\nbody b\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa, "{\"==\": [{\"var\": \"frontmatter.status\"}, \"TODO\"]}", .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{"frontmatter.status"});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("a.md", rows[0].path);
    try testing.expectEqualStrings("TODO", rows[0].values[0].string);
}

test "query with an always-true filter returns every node, in list order" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("a.md", "body\n");
    try fs.set("b.md", "body\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa, "true", .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(usize, 0), rows[0].values.len);
}

test "content and path are queryable fields, not just frontmatter" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("designs/x.md", "## Status\nReady\n");
    try fs.set("tasks/y.md", "## Status\nReady\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa,
        \\{"and": [{"glob": ["designs/*", {"var": "path"}]}, {"regexp": ["Ready", {"var": "content"}]}]}
    , .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{"path"});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("designs/x.md", rows[0].path);
}

test "a tags flow-sequence is queryable as an array field" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("a.md", "---\ntags: [synapse, vault-infra]\n---\nbody\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa, "{\"in\": [\"synapse\", {\"var\": \"tags\"}]}", .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
}

test "a note that fails to match the filter contributes no row" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("a.md", "---\nstatus: TODO\n---\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa, "{\"==\": [{\"var\": \"frontmatter.status\"}, \"DONE\"]}", .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "a missing requested field projects as JSON null, not an error" {
    const gpa = testing.allocator;
    var fs = TestStore.init(gpa);
    defer fs.deinit();
    try fs.set("a.md", "---\ntitle: x\n---\n");
    const store = fs.store();

    var filter = try std.json.parseFromSlice(Value, gpa, "true", .{});
    defer filter.deinit();

    const rows = try query(gpa, testing.io, store, filter.value, &.{"frontmatter.missing"});
    defer {
        for (rows) |r| r.deinit(gpa);
        gpa.free(rows);
    }
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(Value.null, rows[0].values[0]);
}
