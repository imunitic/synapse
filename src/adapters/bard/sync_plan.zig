//! `synapse-bard-009`: the clustering + extraction pipeline `sync` runs,
//! factored out of `apps/bard/sync_cmd.zig` into the adapter layer so a
//! second binary -- `synapse-bard-hook`'s `SessionStart` handler -- can
//! compute the exact same plan in-process, for drift detection, without
//! shelling out to the `synapse-bard` binary. `sync_cmd.zig` calls
//! `computePlan` for its own real-write path; `session_start.zig` calls it
//! read-only, comparing the result against disk via `cluster.isDirty`/
//! `cluster.wouldRemove`. One implementation of "what would sync produce",
//! never two that can drift apart from each other -- the same reason this
//! module exists rather than session_start.zig re-deriving its own
//! clustering pass.
//!
//! See `designs/synapse-bard/synapse-bard — Bible-graph drift detection.md`
//! (Synapse Vault) for the full design.

const std = @import("std");
const ports = @import("ports");
const frontmatter = @import("frontmatter.zig");
const graph_store = @import("graph_store.zig");
const cluster = @import("cluster.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const BardGraphStore = graph_store.BardGraphStore;
const Store = ports.Store;

/// One cluster: the boundary folder (repo-root-relative) and every `.md`
/// path at or below it, `.md` extension included, also repo-root-relative.
pub const Cluster = struct {
    boundary: []const u8,
    candidates: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *Cluster, gpa: Allocator) void {
        gpa.free(self.boundary);
        for (self.candidates.items) |c| gpa.free(c);
        self.candidates.deinit(gpa);
    }
};

/// One cluster `sync` would write, computed but not yet on disk -- `node`
/// is the filename (`"Characters - Main.md"`), `body` is the full rendered
/// content *with the existing file's own preserved tail already spliced
/// in* (via `store.read` + `cluster.preservedTail`, same as a real write
/// does), so a caller never has to know about tails separately: `body` is
/// directly what a write would produce, and `cluster.generatedRegion(body)`
/// is directly what drift detection compares against what's on disk.
pub const PlannedCluster = struct {
    node: []const u8,
    body: []const u8,
};

/// Everything `sync` computes before it writes a single byte.
pub const Plan = struct {
    clusters: std.ArrayListUnmanaged(PlannedCluster) = .empty,
    /// Pre-formatted `"skipped (...): ..."` / `"COLLISION: ..."` lines, in
    /// the order the original single-pass loop produced them -- only
    /// `sync`'s real-write path prints these; drift detection doesn't need
    /// them.
    report_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    ingested: usize = 0,
    skipped: usize = 0,
    collisions: usize = 0,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        for (self.clusters.items) |c| {
            gpa.free(c.node);
            gpa.free(c.body);
        }
        self.clusters.deinit(gpa);
        for (self.report_lines.items) |l| gpa.free(l);
        self.report_lines.deinit(gpa);
    }
};

