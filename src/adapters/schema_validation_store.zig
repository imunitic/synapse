//! Mandatory validation boundary for schema-declaring Vault notes.
//!
//! Legacy notes with no `schema` field pass through unchanged. Once a note
//! declares one, its schema resolves from
//! `${SYNAPSE_CONTENT_ROOT}/schema/{identifier}.yaml`, is parsed and
//! validated, and the candidate note reaches the inner Store only on
//! success. Reads, listing, and searching are transparent pass-throughs.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const local_timestamp = @import("local_timestamp.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Store = ports.Store;

pub const SchemaValidationStore = struct {
    gpa: Allocator,
    inner: Store,
    vars: core.conf.Vars,

    pub fn init(gpa: Allocator, inner: Store, vars: core.conf.Vars) SchemaValidationStore {
        return .{ .gpa = gpa, .inner = inner, .vars = vars };
    }

    pub fn store(self: *SchemaValidationStore) Store {
        return Store.from(SchemaValidationStore, self);
    }

    pub fn read(self: *SchemaValidationStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        return self.inner.read(gpa, io, node);
    }

    pub fn list(self: *SchemaValidationStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return self.inner.list(gpa, io);
    }

    pub fn search(self: *SchemaValidationStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return self.inner.search(gpa, io, query);
    }

    pub fn write(self: *SchemaValidationStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const existing = try self.inner.read(self.gpa, io, node);
        defer if (existing) |old| self.gpa.free(old);
        const old_schema = if (existing) |old| core.note_schema.schemaId(old) else null;
        const schema_id = core.note_schema.schemaId(body) orelse {
            if (old_schema != null) return self.reject("frontmatter.schema: cannot be removed from a schema-declaring note", .{});
            return self.inner.write(io, node, body);
        };
        if (!safeSchemaId(schema_id)) return self.reject("frontmatter.schema: unsafe identifier '{s}'", .{schema_id});

        const mode: core.note_schema.Mode = if (existing == null)
            .create
        else if (old_schema == null or !std.mem.eql(u8, old_schema.?, schema_id))
            .migration
        else
            .update;

        // An update to a schema-declaring note refreshes `updated` here, at
        // the persistence boundary, before any validation runs -- so the
        // caller never has to pre-read the note to own the timestamp the way
        // `vault_cmd` used to, and no layer above this has to read twice.
        var refreshed: ?[]u8 = null;
        defer if (refreshed) |value| self.gpa.free(value);
        if (existing != null) {
            const timestamp = try local_timestamp.now(self.gpa, io);
            defer self.gpa.free(timestamp);
            refreshed = try core.frontmatter.set(self.gpa, body, "updated", .{ .scalar = timestamp });
        }
        const candidate = refreshed orelse body;

        var schema_doc = self.loadSchema(io, schema_id) catch |err|
            return self.reject("schema: {s}", .{@errorName(err)});
        defer schema_doc.deinit();
        if (try core.note_schema.validateSchema(self.gpa, schema_doc.root, schema_id)) |message|
            return .{ .accepted = false, .status = 422, .body = message };

        const projects = try self.loadVocabulary(io, "synapse-projects.conf");
        defer if (projects) |text| self.gpa.free(text);
        const tags = try self.loadVocabulary(io, "synapse-tag-vocabulary.conf");
        defer if (tags) |text| self.gpa.free(text);

        const duplicate = if (mode == .create or mode == .migration)
            try self.findDuplicateIdentity(io, schema_doc.root, node, candidate)
        else
            null;
        defer if (duplicate) |value| self.gpa.free(value);

        if (try core.note_schema.validateNote(self.gpa, schema_doc.root, candidate, node, .{
            .mode = mode,
            .existing = existing,
            .duplicate_identity = duplicate,
            .projects_vocabulary = projects,
            .tags_vocabulary = tags,
        })) |message| return .{ .accepted = false, .status = 422, .body = message };

        return self.inner.write(io, node, candidate);
    }

    fn loadSchema(self: *SchemaValidationStore, io: Io, schema_id: []const u8) !core.schema_yaml.Document {
        const root = self.vars.get("SYNAPSE_CONTENT_ROOT") orelse return error.ContentRootMissing;
        if (root.len == 0) return error.ContentRootMissing;
        const relative = try std.fmt.allocPrint(self.gpa, "schema/{s}.yaml", .{schema_id});
        defer self.gpa.free(relative);
        const path = try std.fs.path.join(self.gpa, &.{ root, relative });
        defer self.gpa.free(path);
        const source = try Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(1 << 20));
        defer self.gpa.free(source);
        return core.schema_yaml.parse(self.gpa, source);
    }

    fn loadVocabulary(self: *SchemaValidationStore, io: Io, name: []const u8) !?[]u8 {
        const path = (try core.conf.resolveConfPath(self.gpa, io, self.vars, name)) orelse return null;
        defer self.gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(4 << 20)) catch null;
    }

    /// The schema's `unique` check names the canonical identity field. Only
    /// creation and explicit schema migration call this; ordinary updates
    /// never list or scan the vault.
    fn findDuplicateIdentity(
        self: *SchemaValidationStore,
        io: Io,
        schema: *const core.schema_yaml.Value,
        candidate_path: []const u8,
        candidate: []const u8,
    ) !?[]u8 {
        const identity_ref = uniqueField(schema) orelse return null;
        const identity_name = identity_ref["frontmatter.".len..];
        var wanted_lookup = try core.note_schema.lookupField(self.gpa, candidate, identity_name);
        defer wanted_lookup.deinit(self.gpa);
        const wanted = switch (wanted_lookup.value) {
            .string => |value| value,
            else => return null,
        };

        const names = try self.inner.list(self.gpa, io);
        defer {
            for (names) |name| self.gpa.free(name);
            self.gpa.free(names);
        }
        for (names) |name| {
            if (std.mem.eql(u8, name, candidate_path)) continue;
            const note = (try self.inner.read(self.gpa, io, name)) orelse continue;
            defer self.gpa.free(note);
            for ([_][]const u8{ "note_id", "task_id" }) |field| {
                var found = try core.note_schema.lookupField(self.gpa, note, field);
                defer found.deinit(self.gpa);
                switch (found.value) {
                    .string => |value| if (std.mem.eql(u8, value, wanted)) return try self.gpa.dupe(u8, wanted),
                    else => {},
                }
            }
        }
        return null;
    }

    fn reject(self: *SchemaValidationStore, comptime fmt: []const u8, args: anytype) !Store.WriteResult {
        return .{ .accepted = false, .status = 422, .body = try std.fmt.allocPrint(self.gpa, fmt, args) };
    }
};

