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
//! `callers` is not here: it needs no graph, so the script execs
//! `synapse-callers.sh` ahead of the whole preamble. Tranche C ports it.
//!
//! ## The surface is frozen; the interior is not
//!
//! Every byte of stdout, every exit code and every stderr line is what the script
//! produced -- 34 tests in `tests/synapse-query.bats` plus 39 across the drift,
//! links and grounding files say so, and they are the specification. Behind that:
//!
//! - **No `jq`.** The reverse index is `_index.bin`, read through `core.index_map`
//!   rather than by spawning `synapse index`; the tags cache is read through
//!   `core.tags_cache` rather than through `tags-cache --dump`. Both were text
//!   projections whose only consumer was this script.
//! - **No `curl` on the read path.** `Index.md`, node files and `_manifest.tsv` are
//!   read from disk, and `grounding` walks node frontmatter instead of asking the
//!   API's JsonLogic endpoint. See `context.zig` for why that is the right way
//!   round rather than a shortcut.
//! - **No `sed`, `awk`, `comm`, `paste` or `wc`.** The rules they carried live in
//!   `core/query.zig`, `core/verify.zig`, `core/drift.zig` and `core/symbol.zig`,
//!   each pinned by tests against the case that made it necessary.
//!
//! What still spawns is `git` -- `cat-file`, `diff`, `merge-base`, `rev-list` --
//! and `grep -E` for a user-authored ERE out of `_manifest.tsv`. Both for the same
//! reason: the answer belongs to a tool that owns the format or the dialect, and
//! reimplementing either would be a second dialect that disagrees at the edges.
//!
//! Blob hashing is the exception that went the other way: `git hash-object` is
//! `sha1("blob {len}\0" + content)`, a format git documents and does not change,
//! so `core.verify.blobHash` computes it in process. That removes one spawn per
//! `stale` run over a node's whole source list.
//!
//! ## Silence is the protocol
//!
//! `stale`, `drift`, `grounding` and `links --check` print nothing when they find
//! nothing, and exit 1 means "could not run" -- never "clean". Every early return
//! below is one or the other on purpose: a subcommand that gave up quietly would
//! be read as a graph that matches.

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
    const sub = args.next() orelse return usage();
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        std.debug.print("{s}", .{usage_text});
        return 0;
    }
    // Validated *before* the environment, exactly as the script did: a usage error
    // is a property of the arguments, and reporting "could not run" for a typo'd
    // subcommand just because a vault is missing sends the caller looking in the
    // wrong place entirely.
    const known = [_][]const u8{ "body", "sources", "field", "stale", "drift", "grounding", "links", "symbol" };
    var ok = false;
    for (known) |k| if (std.mem.eql(u8, sub, k)) {
        ok = true;
    };
    if (!ok) return usage();

    // Collected up front so each subcommand can index them rather than thread an
    // iterator through every helper.
    var rest: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rest.deinit(gpa);
    while (args.next()) |a| try rest.append(gpa, a);

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
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
    \\usage: synapse query <subcommand> [args]
    \\
    \\  body    <node>                     fenced prose only, no frontmatter
    \\  sources <node>                     every path the node covers
    \\  sources <node> --count             just the number
    \\  sources <node> --modules           module<TAB>count, byte sorted
    \\  sources <node> --filter <pattern>  matching paths only (substring)
    \\  field   <node> <key>               one top-level frontmatter scalar
    \\  stale                              nodes whose files no longer match
    \\  drift                              what changed since each node's commit
    \\  grounding                          nodes whose evidence no longer matches
    \\  grounding <node> --list            that node's groundings, path<TAB>lines
    \\  links   <node>                     outbound relations, relation<TAB>target
    \\  links   <node> --inbound           what points here, relation<TAB>source
    \\  links   <node> --closure           reachable outbound, depth<TAB>node
    \\  links   --check                    link targets that resolve to no node
    \\  symbol  <name> <node>              exact-name hits, path<TAB>tag-line
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

