//! `synapse rank` -- the work half of `claude/lib/synapse/synapse-rank.sh`.
//!
//!   rank --sources <file> [--repo <path>] [--out <dir>] [--top N] [--tier code|dsl] [--pool summary|crux]
//!   rank --lists <dir>    [--repo <path>] [--out <dir>] [--top N]
//!
//! `--sources` prints `tier<TAB>score<TAB>path`, ranked within each tier,
//! code first; per-tier counts go to stderr.
//!
//! `code` ranks the tags cache `vocab` already filled (definitions per KB;
//! never re-tags here), read-only and never backfilled -- several nodes
//! ranking at once must never become several writers to one cache file
//! ([[sb — Parallel node authoring]]). A missing/empty cache scores every
//! code file zero rather than erroring; run `vocab` first for a real answer.
//!
//! `dsl` ranks the code that *consumes* a declaration (a declarative file
//! carries little meaning alone), matching names against a module-bucketed
//! file list -- unrelated to the tags cache.
//!
//! `--lists` (sb-011 stage 1) computes both pools for every `NN.txt` node in
//! a directory in one repo pass, writing `{out}/rank/NN.{summary,crux}.tsv`
//! instead of stdout -- the module bucketing `dsl` needs doesn't depend on
//! which node is ranked, so `--sources` invoked once per node pays for it N
//! times over; this computes it once. `--pool`/`--tier` are meaningless here
//! (every node gets both) and are rejected, not silently ignored.

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

    // Exactly one input mode; `--lists` computes both pools, so `--pool`/`--tier`
    // (pick one for a single stream) have no meaning alongside it.
    if (sources == null and lists == null) return usage();
    if (sources != null and lists != null) return usage();
    if (lists != null and (tier != null or pool != null)) return usage();
    if (tier) |t| {
        if (!std.mem.eql(u8, t, "code") and !std.mem.eql(u8, t, "dsl")) return usage();
    }

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try rank(gpa, io, env, .{
        .sources = sources,
        .lists = lists,
        .repo = repo,
        .out_dir = out_dir,
        .top = top,
        .tier = tier,
        .pool = pool,
    }, &out.interface);
    try out.interface.flush();
    return code;
}

pub const Options = struct {
    sources: ?[]const u8 = null,
    lists: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    top: usize = 10,
    tier: ?[]const u8 = null,
    pool: ?[]const u8 = null,
};

/// The ranking itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture repo without going through the CLI or
/// capturing stdout. Assumes `opts` already passed the mutual-exclusion
/// checks `run()` makes first.
pub fn rank(gpa: Allocator, io: Io, env: *std.process.Environ.Map, opts: Options, result: *Io.Writer) !u8 {
    const sources = opts.sources;
    const lists = opts.lists;
    const repo = opts.repo;
    const out_dir = opts.out_dir;
    const top = opts.top;
    const tier = opts.tier;
    const pool = opts.pool;

    const cwd = Io.Dir.cwd();
    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("synapse-rank: not inside a git repo\n", .{});
        return 1;
    }

    // Same default `context.workDirFor` uses for `vocab` -- where it left
    // `_tags_cache.bin`.
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
    const registry_path = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
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
    // A crux is code -- forced here rather than checked at every use.
    const want = if (crux) "code" else tier;

    const all = try dedupeSorted(arena, listing);
    const split = try splitCodeNoncode(arena, all.items, usable);
    var code = split.code;
    const noncode = split.noncode;

    // Tests leave the crux pool: `core.rank.isTest`, or a user ERE via `grep -E`.
    var tests_dropped: usize = 0;
    if (crux) {
        const dropped = try dropTests(gpa, io, env, arena, code.items);
        tests_dropped = code.items.len - dropped.items.len;
        code = dropped;
    }

    const code_rows = try rankCode(io, arena, &cache, root, code.items);
    // dsl_rows computed only when it could be emitted, not wastefully for a
    // crux pool (which forces `want` to "code" and never prints them).
    const dsl_only = want != null and std.mem.eql(u8, want.?, "dsl");
    const code_only = want != null and std.mem.eql(u8, want.?, "code");
    const dsl_rows = if (!code_only and usable.len != 0 and noncode.items.len != 0) blk: {
        const idx = try buildDslIndex(gpa, io, arena, root, usable);
        break :blk try rankDsl(arena, idx, noncode.items);
    } else &[_]Row{};

    if (!dsl_only) try emit(result, code_rows, top, .code);
    if (!code_only) try emit(result, dsl_rows, top, .dsl);

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

