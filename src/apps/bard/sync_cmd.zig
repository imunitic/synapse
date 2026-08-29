//! `synapse-bard sync` -- populates `_bard/graph/` from the bible's real
//! source tree. Not `/synapse-init`'s mechanism (checked, not assumed):
//! that command builds the coding graph through LLM judgment, deciding
//! what subsystems exist and authoring summary/crux prose per node. Bard's
//! version is a mechanical transform with no judgment calls.
//!
//! This was rewritten from an earlier flat one-file-per-entity layout to
//! clustering: `_bard/graph/` now holds one
//! node per *cluster* (a source folder), each carrying a `sources:`
//! manifest of its member entities rather than a copy of one entity's own
//! frontmatter -- a flat 53-file `_bard/graph/` wasn't browsable the way
//! Synapse's own code-graph is. See `src/adapters/bard/cluster.zig` for
//! the manifest format.
//!
//! Always a full re-ingest, never incremental: the whole corpus extracts in
//! ~10ms (measured directly), so there's nothing to gain from
//! dirty-tracking complexity -- re-ingesting a few hundred small files
//! is cheaper than the bookkeeping a "what changed" system would cost.
//!
//! `--check` is a dry-run mode answering "would a real `sync` change
//! anything", reusing `adapters.bard_sync_plan.computePlan`
//! -- the exact same clustering/extraction pipeline the write path below
//! uses -- so there is never a second, parallel notion of what `sync` would
//! produce. `--check` never calls `port.write`/`store.delete`; it only
//! reads.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const ports = @import("ports");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The vault's starter index, embedded at compile time -- no runtime
/// dependency on `CLAUDE_PLUGIN_ROOT` (unset entirely for a repo where
/// `synapse-bard`'s `.claude/` files were committed directly rather than
/// installed through Claude Code's plugin system). A byte-identical copy of
/// `plugins/synapse-bard/Index.md.template` (the one a marketplace plugin
/// install actually ships) rather than that file directly -- `@embedFile`'s
/// package boundary is this module's own root, which doesn't reach
/// `plugins/`; the "identical copy" test below is what keeps the two from
/// drifting apart silently.
const vault_index_template = @embedFile("vault_index_template.md");

const usage =
    \\usage: synapse-bard sync
    \\       synapse-bard sync --check
    \\
    \\Walks the bible repo for entity files (any path with a `_`- or
    \\`.`-prefixed folder is excluded), groups them into clusters -- the
    \\shallowest folder in each top-level, non-excluded folder's tree that
    \\directly contains a `.md` file -- and writes one
    \\_bard/graph/{Cluster Title}.md per cluster, carrying a `sources:`
    \\manifest of its member entities. Always a full re-ingest; stale
    \\cluster nodes for folders no longer producing any entity are removed.
    \\
    \\  --check    report whether _bard/graph/ matches what a real run
    \\             would produce, without writing anything. Exit 0 if it
    \\             already matches, exit 1 if it doesn't.
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    var check = false;
    if (args.next()) |first| {
        // Help must not need an environment.
        if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        if (std.mem.eql(u8, first, "--check")) {
            check = true;
        } else {
            std.debug.print("synapse-bard sync: unexpected argument '{s}'\n{s}", .{ first, usage });
            return 2;
        }
        if (args.next()) |extra| {
            std.debug.print("synapse-bard sync: unexpected argument '{s}'\n{s}", .{ extra, usage });
            return 2;
        }
    }

    const roots = common.Roots.resolve(gpa, io) catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer roots.deinit(gpa);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, roots.graph_root);
    defer store.deinit();

    var plan = try adapters.bard_sync_plan.computePlan(gpa, io, roots.repo_root, store.store());
    defer plan.deinit(gpa);

    if (check) return runCheck(gpa, io, store.store(), &plan);
    return runWrite(gpa, io, &store, &plan, roots.vault_root);
}