/// The node, or a message and null. Exit 1 for an unknown node -- "no
/// information", never "clean".
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
    // A node built before fencing existed. Announced rather than hidden, because
    // `## Notes` will be included in what follows.
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
        // `wc -l` over the same list the other forms print.
        .count => try w.print("{d}\n", .{paths.items.len}),
        // `grep -F`: a substring, not a pattern. A path list is not a place for a
        // regex dialect, and the script's `-F` said so.
        .filter => for (paths.items) |p| {
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
    if (std.mem.eql(u8, rest[1], "sources")) {
        std.debug.print(
            "{s}: 'sources' is a list, not a scalar field -- use: synapse query sources <node>\n",
            .{prog},
        );
        return 2;
    }
    const text = (try need(ctx, io, rest[0])) orelse return 1;
    defer gpa.free(text);
    // An absent key prints nothing and exits 0, so a caller can test emptiness
    // without parsing a message.
    if (core.query.field(text, rest[1])) |v| try w.print("{s}\n", .{v});
    return 0;
}

// --- the node list, from the index ------------------------------------------

/// The nodes the index says exist, in its own (name-sorted) order.
///
/// The index is authoritative for *which nodes exist*; each node's own `sources`
/// stays authoritative for what it covers. Verifying against the index instead
/// would mask node/index drift and report a false mismatch whenever the two
/// disagree for an unrelated reason.
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

/// A repo-relative file's content, or null when it is not a regular file.
///
/// Null covers deleted paths and submodule gitlinks -- one `ls-files` entry, but a
/// directory on disk -- which is the case `git hash-object --stdin-paths` failed
/// the whole batch on, leaving the caller exit 128 and no offending path.
fn readRepoFile(gpa: Allocator, io: Io, ctx: *const Context, rel: []const u8) !?[]u8 {
    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.repo_root, rel });
    defer gpa.free(full);
    const st = Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind != .file) return null;
    return Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(256 << 20)) catch null;
}

// --- drift ------------------------------------------------------------------

