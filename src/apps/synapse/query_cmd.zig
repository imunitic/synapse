//! `synapse query` -- `claude/lib/synapse/synapse-query.sh`'s eight subcommands.
//!
//!   body    <node>                     fenced prose only, no frontmatter
//!   sources <node> [--count|--modules|--filter <p>]
//!   field   <node> <key>               one top-level frontmatter scalar
//!   stale                              nodes whose files no longer match
//!   drift                              what changed since each node's commit
//!   grounding [<node> --list]          recorded evidence that no longer matches
//!   links    <node> [--inbound|--closure] / links --check
//!   symbol   <name> <node>             exact-name def/ref hits in the node's sources
//!
//! `callers` is not here -- it needs no graph, so it's its own top-level
//! subcommand (`synapse callers`, in `refs_cmd.zig`) rather than one of
//! these eight.
//!
//! `--namespace <repo>@<branch>`, given before the subcommand, names the
//! namespace directly instead of deriving it from the cwd's git identity --
//! how a query reaches another checkout's graph without being inside it.
//! `stale`/`drift`/`grounding`/`symbol` still need real source files on
//! disk, so `requireRepoRoot` refuses them outright under an explicit
//! namespace with no `SYNAPSE_REPO_ROOT` -- reading through an empty root
//! would otherwise misreport (every source "missing") rather than fail.
//!
//! stdout/exit codes/stderr are frozen to match the script exactly (73 tests
//! across `tests/synapse-query.bats` plus drift/links/grounding pin it).
//! Behind that surface: `_index.bin`/tags cache read directly through
//! `core.index_map`/`core.tags_cache`, the vault itself read directly from
//! disk (see `context.zig`), and formatting/set-diffing logic in
//! `core/query.zig`, `core/verify.zig`, `core/drift.zig`, `core/symbol.zig`.
//! `git` and `grep -E` still spawn -- both own a format/dialect worth not
//! reimplementing. `git hash-object`'s blob hash is computed in-process
//! instead (`core.verify.blobHash`), since it's a documented, stable
//! format.
//!
//! `stale`/`drift`/`grounding`/`links --check` print nothing when they find
//! nothing; exit 1 means "could not run", never "clean".

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");
const build_lists_cmd = @import("build_lists_cmd.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

const prog = "synapse-query";

pub fn run(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var sub = args.next() orelse return usage();
    var explicit_namespace: ?[]const u8 = null;
    if (std.mem.eql(u8, sub, "--namespace")) {
        explicit_namespace = args.next() orelse return usage();
        sub = args.next() orelse return usage();
    }
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        std.debug.print("{s}", .{usage_text});
        return 0;
    }
    // Validated before the environment: a typo'd subcommand shouldn't read as
    // a missing vault.
    const known = [_][]const u8{ "body", "sources", "field", "stale", "drift", "grounding", "links", "symbol" };
    var ok = false;
    for (known) |k| if (std.mem.eql(u8, sub, k)) {
        ok = true;
    };
    if (!ok) return usage();

    // Collected up front so subcommands can index rather than thread an iterator.
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rest.deinit(gpa);
    while (args.next()) |a| try rest.append(gpa, a);

    // `field --file` names its own file, not a vault node, so it's handled
    // before ctx.resolve -- for pre-push drafts (b-NN.md) with no title yet.
    if (std.mem.eql(u8, sub, "field") and rest.items.len != 0 and std.mem.eql(u8, rest.items[0], "--file")) {
        if (rest.items.len != 3 or rest.items[1].len == 0 or rest.items[2].len == 0) return usage();
        var out_buf: [256 * 1024]u8 = undefined;
        var out = Io.File.stdout().writer(io, &out_buf);
        const code = try cmdFieldFile(io, rest.items[1], rest.items[2], &out.interface);
        try out.interface.flush();
        return code;
    }

    var ctx = if (explicit_namespace) |ns|
        (try context.resolveExplicit(gpa, io, env, prog, ns)) orelse return 1
    else
        (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();
    if (!try context.verifyNamespace(&ctx, io, prog)) return 1;

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    const code = try dispatch(Extractor, gpa, io, env, &ctx, sub, rest.items, w);
    try w.flush();
    return code;
}

fn dispatch(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    sub: []const u8,
    rest: []const []const u8,
    w: *Io.Writer,
) !u8 {
    if (std.mem.eql(u8, sub, "body")) return cmdBody(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "sources")) return cmdSources(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "field")) return cmdField(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "stale")) return cmdStale(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "drift")) return cmdDrift(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "grounding")) return cmdGrounding(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "links")) return cmdLinks(gpa, io, ctx, rest, w);
    if (std.mem.eql(u8, sub, "symbol")) return cmdSymbol(Extractor, gpa, io, env, ctx, rest, w);
    unreachable;
}

const usage_text =
    \\usage: synapse query [--namespace <repo>@<branch>] <subcommand> [args]
    \\
    \\  --namespace <repo>@<branch>        address another checkout's graph, not the cwd's
    \\  body    <node>                     fenced prose only, no frontmatter
    \\  sources <node>                     every path the node covers
    \\  sources <node> --count             just the number
    \\  sources <node> --modules           module<TAB>count, byte sorted
    \\  sources <node> --filter <pattern>  matching paths only (substring)
    \\  field   <node> <key>               one top-level frontmatter scalar
    \\  field   --file <path> <key>        same, from a file directly -- no vault node needed
    \\  stale                              nodes whose files no longer match
    \\  drift                              what changed since each node's commit
    \\  grounding                          nodes whose evidence no longer matches
    \\  grounding <node> --list            that node's groundings, path<TAB>lines
    \\  links   <node>                     outbound relations, relation<TAB>target
    \\  links   <node> --inbound           what points here, relation<TAB>source
    \\  links   <node> --closure           reachable outbound, depth<TAB>node
    \\  links   --check                    link targets that resolve to no node
    \\  symbol  <name> <node>              exact-name hits, name<TAB>role<TAB>kind<TAB>path:line<TAB>expression
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

/// The node, or null. Exit 1 for unknown -- "no information", never "clean".
fn need(ctx: *const Context, io: Io, name: []const u8) !?[]u8 {
    return context.readNode(ctx, io, name);
}

// --- body -------------------------------------------------------------------

fn cmdBody(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len != 1 or rest[0].len == 0) return usage();
    const text = (try need(ctx, io, rest[0])) orelse return 1;
    defer gpa.free(text);

    if (core.query.body(text)) |inner| {
        if (inner.len != 0) {
            try w.writeAll(inner);
            try w.writeAll("\n");
        }
        return 0;
    }
    // Pre-fencing node: announced, since `## Notes` is included in what follows.
    std.debug.print(
        "{s}: no generated fence in '{s}'; printing everything after the frontmatter\n",
        .{ prog, rest[0] },
    );
    try w.writeAll(core.query.bodyAfterFrontmatter(text));
    return 0;
}

// --- sources ----------------------------------------------------------------

fn cmdSources(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len == 0 or rest[0].len == 0) return usage();
    const node_name = rest[0];
    const Mode = enum { all, count, modules, filter };
    var mode: Mode = .all;
    var pattern: []const u8 = "";
    if (rest.len > 1) {
        if (std.mem.eql(u8, rest[1], "--count")) {
            mode = .count;
            if (rest.len != 2) return usage();
        } else if (std.mem.eql(u8, rest[1], "--modules")) {
            mode = .modules;
            if (rest.len != 2) return usage();
        } else if (std.mem.eql(u8, rest[1], "--filter")) {
            mode = .filter;
            if (rest.len != 3 or rest[2].len == 0) return usage();
            pattern = rest[2];
        } else return usage();
    }

    const text = (try need(ctx, io, node_name)) orelse return 1;
    defer gpa.free(text);
    var paths = try core.query.sources(gpa, text);
    defer paths.deinit(gpa);

    switch (mode) {
        .all => for (paths.items) |p| try w.print("{s}\n", .{p}),
        .count => try w.print("{d}\n", .{paths.items.len}), // `wc -l`
        .filter => for (paths.items) |p| { // `grep -F`: substring, not regex
            if (std.mem.indexOf(u8, p, pattern) != null) try w.print("{s}\n", .{p});
        },
        .modules => {
            const counts = try core.query.moduleCounts(gpa, paths.items, ctx.chains);
            defer gpa.free(counts);
            for (counts) |m| try w.print("{s}\t{d}\n", .{ m.module, m.count });
        },
    }
    return 0;
}

// --- field ------------------------------------------------------------------

fn cmdField(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len != 2 or rest[0].len == 0 or rest[1].len == 0) return usage();
    const path = try context.nodePath(ctx, gpa, rest[0]);
    defer gpa.free(path);

    var file = Io.Dir.cwd().openFile(io, path, .{}) catch {
        std.debug.print("{s}: no such file: {s}\n", .{ prog, path });
        return 1;
    };
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return writeField(&file_reader.interface, rest[1], w);
}

/// `field --file`'s own body: same field logic against a plain file, for
/// callers with no node identity yet (a pre-push `b-NN.md` draft).
fn cmdFieldFile(io: Io, path: []const u8, key: []const u8, w: *Io.Writer) !u8 {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch {
        std.debug.print("{s}: no such file: {s}\n", .{ prog, path });
        return 1;
    };
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return writeField(&file_reader.interface, key, w);
}

