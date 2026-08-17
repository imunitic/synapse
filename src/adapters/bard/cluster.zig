//! `_bard/graph/` cluster nodes (`synapse-bard-005`) -- the storage format
//! that replaced `synapse-bard-004`'s flat one-file-per-entity layout.
//! `synapse-bard sync` writes one node per source folder (a "cluster",
//! boundary chosen by `sync_cmd.zig`'s own shallowest-content-wins walk),
//! carrying a `sources:` manifest -- each member entity's slug plus its
//! real repo-relative path -- instead of a copy of that entity's own
//! frontmatter. `query`/`field`/`search` resolve a slug *through* a
//! cluster's `sources:` to find the real file to read, rather than reading
//! `_bard/graph/{slug}.md` directly the way they did before this task.
//!
//! `sources:`'s shape is fixed and this module is its only writer, so the
//! parser below is a narrow pattern match on that exact shape, not a
//! general YAML-list-of-mappings parser -- the same "own the whole
//! round-trip, so don't build more than the round-trip needs" reasoning
//! `synapse-bard`'s other adapters already use.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const graph_store = @import("graph_store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const BardGraphStore = graph_store.BardGraphStore;

/// One member of a cluster's `sources:` list, read back from a cluster
/// node. `slug`/`path` are both owned, allocator-independent copies.
pub const SourceEntry = struct {
    slug: []const u8,
    path: []const u8,
};

pub fn freeSourceEntries(gpa: Allocator, entries: []const SourceEntry) void {
    for (entries) |e| {
        gpa.free(e.slug);
        gpa.free(e.path);
    }
    gpa.free(entries);
}

/// A member entity as `sync` is about to write it -- `name` (for the
/// `## Entities` bullet's display text) is never stored in `sources:`
/// itself (see the module doc: `sources:` only needs slug+path to resolve
/// a query), so it's only carried through this write-side struct.
pub const WriteEntry = struct {
    slug: []const u8,
    path: []const u8,
    name: []const u8,
};

const end_marker = "<!-- synapse:generated:end -->\n";

/// Everything after the generated region's closing marker in an existing
/// cluster node's body -- a human's own hand-added prose survives a re-run
/// of `sync` untouched. Empty when there's no marker (a brand-new cluster,
/// or one written before this fencing existed).
pub fn preservedTail(existing_body: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, existing_body, end_marker) orelse return "";
    return existing_body[idx + end_marker.len ..];
}

/// Renders one cluster node's full file content: frontmatter (`title` +
/// `sources:`), then the fenced generated region (`## Entities`, one
/// wikilinked bullet per member), then whatever human-authored `tail`
/// (from `preservedTail` above) follows it. `entries` is written in the
/// order given -- callers sort first if a stable order matters.
pub fn renderClusterBody(gpa: Allocator, title: []const u8, entries: []const WriteEntry, tail: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print("---\ntitle: \"{s}\"\nsources:\n", .{title});
    for (entries) |e| {
        try w.print("  - slug: \"{s}\"\n    path: \"{s}\"\n", .{ e.slug, e.path });
    }
    try w.writeAll("---\n\n<!-- synapse:generated:start -->\n## Entities\n");
    for (entries) |e| {
        try w.print("- [[{s}]] \xe2\x80\x94 {s}\n", .{ e.slug, e.name });
    }
    try w.writeAll(end_marker);
    if (tail.len != 0) try w.writeAll(tail);

    return gpa.dupe(u8, out.written());
}

