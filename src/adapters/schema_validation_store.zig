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

        var schema_doc = loadSchemaDocument(self.gpa, io, self.vars, schema_id) catch |err|
            return self.reject("schema: {s}", .{@errorName(err)});
        defer schema_doc.deinit();
        if (try core.note_schema.validateSchema(self.gpa, schema_doc.root, schema_id)) |message|
            return .{ .accepted = false, .status = 422, .body = message };

        const stems = try core.note_schema.neededVocabularyStems(self.gpa, schema_doc.root);
        defer self.gpa.free(stems);
        var vocabularies: std.ArrayListUnmanaged(core.note_schema.VocabularySource) = .empty;
        defer {
            for (vocabularies.items) |v| self.gpa.free(v.content);
            vocabularies.deinit(self.gpa);
        }
        for (stems) |stem| {
            const filename = try std.fmt.allocPrint(self.gpa, "{s}.conf", .{stem});
            defer self.gpa.free(filename);
            const content = try loadVocabularyText(self.gpa, io, self.vars, filename) orelse continue;
            try vocabularies.append(self.gpa, .{ .stem = stem, .content = content });
        }

        const duplicate = if (mode == .create or mode == .migration)
            try self.findDuplicateIdentity(io, schema_doc.root, node, candidate)
        else
            null;
        defer if (duplicate) |value| self.gpa.free(value);

        // A malformed rule (a known operator called with the wrong
        // argument shape, most likely from a stale schema-override file
        // predating a schema change) rejects the write the same way an
        // ordinary `checks:` violation does, instead of crashing the whole
        // process -- caught for real against a live schema-override file,
        // not assumed.
        if (core.note_schema.validateNote(self.gpa, schema_doc.root, candidate, node, .{
            .mode = mode,
            .existing = existing,
            .duplicate_identity = duplicate,
            .vocabularies = vocabularies.items,
        }) catch |err| return self.reject("checks: {s}", .{@errorName(err)})) |message|
            return .{ .accepted = false, .status = 422, .body = message };

        // Only reached once validation has already passed -- a rejected
        // write never reaches lint. A `warn`-severity finding is advisory
        // only: printed to stderr, never `WriteResult`/the exit code/
        // stdout, so `vault-write`'s stdout stays byte-identical for a
        // machine caller regardless of what this prints. An `.error`-
        // severity finding is not advisory -- it blocks the write the same
        // way `validateNote`'s own checks do, checked here rather than
        // inside `lintNote` itself, which never blocks anything on its own.
        const findings = core.note_schema.lintNote(self.gpa, schema_doc.root, candidate, node) catch |err|
            return self.reject("lints: {s}", .{@errorName(err)});
        defer {
            for (findings) |f| self.gpa.free(f.message);
            self.gpa.free(findings);
        }
        var blocking: Io.Writer.Allocating = .init(self.gpa);
        defer blocking.deinit();
        for (findings) |finding| {
            if (finding.severity == .@"error") {
                if (blocking.written().len != 0) try blocking.writer.writeAll("\n");
                try blocking.writer.writeAll(finding.message);
            } else {
                std.debug.print("synapse: {s}: {s}\n", .{ node, finding.message });
            }
        }
        if (blocking.written().len != 0)
            return .{ .accepted = false, .status = 422, .body = try self.gpa.dupe(u8, blocking.written()) };

        return self.inner.write(io, node, candidate);
    }

    /// `note_id`/`task_id` are the only two identity-field names any
    /// shipped schema uses (mirroring the same convention the scan loop
    /// below already checks on every *other* note) -- only run at all when
    /// the schema's own `checks:` actually consults `id_is_unique`. Only
    /// creation and explicit schema migration call this; ordinary updates
    /// never list or scan the vault.
    fn findDuplicateIdentity(
        self: *SchemaValidationStore,
        io: Io,
        schema: *const core.schema_yaml.Value,
        candidate_path: []const u8,
        candidate: []const u8,
    ) !?[]u8 {
        if (!try core.note_schema.needsIdentityScan(self.gpa, schema)) return null;
        const wanted = for ([_][]const u8{ "note_id", "task_id" }) |field| {
            var found = try core.note_schema.lookupField(self.gpa, candidate, field);
            defer found.deinit(self.gpa);
            switch (found.value) {
                .string => |value| if (value.len != 0) break try self.gpa.dupe(u8, value),
                else => {},
            }
        } else return null;
        defer self.gpa.free(wanted);

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

pub fn loadSchemaDocument(gpa: Allocator, io: Io, vars: core.conf.Vars, schema_id: []const u8) !core.schema_yaml.Document {
    const root = vars.get("SYNAPSE_CONTENT_ROOT") orelse return error.ContentRootMissing;
    if (root.len == 0) return error.ContentRootMissing;
    const relative = try std.fmt.allocPrint(gpa, "schema/{s}.yaml", .{schema_id});
    defer gpa.free(relative);
    const path = try std.fs.path.join(gpa, &.{ root, relative });
    defer gpa.free(path);
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(source);
    var base = try core.schema_yaml.parse(gpa, source);
    errdefer base.deinit();

    // One override file per schema id (sb-119/sb-120), same nesting as the
    // shipped schema itself -- resolved through the standard tiered config
    // cascade, not a bespoke lookup: `resolveConfPath` already handles a
    // nested relative name with no changes, and its own tier-3
    // (bundled-template) fallback naturally never matches here, since no
    // override is ever shipped. Absent is always a no-op -- `base` returned
    // completely unchanged, so nothing here can regress an existing schema.
    const override_relative = try std.fmt.allocPrint(gpa, "schema-overrides/{s}.yaml", .{schema_id});
    defer gpa.free(override_relative);
    const override_path = (try core.conf.resolveConfPath(gpa, io, vars, override_relative)) orelse return base;
    defer gpa.free(override_path);
    const override_source = try Io.Dir.cwd().readFileAlloc(io, override_path, gpa, .limited(1 << 20));
    defer gpa.free(override_source);
    var override = try core.schema_yaml.parse(gpa, override_source);
    defer override.deinit();

    const merged = try core.schema_yaml.merge(gpa, base.root, override.root);
    base.deinit();
    return merged;
}

pub fn loadVocabularyText(gpa: Allocator, io: Io, vars: core.conf.Vars, name: []const u8) !?[]u8 {
    const path = (try core.conf.resolveConfPath(gpa, io, vars, name)) orelse return null;
    defer gpa.free(path);
    // resolveConfPath already confirmed this path exists -- any error here
    // is a genuine, unexpected failure, not the ordinary "not configured".
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |e| {
        std.debug.print("synapse: unreadable vocabulary conf: {s} ({t})\n", .{ path, e });
        return null;
    };
}

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
    "  - eq:\n" ++
    "      - var: filename.stem\n" ++
    "      - var: frontmatter.title\n" ++
    "  - on_create:\n" ++
    "      var: id_is_unique\n" ++
    "  - lte:\n" ++
    "      - var: created_epoch\n" ++
    "      - var: updated_epoch\n" ++
    "lints:\n" ++
    "  - no_hard_wrap:\n" ++
    "      var: body.prose\n" ++
    "    severity: warn\n" ++
    "    message: 'body: no_hard_wrap paragraph is wrapped'\n";

const existing_note =
    "---\n" ++
    "schema: vault-note/v1\n" ++
    "title: Example\n" ++
    "note_id: sb-081\n" ++
    "created: '2026-08-30T01:00:00+02:00'\n" ++
    "updated: '2026-08-30T01:00:00+02:00'\n" ++
    "tags: []\n" ++
    "---\n\n# Example\n\n## Summary\nOld.\n";

fn writeTestSchema(tmp: *testing.TmpDir, io: Io) ![]u8 {
    try tmp.dir.createDirPath(io, "schema/vault-note");
    try tmp.dir.writeFile(io, .{ .sub_path = "schema/vault-note/v1.yaml", .data = test_schema });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    return testing.allocator.dupe(u8, root);
}

/// Writes a `schema-overrides/{schema_id}.yaml` under `{root}/synapse/`,
/// the exact shape `resolveConfPath`'s tier-1 (`$XDG_CONFIG_HOME`) lookup
/// resolves -- `root` doubles as both `SYNAPSE_CONTENT_ROOT` (the base
/// schema) and `XDG_CONFIG_HOME` (the override) in these tests, same as a
/// real machine where both happen to be configured, never a requirement
/// the code itself imposes.
fn writeOverride(tmp: *testing.TmpDir, io: Io, schema_id: []const u8, content: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "synapse/schema-overrides/{s}", .{std.fs.path.dirname(schema_id).?});
    defer testing.allocator.free(dir);
    try tmp.dir.createDirPath(io, dir);
    const sub_path = try std.fmt.allocPrint(testing.allocator, "synapse/schema-overrides/{s}.yaml", .{schema_id});
    defer testing.allocator.free(sub_path);
    try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = content });
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
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T02:00:00+02:00'\ntags: []\n" ++
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
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T01:00:00+02:00'\ntags: []\n" ++
        "---\n\n# Wrong\n\n## Summary\nInvalid filename.\n";
    const result = try validation.store().write(testing.io, "Example.md", invalid);
    defer testing.allocator.free(result.body);
    try testing.expect(!result.accepted);
    try testing.expectEqual(@as(usize, 0), fake.writes);
}