/// Streams `reader` a line at a time (`core.query.fieldStreaming`) instead of
/// reading the whole node first -- a lookup on a code-graph node whose
/// `sources:` block runs to hundreds of lines no longer pays for reading any
/// of it when the key it wants sits earlier in the frontmatter.
fn writeField(reader: *Io.Reader, key: []const u8, w: *Io.Writer) !u8 {
    if (std.mem.eql(u8, key, "sources")) {
        std.debug.print(
            "{s}: 'sources' is a list, not a scalar field -- use: synapse query sources <node>\n",
            .{prog},
        );
        return 2;
    }
    // Absent key: prints nothing, exits 0 -- testable without parsing a message.
    if (try core.query.fieldStreaming(reader, key)) |v| try w.print("{s}\n", .{v});
    return 0;
}

// --- the node list, from the index ------------------------------------------

/// Nodes the index says exist, name-sorted. The index is authoritative for
/// which nodes exist; each node's own `sources` stays authoritative for what
/// it covers.
const NodeList = struct {
    map: core.index_map.Map,
    names: std.ArrayListUnmanaged([]const u8),

    fn open(gpa: Allocator, io: Io, ctx: *const Context) !?NodeList {
        const path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{ctx.work_dir});
        defer gpa.free(path);
        var map = core.index_map.Map.open(io, path) catch return null;
        if (map.discarded != null) {
            map.close(io);
            return null;
        }
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(gpa);
        var id: u32 = 0;
        while (id < map.nodeCount()) : (id += 1) try names.append(gpa, map.view.nodeName(id));
        return .{ .map = map, .names = names };
    }

    fn close(self: *NodeList, gpa: Allocator, io: Io) void {
        self.names.deinit(gpa);
        self.map.close(io);
    }
};

// --- stale ------------------------------------------------------------------

fn cmdStale(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len != 0) return usage();
    if (!requireRepoRoot(ctx, "stale")) return 1;
    var list = (try NodeList.open(gpa, io, ctx)) orelse return 1;
    defer list.close(gpa, io);

    for (list.names.items) |node_file| {
        const text = try context.readNode(ctx, io, node_file);
        defer if (text) |t| gpa.free(t);
        const name = context.stripMd(node_file);

        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(gpa);
        var missing: std.ArrayListUnmanaged([]const u8) = .empty;
        defer missing.deinit(gpa);
        var hashes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (hashes.items) |h| gpa.free(h);
            hashes.deinit(gpa);
        }

        var stored: ?[]const u8 = null;
        if (text) |t| {
            stored = core.query.field(t, "sources_digest");
            var found = try core.query.sources(gpa, t);
            defer found.deinit(gpa);
            try paths.appendSlice(gpa, found.items);
            for (paths.items) |p| {
                const content = try readRepoFile(gpa, io, ctx, p);
                if (content) |c| {
                    defer gpa.free(c);
                    try hashes.append(gpa, try gpa.dupe(u8, &core.verify.blobHash(c)));
                } else try missing.append(gpa, p);
            }
        }

        const state = try core.verify.staleness(
            gpa,
            text != null,
            stored,
            paths.items,
            missing.items,
            hashes.items,
        );
        if (state == .clean) continue;
        const reason = try state.reason(gpa);
        defer if (state == .sources_gone) gpa.free(reason);
        try w.print("{s}\t{s}\n", .{ name, reason });
    }
    return 0;
}

/// A repo-relative file's content, or null if not a regular file (deleted
/// path, or a submodule gitlink).
fn readRepoFile(gpa: Allocator, io: Io, ctx: *const Context, rel: []const u8) !?[]u8 {
    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.repo_root, rel });
    defer gpa.free(full);
    const st = Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind != .file) return null;
    return Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(256 << 20)) catch null;
}

/// `stale`/`drift`/`grounding`/`symbol` all read the target checkout's real
/// files, not just the vault -- an explicit `--namespace` with no
/// `SYNAPSE_REPO_ROOT` can't honor that, and reading through an empty root
/// would misreport rather than fail loudly (every source "missing", every
/// grounding "gone", `git` spawned with no cwd). Caught once, before any of
/// that runs, rather than surfacing as a confusing per-file error.
fn requireRepoRoot(ctx: *const Context, sub: []const u8) bool {
    if (!ctx.namespace_explicit or ctx.repo_root.len != 0) return true;
    std.debug.print(
        "{s}: '{s}' needs {s}'s real files on disk -- set SYNAPSE_REPO_ROOT to its working tree\n",
        .{ prog, sub, ctx.namespace },
    );
    return false;
}

// --- drift ------------------------------------------------------------------

/// One baseline commit and what's derived from it, keyed per distinct
/// commit -- nodes sharing a baseline share the (expensive) diff.
const Baseline = struct {
    commit: []const u8,
    diff: core.drift.Diff,
    divergent: bool,
    dirty: bool,

    fn added(self: Baseline) []const []const u8 {
        return self.diff.added;
    }
};

fn cmdDrift(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len != 0) return usage();
    if (!requireRepoRoot(ctx, "drift")) return 1;
    var list = (try NodeList.open(gpa, io, ctx)) orelse return 1;
    defer list.close(gpa, io);

    // Buffered, not printed live, so silence can mean "the graph matches".
    // Context is only worth printing next to a real finding.
    var repo_findings: Io.Writer.Allocating = .init(gpa);
    defer repo_findings.deinit();
    var node_findings: Io.Writer.Allocating = .init(gpa);
    defer node_findings.deinit();

    var baselines: std.ArrayListUnmanaged(Baseline) = .empty;
    defer {
        for (baselines.items) |b| freeOwnedDiff(gpa, b.diff);
        baselines.deinit(gpa);
    }
    // node index -> baseline index, for the second pass.
    var pairs: std.ArrayListUnmanaged(struct { node: []const u8, base: usize, paths: [][]const u8 }) = .empty;
    defer {
        for (pairs.items) |p| gpa.free(p.paths);
        pairs.deinit(gpa);
    }
    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }

    for (list.names.items) |node_file| {
        const name = context.stripMd(node_file);
        const text = try context.readNode(ctx, io, node_file) orelse {
            try (core.drift.Undiffable{ .node_file_missing = {} }).write(&node_findings.writer, name);
            continue;
        };
        try texts.append(gpa, text);

        const baseline = core.query.field(text, "commit") orelse "";
        if (baseline.len == 0) {
            try (core.drift.Undiffable{ .no_commit_recorded = {} }).write(&node_findings.writer, name);
            continue;
        }
        if (!try commitExists(gpa, io, ctx, baseline)) {
            try (core.drift.Undiffable{ .baseline_absent = baseline }).write(&node_findings.writer, name);
            continue;
        }

        const base_index = try baselineFor(gpa, io, ctx, &baselines, baseline, &repo_findings.writer);
        var found = try core.query.sources(gpa, text);
        defer found.deinit(gpa);
        const paths = try gpa.dupe([]const u8, found.items);
        std.mem.sort([]const u8, paths, {}, lessByBytes);
        try pairs.append(gpa, .{ .node = name, .base = base_index, .paths = paths });
    }

    for (pairs.items) |p| {
        const b = &baselines.items[p.base];
        const d = core.drift.nodeDrift(p.paths, b.diff);
        if (d.any()) b.dirty = true;
        try core.drift.writeNodeFindings(&node_findings.writer, p.node, d);
    }

    try reportAddedPaths(gpa, io, ctx, &list, baselines.items, &repo_findings.writer);

    if (repo_findings.written().len == 0 and node_findings.written().len == 0) return 0; // silence is the signal

    // Context, printed only now that there is a finding to attach it to.
    if (try upstreamName(gpa, io, ctx)) |upstream| {
        defer gpa.free(upstream);
        const behind = try revCount(gpa, io, ctx, try std.fmt.allocPrint(gpa, "HEAD..{s}", .{upstream}), true);
        if (behind > 0)
            // Never fetches, so this is the state as of the last fetch.
            try w.print("(repo)\t{d} commits behind {s}, as of the last fetch\n", .{ behind, upstream });
    }
    for (baselines.items) |b| {
        if (!b.dirty) continue;
        // Skipped when divergent -- the divergence line above already
        // reports both directions.
        if (b.divergent) continue;
        const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{b.commit});
        const n = try revCount(gpa, io, ctx, spec, true);
        if (n > 0) try w.print("(repo)\t{d} commits since baseline {s}\n", .{ n, core.drift.shortCommit(b.commit) });
    }
    try w.writeAll(repo_findings.written());
    try w.writeAll(node_findings.written());
    return 0;
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `git cat-file -e <commit>^{commit}`: is this baseline in local history?
/// A shallow clone answers no -- a finding, not an error, since `stale` can
/// still re-hash.
fn commitExists(gpa: Allocator, io: Io, ctx: *const Context, commit: []const u8) !bool {
    const spec = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{commit});
    defer gpa.free(spec);
    const res = try adapters.process.run(io, gpa, &.{ "git", "cat-file", "-e", spec }, .{
        .cwd = .{ .path = ctx.repo_root },
    });
    defer res.deinit(gpa);
    return res.ok();
}