/// One ranked file. `score` is a float for `code`, a whole count for `dsl`
/// (`%.3f` vs `%d`).
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

/// `sort -u` then drop blanks; duplicates must not double-count a file.
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
/// never tagged here. An empty `cache` just scores every path zero. Takes
/// an already-open cache so `--lists` can rank every node against one handle.
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

        // Cache miss or unsupported file: scores zero, stays in its tier.
        var defs: usize = 0;
        if (cache.get(p)) |entry| {
            if (!entry.unsupported) {
                var lines = std.mem.splitScalar(u8, entry.tags, '\n');
                while (lines.next()) |line| {
                    const tag = core.tag_line.parse(line) orelse continue;
                    if (tag.role == .def) defs += 1; // definitions, not references
                }
            }
        }

        // Rounded to 3 decimals *before* sorting, matching the script's
        // print-then-sort: sorting unrounded values ordered ties by a
        // difference the output never shows (78 misordered pairs out of
        // 1,278 rows on a real node, all identical when printed).
        const rounded = @round(core.rank.density(defs, st.size) * 1000.0) / 1000.0;
        try rows.append(arena, .{ .score = rounded, .path = p });
    }
    std.mem.sort(Row, rows.items, {}, lessByScore);
    return rows.items;
}

/// Every usable-grammar path in the repo, bucketed by module -- one
/// `git ls-files`, shared across every node's DSL ranking rather than redone
/// per node.
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

/// Which code file consumes each declaration, and how many, against an index
/// built once by `buildDslIndex` and shared across every node. Bucketed by
/// module first -- unbucketed this is every declaration against every code
/// file in the repo (98k pairs on a large one). Searched repo-wide, not
/// within `sources`: a declaration's consumer is often outside the node.
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

/// `--lists`: both pools for every node found in `dir`, one repo pass. A node
/// is any `NN.txt` (01-99); no title required, since nothing here reads one.
/// `dsl_idx` is built once and reused for every node.
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

    // Two arenas: `dsl_idx` outlives the loop, so it needs its own arena;
    // `node_arena` resets after every node so a large namespace doesn't
    // accumulate garbage. Resetting the shared one would free the index out
    // from under every node after the first.
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

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

