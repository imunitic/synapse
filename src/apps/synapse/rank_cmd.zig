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
    const registry_path = (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-grammars.conf")) orelse
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

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    const code_rows = try rankCode(io, arena, &cache, root, code.items);
    // dsl_rows computed only when it could be emitted, not wastefully for a
    // crux pool (which forces `want` to "code" and never prints them).
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

/// A `core.conf.Vars` over this process's environment. Indirection exists
/// because `core` may not name `std.process` (`ci/check-layering.sh`).
fn envVars(env: *std.process.Environ.Map) core.conf.Vars {
    return .{ .ctx = @ptrCast(env), .getFn = envLookup };
}

fn envLookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const env: *std.process.Environ.Map = @ptrCast(@alignCast(ctx));
    return env.get(name);
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
