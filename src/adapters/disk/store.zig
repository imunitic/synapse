//! `DiskStore`: a `ports.Store` backed by plain markdown files directly on
//! disk, no Obsidian Local REST API, no MCP server, no network dependency
//! at all. Same node-addressing shape as `ObsidianStore`: `namespace`
//! prefixes every node name so a caller passes a bare title, never a vault
//! path; an empty `namespace` means `node` is already a full vault-relative
//! path (the `frontmatter`/whole-vault case).
//!
//! An Obsidian vault already *is* a folder of markdown files with YAML
//! frontmatter -- this reads and writes that exact same folder directly.
//! Pointing `SYNAPSE_VAULT_DIR` at an existing Obsidian vault and switching
//! `SYNAPSE_VAULT_STORE` to `disk` keeps everything working unchanged;
//! Obsidian itself stays fully usable as a human-browsing/graph-view app on
//! the same folder, decoupled from how this binary reads/writes it.

const std = @import("std");
const ports = @import("ports");
const bard_graph_store = @import("../bard/graph_store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

pub const DiskStore = struct {
    gpa: Allocator,
    /// The vault root -- every node path resolves under here.
    vault: []const u8,
    /// `synapse/{repo}@{branch}`, prefixed onto every node name, same
    /// convention as `ObsidianStore.namespace`. Empty means `node` is
    /// already a full vault-relative path.
    namespace: []const u8,

    pub fn init(gpa: Allocator, vault: []const u8, namespace: []const u8) !DiskStore {
        return .{
            .gpa = gpa,
            .vault = try gpa.dupe(u8, vault),
            .namespace = try gpa.dupe(u8, namespace),
        };
    }

    pub fn deinit(self: *DiskStore) void {
        self.gpa.free(self.vault);
        self.gpa.free(self.namespace);
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque` cast from
    /// `DiskStore` alone, so it can never disagree with `.ptr` the way a
    /// hand-written vtable literal could.
    pub fn store(self: *DiskStore) Store {
        return Store.from(DiskStore, self);
    }

    fn nodePath(self: *DiskStore, gpa: Allocator, node: []const u8) ![]u8 {
        if (self.namespace.len == 0) return std.fs.path.join(gpa, &.{ self.vault, node });
        return std.fs.path.join(gpa, &.{ self.vault, self.namespace, node });
    }

    pub fn read(self: *DiskStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const path = try self.nodePath(gpa, node);
        defer gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch |e| {
            if (e == error.FileNotFound) return null;
            return e;
        };
    }

    pub fn write(self: *DiskStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const path = try self.nodePath(self.gpa, node);
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
        return .{ .accepted = true };
    }

    /// Every `.md` file anywhere under `{vault}/{namespace}`, recursively.
    /// See `listMarkdownFiles` below -- the real implementation, shared with
    /// `ObsidianStore.list`, since a vault's files are the same files on
    /// disk regardless of which backend is asked for them.
    pub fn list(self: *DiskStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return listMarkdownFiles(gpa, io, self.vault, self.namespace);
    }

    /// Full-text, case-insensitive substring search over every node's
    /// content -- matching `ObsidianStore.search`'s own plain-string
    /// contract exactly, no field:value heuristic. Structured filtering
    /// (JsonLogic) is a separate `core`-level composition over `read`/
    /// `list`, not this method's job -- see the design note.
    pub fn search(self: *DiskStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        const names = try self.list(gpa, io);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }

        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer {
            for (out.items) |h| gpa.free(h.context);
            out.deinit(gpa);
        }

        for (names) |name| {
            const body = (try self.read(gpa, io, name)) orelse continue;
            defer gpa.free(body);
            const count = bard_graph_store.countIgnoreCase(body, query);
            if (count == 0) continue;
            try out.append(gpa, .{
                .node = try gpa.dupe(u8, name),
                .score = @floatFromInt(count),
                .context = try gpa.dupe(u8, bard_graph_store.firstMatchingLine(body, query) orelse ""),
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Every `.md` file anywhere under `{root}/{namespace}` (or `{root}` when
/// `namespace` is empty), recursively -- the real listing implementation,
/// shared by `DiskStore.list` and `ObsidianStore.list` alike. Obsidian's
/// REST API has no recursive-listing endpoint at all (checked against the
/// real `coddingtonbear/obsidian-local-rest-api` OpenAPI spec: `GET
/// /vault/{pathToDirectory}/` takes exactly one parameter, the path itself
/// -- one call would only ever be one directory deep, and there is no
/// query flag to ask for more), so getting a recursive listing through it
/// means one HTTP round trip per subdirectory. But an Obsidian vault's
/// files are the same files on disk either way, and listing (unlike a
/// `read`, which might miss an unsaved in-editor buffer) has no live-state
/// risk worth paying network round trips to avoid -- so both backends read
/// the directory tree directly, and only `read`/`write`/`search` go
/// through Obsidian's REST API for `ObsidianStore` specifically.
///
/// Names are returned with `/` separators, relative to the listed root --
/// the same shape a namespace-scoped `node` name already has, just now
/// possibly with path segments in it. Any path component starting with `.`
/// (`.git`, `.obsidian`) is skipped -- vault tooling directories, never
/// content. A namespace directory that doesn't exist yet lists as empty,
/// not an error, matching `read`'s own "absence is ordinary" rule.
pub fn listMarkdownFiles(gpa: Allocator, io: Io, root: []const u8, namespace: []const u8) anyerror![]const []const u8 {
    const dir_path = if (namespace.len == 0)
        try gpa.dupe(u8, root)
    else
        try std.fs.path.join(gpa, &.{ root, namespace });
    defer gpa.free(dir_path);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    var root_dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        if (e == error.FileNotFound) return out.toOwnedSlice(gpa);
        return e;
    };
    defer root_dir.close(io);

    var walker = try root_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (hasDotSegment(entry.path)) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.path));
    }
    return out.toOwnedSlice(gpa);
}