/// A real repo (files, a git commit) plus a real tags cache, built directly
/// through `core.tags_cache.Cache.commit` rather than via a real or fake
/// tagger -- `rankCode` only ever reads real bytes on disk (for size) and
/// real tag-line text in the cache (for definition counts), so both can be
/// supplied straight from a test without tagging anything.
const RankFixture = struct {
    fx: fixture.Fixture,
    updates: std.ArrayListUnmanaged(core.tags_cache.Update),

    fn init(gpa: Allocator) !RankFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        // java/py/ts, matching the bats fixture's own registry -- any
        // extension a test uses as "code" must be registered here or it
        // falls out of the code tier entirely.
        try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        try fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-grammars.conf",
            .data =
            \\{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
            \\ "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
            \\ "ts": {"repo": "https://example.invalid/tree-sitter-typescript", "scope": "source.tsx"}}
            ,
        });
        return .{ .fx = fx, .updates = .empty };
    }

    fn deinit(self: *RankFixture) void {
        self.freeUpdates();
        self.updates.deinit(self.fx.gpa);
        self.fx.deinit();
    }

    fn freeUpdates(self: *RankFixture) void {
        for (self.updates.items) |u| {
            self.fx.gpa.free(u.path);
            self.fx.gpa.free(u.entry.tags);
        }
        self.updates.clearRetainingCapacity();
    }

    /// A real file (`defs` lines of `symbol:NAME` plus `pad` filler bytes,
    /// matching the bats fixture's own byte shape) and a queued cache entry
    /// with one real "def" tag line per symbol -- `rankCode` never tags
    /// anything itself, only reads what's already in the cache.
    fn src(self: *RankFixture, path: []const u8, pad: usize, defs: []const []const u8) !void {
        try self.srcWithRefs(path, pad, defs, &.{});
    }

    /// Same, plus `refs` real "ref" tag lines -- for fixtures that need a
    /// file with both definitions and references.
    fn srcWithRefs(self: *RankFixture, path: []const u8, pad: usize, defs: []const []const u8, refs: []const []const u8) !void {
        const gpa = self.fx.gpa;
        var content: Io.Writer.Allocating = .init(gpa);
        defer content.deinit();
        for (defs) |s| try content.writer.print("symbol:{s}\n", .{s});
        for (refs) |s| try content.writer.print("ref:{s}\n", .{s});
        var i: usize = 0;
        while (i < pad) : (i += 1) try content.writer.writeByte('x');
        try self.fx.writeRepoFile(path, content.written());

        var tags: Io.Writer.Allocating = .init(gpa);
        defer tags.deinit();
        var row: u32 = 1;
        for (defs) |s| {
            try tags.writer.print("{s}\t | kind   \tdef ({d}, 1) - ({d}, 20) `x`\n", .{ s, row, row });
            row += 1;
        }
        for (refs) |s| {
            try tags.writer.print("{s}\t | kind   \tref ({d}, 1) - ({d}, 20) `x`\n", .{ s, row, row });
            row += 1;
        }

        try self.updates.append(gpa, .{
            .path = try gpa.dupe(u8, path),
            .entry = .{ .hash = std.mem.zeroes([20]u8), .tags = try gpa.dupe(u8, tags.written()) },
        });
    }

    /// A real file with no cache entry at all -- config/data/declaration
    /// files, which `rankCode` never looks up (only paths in the code tier
    /// are looked up), and non-code files DSL ranking matches by filename
    /// stem alone.
    fn plain(self: *RankFixture, path: []const u8, content: []const u8) !void {
        try self.fx.writeRepoFile(path, content);
    }

    /// Writes the queued tags cache and commits the repo. Call once, after
    /// every `src`/`plain` call for this test.
    fn commit(self: *RankFixture) !void {
        try self.fx.gitCommit("fixture");
        if (self.updates.items.len == 0) return;
        const cache_path = try std.fmt.allocPrint(self.fx.gpa, "{s}/_tags_cache.bin", .{self.fx.work});
        defer self.fx.gpa.free(cache_path);
        var cache = try Cache.open(testing.io, cache_path);
        defer cache.close(testing.io);
        _ = try cache.commit(self.fx.gpa, testing.io, self.updates.items, &.{});
        self.freeUpdates();
    }

    /// `opts.sources`, if set, is the sources *list content* (one path per
    /// line) rather than a file path -- `rank`'s own `--sources` flag names
    /// a file, so this writes that content to a real one first and points
    /// `rank` at it.
    fn run(self: *RankFixture, opts: Options) !RunResult {
        var full = opts;
        full.repo = self.fx.repo;
        full.out_dir = self.fx.work;
        var sources_path: ?[]const u8 = null;
        defer if (sources_path) |p| self.fx.gpa.free(p);
        if (opts.sources) |content| {
            try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/sources.txt", .data = content });
            sources_path = try std.fmt.allocPrint(self.fx.gpa, "{s}/sources.txt", .{self.fx.work});
            full.sources = sources_path;
        }
        var out: Io.Writer.Allocating = .init(self.fx.gpa);
        defer out.deinit();
        const code = try rank(self.fx.gpa, self.fx.io(), &self.fx.env, full, &out.writer);
        return .{ .code = code, .out = try self.fx.gpa.dupe(u8, out.written()) };
    }
};

const RunResult = struct { code: u8, out: []u8 };

/// Every `code`/`dsl` row, stripped of the summary line on stderr (which
/// never reaches the captured writer in the first place -- unlike bats,
/// which merges stdout and stderr, this fixture only ever captures stdout).
fn rankOf(gpa: Allocator, path: []const u8, out: []const u8) !?usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "code\t") and !std.mem.startsWith(u8, line, "dsl\t")) continue;
        n += 1;
        var cols = std.mem.splitScalar(u8, line, '\t');
        _ = cols.next();
        _ = cols.next();
        const p = cols.next() orelse continue;
        if (std.mem.eql(u8, p, path)) return n;
    }
    _ = gpa;
    return null;
}

