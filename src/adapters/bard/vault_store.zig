//! `BardVaultStore`: a `ports.Store` backed by plain files under `_bard/vault/`
//! -- design notes, task notes, decisions, git-tracked, one `.md` per note
//! under `designs/`/`tasks/`/whatever the writer grows next. Distinct from
//! `_bard/graph/` (`graph_store.zig`), a separate `Store` instance over a
//! separate, flat directory.
//!
//! `node` is a vault-relative path including `.md` (e.g.
//! `"designs/synapse-bard/synapse-bard — Bible-graph.md"`) -- unlike the
//! graph store's flat namespace, notes live in subdirectories, so `list`
//! walks recursively and `write` creates whatever parent directories `node`
//! implies.
//!
//! ## The backlink graph is `DiskStore`'s own `DiskLinkGraph`, self-links
//! ## filtered
//!
//! A wikilink resolves by filename stem, not by vault path -- the same rule
//! `DiskLinkGraph` (`../disk/store.zig`) already implements, Unicode
//! case-fold aware, for the coding vault's own notes. Bard vault notes put
//! `[[wikilinks]]` inline in prose anywhere, with no relation prefix and no
//! reserved section -- exactly what `DiskLinkGraph.backlinks` already
//! resolves against a note's whole body, not the `## Links`-scoped shape
//! `core/query.zig`'s `edges`/`parseEdge` expects. The one gap:
//! `DiskLinkGraph.backlinks` doesn't exclude a note linking to itself (a
//! reasonable default for the coding vault, where a self-link is rare and
//! not specially meaningful) -- `filterSelf` below is the one place that
//! matters, so both `search`'s ranking and `linkingNotes` stay consistent
//! with each other without re-implementing extraction to get there.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const disk_store = @import("../disk/store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;

/// Not a real note -- the vault's own bootstrap file, excluded from `list`.
const index_node = "Index.md";