fn baselineFor(
    gpa: Allocator,
    io: Io,
    ctx: *const Context,
    baselines: *std.ArrayListUnmanaged(Baseline),
    commit: []const u8,
    repo_findings: *Io.Writer,
) !usize {
    for (baselines.items, 0..) |b, i| if (std.mem.eql(u8, b.commit, commit)) return i;

    const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{commit});
    defer gpa.free(spec);
    const res = try adapters.process.run(io, gpa, &.{ "git", "diff", "--name-status", "-M", spec }, .{
        .cwd = .{ .path = ctx.repo_root },
    });
    defer res.deinit(gpa);
    // A failed diff counts as empty; divergence is reported separately below.
    const raw = if (res.ok()) res.stdout else "";
    const diff = try core.drift.parseNameStatus(gpa, raw);
    // `parseNameStatus` slices into `raw`, which `res.deinit` frees -- copy first.
    const owned = try ownDiff(gpa, diff);
    errdefer freeOwnedDiff(gpa, owned);
    diff.deinit(gpa);

    const divergent = !try isAncestor(gpa, io, ctx, commit);
    if (divergent) {
        // Its own finding: the graph was built off a line this checkout isn't on.
        const lr = try leftRight(gpa, io, ctx, commit);
        try repo_findings.print(
            "(repo)\tbaseline {s} is not an ancestor of HEAD: {d} commits only on the baseline, {d} only here -- the graph describes a different line\n",
            .{ core.drift.shortCommit(commit), lr[0], lr[1] },
        );
    }
    try baselines.append(gpa, .{
        .commit = commit,
        .diff = owned,
        .divergent = divergent,
        .dirty = false,
    });
    return baselines.items.len - 1;
}

/// A `Diff` owning its own path strings.
fn ownDiff(gpa: Allocator, d: core.drift.Diff) !core.drift.Diff {
    return .{
        .modified = try dupePaths(gpa, d.modified),
        .deleted = try dupePaths(gpa, d.deleted),
        .renamed_from = try dupePaths(gpa, d.renamed_from),
        .added = try dupePaths(gpa, d.added),
    };
}

fn dupePaths(gpa: Allocator, in: []const []const u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, in.len);
    for (in, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
    return out;
}

/// `Diff.deinit` only frees the four outer slices, correct for
/// `parseNameStatus`'s own result (each path borrowed from the diff output
/// buffer it slices into) but not for one `ownDiff` produced -- every path
/// in *that* one is its own allocation from `dupePaths`, and `Diff.deinit`
/// alone leaks all of them.
fn freeOwnedDiff(gpa: Allocator, d: core.drift.Diff) void {
    for (d.modified) |p| gpa.free(p);
    for (d.deleted) |p| gpa.free(p);
    for (d.renamed_from) |p| gpa.free(p);
    for (d.added) |p| gpa.free(p);
    d.deinit(gpa);
}

fn isAncestor(gpa: Allocator, io: Io, ctx: *const Context, commit: []const u8) !bool {
    const res = try adapters.process.run(io, gpa, &.{
        "git", "merge-base", "--is-ancestor", commit, "HEAD",
    }, .{ .cwd = .{ .path = ctx.repo_root } });
    defer res.deinit(gpa);
    return res.ok();
}

/// `git rev-list --left-right --count <base>...HEAD`, as `{left, right}`.
fn leftRight(gpa: Allocator, io: Io, ctx: *const Context, commit: []const u8) ![2]usize {
    const spec = try std.fmt.allocPrint(gpa, "{s}...HEAD", .{commit});
    defer gpa.free(spec);
    const res = try adapters.process.run(io, gpa, &.{
        "git", "rev-list", "--left-right", "--count", spec,
    }, .{ .cwd = .{ .path = ctx.repo_root } });
    defer res.deinit(gpa);
    if (!res.ok()) return .{ 0, 0 };
    var it = std.mem.tokenizeAny(u8, res.stdout, " \t\r\n");
    const l = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    const r = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    return .{ l, r };
}

fn revCount(gpa: Allocator, io: Io, ctx: *const Context, spec: []const u8, own_spec: bool) !usize {
    defer if (own_spec) gpa.free(spec);
    const res = try adapters.process.run(io, gpa, &.{ "git", "rev-list", "--count", spec }, .{
        .cwd = .{ .path = ctx.repo_root },
    });
    defer res.deinit(gpa);
    if (!res.ok()) return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
}

fn upstreamName(gpa: Allocator, io: Io, ctx: *const Context) !?[]u8 {
    const res = try adapters.process.run(io, gpa, &.{
        "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
    }, .{ .cwd = .{ .path = ctx.repo_root } });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const name = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (name.len == 0) return null;
    return try gpa.dupe(u8, name);
}

/// Added paths no node claims, split by whether a manifest pattern would
/// already cover them.
fn reportAddedPaths(
    gpa: Allocator,
    io: Io,
    ctx: *const Context,
    list: *const NodeList,
    baselines: []const Baseline,
    repo_findings: *Io.Writer,
) !void {
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    defer added.deinit(gpa);
    for (baselines) |b| try added.appendSlice(gpa, b.added());
    if (added.items.len == 0) return;
    std.mem.sort([]const u8, added.items, {}, lessByBytes);

    // `comm -23 added claimed`: table is byte-sorted, so `find` binary-searches.
    var unclaimed: Io.Writer.Allocating = .init(gpa);
    defer unclaimed.deinit();
    var count: usize = 0;
    var prev: []const u8 = "";
    for (added.items) |p| {
        if (std.mem.eql(u8, p, prev)) continue; // `sort -u`
        prev = p;
        if (list.map.view.find(p) != null) continue;
        try unclaimed.writer.print("{s}\n", .{p});
        count += 1;
    }
    if (count == 0) return;

    const manifest = try readManifest(gpa, io, ctx);
    defer if (manifest) |m| gpa.free(m);
    if (manifest == null) {
        try repo_findings.print(
            "(repo)\t{d} new paths claimed by no node, and no manifest to classify them against\n",
            .{count},
        );
        return;
    }

    // One grep -E per manifest row over the whole list, not per path per row.
    var matched: std.StringHashMapUnmanaged(void) = .empty;
    defer matched.deinit(gpa);
    // Keys slice into each grep result; those buffers must outlive the map,
    // so they're freed only after the loop, not per iteration.
    var hits: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h);
        hits.deinit(gpa);
    }
    var rows = std.mem.splitScalar(u8, manifest.?, '\n');
    while (rows.next()) |raw| {
        const row = build_lists_cmd.parseRow(raw) orelse continue;
        const hit = build_lists_cmd.selectPaths(gpa, io, unclaimed.written(), row.include, row.exclude) catch continue;
        try hits.append(gpa, hit);
        var lines = std.mem.splitScalar(u8, hit, '\n');
        while (lines.next()) |l| if (l.len != 0) try matched.put(gpa, l, {});
    }

    if (matched.count() > 0)
        try repo_findings.print(
            "(repo)\t{d} new paths already match a manifest pattern -- re-run `synapse build-lists` to claim them\n",
            .{matched.count()},
        );

    var needs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer needs.deinit(gpa);
    var lines = std.mem.splitScalar(u8, unclaimed.written(), '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        if (matched.contains(l)) continue;
        try needs.append(gpa, l);
    }
    if (needs.items.len == 0) return;

    try repo_findings.print("(repo)\t{d} new paths match no manifest pattern: ", .{needs.items.len});
    // `head -5 | tr '\n' ' '`: five names, space-joined.
    for (needs.items[0..@min(5, needs.items.len)]) |p| try repo_findings.print("{s} ", .{p});
    try repo_findings.writeAll("\n");
}

/// `_manifest.tsv` from the vault, or the work dir's copy, or null.
fn readManifest(gpa: Allocator, io: Io, ctx: *const Context) !?[]u8 {
    const in_vault = try std.fmt.allocPrint(gpa, "{s}/_manifest.tsv", .{ctx.abs_dir});
    defer gpa.free(in_vault);
    if (Io.Dir.cwd().readFileAlloc(io, in_vault, gpa, .limited(64 << 20))) |t| return t else |_| {}
    const in_work = try std.fmt.allocPrint(gpa, "{s}/manifest.tsv", .{ctx.work_dir});
    defer gpa.free(in_work);
    return Io.Dir.cwd().readFileAlloc(io, in_work, gpa, .limited(64 << 20)) catch null;
}

// --- grounding --------------------------------------------------------------

fn cmdGrounding(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len == 2 and std.mem.eql(u8, rest[1], "--list")) {
        // Node existence checked first, so a typo doesn't read as "no groundings".
        const text = (try need(ctx, io, rest[0])) orelse return 1;
        defer gpa.free(text);
        var gs = try core.verify.groundings(gpa, text);
        defer gs.deinit(gpa);
        for (gs.items) |g| try w.print("{s}\t{s}\n", .{ g.path, g.lines });
        return 0;
    }
    if (rest.len != 0) return usage();
    if (!requireRepoRoot(ctx, "grounding")) return 1;

    // Every node with a grounding -- walked from disk, same reads `stale`/`links`
    // already use, no HTTP.
    var files = try context.listNodeFiles(ctx, io);
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    for (files.items) |file| {
        const text = try context.readNode(ctx, io, file) orelse continue;
        defer gpa.free(text);
        const name = context.stripMd(file);
        var gs = try core.verify.groundings(gpa, text);
        defer gs.deinit(gpa);

        for (gs.items) |g| {
            const content = try readRepoFile(gpa, io, ctx, g.path);
            if (content == null) {
                try w.print("{s}\tgrounding file gone: {s}\n", .{ name, g.path });
                continue;
            }
            defer gpa.free(content.?);
            const range = g.range() orelse continue;
            if (core.verify.slice(content.?, range.start, range.end)) |cut| {
                if (std.mem.eql(u8, &core.verify.sha256Hex(cut), g.digest)) continue;
            }
            // A pure line shift (insertion above the range) is re-pointed,
            // not flagged broken.
            const span = range.end - range.start + 1;
            if (core.verify.findMoved(content.?, span, g.digest)) |to| {
                try w.print(
                    "{s}\tgrounding moved: {s} {s} -> {d}-{d} (re-point, no reading needed)\n",
                    .{ name, g.path, g.lines, to.start, to.end },
                );
            } else {
                try w.print(
                    "{s}\tgrounding changed: {s} {s} (re-check the claim resting on it)\n",
                    .{ name, g.path, g.lines },
                );
            }
        }
    }
    return 0;
}