test "rank: an oversized file does not outrank a small one with the same definitions" {
    // The finding the code tier exists for: raw definition counts rank
    // generated constant tables and wide accessor classes first, which is
    // the opposite of useful. Both files here declare exactly the same
    // symbols; only size differs.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Service.java", 0, &.{ "Alpha", "Beta", "Gamma" });
    try rf.src("core/src/Generated.java", 40000, &.{ "Alpha", "Beta", "Gamma" });
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Service.java\ncore/src/Generated.java\n" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const service = (try rankOf(gpa, "core/src/Service.java", r.out)).?;
    const generated = (try rankOf(gpa, "core/src/Generated.java", r.out)).?;
    try testing.expect(service < generated);
}

test "rank: raw counts alone would give the opposite answer" {
    // Pins that normalising is what decides it: here the big file declares
    // strictly MORE symbols and must still rank below.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Service.java", 0, &.{ "Alpha", "Beta" });
    try rf.src("core/src/Generated.java", 40000, &.{ "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight" });
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Service.java\ncore/src/Generated.java\n" });
    defer gpa.free(r.out);
    const service = (try rankOf(gpa, "core/src/Service.java", r.out)).?;
    const generated = (try rankOf(gpa, "core/src/Generated.java", r.out)).?;
    try testing.expect(service < generated);
}

test "rank: references do not count as definitions" {
    // A summary is made of what a subsystem DECLARES. A file that merely
    // calls a lot of things is not thereby a good thing to read first.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Declarer.java", 0, &.{ "Alpha", "Beta", "Gamma", "Delta" });
    try rf.srcWithRefs("core/src/Caller.java", 0, &.{}, &.{ "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "T9" });
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Declarer.java\ncore/src/Caller.java\n" });
    defer gpa.free(r.out);
    const declarer = (try rankOf(gpa, "core/src/Declarer.java", r.out)).?;
    const caller = (try rankOf(gpa, "core/src/Caller.java", r.out)).?;
    try testing.expect(declarer < caller);
}

test "rank: a file that parsed to no definitions is ranked last, not dropped" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Real.java", 0, &.{ "Alpha", "Beta" });
    try rf.plain("core/src/Empty.java", "notags\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Real.java\ncore/src/Empty.java\n" });
    defer gpa.free(r.out);
    const empty = try rankOf(gpa, "core/src/Empty.java", r.out);
    try testing.expect(empty != null);
    const real = (try rankOf(gpa, "core/src/Real.java", r.out)).?;
    try testing.expect(real < empty.?);
}

// --- dsl tier ----------------------------------------------------------

test "rank: a declaration ranks its consumer, resolved by stem prefix" {
    // `Kunde.gui` is a declaration; `KundeController.java` is the code that
    // binds it and carries the domain verbs. The declaration itself is
    // never ranked.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/KundeController.java", 0, &.{"Alpha"});
    try rf.plain("core/src/Kunde.gui", "declaration\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Kunde.gui\ncore/src/KundeController.java\n" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "dsl\t") != null);
    try testing.expect((try rankOf(gpa, "core/src/KundeController.java", r.out)) != null);
    // The .gui file is evidence, not a reading target.
    try testing.expect(std.mem.indexOf(u8, r.out, "core/src/Kunde.gui") == null);
}

test "rank: the consumer hop is constrained to the declaration's own module" {
    // THE finding that makes the hop worth anything: generic stems match
    // dozens of unrelated classes across a large repo, so a stem-only match
    // resolves to whichever sorts first and is worse than no answer at all.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("billing/src/AdresseHandler.java", 0, &.{"Alpha"});
    try rf.src("shipping/src/AdresseHandler.java", 0, &.{"Beta"});
    try rf.plain("billing/src/Adresse.domvo", "declaration\n");
    try rf.commit();

    // Neither AdresseHandler.java is itself a source here -- only the
    // declaration is -- so any AdresseHandler.java row in the output can
    // only have come from the dsl consumer hop, not from being listed
    // directly.
    const r = try rf.run(.{ .sources = "billing/src/Adresse.domvo\n", .tier = "dsl" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "dsl\t1\tbilling/src/AdresseHandler.java") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "shipping/src/AdresseHandler.java") == null);
}