test "a lint finding is advisory: the write still succeeds and WriteResult is unaffected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    const vars: TestVars = .{ .pairs = &.{.{ "SYNAPSE_CONTENT_ROOT", root }} };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    // A valid note by every `checks:` rule, but its `## Summary` is a
    // paragraph hard-wrapped across two lines -- exactly what `no_hard_wrap`
    // exists to catch, and nothing this rule catches is a contract
    // violation, so `validateNote` has nothing to say about it.
    const wrapped =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\n" ++
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T01:00:00+02:00'\ntags: []\n" ++
        "---\n\n# Example\n\n## Summary\nThis sentence got\nhard-wrapped across two lines.\n";
    const result = try validation.store().write(testing.io, "Example.md", wrapped);
    defer testing.allocator.free(result.body);
    try testing.expect(result.accepted);
    try testing.expectEqual(@as(u16, 0), result.status);
    try testing.expectEqual(@as(usize, 0), result.body.len);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

test "an error-severity lint finding blocks the write, the same way a checks: violation does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const error_severity_schema = try std.mem.replaceOwned(u8, testing.allocator, test_schema, "severity: warn", "severity: error");
    defer testing.allocator.free(error_severity_schema);
    try tmp.dir.createDirPath(testing.io, "schema/vault-note");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "schema/vault-note/v1.yaml", .data = error_severity_schema });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testing.allocator.dupe(u8, buffer[0..try tmp.dir.realPath(testing.io, &buffer)]);
    defer testing.allocator.free(root);
    const vars: TestVars = .{ .pairs = &.{.{ "SYNAPSE_CONTENT_ROOT", root }} };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const wrapped =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\n" ++
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T01:00:00+02:00'\ntags: []\n" ++
        "---\n\n# Example\n\n## Summary\nThis sentence got\nhard-wrapped across two lines.\n";
    const result = try validation.store().write(testing.io, "Example.md", wrapped);
    defer testing.allocator.free(result.body);
    try testing.expect(!result.accepted);
    try testing.expectEqual(@as(u16, 422), result.status);
    try testing.expect(std.mem.indexOf(u8, result.body, "no_hard_wrap") != null);
    try testing.expectEqual(@as(usize, 0), fake.writes);
}