// --- links ------------------------------------------------------------------

fn cmdLinks(gpa: Allocator, io: Io, ctx: *const Context, rest: []const []const u8, w: *Io.Writer) !u8 {
    if (rest.len == 0) return usage();
    if (std.mem.eql(u8, rest[0], "--check")) {
        if (rest.len != 1) return usage();
        return linksCheck(gpa, io, ctx, w);
    }
    if (rest[0][0] == '-') return usage();

    const node_name = context.stripMd(rest[0]);
    const text = (try need(ctx, io, rest[0])) orelse return 1;
    defer gpa.free(text);

    if (rest.len == 1) {
        // One read: deriving the whole graph to filter one node is 48 reads to answer 1.
        var es = try core.query.edges(gpa, text);
        defer es.deinit(gpa);
        var rows = try gpa.alloc([2][]const u8, es.items.len);
        defer gpa.free(rows);
        for (es.items, 0..) |e, i| rows[i] = .{ e.relation, e.target };
        sortRows(rows);
        for (rows) |r| try w.print("{s}\t{s}\n", .{ r[0], r[1] });
        return 0;
    }
    if (rest.len != 2) return usage();

    if (std.mem.eql(u8, rest[1], "--inbound")) return linksInbound(gpa, io, ctx, node_name, w);
    if (std.mem.eql(u8, rest[1], "--closure")) return linksClosure(gpa, io, ctx, node_name, w);
    return usage();
}

fn sortRows(rows: [][2][]const u8) void {
    std.mem.sort([2][]const u8, rows, {}, struct {
        fn less(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return switch (std.mem.order(u8, a[0], b[0])) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a[1], b[1]) == .lt,
            };
        }
    }.less);
}

/// `source<TAB>relation<TAB>target` for every link in the namespace.
const Graph = struct {
    texts: std.ArrayListUnmanaged([]u8),
    names: std.ArrayListUnmanaged([]const u8),
    edges: std.ArrayListUnmanaged(struct { src: []const u8, rel: []const u8, tgt: []const u8 }),

    fn build(gpa: Allocator, io: Io, ctx: *const Context) !Graph {
        var g: Graph = .{ .texts = .empty, .names = .empty, .edges = .empty };
        var files = try context.listNodeFiles(ctx, io);
        defer {
            for (files.items) |f| gpa.free(f);
            files.deinit(gpa);
        }
        for (files.items) |file| {
            const text = try context.readNode(ctx, io, file) orelse continue;
            try g.texts.append(gpa, text);
            // Filename minus `.md` -- what a wikilink resolves against.
            const name = try gpa.dupe(u8, context.stripMd(file));
            try g.names.append(gpa, name);
            var es = try core.query.edges(gpa, text);
            defer es.deinit(gpa);
            for (es.items) |e|
                try g.edges.append(gpa, .{ .src = name, .rel = e.relation, .tgt = e.target });
        }
        return g;
    }

    fn deinit(self: *Graph, gpa: Allocator) void {
        for (self.texts.items) |t| gpa.free(t);
        self.texts.deinit(gpa);
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
        self.edges.deinit(gpa);
    }

    fn has(self: *const Graph, name: []const u8) bool {
        for (self.names.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

fn linksCheck(gpa: Allocator, io: Io, ctx: *const Context, w: *Io.Writer) !u8 {
    var g = try Graph.build(gpa, io, ctx);
    defer g.deinit(gpa);
    // A broken wikilink renders as plain text; nothing else notices.
    for (g.edges.items) |e| {
        if (g.has(e.tgt)) continue;
        try w.print("{s}\t{s} -> {s} (no such node)\n", .{ e.src, e.rel, e.tgt });
    }
    return 0;
}

fn linksInbound(gpa: Allocator, io: Io, ctx: *const Context, node: []const u8, w: *Io.Writer) !u8 {
    var g = try Graph.build(gpa, io, ctx);
    defer g.deinit(gpa);
    var rows: std.ArrayListUnmanaged([2][]const u8) = .empty;
    defer rows.deinit(gpa);
    for (g.edges.items) |e| {
        if (!std.mem.eql(u8, e.tgt, node)) continue;
        try rows.append(gpa, .{ e.rel, e.src });
    }
    sortRows(rows.items);
    for (rows.items) |r| try w.print("{s}\t{s}\n", .{ r[0], r[1] });
    return 0;
}

/// BFS, so depth is the shortest hop count and a cycle terminates.
fn linksClosure(gpa: Allocator, io: Io, ctx: *const Context, start: []const u8, w: *Io.Writer) !u8 {
    var g = try Graph.build(gpa, io, ctx);
    defer g.deinit(gpa);

    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(gpa);
    try seen.put(gpa, start, 0);
    var queue: std.ArrayListUnmanaged([]const u8) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, start);

    var rows: std.ArrayListUnmanaged(struct { depth: usize, node: []const u8 }) = .empty;
    defer rows.deinit(gpa);

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const cur = queue.items[i];
        const depth = seen.get(cur).?;
        for (g.edges.items) |e| {
            if (!std.mem.eql(u8, e.src, cur)) continue;
            if (e.tgt.len == 0 or seen.contains(e.tgt)) continue;
            try seen.put(gpa, e.tgt, depth + 1);
            try queue.append(gpa, e.tgt);
            try rows.append(gpa, .{ .depth = depth + 1, .node = e.tgt });
        }
    }

    // `sort -k1,1n -k2,2`: depth numerically, then node name.
    std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
        fn less(_: void, a: @TypeOf(rows.items[0]), b: @TypeOf(rows.items[0])) bool {
            if (a.depth != b.depth) return a.depth < b.depth;
            return std.mem.order(u8, a.node, b.node) == .lt;
        }
    }.less);
    for (rows.items) |r| try w.print("{d}\t{s}\n", .{ r.depth, r.node });
    return 0;
}

// --- symbol -----------------------------------------------------------------

fn cmdSymbol(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    rest: []const []const u8,
    w: *Io.Writer,
) !u8 {
    // Disabled: no cache I/O, no tagging -- matches the prompt-injection hook's own knob.
    if (env.get("SYNAPSE_DISABLE_SYMBOL_CACHE") != null) return 0;
    if (rest.len != 2 or rest[0].len == 0 or rest[1].len == 0) return usage();
    if (!requireRepoRoot(ctx, "symbol")) return 1;
    const name = rest[0];

    const text = (try need(ctx, io, rest[1])) orelse return 1;
    defer gpa.free(text);
    var paths = try core.query.sources(gpa, text);
    defer paths.deinit(gpa);
    if (paths.items.len == 0) return 0;

    // Hash every source, then backfill the cache -- reuses hashes this pass
    // needs anyway.
    var pairs = try gpa.alloc(core.tags_cache.PathHash, paths.items.len);
    defer gpa.free(pairs);
    var n: usize = 0;
    for (paths.items) |p| {
        const content = try readRepoFile(gpa, io, ctx, p);
        if (content == null) {
            std.debug.print("{s}: could not hash '{s}' sources\n", .{ prog, rest[1] });
            return 1;
        }
        defer gpa.free(content.?);
        pairs[n] = .{ .path = p, .hash = core.verify.blobHashRaw(content.?) };
        n += 1;
    }

    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{ctx.work_dir});
    defer gpa.free(cache_path);
    var cache = core.tags_cache.Cache.open(io, cache_path) catch {
        std.debug.print("{s}: no tags cache for this project yet -- nothing checked\n", .{prog});
        return 0;
    };
    defer cache.close(io);
    if (cache.discarded != null) {
        std.debug.print("{s}: unreadable tags cache: {s}\n", .{ prog, cache_path });
        return 0;
    }
    // Non-fatal: still worth answering from whatever's already cached.
    tags_cache_cmd.backfill(Extractor, gpa, io, env, ctx.repo_root, &cache, pairs[0..n], null) catch
        std.debug.print(
            "{s}: symbol cache backfill failed for '{s}' -- continuing with what's already cached\n",
            .{ prog, rest[1] },
        );

    for (paths.items) |p| {
        switch (core.symbol.outcomeFor(cache.get(p))) {
            .not_cached => std.debug.print("{s}: {s} not checked (no cache entry)\n", .{ prog, p }),
            .unsupported => std.debug.print(
                "{s}: {s} not checked (unsupported: no grammar, tree-sitter, or C compiler)\n",
                .{ prog, p },
            ),
            .checked => |tags| {
                var it = core.symbol.matches(tags, name);
                while (it.next()) |tag| try core.tag_line.writeRefsRow(w, p, tag);
            },
        }
    }
    return 0;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");

/// "let lineNN = N\n" for N in `from..=to`.
fn calcMl(gpa: Allocator, from: u32, to: u32) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var n = from;
    while (n <= to) : (n += 1) try out.writer.print("let line{d:0>2} = {d}\n", .{ n, n });
    return gpa.dupe(u8, out.written());
}

