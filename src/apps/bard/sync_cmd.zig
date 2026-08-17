//! `synapse-bard sync` -- populates `_bard/graph/` from the bible's real
//! source tree. Not `/synapse-init`'s mechanism (checked, not assumed):
//! that command builds the coding graph through LLM judgment, deciding
//! what subsystems exist and authoring summary/crux prose per node. Bard's
//! version is a mechanical 1:1 transform with no judgment calls -- one
//! source entity file maps to exactly one `_bard/graph/{slug}.md`, and
//! what goes in it is entirely determined by what's already in the source
//! file's own frontmatter.
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
    \\`.`-prefixed folder is excluded), extracts each one, and writes
    \\_bard/graph/{slug}.md -- a verbatim copy of the source file's own
    \\frontmatter block, prose body dropped. Always a full re-ingest;
    \\stale nodes for entities no longer in source are removed.
    \\
;

pub fn run(gpa: Allocator, io: Io, args: *std.process.Args.Iterator) !u8 {
    if (args.next()) |extra| {
        std.debug.print("synapse-bard sync: unexpected argument '{s}'\n{s}", .{ extra, usage });
        return 2;
    }

    const id = core.identity.resolve(gpa, io, ".") catch {
        std.debug.print("synapse-bard: not inside a git repository\n", .{});
        return 1;
    };
    defer id.deinit(gpa);

    const graph_root = try std.fmt.allocPrint(gpa, "{s}/_bard/graph", .{id.layout.repo_root});
    defer gpa.free(graph_root);

    const candidates = try collectCandidates(gpa, io, id.layout.repo_root);
    defer {
        for (candidates) |c| gpa.free(c);
        gpa.free(candidates);
    }
    std.mem.sort([]const u8, candidates, {}, lessThan);

    var ex: adapters.bard_frontmatter.BardFrontmatterExtractor = .{};
    defer ex.deinit(gpa);
    const outcomes = try ex.port().extract(gpa, io, id.layout.repo_root, candidates);
    defer common.freeOutcomes(gpa, outcomes);

    var store: adapters.bard_graph_store.BardGraphStore = try .init(gpa, graph_root);
    defer store.deinit();
    const port = store.store();

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);

    var written: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (written.items) |n| gpa.free(n);
        written.deinit(gpa);
    }

    // Flat namespace, source files scattered across many folders -- two
    // different entities can share a filename stem (a place and a person
    // both landing on the same slug, say). `BardGraphStore.write` is a
    // plain overwrite with no existence check, so left undetected the
    // second one processed would silently clobber the first's data with no
    // warning at all. Tracks slug -> the *first* source path that claimed
    // it; every later candidate mapping to an already-claimed slug is
    // reported and skipped, never overwrites -- same "refuse rather than
    // silently mishandle" philosophy `BardFrontmatterExtractor` itself
    // already holds to.
    var claimed: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer claimed.deinit(gpa);

    var ingested: usize = 0;
    var skipped: usize = 0;
    var collisions: usize = 0;
    for (candidates, 0..) |candidate, i| {
        const slug = stemOf(candidate);
        switch (outcomes[i]) {
            .unsupported => {
                skipped += 1;
                try w.interface.print(
                    "skipped ({s}): {s}\n",
                    .{ @tagName(ex.last_refusals[i] orelse .not_a_note), candidate },
                );
            },
            .tags => {
                if (claimed.get(slug)) |first| {
                    collisions += 1;
                    try w.interface.print(
                        "COLLISION: {s} and {s} both resolve to slug '{s}' -- kept {s}, skipped {s}\n",
                        .{ first, candidate, slug, first, candidate },
                    );
                    continue;
                }

                const full = try std.fs.path.join(gpa, &.{ id.layout.repo_root, candidate });
                defer gpa.free(full);
                const src = try Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(1 << 20));
                defer gpa.free(src);

                const block = adapters.bard_frontmatter.frontmatterBlock(src) orelse {
                    // The extractor accepted it (real frontmatter, in the
                    // supported subset) so this can't actually happen; kept
                    // as a reportable skip rather than a crash if it ever does.
                    skipped += 1;
                    try w.interface.print("skipped (no frontmatter block found): {s}\n", .{candidate});
                    continue;
                };

                const node = try std.fmt.allocPrint(gpa, "{s}.md", .{slug});
                errdefer gpa.free(node);
                try port.write(io, node, block);
                try claimed.put(gpa, slug, candidate);
                try written.append(gpa, node);
                ingested += 1;
            },
        }
    }

    const removed = try reconcile(gpa, io, &store, written.items);

    try w.interface.print("\ningested: {d}\n", .{ingested});
    try w.interface.print("skipped (unsupported): {d}\n", .{skipped});
    try w.interface.print("collisions: {d}\n", .{collisions});
    try w.interface.print("removed (no longer in source): {d}\n", .{removed});
    try w.interface.flush();
    return 0;
}

/// Deletes every existing node not present in `written` (the slugs just
/// ingested this run) -- a renamed or deleted source entity must not leave
/// a stale node behind. Returns the count removed.
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

/// Every `.md` file under `root`, recursive, excluding any path with a
/// `_`- or `.`-prefixed folder as a component -- pruned *before*
/// descending, not filtered after, so this never walks into `.git/`
/// (thousands of loose objects) or `_bard/` at all. Returned paths are
/// repo-root-relative, matching what `BardFrontmatterExtractor.extract`
/// expects.
fn collectCandidates(gpa: Allocator, io: Io, root: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    try walk(gpa, io, dir, "", &out);
    return out.toOwnedSlice(gpa);
}

fn walk(gpa: Allocator, io: Io, dir: Io.Dir, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '_' or entry.name[0] == '.') continue;

        const rel = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fs.path.join(gpa, &.{ prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                    gpa.free(rel);
                    continue;
                };
                defer sub.close(io);
                try walk(gpa, io, sub, rel, out);
                gpa.free(rel);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try out.append(gpa, rel);
                } else {
                    gpa.free(rel);
                }
            },
            else => gpa.free(rel),
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