/// Clusters the source tree, extracts every candidate's frontmatter, and
/// renders the full body `sync` would write for every cluster that ends up
/// with at least one accepted member -- everything short of actually
/// writing a byte to `_bard/graph/`. `store` is read from (to find each
/// cluster's existing preserved tail) but never written to here.
pub fn computePlan(gpa: Allocator, io: Io, repo_root: []const u8, store: Store) !Plan {
    var clusters = try findClusters(gpa, io, repo_root);
    defer {
        for (clusters.items) |*c| c.deinit(gpa);
        clusters.deinit(gpa);
    }
    std.mem.sort(Cluster, clusters.items, {}, clusterLessThan);
    for (clusters.items) |*c| std.mem.sort([]const u8, c.candidates.items, {}, lessThan);

    // Flatten for one batch `extract()` call across the whole corpus (CLI
    // startup cost paid once, same reasoning `synapse-bard-004` already
    // used), tracking which cluster each flattened path belongs to.
    var flat: std.ArrayListUnmanaged([]const u8) = .empty;
    defer flat.deinit(gpa);
    var owner: std.ArrayListUnmanaged(usize) = .empty;
    defer owner.deinit(gpa);
    for (clusters.items, 0..) |c, ci| {
        for (c.candidates.items) |p| {
            try flat.append(gpa, p);
            try owner.append(gpa, ci);
        }
    }

    var ex: frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const outcomes = try ex.port().extract(gpa, io, repo_root, flat.items);
    defer freeOutcomes(gpa, outcomes);

    var plan: Plan = .{};
    errdefer plan.deinit(gpa);

    // Slug uniqueness is global across the whole graph, not per-cluster: a
    // slug can only resolve to one real path (`query`/`field` need exactly
    // one answer), so two entities anywhere in the corpus sharing a
    // filename stem is a collision even if they land in different
    // clusters. Same "refuse rather than silently mishandle" tracking
    // `synapse-bard-004` built for the flat layout, unchanged in mechanism.
    var claimed: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer claimed.deinit(gpa);

    const accepted = try gpa.alloc(std.ArrayListUnmanaged(cluster.WriteEntry), clusters.items.len);
    defer {
        for (accepted) |*a| a.deinit(gpa);
        gpa.free(accepted);
    }
    for (accepted) |*a| a.* = .empty;

    for (flat.items, 0..) |candidate, i| {
        const ci = owner.items[i];
        const slug = stemOf(candidate);
        switch (outcomes[i]) {
            .unsupported => {
                plan.skipped += 1;
                try plan.report_lines.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "skipped ({s}): {s}\n",
                    .{ @tagName(ex.last_refusals[i] orelse .not_a_note), candidate },
                ));
            },
            .tags => |tags| {
                if (claimed.get(slug)) |first| {
                    plan.collisions += 1;
                    try plan.report_lines.append(gpa, try std.fmt.allocPrint(
                        gpa,
                        "COLLISION: {s} and {s} both resolve to slug '{s}' -- kept {s}, skipped {s}\n",
                        .{ first, candidate, slug, first, candidate },
                    ));
                    continue;
                }

                var name: []const u8 = slug;
                for (tags) |t| if (t.role == .def) {
                    name = t.name;
                    break;
                };

                try accepted[ci].append(gpa, .{ .slug = slug, .path = candidate, .name = name });
                try claimed.put(gpa, slug, candidate);
                plan.ingested += 1;
            },
        }
    }

    for (clusters.items, 0..) |c, ci| {
        if (accepted[ci].items.len == 0) continue; // every candidate here was refused or collided away

        const title = try cluster.clusterTitle(gpa, c.boundary);
        defer gpa.free(title);
        const node = try std.fmt.allocPrint(gpa, "{s}.md", .{title});
        errdefer gpa.free(node);

        const existing = try store.read(gpa, io, node);
        defer if (existing) |e| gpa.free(e);
        const tail = if (existing) |e| cluster.preservedTail(e) else "";

        const body = try cluster.renderClusterBody(gpa, title, accepted[ci].items, tail);
        errdefer gpa.free(body);

        try plan.clusters.append(gpa, .{ .node = node, .body = body });
    }

    return plan;
}

/// Deletes every existing node not present in `written` (the cluster
/// filenames just produced this run) -- a folder that no longer produces
/// any accepted entity (renamed, emptied, or every member now refused)
/// must not leave a stale cluster node behind. Returns the count removed.
/// The real-write counterpart to `cluster.wouldRemove`'s read-only report.
pub fn reconcile(gpa: Allocator, io: Io, store: *BardGraphStore, written: []const []const u8) !usize {
    const port = store.store();
    const existing = try port.list(gpa, io);
    defer freeNames(gpa, existing);

    var keep: std.StringHashMapUnmanaged(void) = .empty;
    defer keep.deinit(gpa);
    for (written) |n| try keep.put(gpa, n, {});

    var removed: usize = 0;
    for (existing) |node| {
        if (keep.contains(node)) continue;
        try store.delete(io, node);
        removed += 1;
    }
    return removed;
}

fn freeNames(gpa: Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn freeOutcomes(gpa: Allocator, out: []ports.Extractor.Outcome) void {
    for (out) |o| switch (o) {
        .unsupported => {},
        .tags => |ts| {
            for (ts) |t| {
                gpa.free(t.name);
                gpa.free(t.kind);
                gpa.free(t.expression);
            }
            gpa.free(ts);
        },
    };
    gpa.free(out);
}

/// Every top-level, non-`_`/`.`-prefixed folder under `root` becomes the
/// starting point for a boundary search -- clustering only ever applies
/// within folders, so a loose `.md` file directly in the repo root (a
/// README, say) is never a candidate at all.
fn findClusters(gpa: Allocator, io: Io, root: []const u8) !std.ArrayListUnmanaged(Cluster) {
    var out: std.ArrayListUnmanaged(Cluster) = .empty;
    errdefer {
        for (out.items) |*c| c.deinit(gpa);
        out.deinit(gpa);
    }

    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '_' or entry.name[0] == '.') continue;
        if (entry.kind != .directory) continue;
        var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        const rel = try gpa.dupe(u8, entry.name);
        try findBoundary(gpa, io, sub, rel, &out);
    }
    return out;
}