/// A node grounded in a two-line doc comment at the top of `lib/calc.ml`,
/// matching the bats fixture's own `build_grounded_node` -- built directly
/// as a node file and a repo file, not through `write-node`, since
/// `cmdGrounding` only cares what's on disk, not how it got there.
fn buildGroundedNode(gpa: Allocator, fx: *fixture.Fixture) !void {
    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 12);
    defer gpa.free(body_lines);
    const calc = try std.fmt.allocPrint(gpa, "{s}{s}", .{ header, body_lines });
    defer gpa.free(calc);
    try fx.writeRepoFile("lib/calc.ml", calc);
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");

    const digest = core.verify.sha256Hex(header);
    const node = try std.fmt.allocPrint(gpa,
        \\---
        \\title: "Premium"
        \\summary: "Premium calc."
        \\sources:
        \\  - path: lib/calc.ml
        \\    hash: 1111111111111111111111111111111111111111
        \\grounded_in:
        \\  - path: lib/calc.ml
        \\    lines: "1-2"
        \\    digest: {s}
        \\stale: false
        \\built_at: "test"
        \\---
        \\
        \\# Premium
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Rounds half-up at two decimals.
        \\<!-- synapse:generated:end -->
        \\
    , .{&digest});
    defer gpa.free(node);
    try fx.writeNodeFile("Premium", node);
}

fn runGrounding(gpa: Allocator, fx: *fixture.Fixture, rest: []const []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdGrounding(gpa, fx.io(), &ctx, rest, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "grounding: silence when every recorded grounding still matches" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    // Positive control first: the grounding is actually visible.
    const list = try runGrounding(gpa, &fx, &.{ "Premium", "--list" });
    defer gpa.free(list.out);
    try testing.expect(list.out.len != 0);

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "grounding: an unrelated edit elsewhere in the file stays silent" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 12);
    defer gpa.free(body_lines);
    const appended = try std.fmt.allocPrint(gpa, "{s}{s}let tail = 99\n", .{ header, body_lines });
    defer gpa.free(appended);
    try fx.writeRepoFile("lib/calc.ml", appended);

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "grounding: a pure line shift is reported as moved, with the new range" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const header = "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 12);
    defer gpa.free(body_lines);
    const shifted = try std.fmt.allocPrint(gpa, "(* new header *)\n(* second line *)\n{s}{s}", .{ header, body_lines });
    defer gpa.free(shifted);
    try fx.writeRepoFile("lib/calc.ml", shifted);

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "grounding moved") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "1-2 -> 3-4") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "grounding changed") == null);
}

test "grounding: an edit to the grounded text itself is reported as changed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const header = "(* Computes the premium for a contract.\n   Truncates toward zero at two decimals. *)\n";
    const body_lines = try calcMl(gpa, 3, 12);
    defer gpa.free(body_lines);
    const edited = try std.fmt.allocPrint(gpa, "{s}{s}", .{ header, body_lines });
    defer gpa.free(edited);
    try fx.writeRepoFile("lib/calc.ml", edited);

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "grounding changed") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "lib/calc.ml 1-2") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "re-check the claim") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "grounding moved") == null);
}

test "grounding: a deleted grounding file is named" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);
    // Delete by overwriting the repo dir entry: writeRepoFile only adds, so
    // remove the tmp-dir file directly.
    try fx.tmp.dir.deleteFile(testing.io, "repo/lib/calc.ml");

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "grounding file gone: lib/calc.ml") != null);
}

test "grounding: a node with no grounded_in is silently skipped" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeNodeFile("Plain",
        \\---
        \\title: "Plain"
        \\summary: "S."
        \\sources:
        \\  - path: src/foo.ml
        \\    hash: 1111111111111111111111111111111111111111
        \\stale: false
        \\built_at: "test"
        \\---
        \\# Plain
        \\
    );

    const r = try runGrounding(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "grounding: takes no arguments" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const r = try runGrounding(gpa, &fx, &.{"extra"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 2), r.code);
}

test "grounding --list: prints the recorded pointers, so a rebuild can re-emit them" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const r = try runGrounding(gpa, &fx, &.{ "Premium", "--list" });
    defer gpa.free(r.out);
    try testing.expectEqualStrings("lib/calc.ml\t1-2\n", r.out);
}

test "grounding --list: the digest is not printed, only what a directive needs" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const r = try runGrounding(gpa, &fx, &.{ "Premium.md", "--list" });
    defer gpa.free(r.out);
    // a directive needs path and lines; the digest is the writer's to
    // recompute.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "\t"));
}

test "grounding --list: a node without groundings prints nothing, exit 0" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeNodeFile("Bare",
        \\---
        \\title: "Bare"
        \\summary: "S."
        \\sources:
        \\  - path: src/foo.ml
        \\    hash: 1111111111111111111111111111111111111111
        \\stale: false
        \\built_at: "test"
        \\---
        \\# Bare
        \\
    );

    const r = try runGrounding(gpa, &fx, &.{ "Bare", "--list" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "grounding --list: an unknown node exits 1" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try buildGroundedNode(gpa, &fx);

    const r = try runGrounding(gpa, &fx, &.{ "Nope", "--list" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

// --- links --------------------------------------------------------------

/// A node carrying only a Links section -- enough for `cmdLinks`, matching
/// the bats fixture's own `node()` helper.
fn linksNode(gpa: Allocator, fx: *fixture.Fixture, title: []const u8, links: []const []const u8) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print(
        "---\ntitle: \"{s}\"\nsummary: \"S.\"\n---\n\n# {s}\n" ++
            "<!-- synapse:generated:start -->\n\n## Summary\nProse.\n\n## Links\n",
        .{ title, title },
    );
    for (links) |l| try out.writer.print("- {s}\n", .{l});
    try out.writer.writeAll("\n## Sources\n- `src` (1)\n<!-- synapse:generated:end -->\n\n## Notes\n");
    try fx.writeNodeFile(title, out.written());
}

fn runLinks(gpa: Allocator, fx: *fixture.Fixture, rest: []const []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdLinks(gpa, fx.io(), &ctx, rest, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "links: outbound relations come back with their type" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{ "depends_on [[Beta]]", "uses [[Gamma]]" });
    try linksNode(gpa, &fx, "Beta", &.{});
    try linksNode(gpa, &fx, "Gamma", &.{});

    const r = try runLinks(gpa, &fx, &.{"Alpha"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.out, "\n"));
    try testing.expect(std.mem.indexOf(u8, r.out, "depends_on\tBeta") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "uses\tGamma") != null);
}

test "links: --inbound distinguishes relations, which the link graph cannot" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{"depends_on [[Target]]"});
    try linksNode(gpa, &fx, "Beta", &.{"uses [[Target]]"});
    try linksNode(gpa, &fx, "Gamma", &.{"depends_on [[Target]]"});
    try linksNode(gpa, &fx, "Target", &.{});

    const r = try runLinks(gpa, &fx, &.{ "Target", "--inbound" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "depends_on\tAlpha") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "depends_on\tGamma") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "uses\tBeta") != null);
    // the whole point: Beta must not appear as a depends_on
    try testing.expect(std.mem.indexOf(u8, r.out, "depends_on\tBeta") == null);
}

test "links: --closure reports every reachable node with its shortest depth" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "A", &.{"uses [[B]]"});
    try linksNode(gpa, &fx, "B", &.{"uses [[C]]"});
    try linksNode(gpa, &fx, "C", &.{"uses [[D]]"});
    try linksNode(gpa, &fx, "D", &.{});

    const r = try runLinks(gpa, &fx, &.{ "A", "--closure" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "1\tB") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "2\tC") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "3\tD") != null);
    // the start node is not its own descendant
    try testing.expect(std.mem.indexOf(u8, r.out, "\tA") == null);
}

test "links: --closure prefers the shorter path when two exist" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "A", &.{ "uses [[B]]", "uses [[C]]" });
    try linksNode(gpa, &fx, "B", &.{"uses [[D]]"});
    try linksNode(gpa, &fx, "C", &.{});
    try linksNode(gpa, &fx, "D", &.{});

    const r = try runLinks(gpa, &fx, &.{ "A", "--closure" });
    defer gpa.free(r.out);
    // D is reachable at depth 2 via B; breadth-first must not report it deeper
    try testing.expect(std.mem.indexOf(u8, r.out, "2\tD") != null);
}

test "links: --closure terminates on a cycle instead of looping" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "A", &.{"uses [[B]]"});
    try linksNode(gpa, &fx, "B", &.{"uses [[C]]"});
    try linksNode(gpa, &fx, "C", &.{"uses [[A]]"});

    const r = try runLinks(gpa, &fx, &.{ "A", "--closure" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "1\tB") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "2\tC") != null);
    // A is reachable from itself through the cycle, but is already seen, so
    // the walk stops rather than revisiting it.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.out, "\n"));
}

test "links: --check names a target that resolves to no node" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{ "depends_on [[Beta]]", "uses [[Ghost]]" });
    try linksNode(gpa, &fx, "Beta", &.{});

    const r = try runLinks(gpa, &fx, &.{"--check"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "Alpha\tuses -> Ghost (no such node)") != null);
    // a broken wikilink is a valid link to a not-yet-existing note, rendered
    // silently by any vault viewer -- this is the only thing that reports it
    try testing.expect(std.mem.indexOf(u8, r.out, "Beta") == null);
}