/// Real sync: writes every planned cluster, then deletes whatever
/// `_bard/graph/` node the plan didn't produce at all. Takes the concrete
/// store, not `ports.Store` -- `reconcile` below needs `.delete`, which
/// isn't on the shared interface.
fn runWrite(gpa: Allocator, io: Io, store: *adapters.bard_graph_store.BardGraphStore, plan: *const adapters.bard_sync_plan.Plan, vault_root: []const u8) !u8 {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    for (plan.report_lines.items) |l| try w.interface.print("{s}", .{l});

    for (plan.clusters.items) |pc| _ = try store.write(io, pc.node, pc.body);

    const written = try gpa.alloc([]const u8, plan.clusters.items.len);
    defer gpa.free(written); // the names themselves are borrowed from `plan`, not owned here
    for (plan.clusters.items, 0..) |pc, i| written[i] = pc.node;
    const removed = try adapters.bard_sync_plan.reconcile(gpa, io, store, written);

    const seeded = try seedVaultIndex(io, vault_root);

    try w.interface.print("\ningested: {d}\n", .{plan.ingested});
    try w.interface.print("skipped (unsupported): {d}\n", .{plan.skipped});
    try w.interface.print("collisions: {d}\n", .{plan.collisions});
    try w.interface.print("clusters: {d}\n", .{plan.clusters.items.len});
    try w.interface.print("removed (no longer in source): {d}\n", .{removed});
    if (seeded) try w.interface.print("seeded {s}/Index.md (first use)\n", .{vault_root});
    try w.interface.flush();
    return 0;
}

/// Seeds `{vault_root}/Index.md` from the shipped template when it doesn't
/// exist yet, mechanically -- no confirmation step. Bringing `synapse-bard`
/// online in a repo via `sync` already is the human's explicit signal the
/// vault should exist; the shared, cross-project Synapse Vault's own
/// confirm-before-seeding caution is about a vault shared across unrelated
/// projects, which `_bard/vault/` never is. Returns whether it actually
/// seeded anything, so the caller can report it.
fn seedVaultIndex(io: Io, vault_root: []const u8) !bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&buf, "{s}/Index.md", .{vault_root});
    Io.Dir.cwd().access(io, index_path, .{}) catch {
        try Io.Dir.cwd().createDirPath(io, vault_root);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = vault_index_template });
        return true;
    };
    return false;
}

/// `--check`: reads only, never writes. A cluster is dirty when its
/// computed generated region (frontmatter + `## Entities`, never the
/// preserved tail -- see `cluster.generatedRegion`'s own doc comment)
/// doesn't match what's currently on disk, or when the file doesn't exist
/// yet at all. Separately, any `_bard/graph/` node the plan doesn't produce
/// at all is what a real sync's `reconcile` would delete -- reported, not
/// deleted.
fn runCheck(gpa: Allocator, io: Io, store: ports.Store, plan: *const adapters.bard_sync_plan.Plan) !u8 {
    var dirty: std.ArrayListUnmanaged([]const u8) = .empty; // node names, borrowed from `plan`
    defer dirty.deinit(gpa);
    for (plan.clusters.items) |pc| {
        const existing = try store.read(gpa, io, pc.node);
        defer if (existing) |e| gpa.free(e);
        if (adapters.bard_cluster.isDirty(existing, pc.body)) try dirty.append(gpa, pc.node);
    }

    const existing_nodes = try store.list(gpa, io);
    defer common.freeNames(gpa, existing_nodes);
    const planned_nodes = try gpa.alloc([]const u8, plan.clusters.items.len);
    defer gpa.free(planned_nodes);
    for (plan.clusters.items, 0..) |pc, i| planned_nodes[i] = pc.node;
    const would_remove = try adapters.bard_cluster.wouldRemove(gpa, existing_nodes, planned_nodes);
    defer gpa.free(would_remove);

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const total = dirty.items.len + would_remove.len;
    if (total == 0) {
        try w.interface.print("_bard/graph/ matches source -- no drift\n", .{});
        try w.interface.flush();
        return 0;
    }
    for (dirty.items) |n| try w.interface.print("drift: {s}\n", .{n});
    for (would_remove) |n| try w.interface.print("would remove: {s}\n", .{n});
    try w.interface.print("\n{d} cluster(s) out of date -- run `synapse-bard sync`\n", .{total});
    try w.interface.flush();
    return 1;
}