test "rank: consumers rank by how many declarations they serve" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/BusyHandler.java", 0, &.{"Alpha"});
    try rf.src("core/src/IdleHandler.java", 0, &.{"Beta"});
    // Both stems prefix `BusyHandler`, so both resolve to the same consumer.
    try rf.plain("core/src/Busy.domvo", "x\n");
    try rf.plain("core/src/BusyHandler.domvo", "x\n");
    try rf.plain("core/src/Idle.domvo", "x\n");
    try rf.commit();

    const r = try rf.run(.{
        .sources = "core/src/Busy.domvo\ncore/src/BusyHandler.domvo\ncore/src/Idle.domvo\n",
        .tier = "dsl",
    });
    defer gpa.free(r.out);
    const busy = (try rankOf(gpa, "core/src/BusyHandler.java", r.out)).?;
    const idle = (try rankOf(gpa, "core/src/IdleHandler.java", r.out)).?;
    try testing.expect(busy < idle);
    try testing.expect(std.mem.indexOf(u8, r.out, "dsl\t2\tcore/src/BusyHandler.java") != null);
}

test "rank: a consumer outside the node's own sources is still found" {
    // The code that uses a node's declarations is frequently the reason to
    // read it, and is not always a file the node itself owns.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/KundeController.java", 0, &.{"Alpha"});
    try rf.plain("core/src/Kunde.gui", "x\n");
    try rf.commit();

    // The controller is deliberately NOT listed.
    const r = try rf.run(.{ .sources = "core/src/Kunde.gui\n", .tier = "dsl" });
    defer gpa.free(r.out);
    try testing.expect((try rankOf(gpa, "core/src/KundeController.java", r.out)) != null);
}

test "rank: config and data with no consumer are unranked but counted" {
    // Scored zero and omitted from the ranking, still fully covered by
    // `sources` -- coverage and relevance are separate axes.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Real.java", 0, &.{"Alpha"});
    try rf.plain("core/src/settings.properties", "a=1\n");
    try rf.plain("core/src/data.json", "{}\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Real.java\ncore/src/settings.properties\ncore/src/data.json\n" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "settings.properties") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "data.json") == null);
}

test "rank: a stem under three characters makes no hop" {
    // Such a stem prefixes half the repo and tells you nothing.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/AbcHandler.java", 0, &.{"Alpha"});
    try rf.plain("core/src/Ab.domvo", "x\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Ab.domvo\n", .tier = "dsl" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, r.out, "dsl\t"));
}

// --- the two pools -------------------------------------------------------

test "rank: the crux pool excludes tests even when density ranks them first" {
    // Density ranks tests high for a structural reason -- many small @Test
    // methods, each a definition, in a small file -- so this is not a rare
    // collision, it is the normal outcome. Without the split, the crux
    // pointer would routinely land on a test.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("src/main/java/Service.java", 3000, &.{ "Alpha", "Beta" });
    try rf.src("src/test/java/ServiceTest.java", 0, &.{ "T1", "T2", "T3", "T4", "T5", "T6" });
    try rf.commit();

    // It really would have won on density alone.
    const summary = try rf.run(.{
        .sources = "src/main/java/Service.java\nsrc/test/java/ServiceTest.java\n",
        .pool = "summary",
        .tier = "code",
    });
    defer gpa.free(summary.out);
    try testing.expectEqual(@as(usize, 1), (try rankOf(gpa, "src/test/java/ServiceTest.java", summary.out)).?);

    const crux = try rf.run(.{
        .sources = "src/main/java/Service.java\nsrc/test/java/ServiceTest.java\n",
        .pool = "crux",
    });
    defer gpa.free(crux.out);
    try testing.expect((try rankOf(gpa, "src/test/java/ServiceTest.java", crux.out)) == null);
    try testing.expect((try rankOf(gpa, "src/main/java/Service.java", crux.out)) != null);
}

test "rank: the summary pool keeps tests, because a summary is made of names" {
    // `Gegenpartei` and `Frist` came only from test class names on a real
    // node. Excluding tests from both halves would have cost those
    // concepts entirely.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("src/main/java/Service.java", 0, &.{"Alpha"});
    try rf.src("src/test/java/GegenparteiTest.java", 0, &.{"Frist"});
    try rf.commit();

    const r = try rf.run(.{
        .sources = "src/main/java/Service.java\nsrc/test/java/GegenparteiTest.java\n",
        .pool = "summary",
    });
    defer gpa.free(r.out);
    try testing.expect((try rankOf(gpa, "src/test/java/GegenparteiTest.java", r.out)) != null);
}