test "links: --check is silent when every target resolves" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{"depends_on [[Beta]]"});
    try linksNode(gpa, &fx, "Beta", &.{"part_of [[Alpha]]"});

    const r = try runLinks(gpa, &fx, &.{"--check"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "links: a node with no Links section returns nothing, exit 0" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Lonely", &.{});

    const r = try runLinks(gpa, &fx, &.{"Lonely"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "links: an unknown node exits 1 rather than reporting no relations" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{"uses [[Beta]]"});
    try linksNode(gpa, &fx, "Beta", &.{});

    const r = try runLinks(gpa, &fx, &.{"Nope"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "links: usage errors exit 2" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try linksNode(gpa, &fx, "Alpha", &.{});

    const no_args = try runLinks(gpa, &fx, &.{});
    defer gpa.free(no_args.out);
    try testing.expectEqual(@as(u8, 2), no_args.code);

    const bad_flag = try runLinks(gpa, &fx, &.{ "Alpha", "--bogus" });
    defer gpa.free(bad_flag.out);
    try testing.expectEqual(@as(u8, 2), bad_flag.code);

    const extra = try runLinks(gpa, &fx, &.{ "--check", "extra" });
    defer gpa.free(extra.out);
    try testing.expectEqual(@as(u8, 2), extra.code);
}

// --- stale ----------------------------------------------------------------

/// A node covering `sources` (each a real repo file already written), with
/// a digest correct by construction unless `force_digest` overrides it --
/// matching the bats fixture's own `write_node` helper.
fn staleNode(gpa: Allocator, sources: []const struct { path: []const u8, content: []const u8 }, force_digest: ?[]const u8) ![]u8 {
    var node_sources = try gpa.alloc(core.node.Source, sources.len);
    defer {
        for (node_sources) |s| gpa.free(s.hash);
        gpa.free(node_sources);
    }
    for (sources, 0..) |s, i|
        node_sources[i] = .{ .path = s.path, .hash = try gpa.dupe(u8, &core.verify.blobHash(s.content)) };
    const real_digest = try core.node.sourcesDigest(gpa, node_sources);
    const digest = force_digest orelse &real_digest;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("---\ntitle: \"Foo Node\"\nnode_type: synapse-node\nsources:\n");
    for (node_sources) |s| try out.writer.print("  - path: {s}\n    hash: {s}\n", .{ s.path, s.hash });
    try out.writer.print("sources_digest: \"{s}\"\nstale: false\nbuilt_at: \"test\"\n---\n\n# Foo Node\n", .{digest});
    return gpa.dupe(u8, out.written());
}

fn runStale(gpa: Allocator, fx: *fixture.Fixture) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdStale(gpa, fx.io(), &ctx, &.{}, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "stale: node whose files are unchanged: reports nothing, exit 0" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try staleNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }}, null);
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "stale: source file changed outside Claude Code: reports the node" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try staleNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }}, null);
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    // The case Tier 1 cannot see: an edit that never went through a hook.
    try fx.writeRepoFile("src/foo.ml", "let x = 2 (* changed *)\n");

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "Foo Node") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "content changed") != null);
}

test "stale: recorded source file deleted: reports it by name" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try staleNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }}, null);
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    try fx.tmp.dir.deleteFile(testing.io, "repo/src/foo.ml");

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "source files gone: src/foo.ml") != null);
}

test "stale: multi-file node: order in sources does not affect the digest" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("src/bar.ml", "let y = 1\n");
    // written in reverse order; the digest sorts, so it must still verify
    const node = try staleNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "src/bar.ml", .content = "let y = 1\n" },
    }, null);
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.writeIndexBin(&.{
        .{ .path = "src/foo.ml", .node = "Foo Node.md" },
        .{ .path = "src/bar.ml", .node = "Foo Node.md" },
    });

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "stale: node with a wrong stored digest: reported as changed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try staleNode(
        gpa,
        &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }},
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "content changed") != null);
}

test "stale: node built before sources_digest existed: reported, not silently passed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try staleNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }}, null);
    defer gpa.free(node);
    // Strip the digest line, simulating a namespace built under the old format.
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, node, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "sources_digest:")) continue;
        try lines.appendSlice(gpa, line);
        try lines.append(gpa, '\n');
    }
    try fx.writeNodeFile("Foo Node", lines.items);
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Foo Node.md" }});

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "no sources_digest") != null);
}

test "stale: node in the index but missing from the vault: reported" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeIndexBin(&.{.{ .path = "src/foo.ml", .node = "Ghost Node.md" }});

    const r = try runStale(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "node file missing") != null);
}

// --- body / sources / field ------------------------------------------------
// The point of these subcommands is that they read the expensive parts
// internally and print only a projection, so the assertions are mostly
// about what is *absent* from the output.

/// A node with a generated fence, real hashes, and Notes content that must
/// never leak into `body` -- matching the bats fixture's own
/// `write_fenced_node` helper.
fn fencedNode(gpa: Allocator, sources: []const struct { path: []const u8, content: []const u8 }) ![]u8 {
    var node_sources = try gpa.alloc(core.node.Source, sources.len);
    defer {
        for (node_sources) |s| gpa.free(s.hash);
        gpa.free(node_sources);
    }
    for (sources, 0..) |s, i|
        node_sources[i] = .{ .path = s.path, .hash = try gpa.dupe(u8, &core.verify.blobHash(s.content)) };
    const digest = try core.node.sourcesDigest(gpa, node_sources);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("---\ntitle: \"Foo Node\"\nnode_type: synapse-node\nsources:\n");
    for (node_sources) |s| try out.writer.print("  - path: {s}\n    hash: {s}\n", .{ s.path, s.hash });
    try out.writer.print(
        "sources_digest: \"{s}\"\nstale: false\nbuilt_at: \"2026-08-03 16:15\"\n---\n\n" ++
            "# Foo Node\n<!-- synapse:generated:start -->\n\n## Summary\nProse that should be printed.\n\n" ++
            "## Sources\n- `src` ({d})\n<!-- synapse:generated:end -->\n\n## Notes\n" ++
            "HUMAN NOTES must never appear in body output.",
        .{ digest, sources.len },
    );
    return gpa.dupe(u8, out.written());
}

fn runBody(gpa: Allocator, fx: *fixture.Fixture, node: []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdBody(gpa, fx.io(), &ctx, &.{node}, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "body: prints the fenced prose only, excluding frontmatter and Notes" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runBody(gpa, &fx, "Foo Node");
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "Prose that should be printed.") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "path:") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "HUMAN NOTES") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "sources_digest") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "synapse:generated") == null);
}

test "body: accepts the node name with or without .md" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runBody(gpa, &fx, "Foo Node.md");
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "Prose that should be printed.") != null);
}

test "resolveExplicit: verifyNamespace skips the remote check, unlike an implicit resolve" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    // A remote that disagrees with the fixture's own ("" via SYNAPSE_REMOTE) --
    // an implicit resolve would reject this; an explicit one has no cwd
    // remote to compare against, so it must not.
    try fx.writeIndex("ssh://git@example.com/SOMEONE-ELSE.git", "main");

    var ctx = (try context.resolveExplicit(gpa, fx.io(), &fx.env, "test", "repo@main")).?;
    defer ctx.deinit();
    try testing.expect(ctx.namespace_explicit);
    try testing.expect(try context.verifyNamespace(&ctx, fx.io(), "test"));

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdBody(gpa, fx.io(), &ctx, &.{"Foo Node"}, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Prose that should be printed.") != null);
}

test "resolveExplicit: a namespace with no @ is a usage error, not a silent misread" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    const ctx = try context.resolveExplicit(gpa, fx.io(), &fx.env, "test", "bogus");
    try testing.expect(ctx == null);
}

test "requireRepoRoot: stale/drift/grounding/symbol refuse under --namespace with no SYNAPSE_REPO_ROOT" {
    // Without this, each would misreport instead of failing: `stale` calls
    // every source "missing", `grounding` calls every grounding "gone",
    // `drift` spawns `git` with an empty cwd, `symbol` prints a per-file
    // hash error that never says why.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_REPO_ROOT");
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");

    var ctx = (try context.resolveExplicit(gpa, fx.io(), &fx.env, "test", "repo@main")).?;
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 0), ctx.repo_root.len);

    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try cmdStale(gpa, fx.io(), &ctx, &.{}, &out.writer);
        try testing.expectEqual(@as(u8, 1), code);
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try cmdDrift(gpa, fx.io(), &ctx, &.{}, &out.writer);
        try testing.expectEqual(@as(u8, 1), code);
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try cmdGrounding(gpa, fx.io(), &ctx, &.{}, &out.writer);
        try testing.expectEqual(@as(u8, 1), code);
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
    {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const code = try cmdSymbol(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, &.{ "X", "Foo Node" }, &out.writer);
        try testing.expectEqual(@as(u8, 1), code);
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
}

test "body: unfenced node falls back to post-frontmatter and warns on stderr" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    // Written without a fence.
    const node = try staleNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }}, null);
    defer gpa.free(node);
    try fx.writeNodeFile("Old Node", node);

    const r = try runBody(gpa, &fx, "Old Node");
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "path:") == null);
}

test "body: unknown node exits 1" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    const r = try runBody(gpa, &fx, "Nope");
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

