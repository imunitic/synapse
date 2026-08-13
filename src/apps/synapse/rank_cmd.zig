//! `synapse rank` -- the work half of `claude/lib/synapse/synapse-rank.sh`.
//!
//!   rank --sources <file> [--repo <path>] [--out <dir>] [--top N] [--tier code|dsl] [--pool summary|crux]
//!   rank --lists <dir>    [--repo <path>] [--out <dir>] [--top N]
//!
//! The `--sources` form prints `tier <TAB> score <TAB> path`, ranked within each
//! tier, code first. Counts per tier go to stderr, so a node whose files all
//! scored zero is a number rather than an empty answer.
//!
//! ## A lookup now, not a tagging pass -- synapse-001, step 4
//!
//! The code tier used to tag every one of its sources itself, threaded the
//! same way `vocab` is, on the strength of the same measurement (tagging is
//! real per-file CPU work, so parallelism paid for itself). That is gone: by
//! the time `/synapse-init` calls `rank`, `vocab` has already tagged the whole
//! repo into `_tags_cache.bin` -- see `vocab_cmd.zig`'s own two-pass split --
//! so re-tagging a node's few dozen sources here was re-parsing files that
//! were already parsed, once per node, for as many nodes as the namespace has.
//!
//! `rankCode` below is a single-threaded read of that cache: no extractor, no
//! grammar registry load beyond the one `usable` already needed for the
//! code/DSL split, no thread pool. **It is also read-only against the cache on
//! purpose, not just incidentally** -- it never backfills a miss. A node whose
//! source somehow was not tagged during orientation scores that file zero
//! rather than tagging it here, the same way a file that parsed to nothing
//! already scored zero. This is what a future parallel authoring step needs:
//! several nodes ranking their sources at once must never become several
//! writers to one cache file. See the design note this implements and
//! [[sb — Parallel node authoring]], which depends on it.
//!
//! A cache that is missing or empty is not an error -- reported once, and
//! every code-tier score comes out zero, same as any other miss. Run `vocab`
//! first for a ranking that means anything; this command will not do it for
//! you.
//!
//! ## The two tiers answer different questions
//!
//! `code` is definitions per KB: not raw counts, which rank generated constant
//! tables first. `dsl` ranks the code that *consumes* a declaration, because a
//! declarative file carries little meaning on its own. Both rules live in
//! `core/rank.zig`; this file supplies the definitions, the sizes and the repo's
//! own code list. `dsl` was never a tagging pass -- it matches declaration
//! names against a module-bucketed file list -- and is unchanged here.
//!
//! ## `--lists`: every node's both pools, one repo pass -- sb-011, stage 1
//!
//! `--sources` ranks one node per invocation, and every invocation pays for a
//! fresh registry load, a fresh cache open, and -- for the DSL tier -- a fresh
//! `git ls-files` over the whole repository, bucketed by module. That
//! bucketing does not depend on which node is being ranked, so a namespace of
//! N nodes computing both pools the way `/synapse-init` does today pays for it
//! 2N times over. `--lists` computes it once (`buildDslIndex`) and reuses it
//! for every node found in the given directory, writing `{out}/rank/NN.summary.tsv`
//! and `{out}/rank/NN.crux.tsv` per node rather than printing to stdout, since
//! there is no single stream that could hold every node's answer. This is
//! [[sb — Parallel node authoring]]'s stage 1: everything about a node except
//! its prose, computed once rather than once per node.
//!
//! `--pool` and `--tier` are meaningless here -- every node gets both pools
//! unconditionally -- so they are rejected alongside `--lists` rather than
//! silently ignored.