test "schema-overrides: a severity override turns a lint that used to only warn into a blocking write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    try writeOverride(&tmp, testing.io, "vault-note/v1", "lints:\n  - no_hard_wrap:\n      var: body.prose\n    severity: error\n");
    const vars: TestVars = .{ .pairs = &.{ .{ "SYNAPSE_CONTENT_ROOT", root }, .{ "XDG_CONFIG_HOME", root } } };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    const wrapped =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\n" ++
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T01:00:00+02:00'\ntags: []\n" ++
        "---\n\n# Example\n\n## Summary\nThis sentence got\nhard-wrapped across two lines.\n";
    const result = try validation.store().write(testing.io, "Example.md", wrapped);
    defer testing.allocator.free(result.body);
    try testing.expect(!result.accepted);
    try testing.expectEqual(@as(u16, 422), result.status);
    try testing.expectEqual(@as(usize, 0), fake.writes);
}

test "schema-overrides: a null on a required field removes it, a note missing that field now validates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    try writeOverride(&tmp, testing.io, "vault-note/v1", "frontmatter:\n  fields:\n    tags: null\n");
    const vars: TestVars = .{ .pairs = &.{ .{ "SYNAPSE_CONTENT_ROOT", root }, .{ "XDG_CONFIG_HOME", root } } };

    var fake = FakeStore.init(testing.allocator);
    defer fake.deinit();
    var validation = SchemaValidationStore.init(testing.allocator, fake.port(), vars.vars());
    // No `tags:` field at all -- the base schema requires it; the override
    // removes the field's own rule entirely, so its absence is no longer a
    // violation.
    const no_tags =
        "---\nschema: vault-note/v1\ntitle: Example\nnote_id: sb-081\n" ++
        "created: '2026-08-30T01:00:00+02:00'\nupdated: '2026-08-30T01:00:00+02:00'\n" ++
        "---\n\n# Example\n\n## Summary\nFine.\n";
    const result = try validation.store().write(testing.io, "Example.md", no_tags);
    defer testing.allocator.free(result.body);
    try testing.expect(result.accepted);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

