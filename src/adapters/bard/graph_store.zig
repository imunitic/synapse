//! `BardGraphStore`: a `ports.Store` backed by plain files under `_bard/graph/`
//! -- one `.md` per entity, git-tracked, no daemon and no network. This is
//! the Bible-graph's own storage, distinct from `_bard/vault/` (design/task
//! notes, a separate `Store` instance over a separate directory).
//!
//! `node` is the bare filename including `.md` -- the same convention
//! `ObsidianStore` and `FakeStore` already use, so a caller that resolves a
//! wikilink target to `"gael-varis.md"` doesn't special-case which `Store`
//! it's talking to.
//!
//! No daemon, no index file: `list` walks the directory, `search` scans file
//! contents directly. A book bible tops out at a few hundred entities --
//! well inside grep-speed territory, so there's nothing here worth caching.

const std = @import("std");
const ports = @import("ports");

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

    pub fn store(self: *BardGraphStore) Store {
        return .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .list = list,
            .search = search,
        } };
    }

    fn read(ptr: *anyopaque, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const self: *BardGraphStore = @ptrCast(@alignCast(ptr));
        const path = try std.fs.path.join(gpa, &.{ self.root, node });
        defer gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) return null;
            return e;
        };
    }

    fn write(ptr: *anyopaque, io: Io, node: []const u8, body: []const u8) anyerror!void {
        const self: *BardGraphStore = @ptrCast(@alignCast(ptr));
        // `_bard/graph/` may not exist yet on a repo's first write -- create
        // it same as any other git-tracked-once-something-lands-in-it
        // directory. Idempotent: does nothing when it's already there.
        try Io.Dir.cwd().createDirPath(io, self.root);
        const path = try std.fs.path.join(self.gpa, &.{ self.root, node });
        defer self.gpa.free(path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    }

    /// Every `.md` file directly under `root`, flat -- `_bard/graph/` is
    /// file-per-entity, no subdirectories. A `root` that doesn't exist yet
    /// (nothing has been written) lists as empty, not an error -- the same
    /// "absence is ordinary" rule `read` follows.
    fn list(ptr: *anyopaque, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const self: *BardGraphStore = @ptrCast(@alignCast(ptr));
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
    fn search(ptr: *anyopaque, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return searchImpl(ptr, gpa, io, parseFieldQuery(query), query);
    }

    /// Full-text only, bypassing the `key:value` heuristic entirely --
    /// `search`/the generic `ports.Store` interface has only `query` to
    /// decide from, but a caller that already knows it wants full-text
    /// (`synapse-bard search`'s bare positional argument, never `--field`)
    /// can call this directly so an ordinary query containing a colon (a
    /// book title, `"The Knife: Book One"`) is never misread as a field
    /// filter. Bypasses the abstract `Store` port on purpose -- this is
    /// `BardGraphStore`'s own richer API, for a caller that already holds
    /// the concrete type, not something every `Store` implementation needs.
    pub fn searchText(self: *BardGraphStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return searchImpl(self, gpa, io, null, query);
    }

    fn searchImpl(ptr: *anyopaque, gpa: Allocator, io: Io, field: ?FieldQuery, query: []const u8) anyerror![]const Store.Hit {
        const names = try list(ptr, gpa, io);
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
            const body = (try read(ptr, gpa, io, name)) orelse continue;
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

            const count = std.mem.count(u8, body, query);
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
fn fieldLine(body: []const u8, key: []const u8, value: []const u8) ?[]const u8 {
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
        if (std.mem.eql(u8, line_value, value)) return line;
        return null;
    }
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
        return value[1 .. value.len - 1];
    return value;
}

fn firstMatchingLine(body: []const u8, query: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, query) != null) return line;
    }
    return null;
}

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

    try port.write(testing.io, "gael-varis.md", "---\nname: Gael\n---\n");
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

    try port.write(testing.io, "n.md", "first");
    try port.write(testing.io, "n.md", "second");

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
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    try port.write(testing.io, "a.md", "a");
    try port.write(testing.io, "notes.txt", "not an entity");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("a.md", names[0]);
}

test "full-text search finds a substring by content, case-sensitive" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    try port.write(testing.io, "a.md", "---\nname: A\n---\nmentions the flame hilt\n");
    try port.write(testing.io, "b.md", "---\nname: B\n---\nmentions nothing relevant\n");

    const hits = try port.search(gpa, testing.io, "flame hilt");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}

test "a key:value query matches the frontmatter field exactly, not a substring" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    try port.write(testing.io, "gael.md", "---\nname: Gael\nfaction: \"The Radiant Dominion\"\n---\n");
    try port.write(testing.io, "aidan.md", "---\nname: Aidan\nfaction: \"The Dominion\"\n---\n");

    const hits = try port.search(gpa, testing.io, "faction:The Radiant Dominion");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("gael.md", hits[0].node);
}

test "searchText finds a query containing a colon as full text, never as a field filter" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    try port.write(testing.io, "book.md", "---\nname: Note\n---\nThe Knife: Book One is her favorite.\n");

    // The same query through the ambiguous port.search() misreads this as
    // a field filter (key "The Knife", value "Book One") and finds nothing
    // -- searchText must not have that failure mode.
    const via_port = try port.search(gpa, testing.io, "The Knife: Book One");
    defer freeHits(gpa, via_port);
    try testing.expectEqual(@as(usize, 0), via_port.len);

    const hits = try s.searchText(gpa, testing.io, "The Knife: Book One");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("book.md", hits[0].node);
}