const std = @import("std");
const core = @import("core");
const treesitter = @import("treesitter");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = core.tags_cache.Cache;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var sources: ?[]const u8 = null;
    var lists: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var top: usize = 10;
    var tier: ?[]const u8 = null;
    var pool: ?[]const u8 = null;

    while (args.next()) |arg| {
        // `--help` exits 0, like every other subcommand: a request for help is not a
        // usage error, and a caller piping `--help` into a pager should not see 2.
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--sources")) {
            sources = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--top")) {
            top = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--tier")) {
            tier = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--pool")) {
            pool = args.next() orelse return usage();
        } else return usage();
    }

    // Exactly one input mode. `--lists` computes both pools for every node it
    // finds, so `--pool`/`--tier` -- which pick one pool or one tier for a
    // single stream -- have no meaning alongside it.
    if (sources == null and lists == null) return usage();
    if (sources != null and lists != null) return usage();
    if (lists != null and (tier != null or pool != null)) return usage();
    if (tier) |t| {
        if (!std.mem.eql(u8, t, "code") and !std.mem.eql(u8, t, "dsl")) return usage();
    }

    const cwd = Io.Dir.cwd();
    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("synapse-rank: not inside a git repo\n", .{});
        return 1;
    }

    // Same default `context.workDirFor` computes for `vocab`: the namespace of
    // `--repo` (or the cwd) when neither `--out` nor the environment names one.
    // This is where `vocab` left `_tags_cache.bin`, and reading a node's sources
    // from it is the entire point of this step.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (out_dir == null and env.get("SYNAPSE_WORK_DIR") == null) {
        derived = try context.workDirFor(gpa, io, env, repo orelse ".", "synapse-rank");
    }
    const work_dir = out_dir orelse env.get("SYNAPSE_WORK_DIR") orelse
        if (derived) |d| d.path else {
        std.debug.print("synapse-rank: no --out and no SYNAPSE_WORK_DIR\n", .{});
        return 1;
    };
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{work_dir});
    defer gpa.free(cache_path);

    const home = env.get("HOME") orelse return 1;
    const registry_path = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("synapse-rank: cannot read the grammar registry\n", .{});
        return 1;
    };
    defer registry.deinit();

    const usable = try registry.usableExtensions(gpa);
    defer gpa.free(usable);

    var cache = try Cache.open(io, cache_path);
    defer cache.close(io);
    if (cache.count() == 0) {
        std.debug.print(
            "synapse-rank: tags cache is empty ({s}) -- every code-tier score will be zero; run synapse vocab first\n",
            .{cache_path},
        );
    }

    if (lists) |dir| {
        cwd.access(io, dir, .{}) catch {
            std.debug.print("synapse-rank: no such lists dir: {s}\n", .{dir});
            return 1;
        };
        return runLists(gpa, io, env, &cache, usable, root, dir, work_dir, top);
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sources_path = sources.?;
    const listing = cwd.readFileAlloc(io, sources_path, gpa, .limited(64 << 20)) catch {
        std.debug.print("synapse-rank: no such sources file: {s}\n", .{sources_path});
        return 1;
    };
    defer gpa.free(listing);

    const crux = if (pool == null or std.mem.eql(u8, pool.?, "summary"))
        false
    else if (std.mem.eql(u8, pool.?, "crux"))
        true
    else
        return usage();
    // A crux is code, so the DSL tier has nothing to contribute to it. Forced
    // here rather than checked at every use, so the two selectors cannot
    // disagree.
    const want = if (crux) "code" else tier;

    const all = try dedupeSorted(arena, listing);
    const split = try splitCodeNoncode(arena, all.items, usable);
    var code = split.code;
    const noncode = split.noncode;

    // Tests leave the crux pool. The built-in rule is `core.rank.isTest`; an
    // override is one ERE the user wrote, so it keeps `grep -E`, the engine it
    // was written against.
    var tests_dropped: usize = 0;
    if (crux) {
        const dropped = try dropTests(gpa, io, env, arena, code.items);
        tests_dropped = code.items.len - dropped.items.len;
        code = dropped;
    }

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    const code_rows = try rankCode(io, arena, &cache, root, code.items);
    // Computed only when it could be emitted: a crux pool forces `want` to
    // "code", so `dsl_only` is always false for it and these rows would never
    // print. Building the module index and matching against it just to throw
    // the result away is the exact per-node waste `--lists` exists to remove;
    // this path gets the same fix for free rather than staying asymmetric.
    const dsl_only = want != null and std.mem.eql(u8, want.?, "dsl");
    const code_only = want != null and std.mem.eql(u8, want.?, "code");
    const dsl_rows = if (!code_only and usable.len != 0 and noncode.items.len != 0) blk: {
        const idx = try buildDslIndex(gpa, io, arena, root, usable);
        break :blk try rankDsl(arena, idx, noncode.items);
    } else &[_]Row{};

    if (!dsl_only) try emit(&out.interface, code_rows, top, .code);
    if (!code_only) try emit(&out.interface, dsl_rows, top, .dsl);
    try out.interface.flush();

    std.debug.print(
        "synapse-rank: pool {s}, {d} sources -> code {d}, dsl-consumers {d}, unranked {d}, tests-excluded {d}\n",
        .{ pool orelse "summary", all.items.len, code_rows.len, dsl_rows.len, noncode.items.len, tests_dropped },
    );
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse rank --sources <file> [--repo <path>] [--out <dir>] [--top N] [--tier code|dsl] [--pool summary|crux]
        \\       synapse rank --lists <dir>    [--repo <path>] [--out <dir>] [--top N]
        \\
    , .{});
    return 2;
}