/// A cluster's boundary path (repo-root-relative, e.g.
/// `"characters/antagonists"` or `"world/countries/Dominion"`) -> its
/// display title (`"Characters - Antagonists"`, `"World - Countries -
/// Dominion"`): path segments joined by " - ", each segment's own on-disk
/// casing preserved except a lowercase first letter is capitalized (plain
/// lowercase folder names like `characters`/`world`/`magic` read as
/// title-cased; already-capitalized proper nouns like `Dominion`/`Severen`,
/// or a folder that already contains its own internal punctuation like
/// `Held - Borderlands`, pass through untouched apart from that one first
/// letter). Filesystem-illegal characters (`/ : * ? " < > |`) are replaced
/// with `_`, matching `synapse-node-format`'s own sanitizing rule --
/// unlikely to ever fire on a real folder name, kept as a safety valve.
///
/// One-directional on purpose: nothing parses a title back into a path.
/// `query`/`field`/`search` always resolve a slug through `sources:`
/// (`resolveSlug`/`allEntities` above), never by reading a cluster's title
/// string, so this function has no parsing counterpart to keep in sync.
pub fn clusterTitle(gpa: Allocator, rel_path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var segments = std.mem.splitScalar(u8, rel_path, '/');
    var first_segment = true;
    while (segments.next()) |seg| {
        if (!first_segment) try out.appendSlice(gpa, " - ");
        first_segment = false;
        for (seg, 0..) |c, i| {
            var ch = c;
            if (i == 0 and ch >= 'a' and ch <= 'z') ch = ch - 'a' + 'A';
            ch = switch (ch) {
                '/', ':', '*', '?', '"', '<', '>', '|' => '_',
                else => ch,
            };
            try out.append(gpa, ch);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `sources:`'s raw YAML, parsed back into entries. `cluster_src` is a
/// cluster node's full file content (frontmatter and body both fine to
/// pass -- only the frontmatter is read). Empty slice, not an error, when
/// there's no `sources:` field at all (a cluster node written by something
/// else, or corrupted by hand) -- `sync`'s reconciliation still needs to
/// `list()` every node in `_bard/graph/`, including ones that don't parse.
pub fn parseSources(gpa: Allocator, cluster_src: []const u8) ![]SourceEntry {
    const raw = (try frontmatter.rawField(gpa, cluster_src, "sources")) orelse return &.{};
    defer gpa.free(raw);
    return parseSourcesBlock(gpa, raw);
}

fn parseSourcesBlock(gpa: Allocator, raw: []const u8) ![]SourceEntry {
    var out: std.ArrayListUnmanaged(SourceEntry) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.slug);
            gpa.free(e.path);
        }
        out.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // the "sources:" line itself
    while (lines.next()) |slug_line| {
        if (std.mem.trim(u8, slug_line, " ").len == 0) continue;
        const path_line = lines.next() orelse break;
        const slug = quotedValueAfter(slug_line, "slug:") orelse continue;
        const path = quotedValueAfter(path_line, "path:") orelse continue;
        try out.append(gpa, .{ .slug = try gpa.dupe(u8, slug), .path = try gpa.dupe(u8, path) });
    }
    return out.toOwnedSlice(gpa);
}

/// `  - slug: "severen"` -> `"severen"`'s inner text -- the fixed two-field,
/// always-double-quoted shape `renderClusterBody` above writes. `null` for
/// anything that doesn't match (missing key, unquoted or unterminated
/// value) rather than a partial/best-effort read -- a cluster node this
/// module itself didn't write is out of scope, not a case to guess at.
fn quotedValueAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    const after = std.mem.trim(u8, line[idx + key.len ..], " ");
    if (after.len < 2 or after[0] != '"' or after[after.len - 1] != '"') return null;
    return after[1 .. after.len - 1];
}

/// Resolves `slug` to its real source path by scanning every cluster
/// node's `sources:`, stopping at the first match -- `synapse-bard-005`'s
/// measured call (see the design note): a reverse-index file would win on
/// relative terms but the absolute gap is noise against a CLI invocation's
/// own process-launch cost at this scale. `null` when no cluster claims
/// this slug.
pub fn resolveSlug(gpa: Allocator, io: Io, store: *BardGraphStore, slug: []const u8) !?SourceEntry {
    const port = store.store();
    const names = try port.list(gpa, io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    for (names) |name| {
        const body = (try port.read(gpa, io, name)) orelse continue;
        defer gpa.free(body);
        const entries = try parseSources(gpa, body);
        defer freeSourceEntries(gpa, entries);
        for (entries) |e| {
            if (std.mem.eql(u8, e.slug, slug)) {
                return .{ .slug = try gpa.dupe(u8, e.slug), .path = try gpa.dupe(u8, e.path) };
            }
        }
    }
    return null;
}

/// Every entity across every cluster, aggregated -- for callers that need
/// the whole graph rather than one slug (`query --inbound`, `search`, both
/// of which touch every entity regardless of which one triggered the
/// call).
pub fn allEntities(gpa: Allocator, io: Io, store: *BardGraphStore) ![]SourceEntry {
    const port = store.store();
    const names = try port.list(gpa, io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    var out: std.ArrayListUnmanaged(SourceEntry) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.slug);
            gpa.free(e.path);
        }
        out.deinit(gpa);
    }

    for (names) |name| {
        const body = (try port.read(gpa, io, name)) orelse continue;
        defer gpa.free(body);
        const entries = try parseSources(gpa, body);
        defer gpa.free(entries); // ownership of slug/path moves into `out` below
        try out.appendSlice(gpa, entries);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn graphRoot(gpa: Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(gpa, "{s}/graph", .{base});
}

test "renderClusterBody round-trips through parseSources" {
    const gpa = testing.allocator;
    const entries = [_]WriteEntry{
        .{ .slug = "severen", .path = "characters/antagonists/Severen/severen.md", .name = "Severen" },
        .{ .slug = "aidan-dayne", .path = "characters/antagonists/Aidan Dayne/aidan-dayne.md", .name = "Aidan Dayne" },
    };
    const body = try renderClusterBody(gpa, "Characters - Antagonists", &entries, "");
    defer gpa.free(body);

    const parsed = try parseSources(gpa, body);
    defer freeSourceEntries(gpa, parsed);

    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("severen", parsed[0].slug);
    try testing.expectEqualStrings("characters/antagonists/Severen/severen.md", parsed[0].path);
    try testing.expectEqualStrings("aidan-dayne", parsed[1].slug);
    try testing.expectEqualStrings("characters/antagonists/Aidan Dayne/aidan-dayne.md", parsed[1].path);
}

test "renderClusterBody's generated region names both members, wikilinked" {
    const gpa = testing.allocator;
    const entries = [_]WriteEntry{
        .{ .slug = "gael-varis", .path = "characters/main/Gael Varis/gael-varis.md", .name = "Gael Varis" },
    };
    const body = try renderClusterBody(gpa, "Characters - Main", &entries, "");
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "## Entities") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[[gael-varis]]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Gael Varis") != null);
}

