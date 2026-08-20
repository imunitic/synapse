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
//! ## The backlink graph isn't reused from `core`, and here's why
//!
//! The task note that specified this store said graph traversal "reuses
//! whatever link-graph logic `core` already has for code-graph node links."
//! Neither of the two candidates actually fits, checked before writing a
//! line of this file:
//!
//! - `core/links.zig` *infers* implicit code edges from rare-symbol
//!   co-occurrence across `_refs.tsv` -- solving "which files are probably
//!   related, given no one said so." A vault wikilink is never implicit; the
//!   author already said so. Wrong problem.
//! - `core/query.zig`'s `edges`/`parseEdge` parses `- <relation> [[Target]]`
//!   lines, scoped to a node's `## Links` section specifically. Bard vault
//!   notes (this file's own module docs included, this session) put
//!   `[[wikilinks]]` inline in prose anywhere, with no relation prefix and
//!   no reserved section. Wrong shape.
//!
//! What's actually reusable is smaller than either: "every `[[target]]` in
//! some text, target before any `|`" -- the same primitive
//! `bard/frontmatter.zig`'s `scanValue` already has, just over prose instead
//! of a YAML scalar. `backlinks` below is that primitive, plus Obsidian's
//! own resolution rule (a wikilink resolves by filename stem, not by vault
//! path -- `core/emit.zig`'s own doc comment says the same for the coding
//! vault).

const std = @import("std");
const ports = @import("ports");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

/// Not a real note -- the vault's own bootstrap file, excluded from `list`
/// the same way `ObsidianStore`'s own doc comment excludes it for the
/// coding vault.
const index_node = "Index.md";

pub const BardVaultStore = struct {
    gpa: Allocator,
    /// Directory notes live under, e.g. `"_bard/vault"` -- resolved once.
    root: []const u8,

    pub fn init(gpa: Allocator, root: []const u8) !BardVaultStore {
        return .{ .gpa = gpa, .root = try gpa.dupe(u8, root) };
    }

    pub fn deinit(self: *BardVaultStore) void {
        self.gpa.free(self.root);
    }

    /// The wrapper idiom (sb-024): `Store.from` generates the `*anyopaque`
    /// cast from `BardVaultStore` alone, so it can never disagree with
    /// `.ptr` the way a hand-written vtable literal could.
    pub fn store(self: *BardVaultStore) Store {
        return Store.from(BardVaultStore, self);
    }

    pub fn read(self: *BardVaultStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const path = try std.fs.path.join(gpa, &.{ self.root, node });
        defer gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) return null;
            return e;
        };
    }

    pub fn write(self: *BardVaultStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const path = try std.fs.path.join(self.gpa, &.{ self.root, node });
        defer self.gpa.free(path);
        // Unlike the graph store's flat namespace, `node` here routinely
        // implies subdirectories (`designs/synapse-bard/...`) that may not
        // exist yet -- create the whole parent chain, idempotently.
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
        return .{ .accepted = true };
    }

    /// Every `.md` file under `root`, recursive -- notes live in
    /// subdirectories, unlike the graph store's flat layout. `Index.md` at
    /// the vault root is excluded (bootstrap, not a note). A `root` that
    /// doesn't exist yet lists as empty, not an error.
    pub fn list(self: *BardVaultStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }

        if (Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var walker = try d.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
                if (std.mem.eql(u8, entry.path, index_node)) continue;
                try out.append(gpa, try gpa.dupe(u8, entry.path));
            }
        } else |e| {
            if (e != error.FileNotFound) return e;
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

        var links = try backlinks(gpa, io, self.root, names);
        defer {
            var it = links.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            links.deinit(gpa);
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
            if (std.mem.indexOf(u8, body, query) == null) continue;
            const count = if (links.get(name)) |l| l.items.len else 0;
            try out.append(gpa, .{
                .node = try gpa.dupe(u8, name),
                .score = @floatFromInt(count),
                .context = try gpa.dupe(u8, firstMatchingLine(body, query) orelse ""),
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

        var links = try backlinks(gpa, io, self.root, names);
        defer {
            var it = links.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            links.deinit(gpa);
        }

        // A real, gpa-allocated empty slice when `resolved` has no
        // backlinks -- not a literal `&.{}`, which isn't allocator-owned
        // memory and would crash the caller's unconditional `gpa.free()`.
        const source_names = if (links.get(resolved)) |l| l.items else &.{};
        var out = try gpa.alloc([]const u8, source_names.len);
        errdefer gpa.free(out);
        for (source_names, 0..) |n, i| out[i] = try gpa.dupe(u8, n);
        std.mem.sort([]const u8, out, {}, lessThan);
        return out;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hitRank(_: void, a: Store.Hit, b: Store.Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.node, b.node) == .lt;
}

fn firstMatchingLine(body: []const u8, query: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, query) != null) return line;
    }
    return null;
}

/// Every note in `names` that links to each note in `names` -- a note that
/// links to the same target three times contributes once, matching what
/// "backlinks" means in Obsidian's own panel (linking notes, not raw
/// occurrences). Both keys and the source names in each value list borrow
/// `names`' own strings; the caller frees each value's `ArrayListUnmanaged`
/// before deiniting the outer map.
fn backlinks(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    names: []const []const u8,
) !std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) {
    // A wikilink resolves by filename stem, not by vault path -- Obsidian's
    // own rule, and the one this codebase's coding-vault side already
    // documents (`core/emit.zig`).
    var by_stem: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer by_stem.deinit(gpa);
    for (names) |n| try by_stem.put(gpa, stemOf(n), n);

    var out: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    errdefer {
        var it = out.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        out.deinit(gpa);
    }

    for (names) |from| {
        const path = try std.fs.path.join(gpa, &.{ root, from });
        defer gpa.free(path);
        const body = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(body);

        // Per-source dedup: this note's own multiple links to the same
        // target must not list `from` more than once against that target.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);

        var rest: []const u8 = body;
        while (std.mem.indexOf(u8, rest, "[[")) |start| {
            const after = rest[start + 2 ..];
            const end = std.mem.indexOf(u8, after, "]]") orelse break;
            const inner = after[0..end];
            rest = after[end + 2 ..];

            const pipe = std.mem.indexOfScalar(u8, inner, '|') orelse inner.len;
            const target_text = std.mem.trim(u8, inner[0..pipe], " ");
            if (target_text.len == 0) continue;
            const resolved = by_stem.get(stripMdSuffix(target_text)) orelse continue;
            if (std.mem.eql(u8, resolved, from)) continue; // no self-backlink
            if (seen.contains(resolved)) continue;
            try seen.put(gpa, resolved, {});

            const slot = try out.getOrPut(gpa, resolved);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(gpa, from);
        }
    }
    return out;
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