const Tier = enum { code, dsl };

/// One ranked file. `score` is a float for the code tier and a whole count for
/// dsl; the tier decides which format the line uses, matching the script's
/// `%.3f` against `%d`.
const Row = struct {
    score: f64,
    path: []const u8,
};

fn emit(w: *Io.Writer, rows: []const Row, top: usize, tier: Tier) !void {
    const limit = if (top == 0) rows.len else @min(top, rows.len);
    for (rows[0..limit]) |r| switch (tier) {
        .code => try w.print("code\t{d:.3}\t{s}\n", .{ r.score, r.path }),
        .dsl => try w.print("dsl\t{d}\t{s}\n", .{ @as(usize, @intFromFloat(r.score)), r.path }),
    };
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Score descending, then path ascending -- the script's `sort -k2,2gr -k3,3`.
fn lessByScore(_: void, a: Row, b: Row) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn hasUsableExtension(path: []const u8, usable: []const []const u8) bool {
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| path[at + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    for (usable) |u| if (std.mem.eql(u8, name[dot + 1 ..], u)) return true;
    return false;
}

fn repoRoot(gpa: Allocator, io: Io, repo: ?[]const u8) ![]u8 {
    const res = adapters.process.run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" }, .{
        .cwd = if (repo) |r| .{ .path = r } else .inherit,
    }) catch return gpa.dupe(u8, "");
    defer res.deinit(gpa);
    if (!res.ok()) return gpa.dupe(u8, "");
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

/// `sort -u` then drop blanks -- the order matters only in that duplicates
/// must not double-count a file.
fn dedupeSorted(arena: Allocator, listing: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r");
        if (p.len == 0) continue;
        if ((try seen.getOrPut(arena, p)).found_existing) continue;
        try all.append(arena, p);
    }
    std.mem.sort([]const u8, all.items, {}, lessByBytes);
    return all;
}

fn splitCodeNoncode(
    arena: Allocator,
    all: []const []const u8,
    usable: []const []const u8,
) !struct {
    code: std.ArrayListUnmanaged([]const u8),
    noncode: std.ArrayListUnmanaged([]const u8),
} {
    var code: std.ArrayListUnmanaged([]const u8) = .empty;
    var noncode: std.ArrayListUnmanaged([]const u8) = .empty;
    for (all) |p| {
        if (usable.len != 0 and hasUsableExtension(p, usable))
            try code.append(arena, p)
        else
            try noncode.append(arena, p);
    }
    return .{ .code = code, .noncode = noncode };
}

/// `grep -vE <re>` over a path list when `SYNAPSE_TEST_PATH_RE` overrides the
/// built-in rule; `core.rank.isTest` otherwise.
fn dropTests(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    arena: Allocator,
    code: []const []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    if (env.get("SYNAPSE_TEST_PATH_RE")) |re| return filterOutMatching(gpa, io, arena, code, re);
    var impl: std.ArrayListUnmanaged([]const u8) = .empty;
    for (code) |p| {
        if (!core.rank.isTest(p)) try impl.append(arena, p);
    }
    return impl;
}

/// `grep -vE <re>` over a path list, for a user-supplied test pattern.
fn filterOutMatching(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    paths: []const []const u8,
    re: []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    for (paths) |p| try input.writer.print("{s}\n", .{p});

    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    const res = adapters.process.run(io, gpa, &.{ "grep", "-vE", re }, .{
        .stdin = input.written(),
    }) catch return kept;
    defer res.deinit(gpa);
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        if (line.len != 0) try kept.append(arena, try arena.dupe(u8, line));
    }
    return kept;
}