fn runSources(gpa: Allocator, fx: *fixture.Fixture, rest: []const []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdSources(gpa, fx.io(), &ctx, rest, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "sources: --count matches the real number of paths" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("src/bar.ml", "let y = 1\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "src/bar.ml", .content = "let y = 1\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSources(gpa, &fx, &.{ "Foo Node", "--count" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("2\n", r.out);
}

test "sources: bare form lists every path, --filter narrows it" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("src/bar.ml", "let y = 1\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "src/bar.ml", .content = "let y = 1\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const all = try runSources(gpa, &fx, &.{"Foo Node"});
    defer gpa.free(all.out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, all.out, "\n"));

    const filtered = try runSources(gpa, &fx, &.{ "Foo Node", "--filter", "bar" });
    defer gpa.free(filtered.out);
    try testing.expectEqualStrings("src/bar.ml\n", filtered.out);
}

test "sources: --modules groups by module root with counts" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("other/src/main/java/A.java", "x\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "other/src/main/java/A.java", .content = "x\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    // "src/main/java" is Maven boilerplate per the shipped default
    // `synapse-module-boilerplate.conf` -- a real bats run gets it from
    // $HOME, so the fixture needs its own copy of that one line.
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "boilerplate.conf", .data = "src/main/java\n" });
    var conf_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = conf_buf[0..try fx.tmp.dir.realPath(testing.io, &conf_buf)];
    const conf_path = try std.fmt.allocPrint(gpa, "{s}/boilerplate.conf", .{root});
    defer gpa.free(conf_path);
    try fx.env.put("SYNAPSE_MODULE_BOILERPLATE_CONF", conf_path);

    const r = try runSources(gpa, &fx, &.{ "Foo Node", "--modules" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    // `other/src/main/java/A.java` is Maven boilerplate and groups as
    // `other`; `src/foo.ml` has src first so it is the repo root's own src.
    try testing.expect(std.mem.indexOf(u8, r.out, "other\t1") != null);
}

test "sources: --modules keeps one segment past src/ for a non-boilerplate layout" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("widget_engine/src/render/render_commands.ml", "x\n");
    try fx.writeRepoFile("widget_engine/src/audio/audio_system.ml", "x\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "widget_engine/src/render/render_commands.ml", .content = "x\n" },
        .{ .path = "widget_engine/src/audio/audio_system.ml", .content = "x\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSources(gpa, &fx, &.{ "Foo Node", "--modules" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    // Neither path is Maven boilerplate, so each keeps the segment right
    // after src/ instead of collapsing both into one "widget_engine".
    try testing.expect(std.mem.indexOf(u8, r.out, "widget_engine/src/render\t1") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "widget_engine/src/audio\t1") != null);
}

test "sources: --modules boilerplate chains are read from config, not hardcoded" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("mod-a/src/main/kotlin/A.kt", "x\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "mod-a/src/main/kotlin/A.kt", .content = "x\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    // Not in the shipped default list yet: falls through to the generic
    // rule, keeping one segment past src/ rather than collapsing to "mod-a".
    const before = try runSources(gpa, &fx, &.{ "Foo Node", "--modules" });
    defer gpa.free(before.out);
    try testing.expect(std.mem.indexOf(u8, before.out, "mod-a/src/main\t1") != null);

    // Point --modules at a real boilerplate conf, same as a user would add
    // to by hand -- now it collapses, proving the chain list is genuinely
    // read from disk each run.
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "boilerplate.conf",
        .data = "src/main/kotlin\n",
    });
    var conf_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = conf_buf[0..try fx.tmp.dir.realPath(testing.io, &conf_buf)];
    const conf_path = try std.fmt.allocPrint(gpa, "{s}/boilerplate.conf", .{root});
    defer gpa.free(conf_path);
    try fx.env.put("SYNAPSE_MODULE_BOILERPLATE_CONF", conf_path);

    const after = try runSources(gpa, &fx, &.{ "Foo Node", "--modules" });
    defer gpa.free(after.out);
    try testing.expect(std.mem.indexOf(u8, after.out, "mod-a\t1") != null);
}

test "field: returns unquoted scalars, empty for an absent key" {
    const gpa = testing.allocator;
    const text = "---\nstale: false\nbuilt_at: \"2026-08-03 16:15\"\n---\n\n# Foo\n";

    var stale_out: Io.Writer.Allocating = .init(gpa);
    defer stale_out.deinit();
    var stale_r: Io.Reader = .fixed(text);
    _ = try writeField(&stale_r, "stale", &stale_out.writer);
    try testing.expectEqualStrings("false\n", stale_out.written());

    var built_out: Io.Writer.Allocating = .init(gpa);
    defer built_out.deinit();
    var built_r: Io.Reader = .fixed(text);
    _ = try writeField(&built_r, "built_at", &built_out.writer);
    try testing.expectEqualStrings("2026-08-03 16:15\n", built_out.written()); // quotes stripped

    var absent_out: Io.Writer.Allocating = .init(gpa);
    defer absent_out.deinit();
    var absent_r: Io.Reader = .fixed(text);
    const code = try writeField(&absent_r, "nonexistent_key", &absent_out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 0), absent_out.written().len);
}

test "field: refuses 'sources' with exit 2 and points at the right subcommand" {
    const gpa = testing.allocator;
    const text = "---\nstale: false\n---\n\n# Foo\n";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var r: Io.Reader = .fixed(text);
    const code = try writeField(&r, "sources", &out.writer);
    try testing.expectEqual(@as(u8, 2), code);
}

test "field --file: reads a plain file directly, no vault node or namespace needed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "b-01.md",
        .data = "---\nsummary: \"A one-line draft summary.\"\n---\n\n## Summary\n",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/b-01.md", .{root});
    defer gpa.free(path);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdFieldFile(testing.io, path, "summary", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("A one-line draft summary.\n", out.written());
}

test "field --file: an absent key prints nothing and exits 0" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b-01.md", .data = "---\nsummary: \"x\"\n---\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/b-01.md", .{root});
    defer gpa.free(path);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdFieldFile(testing.io, path, "nonexistent_key", &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "field --file: a missing file exits 1 with a clear message" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdFieldFile(testing.io, "/nonexistent/nope.md", "summary", &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "field --file: still refuses 'sources' with exit 2" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b-01.md", .data = "---\nsummary: \"x\"\n---\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/b-01.md", .{root});
    defer gpa.free(path);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdFieldFile(testing.io, path, "sources", &out.writer);
    try testing.expectEqual(@as(u8, 2), code);
}

// --- drift -------------------------------------------------------------

fn makeTwoAreaRepo(fx: *fixture.Fixture) !void {
    try fx.writeRepoFile("mod-a/a.java", "class A {}\n");
    try fx.writeRepoFile("mod-a/b.java", "class B {}\n");
    try fx.writeRepoFile("docs/guide.md", "# guide\n");
    try fx.gitCommit("two-areas");
}

/// Writes a node with an explicit baseline commit and source list --
/// matching the bats fixture's own `stage_node`. `commit` null omits the
/// field entirely.
fn driftNode(gpa: Allocator, fx: *fixture.Fixture, title: []const u8, commit: ?[]const u8, sources: []const []const u8) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print(
        "---\ntitle: \"{s}\"\nsummary: \"One line.\"\nnode_type: synapse-node\nsources:\n",
        .{title},
    );
    for (sources) |p| try out.writer.print("  - path: {s}\n    hash: deadbeef\n", .{p});
    try out.writer.writeAll("sources_digest: notchecked\nstale: false\nbuilt_at: \"2026-01-01 00:00\"\n");
    if (commit) |c| try out.writer.print("commit: {s}\n", .{c});
    try out.writer.print(
        "---\n\n# {s}\n<!-- synapse:generated:start -->\nbody\n<!-- synapse:generated:end -->\n\n## Notes\n",
        .{title},
    );
    try fx.writeNodeFile(title, out.written());
}

fn runDrift(gpa: Allocator, fx: *fixture.Fixture, rest: []const []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdDrift(gpa, fx.io(), &ctx, rest, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "drift: a namespace built at HEAD reports nothing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{ "mod-a/a.java", "mod-a/b.java" });
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "drift: a modified file is reported against its own node only" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const base = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(base);
    try driftNode(gpa, &fx, "Mod A", base, &.{ "mod-a/a.java", "mod-a/b.java" });
    try driftNode(gpa, &fx, "Docs", base, &.{"docs/guide.md"});
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });

    try fx.writeRepoFile("mod-a/a.java", "class A { int x; }\n");
    try fx.gitCommit("edit");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "Mod A\tcontent changed in 1 of its files") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "Docs\tcontent changed") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "(repo)\t1 commits since baseline") != null);
}

test "drift: a deleted file is reported as gone" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{ "mod-a/a.java", "mod-a/b.java" });
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });

    const rm = try fx.git(&.{ "rm", "-q", "mod-a/b.java" });
    rm.deinit(gpa);
    try fx.gitCommit("delete");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Mod A\t1 of its files are gone") != null);
}

test "drift: a rename is reported as reseatable rather than as a deletion" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{ "mod-a/a.java", "mod-a/b.java" });
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });

    const mv = try fx.git(&.{ "mv", "mod-a/b.java", "mod-a/renamed.java" });
    mv.deinit(gpa);
    try fx.gitCommit("rename");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    // The distinction that matters: the concept is unchanged, only the path
    // moved, so the node can be rewritten from its own prose with an
    // updated path list. `stale` can only ever call this "source files gone".
    try testing.expect(std.mem.indexOf(u8, r.out, "reseat sources, prose may still hold") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "are gone") == null);
}

test "drift: added paths that an existing manifest pattern already covers are counted, not listed" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{ "mod-a/a.java", "mod-a/b.java" });
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/manifest.tsv", .data = "Mod A\t^mod-a/\t\n" });

    try fx.writeRepoFile("mod-a/c.java", "class C {}\n");
    try fx.writeRepoFile("mod-a/d.java", "class D {}\n");
    try fx.gitCommit("adds");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    // Ordinary development needs no judgment: the clustering patterns claim
    // these on the next build-lists run.
    try testing.expect(std.mem.indexOf(u8, r.out, "2 new paths already match a manifest pattern") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "synapse build-lists") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "match no manifest pattern") == null);
}