fn hasDotSegment(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (seg.len != 0 and seg[0] == '.') return true;
    return false;
}

const testing = std.testing;

fn freeHits(gpa: Allocator, hits: []const Store.Hit) void {
    for (hits) |h| {
        gpa.free(h.node);
        gpa.free(h.context);
    }
    gpa.free(hits);
}

fn vaultRoot(gpa: Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/vault", .{base});
}

test "write then read round-trips through the port, namespace-scoped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "Foo.md", "---\ntitle: Foo\n---\nbody\n");
    const got = (try port.read(gpa, testing.io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", got);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/synapse/repo@main/Foo.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", on_disk);
}

test "an empty namespace addresses a node by its full vault-relative path, unprefixed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "tasks/synapse/sb-037 — Task.md", "---\ntitle: Task\n---\nbody\n");
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/tasks/synapse/sb-037 — Task.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", on_disk);

    const got = (try port.read(gpa, testing.io, "tasks/synapse/sb-037 — Task.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", got);
}

test "a missing node reads as null, not as an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    try testing.expectEqual(@as(?[]u8, null), try s.store().read(gpa, testing.io, "absent.md"));
}

test "listing a namespace that was never written to is empty, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const names = try s.store().list(gpa, testing.io);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "list walks nested subdirectories, not just the top level" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "designs/synapse/sb-001.md", "a\n");
    _ = try port.write(testing.io, "tasks/eon/ecs-001.md", "b\n");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_design = false;
    var saw_task = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "designs/synapse/sb-001.md")) saw_design = true;
        if (std.mem.eql(u8, n, "tasks/eon/ecs-001.md")) saw_task = true;
    }
    try testing.expect(saw_design);
    try testing.expect(saw_task);
}

test "list skips dot-prefixed directories like .obsidian and .git" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "");
    defer s.deinit();
    const port = s.store();
    _ = try port.write(testing.io, "designs/x.md", "real content\n");
    _ = try port.write(testing.io, ".obsidian/plugins/foo/data.md", "not vault content\n");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("designs/x.md", names[0]);
}

test "rewriting a node replaces it, and list reflects exactly what was written" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "n.md", "first");
    _ = try port.write(testing.io, "n.md", "second");

    const body = (try port.read(gpa, testing.io, "n.md")).?;
    defer gpa.free(body);
    try testing.expectEqualStrings("second", body);

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("n.md", names[0]);
}

test "list only sees .md files, not other files someone dropped in the directory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "a");
    _ = try port.write(testing.io, "notes.txt", "not a node");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("a.md", names[0]);
}

test "full-text search finds a substring by content, case-insensitive" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "---\ntitle: A\n---\nmentions the widget factory\n");
    _ = try port.write(testing.io, "b.md", "---\ntitle: B\n---\nmentions nothing relevant\n");

    const hits = try port.search(gpa, testing.io, "widget factory");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

test "a query matching nothing returns an empty slice, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "nothing matches this");
    const hits = try port.search(gpa, testing.io, "gadget");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

// `Store.from(DiskStore, self)` needs all four methods to exist on the type
// to compile -- but only the moment something actually calls `.store()`.
// This test is that reference, exercised end to end.
test "DiskStore.store() compiles, and every op round-trips" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vault = try vaultRoot(gpa, &tmp);
    defer gpa.free(vault);

    var s = try DiskStore.init(gpa, vault, "synapse/repo@main");
    defer s.deinit();
    var store = s.store();

    const wr = try store.write(testing.io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, testing.io, "Foo.md")).?;
    defer gpa.free(got);
    const names = try store.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    const hits = try store.search(gpa, testing.io, "body");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}