/// The shallowest-content-wins rule (settled in the design note, measured
/// against the real repo: 65 files -> 24 clusters): one pass over `dir`
/// decides whether it directly contains any `.md` file. If it does, `dir`
/// itself is the cluster boundary -- every `.md` at or below it, however
/// deep, belongs to this one cluster, and no further boundary is drawn
/// beneath it even if a subdirectory also has its own direct content. If
/// it doesn't, keep searching one level deeper in each subdirectory for
/// the next shallowest boundary. Exactly one `dir.iterate()` call per
/// directory -- deciding and collecting in the same pass, rather than
/// iterating once to check and again to collect, since a directory
/// iterator's position isn't guaranteed to support being read twice.
fn findBoundary(gpa: Allocator, io: Io, dir: Io.Dir, rel: []const u8, out: *std.ArrayListUnmanaged(Cluster)) !void {
    var direct_md: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (direct_md.items) |n| gpa.free(n);
        direct_md.deinit(gpa);
    }
    var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (subdirs.items) |n| gpa.free(n);
        subdirs.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '_' or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".md")) {
                try direct_md.append(gpa, try gpa.dupe(u8, entry.name));
            },
            .directory => try subdirs.append(gpa, try gpa.dupe(u8, entry.name)),
            else => {},
        }
    }

    if (direct_md.items.len == 0) {
        defer gpa.free(rel);
        for (subdirs.items) |name| {
            var sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const child_rel = try std.fs.path.join(gpa, &.{ rel, name });
            try findBoundary(gpa, io, sub, child_rel, out);
        }
        return;
    }

    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (candidates.items) |c| gpa.free(c);
        candidates.deinit(gpa);
    }
    for (direct_md.items) |name| {
        try candidates.append(gpa, try std.fs.path.join(gpa, &.{ rel, name }));
    }
    for (subdirs.items) |name| {
        var sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        const child_rel = try std.fs.path.join(gpa, &.{ rel, name });
        defer gpa.free(child_rel);
        try collectAllMd(gpa, io, sub, child_rel, &candidates);
    }
    try out.append(gpa, .{ .boundary = rel, .candidates = candidates });
}

/// Every `.md` file under `dir`, recursive, excluding `_`/`.`-prefixed
/// subdirectories -- no further boundary pruning once a cluster boundary
/// has already been chosen (`findBoundary` above), so everything below it
/// belongs to the same cluster regardless of whether a subdirectory also
/// has its own direct content.
fn collectAllMd(gpa: Allocator, io: Io, dir: Io.Dir, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '_' or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".md")) {
                try out.append(gpa, try std.fs.path.join(gpa, &.{ prefix, entry.name }));
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const child_prefix = try std.fs.path.join(gpa, &.{ prefix, entry.name });
                defer gpa.free(child_prefix);
                try collectAllMd(gpa, io, sub, child_prefix, out);
            },
            else => {},
        }
    }
}

/// The last path segment, minus `.md` -- a candidate list only ever
/// contains `.md`-suffixed entries, so this is always safe.
fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return base[0 .. base.len - 3];
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn clusterLessThan(_: void, a: Cluster, b: Cluster) bool {
    return std.mem.order(u8, a.boundary, b.boundary) == .lt;
}

const testing = std.testing;

test "computePlan clusters a scratch tree and produces one PlannedCluster with the expected body" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: Alice\ntemplate: character\n---\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();

    var plan = try computePlan(gpa, testing.io, root, store.store());
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), plan.ingested);
    try testing.expectEqual(@as(usize, 0), plan.skipped);
    try testing.expectEqual(@as(usize, 0), plan.collisions);
    try testing.expectEqual(@as(usize, 1), plan.clusters.items.len);
    try testing.expectEqualStrings("Characters.md", plan.clusters.items[0].node);
    try testing.expect(std.mem.indexOf(u8, plan.clusters.items[0].body, "[[a]]") != null);
}

test "computePlan's rendered body already carries the existing file's preserved tail" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.createDirPath(testing.io, "characters");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "characters/a.md",
        .data = "---\nname: Alice\ntemplate: character\n---\n",
    });

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);
    var store: BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();

    // Write a cluster node with a hand-added tail before planning, the same
    // shape a real prior `sync` plus a human edit would leave behind.
    _ = try store.store().write(testing.io, "Characters.md", "---\ntitle: \"Characters\"\nsources:\n  - slug: \"a\"\n    path: \"characters/a.md\"\n---\n\n<!-- synapse:generated:start -->\n## Entities\n- [[a]] \xe2\x80\x94 Alice\n<!-- synapse:generated:end -->\n\n## Notes\nKeep me.\n");

    var plan = try computePlan(gpa, testing.io, root, store.store());
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), plan.clusters.items.len);
    try testing.expect(std.mem.endsWith(u8, plan.clusters.items[0].body, "\n## Notes\nKeep me.\n"));
}

test "reconcile deletes a graph-store node the plan didn't produce" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{root});
    defer gpa.free(graph_root);

    var store: BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    _ = try store.store().write(testing.io, "Stale.md", "stale");
    _ = try store.store().write(testing.io, "Keep.md", "keep");

    const removed = try reconcile(gpa, testing.io, &store, &.{"Keep.md"});
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(?[]u8, null), try store.store().read(gpa, testing.io, "Stale.md"));
    const kept = (try store.store().read(gpa, testing.io, "Keep.md")).?;
    defer gpa.free(kept);
}