test "drift: an added path matching no manifest pattern is listed for a decision" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/manifest.tsv", .data = "Mod A\t^mod-a/\t\n" });

    try fx.writeRepoFile("brand-new-subsystem/thing.java", "new\n");
    try fx.gitCommit("newsubsystem");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "1 new paths match no manifest pattern") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "brand-new-subsystem/thing.java") != null);
}

test "drift: without a manifest, unclaimed additions are still reported" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    try fx.writeRepoFile("mod-a/c.java", "class C {}\n");
    try fx.gitCommit("add");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "claimed by no node, and no manifest to classify them against") != null);
}

test "drift: a node with no commit field says so instead of guessing a baseline" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    try driftNode(gpa, &fx, "Mod A", null, &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Mod A\tno commit recorded") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "verify with `stale`") != null);
}

test "drift: a baseline that is not in local history falls back to stale rather than diffing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    // A plausible but absent sha: force-push, a rebase that dropped it, or a
    // shallow clone. Diffing against it would either fail or, worse, appear
    // to work.
    try driftNode(gpa, &fx, "Mod A", "0123456789abcdef0123456789abcdef01234567", &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "baseline 0123456789ab not in local history") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "verify with `stale`") != null);
}

test "drift: a node listed in the index but absent from the vault is reported" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Ghost.md" }});

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Ghost\tnode file missing from the vault") != null);
}

test "drift: being behind upstream is context, printed only alongside a finding" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const base = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(base);
    try driftNode(gpa, &fx, "Mod A", base, &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    // A local branch serves as an upstream, keeping the test free of a real remote.
    const branch = try fx.gitOutput(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer gpa.free(branch);
    (try fx.git(&.{ "branch", "-q", "up" })).deinit(gpa);
    (try fx.git(&.{ "checkout", "-q", "up" })).deinit(gpa);
    try fx.writeRepoFile("mod-a/ahead.java", "ahead\n");
    try fx.gitCommit("ahead");
    (try fx.git(&.{ "checkout", "-q", branch })).deinit(gpa);
    (try fx.git(&.{ "branch", "-q", "--set-upstream-to=up", branch })).deinit(gpa);

    // Behind upstream, but the graph still matches this worktree: nothing to
    // do, so silence. Being behind is a git fact, and reporting it here
    // would make silence useless as a signal.
    const clean = try runDrift(gpa, &fx, &.{});
    defer gpa.free(clean.out);
    try testing.expectEqual(@as(usize, 0), clean.out.len);

    // Once a node actually drifts, the same fact becomes useful context and appears.
    try fx.writeRepoFile("mod-a/a.java", "class A { int x; }\n");
    try fx.gitCommit("edit");
    const dirty = try runDrift(gpa, &fx, &.{});
    defer gpa.free(dirty.out);
    try testing.expect(std.mem.indexOf(u8, dirty.out, "Mod A\tcontent changed in 1 of its files") != null);
    try testing.expect(std.mem.indexOf(u8, dirty.out, "commits behind up, as of the last fetch") != null);

    // Read-only throughout: HEAD must not have moved and nothing may be fetched in.
    const after_branch = try fx.gitOutput(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer gpa.free(after_branch);
    try testing.expectEqualStrings(branch, after_branch);
    if (fx.tmp.dir.access(testing.io, "repo/mod-a/ahead.java", .{})) {
        try testing.expect(false); // ahead.java must not have been fetched in
    } else |_| {}
}

test "drift: a divergent baseline is reported in both directions, and the file diff still holds" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    // The real scenario, and the ordering matters: the release branch forks
    // *before* the commit the node was built at, so the baseline is not on
    // this checkout's line. Branching from the baseline itself would leave
    // it an ancestor and prove nothing.
    const fork = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(fork);
    try fx.writeRepoFile("mod-a/a.java", "class A { int mainline; }\n");
    try fx.gitCommit("mainline-work");
    const base = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(base);
    try driftNode(gpa, &fx, "Mod A", base, &.{ "mod-a/a.java", "mod-a/b.java" });
    try fx.writeIndexBin(&.{
        .{ .path = "mod-a/a.java", .node = "Mod A.md" },
        .{ .path = "mod-a/b.java", .node = "Mod A.md" },
    });

    // Diverge without leaving the branch. Resetting to the fork point and
    // committing elsewhere reproduces the identical topology (the recorded
    // baseline is no longer an ancestor of HEAD).
    (try fx.git(&.{ "reset", "--hard", "-q", fork })).deinit(gpa);
    (try fx.git(&.{ "rm", "-q", "mod-a/b.java" })).deinit(gpa);
    try fx.gitCommit("diverged-line");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    // A one-directional count would claim "1 commits since baseline" and
    // hide that the baseline's line has work this checkout does not.
    try testing.expect(std.mem.indexOf(u8, r.out, "is not an ancestor of HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "the graph describes a different line") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "commits since baseline") == null);
    // The tree diff is still correct and useful: b.java genuinely is not here.
    try testing.expect(std.mem.indexOf(u8, r.out, "Mod A\t1 of its files are gone") != null);
}

test "drift: one diff per distinct baseline, not one per node" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const base = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(base);
    // Three nodes sharing a baseline, as a single build run produces.
    try driftNode(gpa, &fx, "Mod A", base, &.{"mod-a/a.java"});
    try driftNode(gpa, &fx, "Mod B", base, &.{"mod-a/b.java"});
    try driftNode(gpa, &fx, "Docs", base, &.{"docs/guide.md"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    try fx.writeRepoFile("mod-a/a.java", "class A { int x; }\n");
    try fx.gitCommit("edit");

    const r = try runDrift(gpa, &fx, &.{});
    defer gpa.free(r.out);
    // The commits-since line is per baseline, so a shared baseline reports once.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "commits since baseline"));
}

test "drift: arguments are a usage error" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeTwoAreaRepo(&fx);
    const head = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try driftNode(gpa, &fx, "Mod A", head, &.{"mod-a/a.java"});
    try fx.writeIndexBin(&.{.{ .path = "mod-a/a.java", .node = "Mod A.md" }});

    const r = try runDrift(gpa, &fx, &.{"extra"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 2), r.code);
}

// --- symbol ------------------------------------------------------------

fn runSymbol(gpa: Allocator, fx: *fixture.Fixture, rest: []const []const u8) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cmdSymbol(fake_grammar.FakeExtractor, gpa, fx.io(), &fx.env, &ctx, rest, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

fn cachePath(gpa: Allocator, fx: *fixture.Fixture) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{fx.work});
}

test "symbol: exact match across a node's sources, with file and tag line" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "src/foo.ml") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "FAKE_NAME") != null);
}

test "symbol: a name that never appears is silent, exit 0" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSymbol(gpa, &fx, &.{ "this_name_does_not_exist", "Foo Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "symbol: second query against the same node re-tags nothing" {
    // No output distinguishes "re-tagged and got the same answer" from
    // "read from cache" -- what does is that `backfill`'s no-op path never
    // calls `commit` at all, so the cache file's own bytes are untouched.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const first = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(first.out);
    try testing.expectEqual(@as(u8, 0), first.code);

    const cache_path = try cachePath(gpa, &fx);
    defer gpa.free(cache_path);
    const before = try fx.tmp.dir.readFileAlloc(testing.io, "work/_tags_cache.bin", gpa, .limited(1 << 20));
    defer gpa.free(before);

    const second = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(second.out);
    try testing.expectEqual(@as(u8, 0), second.code);
    try testing.expectEqualStrings(first.out, second.out);

    const after = try fx.tmp.dir.readFileAlloc(testing.io, "work/_tags_cache.bin", gpa, .limited(1 << 20));
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "symbol: disabled via env var -- no output, no cache file even created" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.ml", .content = "let x = 1\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);
    try fx.env.put("SYNAPSE_DISABLE_SYMBOL_CACHE", "1");

    const r = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
    try testing.expectEqual(error.FileNotFound, fx.tmp.dir.access(testing.io, "work/_tags_cache.bin", .{}));
}

test "symbol: missing arguments is a usage error, exit 2" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    const r = try runSymbol(gpa, &fx, &.{"FAKE_NAME"});
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 2), r.code);
}

test "symbol: unknown node exits 1" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    const r = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "No Such Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "symbol: unsupported file is reported distinctly, never conflated with no-match" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    // No registry entry for this extension at all.
    try fx.writeRepoFile("src/foo.unknownext", "no grammar for this\n");
    const node = try fencedNode(gpa, &.{.{ .path = "src/foo.unknownext", .content = "no grammar for this\n" }});
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    // No tab-separated hit line at all: the file was never actually tagged.
    try testing.expect(std.mem.indexOf(u8, r.out, "\tFAKE_NAME") == null);

    const cache_path = try cachePath(gpa, &fx);
    defer gpa.free(cache_path);
    var cache = try core.tags_cache.Cache.open(testing.io, cache_path);
    defer cache.close(testing.io);
    const e = cache.get("src/foo.unknownext").?;
    try testing.expect(e.unsupported);
}

test "symbol: a node with several sources returns hits from every one that matches" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_DISABLE_SYMBOL_CACHE");
    try fx.writeGrammars();
    try fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try fx.writeRepoFile("src/bar.ml", "let y = 2\n");
    const node = try fencedNode(gpa, &.{
        .{ .path = "src/foo.ml", .content = "let x = 1\n" },
        .{ .path = "src/bar.ml", .content = "let y = 2\n" },
    });
    defer gpa.free(node);
    try fx.writeNodeFile("Foo Node", node);

    const r = try runSymbol(gpa, &fx, &.{ "FAKE_NAME", "Foo Node" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "src/foo.ml") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "src/bar.ml") != null);
}