/// One baseline commit and everything derived from it once.
///
/// Keyed per distinct baseline rather than per node, because nodes built in the
/// same run share a commit and the diff is the expensive part.
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
    var list = (try NodeList.open(gpa, io, ctx)) orelse return 1;
    defer list.close(gpa, io);

    // Findings are buffered rather than printed as they are found, so that silence
    // can mean "the graph matches the worktree". Context -- how far behind
    // upstream, how many commits since a baseline -- is only worth printing next to
    // a finding; on its own it is a git fact, not graph drift.
    var repo_findings: Io.Writer.Allocating = .init(gpa);
    defer repo_findings.deinit();
    var node_findings: Io.Writer.Allocating = .init(gpa);
    defer node_findings.deinit();

    var baselines: std.ArrayListUnmanaged(Baseline) = .empty;
    defer {
        for (baselines.items) |b| b.diff.deinit(gpa);
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

    // Nothing to report: stay silent, so silence is a usable signal.
    if (repo_findings.written().len == 0 and node_findings.written().len == 0) return 0;

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
        // Skipped for a divergent baseline: `--count base..HEAD` is the
        // one-directional number, and the divergence line already reports both.
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

/// `git cat-file -e <commit>^{commit}`: is this baseline in local history at all?
///
/// A shallow clone, or a baseline from a branch that was never fetched, answers no
/// -- and that is a finding rather than an error, because `stale` can still verify
/// the node by re-hashing.
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
    // A failed diff is an empty one, as `|| : > "$d.raw"` made it: the divergence
    // check below is what reports a baseline this checkout cannot reach.
    const raw = if (res.ok()) res.stdout else "";
    const diff = try core.drift.parseNameStatus(gpa, raw);
    // `parseNameStatus` returns slices into `raw`, which `res.deinit` frees -- so
    // the paths are copied into the diff's own memory here.
    const owned = try ownDiff(gpa, diff);
    diff.deinit(gpa);

    const divergent = !try isAncestor(gpa, io, ctx, commit);
    if (divergent) {
        // Divergence is a finding in its own right: the graph was built against a
        // line this checkout is not on, whatever the file-level diff says.
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

/// Added paths that no node claims, split by whether a manifest pattern would
/// already claim them -- so only the remainder needs a human decision.
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

    // `comm -23 added claimed`: added paths the index does not already cover. The
    // record table is byte-sorted, so `find` is a binary search rather than a scan.
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

    // One `grep -E` pair per manifest row over the whole unclaimed list, rather
    // than per path per row: the pattern is a user-authored ERE and keeps `grep`'s
    // engine, but nothing says it has to be spawned N times.
    var matched: std.StringHashMapUnmanaged(void) = .empty;
    defer matched.deinit(gpa);
    // The keys are slices into each `grep` result, so those buffers have to
    // outlive the map -- a `defer gpa.free` inside the loop below runs on every
    // iteration and would leave every key but the last one dangling.
    var hits: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h);
        hits.deinit(gpa);
    }
    var rows = std.mem.splitScalar(u8, manifest.?, '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        var cols = std.mem.splitScalar(u8, row, '\t');
        const title = cols.next() orelse continue;
        if (title.len == 0) continue;
        const include = cols.next() orelse continue;
        const exclude = cols.next() orelse "";
        const hit = build_lists_cmd.selectPaths(gpa, io, unclaimed.written(), include, exclude) catch continue;
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
    // `head -5 | tr '\n' ' '`: five names and a trailing space, which is what the
    // script's own pipeline left behind.
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
        // Verifies the node exists before reporting "no groundings", so a typo'd
        // title cannot read as "this node has none".
        const text = (try need(ctx, io, rest[0])) orelse return 1;
        defer gpa.free(text);
        var gs = try core.verify.groundings(gpa, text);
        defer gs.deinit(gpa);
        for (gs.items) |g| try w.print("{s}\t{s}\n", .{ g.path, g.lines });
        return 0;
    }
    if (rest.len != 0) return usage();

    // Every node that records a grounding, which is precisely the set worth
    // checking. Walked from disk rather than fetched through the API's JsonLogic
    // search: same set, no HTTP, and the same reads `stale` and `links` already do.
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
            // A pure line shift -- something inserted above the range -- would
            // otherwise report every grounding in the file as broken, which is the
            // fastest way to make a check worth ignoring.
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
        // One file read: a node's own links live in its own file, and deriving all
        // of them to filter for one is 48 reads to answer with 1.
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
            // The name is the filename minus `.md`, which is what `FILENAME` gave
            // the awk -- and what a wikilink resolves against.
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
    // A broken wikilink is a valid link to a not-yet-existing note, so Obsidian
    // renders it without complaint and nothing else in the system notices.
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

/// Breadth-first, so the depth printed is the shortest hop count and a cycle
/// terminates instead of looping.
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
    // Literal first line of this subcommand's logic: a disabled run does no cache
    // I/O and no tagging at all, matching the per-prompt injection hook's own
    // disable-knob convention.
    if (env.get("SYNAPSE_DISABLE_SYMBOL_CACHE") != null) return 0;
    if (rest.len != 2 or rest[0].len == 0 or rest[1].len == 0) return usage();
    const name = rest[0];

    const text = (try need(ctx, io, rest[1])) orelse return 1;
    defer gpa.free(text);
    var paths = try core.query.sources(gpa, text);
    defer paths.deinit(gpa);
    if (paths.items.len == 0) return 0;

    // Hash every source, then backfill whatever the cache is missing. Piggybacks
    // on hashes this pass needs anyway rather than deriving a second staleness
    // signal.
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
    // Non-fatal, exactly as the script's `|| echo ... -- continuing` was: a node
    // is still worth answering from whatever is already cached.
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
                while (it.next()) |line| try w.print("{s}\t{s}\n", .{ p, line });
            },
        }
    }
    return 0;
}