test "schema-overrides: an override for one schema id never affects another" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeTestSchema(&tmp, testing.io);
    defer testing.allocator.free(root);
    // A second, minimal real schema id, unrelated to the override below.
    try tmp.dir.createDirPath(testing.io, "schema/vault-task-note");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "schema/vault-task-note/v1.yaml",
        .data = "schema: synapse-note-schema/v1\nid: vault-task-note/v1\n" ++
            "frontmatter:\n  fields:\n    tags:\n      type: list\n      required: true\n" ++
            "body:\n  h1:\n    required: false\nchecks: []\n",
    });
    try writeOverride(&tmp, testing.io, "vault-note/v1", "frontmatter:\n  fields:\n    tags: null\n");
    const vars: TestVars = .{ .pairs = &.{ .{ "SYNAPSE_CONTENT_ROOT", root }, .{ "XDG_CONFIG_HOME", root } } };

    // vault-note/v1: the override applies, `tags` is gone, so its own
    // schema document has no `tags` field to enforce at all.
    var vault_note_doc = try loadSchemaDocument(testing.allocator, testing.io, vars.vars(), "vault-note/v1");
    defer vault_note_doc.deinit();
    try testing.expectEqual(@as(?*const core.schema_yaml.Value, null), vault_note_doc.root.get("frontmatter").?.get("fields").?.get("tags"));

    // vault-task-note/v1: no override targets it, so it's completely
    // unaffected -- `tags` is still there, required, exactly as declared.
    var task_note_doc = try loadSchemaDocument(testing.allocator, testing.io, vars.vars(), "vault-task-note/v1");
    defer task_note_doc.deinit();
    try testing.expect(task_note_doc.root.get("frontmatter").?.get("fields").?.get("tags") != null);
}