fn safeSchemaId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '/' or std.mem.indexOfScalar(u8, id, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, id, '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        count += 1;
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return count >= 2;
}

fn uniqueField(schema: *const core.schema_yaml.Value) ?[]const u8 {
    const checks = schema.get("checks") orelse return null;
    return switch (checks.*) {
        .list => |items| for (items) |item| {
            if (item.get("unique")) |value| break value.asString();
        } else null,
        else => null,
    };
}

const testing = std.testing;
const FakeStore = @import("fakes/store.zig").FakeStore;

const TestVars = struct {
    pairs: []const [2][]const u8,

    fn vars(self: *const TestVars) core.conf.Vars {
        return .{ .ctx = @ptrCast(@constCast(self)), .getFn = get };
    }

    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx));
        for (self.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
        return null;
    }
};

test "unsafe schema identifiers fail before touching the inner Store" {
    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    const vars: TestVars = .{ .pairs = &.{} };
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const result = try validation.store().write(testing.io, "x.md", "---\nschema: ../secret\n---\n");
    defer testing.allocator.free(result.body);
    try testing.expect(!result.accepted);
    try testing.expectEqual(@as(usize, 0), fake.writes);
}

test "legacy notes pass through without schema resolution" {
    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    const vars: TestVars = .{ .pairs = &.{} };
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const result = try validation.store().write(testing.io, "legacy.md", "---\ntitle: Legacy\n---\n");
    defer testing.allocator.free(result.body);
    try testing.expect(result.accepted);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

const test_schema =
    "schema: synapse-note-schema/v1\n" ++
    "id: vault-note/v1\n" ++
    "frontmatter:\n" ++
    "  fields:\n" ++
    "    schema:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "      const: vault-note/v1\n" ++
    "    title:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "    note_id:\n" ++
    "      type: string\n" ++
    "      required: true\n" ++
    "      mutable: false\n" ++
    "    created:\n" ++
    "      type: timestamp\n" ++
    "      required: true\n" ++
    "      mutable: false\n" ++
    "    updated:\n" ++
    "      type: timestamp\n" ++
    "      required: true\n" ++
    "    tags:\n" ++
    "      type: list\n" ++
    "      required: true\n" ++
    "      items: string\n" ++
    "body:\n" ++
    "  h1:\n" ++
    "    required: true\n" ++
    "    count: 1\n" ++
    "    equals: frontmatter.title\n" ++
    "  sections:\n" ++
    "    - title: Summary\n" ++
    "      level: 2\n" ++
    "      required: true\n" ++
    "checks:\n" ++
    "  - equals: [filename.stem, frontmatter.title]\n" ++
    "  - unique: frontmatter.note_id\n" ++
    "    when: create\n" ++
    "  - not_before: [frontmatter.updated, frontmatter.created]\n";

const existing_note =
    "---\n" ++
    "schema: vault-note/v1\n" ++
    "title: Example\n" ++
    "note_id: sb-081\n" ++
    "created: '2026-08-30 01:00:00 CEST'\n" ++
    "updated: '2026-08-30 01:00:00 CEST'\n" ++
    "tags: []\n" ++
    "---\n\n# Example\n\n## Summary\nOld.\n";

fn writeTestSchema(tmp: *testing.TmpDir, io: Io) ![]u8 {
    try tmp.dir.createDirPath(io, "schema/vault-note");
    try tmp.dir.writeFile(io, .{ .sub_path = "schema/vault-note/v1.yaml", .data = test_schema });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    return testing.allocator.dupe(u8, root);
}

test "ordinary schema updates read the persisted note but never list the vault" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    const vars: TestVars = .{ .pairs = &.{.{ "SYNAPSE_CONTENT_ROOT", root }} };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    _ = try fake.write(testing.io, "Example.md", existing_note);
    fake.reads = 0;
    fake.lists = 0;
    fake.writes = 0;

    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const updated =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\n" ++
        "created: '2026-08-30 01:00:00 CEST'\nupdated: '2026-08-30 02:00:00 CEST'\ntags: []\n" ++
        "---\n\n# Example\n\n## Summary\nUpdated.\n";
    const result = try validation.store().write(testing.io, "Example.md", updated);
    defer testing.allocator.free(result.body);
    try testing.expect(result.accepted);
    try testing.expectEqual(@as(usize, 1), fake.reads);
    try testing.expectEqual(@as(usize, 0), fake.lists);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

test "schema creation performs the one lifecycle-scoped uniqueness scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    const vars: TestVars = .{ .pairs = &.{.{ "SYNAPSE_CONTENT_ROOT", root }} };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const result = try validation.store().write(testing.io, "Example.md", existing_note);
    defer testing.allocator.free(result.body);
    try testing.expect(result.accepted);
    try testing.expectEqual(@as(usize, 1), fake.lists);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

test "a schema rejection never calls the inner write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    const vars: TestVars = .{ .pairs = &.{.{ "SYNAPSE_CONTENT_ROOT", root }} };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const invalid =
        "---\nschema: vault-note/v1\ntitle: Wrong\nnote_id: sb-081\n" ++
        "created: '2026-08-30 01:00:00 CEST'\nupdated: '2026-08-30 01:00:00 CEST'\ntags: []\n" ++
        "---\n\n# Wrong\n\n## Summary\nInvalid filename.\n";
    const result = try validation.store().write(testing.io, "Example.md", invalid);
    defer testing.allocator.free(result.body);
    try testing.expect(!result.accepted);
    try testing.expectEqual(@as(usize, 0), fake.writes);
}