pub const BardVaultStore = struct {
    gpa: Allocator,
    /// Directory notes live under, e.g. `"_bard/vault"` -- resolved once.
    root: []const u8,
    /// `read`/`write` delegate straight to this -- `root` is the whole
    /// vault-relative base, the same shape `DiskStore`'s own empty-namespace
    /// mode already exists for. Reusing it gets `write`'s atomic
    /// temp-file-plus-rename for free, instead of this store's own
    /// direct-write, which could leave a reader observing a
    /// partially-written note.
    disk: disk_store.DiskStore,

    pub fn init(gpa: Allocator, root: []const u8) !BardVaultStore {
        return .{
            .gpa = gpa,
            .root = try gpa.dupe(u8, root),
            .disk = try disk_store.DiskStore.init(gpa, root, ""),
        };
    }

    pub fn deinit(self: *BardVaultStore) void {
        self.gpa.free(self.root);
        self.disk.deinit();
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque`
    /// cast from `BardVaultStore` alone, so it can never disagree with
    /// `.ptr` the way a hand-written vtable literal could.
    pub fn store(self: *BardVaultStore) Store {
        return Store.from(BardVaultStore, self);
    }

    pub fn read(self: *BardVaultStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        return self.disk.read(gpa, io, node);
    }

    pub fn write(self: *BardVaultStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        return self.disk.write(io, node, body);
    }

    /// Every `.md` file under `root`, recursive -- notes live in
    /// subdirectories, unlike the graph store's flat layout. `DiskStore.list`
    /// has no equivalent exclusion concept, so `Index.md` (the vault's own
    /// bootstrap file, not a note) is filtered out of its result here rather
    /// than pushed into `DiskStore` itself.
    pub fn list(self: *BardVaultStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const all = try self.disk.list(gpa, io);
        defer {
            for (all) |n| gpa.free(n);
            gpa.free(all);
        }

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        for (all) |n| {
            if (std.mem.eql(u8, n, index_node)) continue;
            try out.append(gpa, try gpa.dupe(u8, n));
        }
        return out.toOwnedSlice(gpa);
    }

    /// Full-text substring scan (no embeddings, no maintained index --
    /// see the module docs), ranked by each matching note's backlink
    /// count rather than a similarity or occurrence score, most-linked
    /// first. Deterministic tiebreak: node path, ascending.
    pub fn search(self: *BardVaultStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
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

        var lg: disk_store.DiskLinkGraph = .{ .vault = self.root };
        for (names) |name| {
            const body = (try self.read(gpa, io, name)) orelse continue;
            defer gpa.free(body);
            if (!core.unicode_norm.containsCaseFold(body, query)) continue;

            const links = try lg.backlinks(gpa, io, name);
            defer {
                for (links) |l| gpa.free(l.node);
                gpa.free(links);
            }
            const count = countExcludingSelf(links, name);

            try out.append(gpa, .{
                .node = try gpa.dupe(u8, name),
                .score = @floatFromInt(count),
                .context = try gpa.dupe(u8, core.text_search.firstMatchingLine(body, query) orelse ""),
            });
        }

        std.mem.sort(Store.Hit, out.items, {}, hitRank);
        return out.toOwnedSlice(gpa);
    }

    /// Every note that links to `target`, resolved the same way a wikilink
    /// itself resolves (by filename stem, `.md` suffix optional, so
    /// `"Bible-graph"` and `"Bible-graph.md"` and a full vault-relative path
    /// all find the same note). `null` when `target` itself doesn't resolve
    /// to any note in the vault -- distinguishes "this note has no
    /// backlinks" (a real, empty answer) from "no note by this name
    /// exists" (the caller's own mistake to report differently). Not on
    /// `ports.Store` -- same reasoning `BardGraphStore.searchText`/`delete`
    /// already established: a capability the shared interface doesn't need,
    /// added to the concrete type instead. Caller-owned: free every string
    /// in the returned slice, then the slice itself.
    pub fn linkingNotes(self: *BardVaultStore, gpa: Allocator, io: Io, target: []const u8) !?[]const []const u8 {
        const names = try list(self, gpa, io);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }

        var by_stem: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer by_stem.deinit(gpa);
        for (names) |n| try by_stem.put(gpa, stemOf(n), n);
        const resolved = by_stem.get(stemOf(target)) orelse return null;

        var lg: disk_store.DiskLinkGraph = .{ .vault = self.root };
        const links = try lg.backlinks(gpa, io, resolved);
        defer {
            for (links) |l| gpa.free(l.node);
            gpa.free(links);
        }

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        for (links) |l| {
            if (std.mem.eql(u8, l.node, resolved)) continue; // no self-backlink
            try out.append(gpa, try gpa.dupe(u8, l.node));
        }
        const owned = try out.toOwnedSlice(gpa);
        std.mem.sort([]const u8, owned, {}, lessThan);
        return owned;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hitRank(_: void, a: Store.Hit, b: Store.Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.node, b.node) == .lt;
}

/// `DiskLinkGraph.backlinks` doesn't exclude a note linking to itself (see
/// this file's own module doc) -- this is the one place that matters,
/// shared by `search`'s ranking here.
fn countExcludingSelf(links: []const LinkGraph.Backlink, self_name: []const u8) usize {
    var n: usize = 0;
    for (links) |l| {
        if (std.mem.eql(u8, l.node, self_name)) continue;
        n += 1;
    }
    return n;
}

/// The filename stem a wikilink resolves against: the last path segment,
/// minus a trailing `.md` if the link target spelled one out explicitly.
fn stemOf(node: []const u8) []const u8 {
    return stripMdSuffix(std.fs.path.basename(node));
}

fn stripMdSuffix(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, ".md")) return text[0 .. text.len - 3];
    return text;
}

const testing = std.testing;

fn freeHits(gpa: Allocator, hits: []const Store.Hit) void {
    for (hits) |h| {
        gpa.free(h.node);
        gpa.free(h.context);
    }
    gpa.free(hits);
}

/// A fresh `_bard/vault`-shaped subdirectory (not yet created) under a
/// fresh tmp dir, so every test starts from a clean root.
fn vaultRoot(gpa: Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/vault", .{base});
}

test "write then read round-trips a note nested under a subdirectory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "designs/synapse-bard/Bible-graph.md", "# Bible-graph\n");
    const body = (try port.read(gpa, testing.io, "designs/synapse-bard/Bible-graph.md")).?;
    defer gpa.free(body);
    try testing.expectEqualStrings("# Bible-graph\n", body);
}

test "a missing node reads as null, not as an error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    try testing.expectEqual(@as(?[]u8, null), try s.store().read(gpa, testing.io, "absent.md"));
}

test "list walks subdirectories and excludes the vault's own Index.md" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "Index.md", "# Index\n");
    _ = try port.write(testing.io, "designs/a.md", "a\n");
    _ = try port.write(testing.io, "tasks/synapse-bard/synapse-bard-001.md", "task\n");

    const names = try port.list(gpa, testing.io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_design = false;
    var saw_task = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "designs/a.md")) saw_design = true;
        if (std.mem.eql(u8, n, "tasks/synapse-bard/synapse-bard-001.md")) saw_task = true;
    }
    try testing.expect(saw_design);
    try testing.expect(saw_task);
}

test "search ranks matching notes by backlink count, most-linked first" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    // Two notes link to `popular`, none link to `lonely` -- both mention
    // "flame hilt" so both match the query; ranking must still separate them.
    _ = try port.write(testing.io, "popular.md", "# Popular\nmentions the flame hilt\n");
    _ = try port.write(testing.io, "lonely.md", "# Lonely\nalso mentions the flame hilt\n");
    _ = try port.write(testing.io, "a.md", "links to [[popular]]\n");
    _ = try port.write(testing.io, "b.md", "links to [[popular|Popular Note]] and again [[popular]]\n");

    const hits = try port.search(gpa, testing.io, "flame hilt");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("popular.md", hits[0].node);
    try testing.expectEqual(@as(f32, 2.0), hits[0].score); // a.md and b.md, deduped within b.md
    try testing.expectEqualStrings("lonely.md", hits[1].node);
    try testing.expectEqual(@as(f32, 0.0), hits[1].score);
}

fn freeLinkingNotes(gpa: Allocator, notes: []const []const u8) void {
    for (notes) |n| gpa.free(n);
    gpa.free(notes);
}

test "linkingNotes lists every note that links to the target, resolved by stem" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "designs/target.md", "# Target\n");
    _ = try port.write(testing.io, "a.md", "links to [[target]]\n");
    _ = try port.write(testing.io, "b.md", "links to [[target|Target Note]]\n");
    _ = try port.write(testing.io, "c.md", "no link here\n");

    // Both a full path and a bare stem resolve to the same note.
    const by_stem = (try s.linkingNotes(gpa, testing.io, "target")).?;
    defer freeLinkingNotes(gpa, by_stem);
    try testing.expectEqual(@as(usize, 2), by_stem.len);
    try testing.expectEqualStrings("a.md", by_stem[0]);
    try testing.expectEqualStrings("b.md", by_stem[1]);

    const by_path = (try s.linkingNotes(gpa, testing.io, "designs/target.md")).?;
    defer freeLinkingNotes(gpa, by_path);
    try testing.expectEqual(@as(usize, 2), by_path.len);
}

test "linkingNotes returns an empty (non-null) slice for a real note with no backlinks" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    _ = try s.store().write(testing.io, "lonely.md", "# Lonely, nobody links here\n");

    const notes = (try s.linkingNotes(gpa, testing.io, "lonely")).?;
    defer freeLinkingNotes(gpa, notes);
    try testing.expectEqual(@as(usize, 0), notes.len);
}

test "linkingNotes is null for a name that resolves to no note at all" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    try testing.expectEqual(@as(?[]const []const u8, null), try s.linkingNotes(gpa, testing.io, "nonexistent"));
}

test "linkingNotes excludes a note linking to itself, same rule search() uses" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    _ = try s.store().write(testing.io, "self.md", "links to [[self]]\n");

    const notes = (try s.linkingNotes(gpa, testing.io, "self")).?;
    defer freeLinkingNotes(gpa, notes);
    try testing.expectEqual(@as(usize, 0), notes.len);
}

test "a note does not count as its own backlink" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "self.md", "mentions the flame hilt and links to [[self]]\n");

    const hits = try port.search(gpa, testing.io, "flame hilt");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(f32, 0.0), hits[0].score);
}

test "a wikilink resolves to its target despite differing case, via DiskLinkGraph's Unicode case-fold matching" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "designs/Bible-graph.md", "# Bible-graph\nmentions the flame hilt\n");
    // The wikilink spells the title with different casing than the real
    // file -- the old hand-rolled `by_stem` lookup (plain `std.mem.eql`)
    // would have missed this; `DiskLinkGraph`'s case-fold resolution
    // doesn't.
    _ = try port.write(testing.io, "a.md", "links to [[Bible-Graph]]\n");

    const hits = try port.search(gpa, testing.io, "flame hilt");
    defer freeHits(gpa, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("designs/Bible-graph.md", hits[0].node);
    try testing.expectEqual(@as(f32, 1.0), hits[0].score);

    const notes = (try s.linkingNotes(gpa, testing.io, "Bible-graph")).?;
    defer freeLinkingNotes(gpa, notes);
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqualStrings("a.md", notes[0]);
}

test "a write is atomic: no .tmp sibling survives, and an overwrite leaves no partial file" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try vaultRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardVaultStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    _ = try port.write(testing.io, "designs/a.md", "first\n");
    _ = try port.write(testing.io, "designs/a.md", "second\n");

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "vault/designs/a.md.tmp", .{}),
    );
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/designs/a.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("second\n", on_disk);
}