test "rank: the crux pool emits no dsl tier: a crux is code" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/KundeController.java", 0, &.{"Alpha"});
    try rf.plain("core/src/Kunde.gui", "x\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Kunde.gui\ncore/src/KundeController.java\n", .pool = "crux" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, r.out, "dsl\t"));
}

test "rank: test detection does not swallow implementation files that merely end in -test" {
    // `Latest.java` ends in the letters "test". Silently dropping a real
    // implementation file from the crux pool is precisely the kind of wrong
    // answer that never announces itself, so the boundary is asserted directly.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Latest.java", 0, &.{"Alpha"});
    try rf.src("core/src/Contest.java", 0, &.{"Beta"});
    try rf.src("core/src/RealTest.java", 0, &.{"Gamma"});
    try rf.commit();

    const r = try rf.run(.{
        .sources = "core/src/Latest.java\ncore/src/Contest.java\ncore/src/RealTest.java\n",
        .pool = "crux",
    });
    defer gpa.free(r.out);
    try testing.expect((try rankOf(gpa, "core/src/Latest.java", r.out)) != null);
    try testing.expect((try rankOf(gpa, "core/src/Contest.java", r.out)) != null);
    try testing.expect((try rankOf(gpa, "core/src/RealTest.java", r.out)) == null);
}

test "rank: test detection covers the conventions that recur across languages" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Keep.java", 0, &.{"Alpha"});
    try rf.src("core/src/FooTest.java", 0, &.{"A"});
    try rf.src("core/src/FooSpec.java", 0, &.{"B"});
    try rf.src("core/src/thing_test.py", 0, &.{"C"});
    try rf.src("core/src/test_thing.py", 0, &.{"D"});
    try rf.src("core/src/widget.test.ts", 0, &.{"E"});
    try rf.src("core/spec/Helper.java", 0, &.{"F"});
    try rf.commit();

    const r = try rf.run(.{
        .sources = "core/src/Keep.java\ncore/src/FooTest.java\ncore/src/FooSpec.java\n" ++
            "core/src/thing_test.py\ncore/src/test_thing.py\ncore/src/widget.test.ts\ncore/spec/Helper.java\n",
        .pool = "crux",
        .top = 0,
    });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "code\t"));
    try testing.expect((try rankOf(gpa, "core/src/Keep.java", r.out)) != null);
}

test "rank: SYNAPSE_TEST_PATH_RE replaces the built-in rule" {
    // A project that names tests some other way needs one knob, not a patch.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/FooTest.java", 0, &.{"Alpha"});
    try rf.src("core/src/Probe.java", 0, &.{"Beta"});
    try rf.commit();
    try rf.fx.env.put("SYNAPSE_TEST_PATH_RE", "Probe");

    const r = try rf.run(.{ .sources = "core/src/FooTest.java\ncore/src/Probe.java\n", .pool = "crux" });
    defer gpa.free(r.out);
    try testing.expect((try rankOf(gpa, "core/src/FooTest.java", r.out)) != null);
    try testing.expect((try rankOf(gpa, "core/src/Probe.java", r.out)) == null);
}

// --- output shape --------------------------------------------------------

test "rank: --top limits each tier, and --top 0 prints everything" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    var sources: Io.Writer.Allocating = .init(gpa);
    defer sources.deinit();
    var i: usize = 1;
    while (i <= 8) : (i += 1) {
        const path = try std.fmt.allocPrint(gpa, "core/src/F{d}.java", .{i});
        defer gpa.free(path);
        const sym = try std.fmt.allocPrint(gpa, "Sym{d}", .{i});
        defer gpa.free(sym);
        try rf.src(path, 0, &.{sym});
        try sources.writer.print("{s}\n", .{path});
    }
    try rf.commit();

    const capped = try rf.run(.{ .sources = sources.written(), .top = 3 });
    defer gpa.free(capped.out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, capped.out, "code\t"));

    const all = try rf.run(.{ .sources = sources.written(), .top = 0 });
    defer gpa.free(all.out);
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, all.out, "code\t"));
}

test "rank: --tier restricts the output to one tier" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/KundeController.java", 0, &.{"Alpha"});
    try rf.plain("core/src/Kunde.gui", "x\n");
    try rf.commit();

    const code_only = try rf.run(.{ .sources = "core/src/Kunde.gui\ncore/src/KundeController.java\n", .tier = "code" });
    defer gpa.free(code_only.out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, code_only.out, "dsl\t"));

    const dsl_only = try rf.run(.{ .sources = "core/src/Kunde.gui\ncore/src/KundeController.java\n", .tier = "dsl" });
    defer gpa.free(dsl_only.out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, dsl_only.out, "code\t"));
}