/// Definitions per KB, read from the tags cache `vocab` already filled --
/// never tagged here. `cache` may be empty; every path then simply scores
/// zero, same as a path the cache holds but marked unsupported. Takes an
/// already-open cache rather than a path so `--lists` can open it once and
/// rank every node against the same handle.
fn rankCode(
    io: Io,
    arena: Allocator,
    cache: *Cache,
    root: []const u8,
    paths: []const []const u8,
) ![]Row {
    if (paths.len == 0) return &[_]Row{};

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (paths) |p| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
        const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (st.size == 0) continue;

        // Zero for a cache miss or an unsupported file -- the same "present
        // with a score of zero, not vanished from its tier" outcome an
        // untagged file always got.
        var defs: usize = 0;
        if (cache.get(p)) |entry| {
            if (!entry.unsupported) {
                var lines = std.mem.splitScalar(u8, entry.tags, '\n');
                while (lines.next()) |line| {
                    const tag = core.tag_line.parse(line) orelse continue;
                    // Definitions, not all tags: a reference says the file
                    // USES something, a definition says it DECLARES it, and a
                    // summary is made of what a subsystem declares.
                    if (tag.role == .def) defs += 1;
                }
            }
        }

        // Rounded to three decimals *before* sorting, not after. The script
        // printed `%.3f` with awk and then sorted that text, so two files whose
        // true densities are 2.5481 and 2.5484 are tied for it and fall through
        // to path order. Sorting the unrounded value instead ordered them by a
        // difference the output does not show -- 78 adjacent swaps out of 1,278
        // rows on a real node, every one of them a pair with identical printed
        // scores. Formatted and parsed back rather than arithmetic, so this
        // rounds exactly the way the printed line will.
        var buf: [32]u8 = undefined;
        const shown = std.fmt.bufPrint(&buf, "{d:.3}", .{core.rank.density(defs, st.size)}) catch continue;
        const rounded = std.fmt.parseFloat(f64, shown) catch continue;
        try rows.append(arena, .{ .score = rounded, .path = p });
    }
    std.mem.sort(Row, rows.items, {}, lessByScore);
    return rows.items;
}

/// Every usable-grammar path in the repo, bucketed by module -- one
/// `git ls-files`, shared across every node's DSL ranking rather than redone
/// per node. See the module doc comment's `--lists` section.
const DslIndex = struct {
    by_module: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(core.rank.Key)) = .empty,
};

fn buildDslIndex(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    root: []const u8,
    usable: []const []const u8,
) !DslIndex {
    var idx: DslIndex = .{};
    const listed = adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{
        .cwd = .{ .path = root },
    }) catch return idx;
    defer listed.deinit(gpa);
    if (!listed.ok()) return idx;

    var it = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trimEnd(u8, raw, "\r");
        if (p.len == 0) continue;
        if (!hasUsableExtension(p, usable)) continue;
        const owned = try arena.dupe(u8, p);
        const key = core.rank.keyOf(owned);
        const gop = try idx.by_module.getOrPut(arena, key.module);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, key);
    }
    return idx;
}

