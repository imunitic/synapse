//! `BardGraphStore`: a `ports.Store` backed by plain files under `_bard/graph/`
//! -- one `.md` per entity, git-tracked, no daemon and no network. This is
//! the Bible-graph's own storage, distinct from `_bard/vault/` (design/task
//! notes, a separate `Store` instance over a separate directory).
//!
//! `node` is the bare filename including `.md` -- the same convention
//! every `Store` implementation uses, so a caller that resolves a
//! wikilink target to `"gael-varis.md"` doesn't special-case which `Store`
//! it's talking to.
//!
//! No daemon, no index file: `list` walks the directory, `search` scans file
//! contents directly. A book bible tops out at a few hundred entities --
//! well inside grep-speed territory, so there's nothing here worth caching.

const std = @import("std");
const ports = @import("ports");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

pub const BardGraphStore = struct {
    gpa: Allocator,
    /// Directory nodes live under, e.g. `"_bard/graph"` -- resolved once by
    /// the constructor, so every call agrees on where "the graph" is.
    root: []const u8,

    pub fn init(gpa: Allocator, root: []const u8) !BardGraphStore {
        return .{ .gpa = gpa, .root = try gpa.dupe(u8, root) };
    }

    pub fn deinit(self: *BardGraphStore) void {
        self.gpa.free(self.root);
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque`
    /// cast from `BardGraphStore` alone, so it can never disagree with
    /// `.ptr` the way a hand-written vtable literal could.
    pub fn store(self: *BardGraphStore) Store {
        return Store.from(BardGraphStore, self);
    }

    pub fn read(self: *BardGraphStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const path = try std.fs.path.join(gpa, &.{ self.root, node });
        defer gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) return null;
            return e;
        };
    }

    pub fn write(self: *BardGraphStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        // `_bard/graph/` may not exist yet on a repo's first write -- create
        // it same as any other git-tracked-once-something-lands-in-it
        // directory. Idempotent: does nothing when it's already there.
        try Io.Dir.cwd().createDirPath(io, self.root);
        const path = try std.fs.path.join(self.gpa, &.{ self.root, node });
        defer self.gpa.free(path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
        return .{ .accepted = true };
    }

    /// Removes a node -- not on the shared `ports.Store` interface (`read`/
    /// `write`/`list`/`search` only, checked before adding this), so it's a
    /// method on the concrete type instead: a capability
    /// `DiskStore`/`FakeStore`/`BardVaultStore` have no need for
    /// shouldn't become a `Store`-wide requirement. `synapse-bard sync`
    /// is the one caller -- a renamed or deleted source
    /// entity must not leave a stale node behind for `--inbound`/`search` to
    /// keep surfacing. A node that's already gone is not an error, matching
    /// `read`'s own "absence is ordinary" rule.
    pub fn delete(self: *BardGraphStore, io: Io, node: []const u8) anyerror!void {
        const path = try std.fs.path.join(self.gpa, &.{ self.root, node });
        defer self.gpa.free(path);
        Io.Dir.cwd().deleteFile(io, path) catch |e| {
            if (e == error.FileNotFound) return;
            return e;
        };
    }

    /// Every `.md` file directly under `root`, flat -- `_bard/graph/` is
    /// file-per-entity, no subdirectories. A `root` that doesn't exist yet
    /// (nothing has been written) lists as empty, not an error -- the same
    /// "absence is ordinary" rule `read` follows.
    pub fn list(self: *BardGraphStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }

        if (Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
                try out.append(gpa, try gpa.dupe(u8, entry.name));
            }
        } else |e| {
            if (e != error.FileNotFound) return e;
        }
        return out.toOwnedSlice(gpa);
    }

    /// `key:value` (exactly one colon, no spaces around it) matches nodes
    /// whose frontmatter has a root-level `key: value` line -- the
    /// structured half of the design ("all characters where faction = X").
    /// Anything else is a full-text substring scan over the raw file,
    /// matching `FakeStore`'s own convention so tests can share the shape.
    /// Both the `key:value` value half and full-text mode match
    /// case-insensitively -- only the frontmatter `key` itself stays
    /// case-sensitive, since it's a schema name the author isn't guessing
    /// the spelling of the way she might a character's name.
    pub fn search(self: *BardGraphStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return self.searchImpl(gpa, io, parseFieldQuery(query), query);
    }

    fn searchImpl(self: *BardGraphStore, gpa: Allocator, io: Io, field: ?FieldQuery, query: []const u8) anyerror![]const Store.Hit {
        const names = try self.list(gpa, io);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }

        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer {
            for (out.items) |h| {
                gpa.free(h.node);
                gpa.free(h.context);
            }
            out.deinit(gpa);
        }

        for (names) |name| {
            const body = (try self.read(gpa, io, name)) orelse continue;
            defer gpa.free(body);

            if (field) |f| {
                if (fieldLine(body, f.key, f.value)) |line| {
                    try out.append(gpa, .{
                        .node = try gpa.dupe(u8, name),
                        .score = 1.0,
                        .context = try gpa.dupe(u8, line),
                    });
                }
                continue;
            }

            const count = countIgnoreCase(body, query);
            if (count == 0) continue;
            try out.append(gpa, .{
                .node = try gpa.dupe(u8, name),
                .score = @floatFromInt(count),
                .context = try gpa.dupe(u8, firstMatchingLine(body, query) orelse ""),
            });
        }

        // Node ownership: `out.append` above dupes `name` per hit, but the
        // Hit itself is caller-owned from here -- `node` needs the same
        // lifetime as `context`, both freed by whoever frees the slice.
        return out.toOwnedSlice(gpa);
    }
};

const FieldQuery = struct { key: []const u8, value: []const u8 };

/// `"faction:Radiant Dominion"` -> `.{.key = "faction", .value = "Radiant Dominion"}`.
/// Anything without exactly one colon, or with an empty key, isn't a field
/// query -- falls back to full-text search instead.
fn parseFieldQuery(query: []const u8) ?FieldQuery {
    const colon = std.mem.indexOfScalar(u8, query, ':') orelse return null;
    if (std.mem.indexOfScalarPos(u8, query, colon + 1, ':') != null) return null; // a 2nd colon: not this syntax
    const key = std.mem.trim(u8, query[0..colon], " ");
    const value = std.mem.trim(u8, query[colon + 1 ..], " ");
    if (key.len == 0 or value.len == 0) return null;
    return .{ .key = key, .value = value };
}

/// A root-level (column-0) `key: value` line in `body`'s frontmatter, value
/// compared unquoted -- `null` if `key` isn't there or its value doesn't
/// match. Independent single-pass scan, same technique as the extractor's
/// own `rootKindValue`: this Store doesn't parse nested structure, only the
/// flat fields the design's own example ("faction = X") calls for.
///
/// `pub`: `synapse-bard search` reuses this directly
/// over real entity source files resolved through a cluster's `sources:`,
/// not just over this Store's own stored content -- the scanning logic is
/// the same either way, only which bytes get handed to it differs.
pub fn fieldLine(body: []const u8, key: []const u8, value: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    _ = lines.next(); // opening `---`
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const line_key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.mem.eql(u8, line_key, key)) continue;
        const raw_value = std.mem.trim(u8, line[colon + 1 ..], " ");
        const line_value = unquote(raw_value);
        if (std.ascii.eqlIgnoreCase(line_value, value)) return line;
        return null;
    }
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

/// `pub` for the same reason as `fieldLine` above: `synapse-bard search`
/// reuses this over real entity source files, not just this Store's own
/// content. Case-insensitive, matching `fieldLine` -- a writer searching her
/// own bible shouldn't have to remember how she capitalized a name.
///
/// Re-exported from `core.text_search`, not defined here: the actual logic
/// is domain-neutral (no `Store`, no bard-specific type anywhere in it), so
/// it lives where any `Store` implementation can reach it -- `DiskStore`'s
/// own full-text `search` uses the same function.
pub const firstMatchingLine = core.text_search.firstMatchingLine;

/// `pub` for the same reuse reason as `fieldLine`/`firstMatchingLine`:
/// `synapse-bard search`'s full-text mode counts occurrences over real
/// entity source files with this exact function, not a second
/// implementation of the same loop. Re-exported from `core.text_search` --
/// see `firstMatchingLine`'s own comment for why.
pub const countIgnoreCase = core.text_search.countIgnoreCase;

const testing = std.testing;

fn freeHits(gpa: Allocator, hits: []const Store.Hit) void {
    for (hits) |h| {
        gpa.free(h.node);
        gpa.free(h.context);
    }
    gpa.free(hits);
}

/// A fresh `_bard/graph`-shaped subdirectory (not yet created -- `write`'s
/// job) under a fresh tmp dir, so every test starts from a clean root.
fn graphRoot(gpa: Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/graph", .{base});
}

test "write then read round-trips through the port" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "gael-varis.md", "---\nname: Gael\n---\n");
    const body = (try port.read(gpa, testing.io, "gael-varis.md")).?;
    defer gpa.free(body);
    try testing.expectEqualStrings("---\nname: Gael\n---\n", body);
}

test "a missing node reads as null, not as an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    try testing.expectEqual(@as(?[]u8, null), try s.store().read(gpa, testing.io, "absent.md"));
}

test "listing a graph that was never written to is empty, not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const names = try s.store().list(gpa, testing.io);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "rewriting a node replaces it, and list reflects exactly what was written" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
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

test "delete removes a node, and it stops showing up in read/list" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "a");
    _ = try port.write(testing.io, "b.md", "b");
    try s.delete(testing.io, "a.md");

    try testing.expectEqual(@as(?[]u8, null), try port.read(gpa, testing.io, "a.md"));

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("b.md", names[0]);
}

test "delete on a node that doesn't exist is not an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    try s.delete(testing.io, "never-existed.md");
}

test "list only sees .md files, not other files someone dropped in the directory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "a");
    _ = try port.write(testing.io, "notes.txt", "not an entity");

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
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "a.md", "---\nname: A\n---\nmentions the Flame Hilt\n");
    _ = try port.write(testing.io, "b.md", "---\nname: B\n---\nmentions nothing relevant\n");

    const hits = try port.search(gpa, testing.io, "flame hilt");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

test "a key:value query matches the frontmatter field exactly on the key, case-insensitively on the value" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "gael.md", "---\nname: Gael\nfaction: \"The Radiant Dominion\"\n---\n");
    _ = try port.write(testing.io, "aidan.md", "---\nname: Aidan\nfaction: \"The Dominion\"\n---\n");

    const hits = try port.search(gpa, testing.io, "faction:the radiant dominion");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("gael.md", hits[0].node);
}

test "a key:value query does not match a differently-cased key -- only the value is case-insensitive" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "gael.md", "---\nname: Gael\nfaction: \"The Radiant Dominion\"\n---\n");

    const hits = try port.search(gpa, testing.io, "Faction:The Radiant Dominion");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "port.search()'s key:value heuristic can misread a colon in ordinary text -- known, not this Store's problem to solve" {
    // Documents why `search_cmd.zig` moved off this port method entirely
    // for its own full-text mode, rather than fixing the
    // heuristic here: `search`'s single-string signature genuinely can't
    // distinguish "The Knife: Book One" (a title) from a field filter
    // without a second parameter a CLI flag can supply but this interface
    // can't. `fieldLine`/`firstMatchingLine` (exported above) are what the
    // CLI now composes with directly, once it already knows which mode it's
    // in from its own `--field` flag.
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "book.md", "---\nname: Note\n---\nThe Knife: Book One is her favorite.\n");

    const via_port = try port.search(gpa, testing.io, "The Knife: Book One");
    defer freeHits(gpa, via_port);
    try testing.expectEqual(@as(usize, 0), via_port.len);
}