test "rank: a node made entirely of config ranks nothing, and that is not a failure" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.plain("core/src/settings.properties", "a=1\n");
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/settings.properties\n" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "rank: an empty tags cache is not an error: it warns once, and every file scores zero" {
    // rank is read-only against the cache. Without a prior `vocab` call
    // there is nothing to read, and it must not tag anything to
    // compensate -- the whole point is that authoring stays a reader.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.plain("core/src/Real.java", "x\n"); // no cache entry queued at all
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Real.java\n" });
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "code\t0.000\tcore/src/Real.java\n") != null);
}

test "rank: a file the cache never held scores zero without a warning once the cache itself is non-empty" {
    // The narrower case within a warm cache: this specific source has no
    // cache entry at all (never claimed by anything), so it is an ordinary
    // per-file miss rather than a cold cache.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Known.java", 0, &.{ "Alpha", "Beta" });
    try rf.plain("core/src/Unknown.java", "x\n"); // no cache entry
    try rf.commit();

    const r = try rf.run(.{ .sources = "core/src/Known.java\ncore/src/Unknown.java\n" });
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "core/src/Unknown.java\t0.000\n") == null); // not the warning path
    try testing.expect(std.mem.indexOf(u8, r.out, "code\t0.000\tcore/src/Unknown.java") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "\tcore/src/Known.java") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "code\t0.000\tcore/src/Known.java") == null);
}

// --- --lists: both pools for every node, one repo pass -------------------

fn stageNodeList(rf: *RankFixture, nn: []const u8, paths: []const []const u8) !void {
    try rf.fx.tmp.dir.createDirPath(testing.io, "work/lists");
    var body: Io.Writer.Allocating = .init(rf.fx.gpa);
    defer body.deinit();
    for (paths) |p| try body.writer.print("{s}\n", .{p});
    const txt_path = try std.fmt.allocPrint(rf.fx.gpa, "work/lists/{s}.txt", .{nn});
    defer rf.fx.gpa.free(txt_path);
    try rf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_path, .data = body.written() });
}

fn runRankLists(rf: *RankFixture, top: usize) !RunResult {
    const lists_dir = try std.fmt.allocPrint(rf.fx.gpa, "{s}/lists", .{rf.fx.work});
    defer rf.fx.gpa.free(lists_dir);
    return rf.run(.{ .lists = lists_dir, .top = top });
}

test "rank: --lists writes both pools per node, matching what --sources produces for the same list" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Service.java", 0, &.{ "Alpha", "Beta" });
    try rf.src("core/src/ServiceTest.java", 0, &.{ "T1", "T2", "T3" });
    try rf.commit();
    try stageNodeList(&rf, "01", &.{ "core/src/Service.java", "core/src/ServiceTest.java" });

    const r = try runRankLists(&rf, 10);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const summary_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(summary_tsv);
    const crux_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.crux.tsv", gpa, .limited(1 << 20));
    defer gpa.free(crux_tsv);

    const want_summary = try rf.run(.{ .sources = "core/src/Service.java\ncore/src/ServiceTest.java\n", .pool = "summary" });
    defer gpa.free(want_summary.out);
    const want_crux = try rf.run(.{ .sources = "core/src/Service.java\ncore/src/ServiceTest.java\n", .pool = "crux" });
    defer gpa.free(want_crux.out);
    try testing.expectEqualStrings(want_summary.out, summary_tsv);
    try testing.expectEqualStrings(want_crux.out, crux_tsv);
    // And the actual behavioural claim, not just "matches itself": the test
    // is in summary, excluded from crux.
    try testing.expect(std.mem.indexOf(u8, summary_tsv, "ServiceTest.java") != null);
    try testing.expect(std.mem.indexOf(u8, crux_tsv, "ServiceTest.java") == null);
}