test "preservedTail returns everything after the generated region's end marker" {
    const body = "---\ntitle: \"X\"\nsources:\n---\n\n<!-- synapse:generated:start -->\n## Entities\n<!-- synapse:generated:end -->\n\n## Notes\nHand-written.\n";
    try testing.expectEqualStrings("\n## Notes\nHand-written.\n", preservedTail(body));
}

test "preservedTail is empty when there's no end marker at all" {
    try testing.expectEqualStrings("", preservedTail("---\ntitle: \"X\"\n---\n"));
}

test "a re-render with a non-empty tail preserves it verbatim after the marker" {
    const gpa = testing.allocator;
    const entries = [_]WriteEntry{.{ .slug = "a", .path = "a.md", .name = "A" }};
    const body = try renderClusterBody(gpa, "A", &entries, "\n## Notes\nKeep me.\n");
    defer gpa.free(body);
    try testing.expect(std.mem.endsWith(u8, body, "\n## Notes\nKeep me.\n"));
}

test "resolveSlug scans every cluster node and stops at the first match" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    const entries_a = [_]WriteEntry{.{ .slug = "a", .path = "places/a.md", .name = "A" }};
    const body_a = try renderClusterBody(gpa, "Places", &entries_a, "");
    defer gpa.free(body_a);
    try port.write(testing.io, "Places.md", body_a);

    const entries_b = [_]WriteEntry{.{ .slug = "b", .path = "items/b.md", .name = "B" }};
    const body_b = try renderClusterBody(gpa, "Items", &entries_b, "");
    defer gpa.free(body_b);
    try port.write(testing.io, "Items.md", body_b);

    const found = (try resolveSlug(gpa, testing.io, &s, "b")).?;
    defer {
        gpa.free(found.slug);
        gpa.free(found.path);
    }
    try testing.expectEqualStrings("items/b.md", found.path);

    try testing.expectEqual(@as(?SourceEntry, null), try resolveSlug(gpa, testing.io, &s, "nonexistent"));
}

test "allEntities aggregates every cluster's sources into one list" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try graphRoot(gpa, &tmp);
    defer gpa.free(root);

    var s = try BardGraphStore.init(gpa, root);
    defer s.deinit();
    const port = s.store();

    const entries_a = [_]WriteEntry{
        .{ .slug = "a1", .path = "places/a1.md", .name = "A1" },
        .{ .slug = "a2", .path = "places/a2.md", .name = "A2" },
    };
    const body_a = try renderClusterBody(gpa, "Places", &entries_a, "");
    defer gpa.free(body_a);
    try port.write(testing.io, "Places.md", body_a);

    const entries_b = [_]WriteEntry{.{ .slug = "b1", .path = "items/b1.md", .name = "B1" }};
    const body_b = try renderClusterBody(gpa, "Items", &entries_b, "");
    defer gpa.free(body_b);
    try port.write(testing.io, "Items.md", body_b);

    const all = try allEntities(gpa, testing.io, &s);
    defer freeSourceEntries(gpa, all);
    try testing.expectEqual(@as(usize, 3), all.len);
}

test "clusterTitle joins segments with ' - ', capitalizing only a lowercase first letter" {
    const gpa = testing.allocator;
    {
        const t = try clusterTitle(gpa, "characters/antagonists");
        defer gpa.free(t);
        try testing.expectEqualStrings("Characters - Antagonists", t);
    }
    {
        const t = try clusterTitle(gpa, "world/countries/Dominion");
        defer gpa.free(t);
        try testing.expectEqualStrings("World - Countries - Dominion", t);
    }
    {
        // A folder that already has real capitalization (a proper noun,
        // or its own internal punctuation) passes through untouched.
        const t = try clusterTitle(gpa, "places/Dominion/Held - Borderlands");
        defer gpa.free(t);
        try testing.expectEqualStrings("Places - Dominion - Held - Borderlands", t);
    }
    {
        const t = try clusterTitle(gpa, "items");
        defer gpa.free(t);
        try testing.expectEqualStrings("Items", t);
    }
}

test "a cluster node with no sources: field at all parses as zero entries, not an error" {
    const gpa = testing.allocator;
    const parsed = try parseSources(gpa, "---\ntitle: \"Empty\"\n---\n");
    defer freeSourceEntries(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.len);
}