/// Which code file consumes each declaration, and how many it serves,
/// matched against an index built once by `buildDslIndex` and shared across
/// every node.
///
/// Bucketed by module first, so a prefix comparison only ever runs against
/// candidates that could match. Unbucketed this is every declaration against
/// every code file in the repository -- 98k of them on a large one.
///
/// Consumers are searched repo-wide rather than within `sources`: the code that
/// uses a node's declarations is frequently the reason to read it, and is not
/// always a file the node itself owns.
fn rankDsl(
    arena: Allocator,
    idx: DslIndex,
    declarations: []const []const u8,
) ![]Row {
    var served: std.StringHashMapUnmanaged(usize) = .empty;
    for (declarations) |d| {
        const dk = core.rank.keyOf(d);
        if (dk.stem.len < core.rank.min_stem) continue;
        const candidates = idx.by_module.get(dk.module) orelse continue;
        for (candidates.items) |ck| {
            if (!core.rank.consumes(dk, ck)) continue;
            const gop = try served.getOrPut(arena, ck.path);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    var sit = served.iterator();
    while (sit.next()) |e| {
        try rows.append(arena, .{
            .score = @floatFromInt(e.value_ptr.*),
            .path = e.key_ptr.*,
        });
    }
    std.mem.sort(Row, rows.items, {}, lessByScore);
    return rows.items;
}

/// `--lists`: both pools for every node found in `dir`, one repo pass.
///
/// A node is any `NN.txt` (01 through 99, matching `build-lists`' own
/// numbering) found in `dir`; a title is not required, because nothing here
/// reads one. `dsl_idx` is built once, before the loop, and reused for every
/// node -- the whole point of this mode.
fn runLists(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    cache: *Cache,
    usable: []const []const u8,
    root: []const u8,
    lists_dir: []const u8,
    work_dir: []const u8,
    top: usize,
) !u8 {
    const cwd = Io.Dir.cwd();

    // Two arenas, deliberately not one. `dsl_idx` below is built once and
    // read by every node for the rest of this call, so it needs an arena that
    // outlives the loop; `node_arena` is reset after every node so a
    // namespace with many nodes does not accumulate one arena's worth of
    // garbage per node. Resetting the shared arena instead would free the
    // index's own backing memory out from under every node after the first.
    var shared_state: std.heap.ArenaAllocator = .init(gpa);
    defer shared_state.deinit();
    const shared = shared_state.allocator();

    var node_state: std.heap.ArenaAllocator = .init(gpa);
    defer node_state.deinit();
    const node_arena = node_state.allocator();

    const dsl_idx = try buildDslIndex(gpa, io, shared, root, usable);

    const rank_dir = try std.fmt.allocPrint(shared, "{s}/rank", .{work_dir});
    cwd.createDirPath(io, rank_dir) catch {
        std.debug.print("synapse-rank: cannot write {s}\n", .{rank_dir});
        return 1;
    };

    var nodes: usize = 0;
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const txt_path = try std.fmt.allocPrint(node_arena, "{s}/{d:0>2}.txt", .{ lists_dir, n });
        const listing = cwd.readFileAlloc(io, txt_path, node_arena, .limited(64 << 20)) catch continue;

        const all = try dedupeSorted(node_arena, listing);
        const split = try splitCodeNoncode(node_arena, all.items, usable);
        const code = split.code;
        const noncode = split.noncode;

        const crux_code = try dropTests(gpa, io, env, node_arena, code.items);
        const tests_dropped = code.items.len - crux_code.items.len;

        const crux_rows = try rankCode(io, node_arena, cache, root, crux_code.items);
        const summary_code_rows = try rankCode(io, node_arena, cache, root, code.items);
        const summary_dsl_rows = if (usable.len != 0 and noncode.items.len != 0)
            try rankDsl(node_arena, dsl_idx, noncode.items)
        else
            &[_]Row{};

        var summary_buf: std.Io.Writer.Allocating = .init(gpa);
        defer summary_buf.deinit();
        try emit(&summary_buf.writer, summary_code_rows, top, .code);
        try emit(&summary_buf.writer, summary_dsl_rows, top, .dsl);
        const summary_path = try std.fmt.allocPrint(node_arena, "{s}/{d:0>2}.summary.tsv", .{ rank_dir, n });
        try cwd.writeFile(io, .{ .sub_path = summary_path, .data = summary_buf.written() });

        var crux_buf: std.Io.Writer.Allocating = .init(gpa);
        defer crux_buf.deinit();
        try emit(&crux_buf.writer, crux_rows, top, .code);
        const crux_path = try std.fmt.allocPrint(node_arena, "{s}/{d:0>2}.crux.tsv", .{ rank_dir, n });
        try cwd.writeFile(io, .{ .sub_path = crux_path, .data = crux_buf.written() });

        std.debug.print(
            "synapse-rank: node {d:0>2}, {d} sources -> code {d}, dsl-consumers {d}, unranked {d}, tests-excluded {d}\n",
            .{ n, all.items.len, summary_code_rows.len, summary_dsl_rows.len, noncode.items.len, tests_dropped },
        );
        nodes += 1;
        _ = node_state.reset(.retain_capacity);
    }

    if (nodes == 0) {
        std.debug.print("synapse-rank: no node lists (NN.txt) found in {s}\n", .{lists_dir});
        return 1;
    }
    std.debug.print("synapse-rank: {d} nodes ranked -> {s}\n", .{ nodes, rank_dir });
    return 0;
}