test "rank: --lists: the DSL index is shared across nodes without cross-contaminating them" {
    // Two unrelated module pairs, one node each. Each node's DSL rows must
    // come only from its own node's declarations, even though both are
    // matched against one repo-wide index built before either node is ranked.
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("billing/src/AdresseHandler.java", 0, &.{"Alpha"});
    try rf.plain("billing/src/Adresse.domvo", "declaration\n");
    try rf.src("shipping/src/BestellungHandler.java", 0, &.{"Beta"});
    try rf.plain("shipping/src/Bestellung.domvo", "declaration\n");
    try rf.commit();
    try stageNodeList(&rf, "01", &.{ "billing/src/Adresse.domvo", "billing/src/AdresseHandler.java" });
    try stageNodeList(&rf, "02", &.{ "shipping/src/Bestellung.domvo", "shipping/src/BestellungHandler.java" });

    const r = try runRankLists(&rf, 10);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const n1 = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(n1);
    const n2 = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/02.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(n2);
    try testing.expect(std.mem.indexOf(u8, n1, "billing/src/AdresseHandler.java") != null);
    try testing.expect(std.mem.indexOf(u8, n1, "shipping/src/BestellungHandler.java") == null);
    try testing.expect(std.mem.indexOf(u8, n2, "shipping/src/BestellungHandler.java") != null);
    try testing.expect(std.mem.indexOf(u8, n2, "billing/src/AdresseHandler.java") == null);
}

test "rank: --lists writes an empty pool file for a node with nothing to rank, rather than skipping it" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.plain("config.json", "x\n");
    try rf.commit();
    try stageNodeList(&rf, "01", &.{"config.json"});

    const r = try runRankLists(&rf, 10);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const summary_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(summary_tsv);
    const crux_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.crux.tsv", gpa, .limited(1 << 20));
    defer gpa.free(crux_tsv);
    try testing.expectEqual(@as(usize, 0), summary_tsv.len);
    try testing.expectEqual(@as(usize, 0), crux_tsv.len);
}

test "rank: --lists honours --top per file" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/A.java", 0, &.{ "A1", "A2", "A3" });
    try rf.src("core/src/B.java", 0, &.{"B1"});
    try rf.commit();
    try stageNodeList(&rf, "01", &.{ "core/src/A.java", "core/src/B.java" });

    const r = try runRankLists(&rf, 1);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const summary_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(summary_tsv);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, summary_tsv, "code\t"));
}

test "rank: --lists needs no .title file -- nothing in the ranking path reads one" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.src("core/src/Service.java", 0, &.{"Alpha"});
    try rf.commit();
    try stageNodeList(&rf, "01", &.{"core/src/Service.java"});
    try testing.expect(rf.fx.tmp.dir.access(testing.io, "work/lists/01.title", .{}) == error.FileNotFound);

    const r = try runRankLists(&rf, 10);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const summary_tsv = try rf.fx.tmp.dir.readFileAlloc(testing.io, "work/rank/01.summary.tsv", gpa, .limited(1 << 20));
    defer gpa.free(summary_tsv);
    try testing.expect(std.mem.indexOf(u8, summary_tsv, "core/src/Service.java") != null);
}

test "rank: real behavioral errors -- missing sources file, missing lists dir, empty lists dir" {
    const gpa = testing.allocator;
    var rf = try RankFixture.init(gpa);
    defer rf.deinit();
    try rf.commit();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // A sources file that does not exist on disk.
    const missing = try rank(gpa, rf.fx.io(), &rf.fx.env, .{ .sources = "/nonexistent/nope.txt", .repo = rf.fx.repo, .out_dir = rf.fx.work }, &out.writer);
    try testing.expectEqual(@as(u8, 1), missing);

    out.clearRetainingCapacity();
    const no_lists_dir = try rank(gpa, rf.fx.io(), &rf.fx.env, .{ .lists = "/nonexistent/lists", .repo = rf.fx.repo, .out_dir = rf.fx.work }, &out.writer);
    try testing.expectEqual(@as(u8, 1), no_lists_dir);

    try rf.fx.tmp.dir.createDirPath(testing.io, "work/lists-empty");
    const empty_dir = try std.fmt.allocPrint(gpa, "{s}/lists-empty", .{rf.fx.work});
    defer gpa.free(empty_dir);
    out.clearRetainingCapacity();
    const empty_lists = try rank(gpa, rf.fx.io(), &rf.fx.env, .{ .lists = empty_dir, .repo = rf.fx.repo, .out_dir = rf.fx.work }, &out.writer);
    try testing.expectEqual(@as(u8, 1), empty_lists);
}
