//! `synapse-bard sync` -- populates `_bard/graph/` from the bible's real
//! source tree. Not `/synapse-init`'s mechanism (checked, not assumed):
//! that command builds the coding graph through LLM judgment, deciding
//! what subsystems exist and authoring summary/crux prose per node. Bard's
//! version is a mechanical transform with no judgment calls.
//!
//! `synapse-bard-005` rewrote this from `synapse-bard-004`'s flat
//! one-file-per-entity layout to clustering: `_bard/graph/` now holds one
//! node per *cluster* (a source folder), each carrying a `sources:`
//! manifest of its member entities rather than a copy of one entity's own
//! frontmatter. See `src/adapters/bard/cluster.zig` for the manifest
//! format and `designs/synapse-bard/synapse-bard — Bible-graph.md` (Synapse
//! Vault) for why: a flat 53-file `_bard/graph/` wasn't browsable the way
//! Synapse's own code-graph is.
//!
//! Always a full re-ingest, never incremental: the whole corpus extracts in
//! ~10ms (`synapse-bard-002`'s own measurement), so there's nothing to gain
//! from dirty-tracking complexity -- re-ingesting a few hundred small files
//! is cheaper than the bookkeeping a "what changed" system would cost.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const ports = @import("ports");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: synapse-bard sync
    \\
    \\Walks the bible repo for entity files (any path with a `_`- or
    \\`.`-prefixed folder is excluded), groups them into clusters -- the
    \\shallowest folder in each top-level, non-excluded folder's tree that
    \\directly contains a `.md` file -- and writes one
    \\_bard/graph/{Cluster Title}.md per cluster, carrying a `sources:`
    \\manifest of its member entities. Always a full re-ingest; stale
    \\cluster nodes for folders no longer producing any entity are removed.
    \\
;

/// One cluster: the boundary folder (repo-root-relative) and every `.md`
/// path at or below it, `.md` extension included, also repo-root-relative.
const Cluster = struct {
    boundary: []const u8,
    candidates: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *Cluster, gpa: Allocator) void {
        gpa.free(self.boundary);
        for (self.candidates.items) |c| gpa.free(c);
        self.candidates.deinit(gpa);
    }
};

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |extra| {
        // Help must not need an environment.
        if (std.mem.eql(u8, extra, "-h") or std.mem.eql(u8, extra, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        std.debug.print("synapse-bard sync: unexpected argument '{s}'\n{s}", .{ extra, usage });
        return 2;
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var clusters = try findClusters(gpa, io, roots.repo_root);
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

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const outcomes = try ex.port().extract(gpa, io, roots.repo_root, flat.items);
    defer common.freeOutcomes(gpa, outcomes);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();
    const port = store.store();

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);

    // Slug uniqueness is global across the whole graph, not per-cluster: a
    // slug can only resolve to one real path (`query`/`field` need exactly
    // one answer), so two entities anywhere in the corpus sharing a
    // filename stem is a collision even if they land in different
    // clusters. Same "refuse rather than silently mishandle" tracking
    // `synapse-bard-004` built for the flat layout, unchanged in mechanism.
    var claimed: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer claimed.deinit(gpa);

    const accepted = try gpa.alloc(std.ArrayListUnmanaged(adapters.bard_cluster.WriteEntry), clusters.items.len);
    defer {
        for (accepted) |*a| a.deinit(gpa);
        gpa.free(accepted);
    }
    for (accepted) |*a| a.* = .empty;

    var ingested: usize = 0;
    var skipped: usize = 0;
    var collisions: usize = 0;

    for (flat.items, 0..) |candidate, i| {
        const ci = owner.items[i];
        const slug = stemOf(candidate);
        switch (outcomes[i]) {
            .unsupported => {
                skipped += 1;
                try w.interface.print(
                    "skipped ({s}): {s}\n",
                    .{ @tagName(ex.last_refusals[i] orelse .not_a_note), candidate },
                );
            },
            .tags => |tags| {
                if (claimed.get(slug)) |first| {
                    collisions += 1;
                    try w.interface.print(
                        "COLLISION: {s} and {s} both resolve to slug '{s}' -- kept {s}, skipped {s}\n",
                        .{ first, candidate, slug, first, candidate },
                    );
                    continue;
                }

                var name: []const u8 = slug;
                for (tags) |t| if (t.role == .def) {
                    name = t.name;
                    break;
                };

                try accepted[ci].append(gpa, .{ .slug = slug, .path = candidate, .name = name });
                try claimed.put(gpa, slug, candidate);
                ingested += 1;
            },
        }
    }

    var written: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (written.items) |n| gpa.free(n);
        written.deinit(gpa);
    }

    var clusters_written: usize = 0;
    for (clusters.items, 0..) |c, ci| {
        if (accepted[ci].items.len == 0) continue; // every candidate here was refused or collided away

        const title = try adapters.bard_cluster.clusterTitle(gpa, c.boundary);
        defer gpa.free(title);
        const node = try std.fmt.allocPrint(gpa, "{s}.md", .{title});
        errdefer gpa.free(node);

        const existing = try port.read(gpa, io, node);
        defer if (existing) |e| gpa.free(e);
        const tail = if (existing) |e| adapters.bard_cluster.preservedTail(e) else "";

        const body = try adapters.bard_cluster.renderClusterBody(gpa, title, accepted[ci].items, tail);
        defer gpa.free(body);

        try port.write(io, node, body);
        try written.append(gpa, node);
        clusters_written += 1;
    }

    const removed = try reconcile(gpa, io, &store, written.items);

    try w.interface.print("\ningested: {d}\n", .{ingested});
    try w.interface.print("skipped (unsupported): {d}\n", .{skipped});
    try w.interface.print("collisions: {d}\n", .{collisions});
    try w.interface.print("clusters: {d}\n", .{clusters_written});
    try w.interface.print("removed (no longer in source): {d}\n", .{removed});
    try w.interface.flush();
    return 0;
}

/// Deletes every existing node not present in `written` (the cluster
/// filenames just produced this run) -- a folder that no longer produces
/// any accepted entity (renamed, emptied, or every member now refused)
/// must not leave a stale cluster node behind. Same mechanism
/// `synapse-bard-004` used for the flat layout; on the very first clustered
/// run this naturally deletes every old `{slug}.md` file too, since none
/// of them are in the newly-written cluster-filename set -- no separate
/// migration step needed. Returns the count removed.
fn reconcile(
    gpa: Allocator,
    io: Io,
    store: *adapters.bard_graph_store.BardGraphStore,
    written: []const []const u8,
) !usize {
    const port = store.store();
    const existing = try port.list(gpa, io);
    defer common.freeNames(gpa, existing);

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
