//! `synapse rank` -- the work half of `claude/lib/synapse/synapse-rank.sh`.
//!
//!   rank --sources <file> [--repo <path>] [--top N] [--tier code|dsl] [--pool summary|crux]
//!
//! Prints `tier <TAB> score <TAB> path`, ranked within each tier, code first.
//! Counts per tier go to stderr, so a node whose files all scored zero is a
//! number rather than an empty answer.
//!
//! ## Threaded, on the strength of the measurement `vocab` produced
//!
//! Same shape as `vocab` and for the same reason: the cost here is tagging, which
//! is real per-file CPU work, so the script's `xargs -P` chunking was buying
//! parallelism rather than amortising startup. `vocab` measured that directly --
//! 1987ms twelve-process, 4453ms sequential in-process, 1142ms threaded -- so this
//! one goes straight to threads instead of re-deriving the same answer. One thread
//! per core, each with its own extractor, each counting definitions for its own
//! slice; the merge is a sum.
//!
//! What disappears is the apparatus: `split`, the generated `worker.sh`, `xargs`,
//! a `synapse tags` spawn per chunk, the `.tags` intermediates, the batched
//! `stat`, and four `awk` programs. Definitions are counted as the tags arrive
//! and never written down -- the script's own note about ~942 MB of tags applies
//! here too.
//!
//! ## The two tiers answer different questions
//!
//! `code` is definitions per KB: not raw counts, which rank generated constant
//! tables first. `dsl` ranks the code that *consumes* a declaration, because a
//! declarative file carries little meaning on its own. Both rules live in
//! `core/rank.zig`; this file supplies the definitions, the sizes and the repo's
//! own code list.

const std = @import("std");
const core = @import("core");
const treesitter = @import("treesitter");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var sources: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var top: usize = 10;
    var tier: ?[]const u8 = null;
    var pool: []const u8 = "summary";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sources")) {
            sources = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--top")) {
            top = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--tier")) {
            tier = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--pool")) {
            pool = args.next() orelse return usage();
        } else return usage();
    }

    const sources_path = sources orelse return usage();
    if (tier) |t| {
        if (!std.mem.eql(u8, t, "code") and !std.mem.eql(u8, t, "dsl")) return usage();
    }
    const crux = if (std.mem.eql(u8, pool, "crux"))
        true
    else if (std.mem.eql(u8, pool, "summary"))
        false
    else
        return usage();
    // A crux is code, so the DSL tier has nothing to contribute to it. Forced
    // here rather than checked at every use, so the two selectors cannot
    // disagree.
    const want = if (crux) "code" else tier;

    const cwd = Io.Dir.cwd();
    const listing = cwd.readFileAlloc(io, sources_path, gpa, .limited(64 << 20)) catch {
        std.debug.print("synapse-rank: no such sources file: {s}\n", .{sources_path});
        return 1;
    };
    defer gpa.free(listing);

    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("synapse-rank: not inside a git repo\n", .{});
        return 1;
    }

    const home = env.get("HOME") orelse return 1;
    const registry_path = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("synapse-rank: cannot read the grammar registry\n", .{});
        return 1;
    };
    defer registry.deinit();
    const grammars_dir = if (env.get("SYNAPSE_GRAMMARS_DIR")) |d|
        try gpa.dupe(u8, d)
    else
        try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
    defer gpa.free(grammars_dir);

    const usable = try registry.usableExtensions(gpa);
    defer gpa.free(usable);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `sort -u` then drop blanks: the script's first two pipeline stages, and the
    // order matters only in that duplicates must not double-count a file.
    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var it = std.mem.splitScalar(u8, listing, '\n');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t\r");
            if (p.len == 0) continue;
            if ((try seen.getOrPut(arena, p)).found_existing) continue;
            try all.append(arena, p);
        }
        std.mem.sort([]const u8, all.items, {}, lessByBytes);
    }

    var code: std.ArrayListUnmanaged([]const u8) = .empty;
    var noncode: std.ArrayListUnmanaged([]const u8) = .empty;
    for (all.items) |p| {
        if (usable.len != 0 and hasUsableExtension(p, usable))
            try code.append(arena, p)
        else
            try noncode.append(arena, p);
    }

    // Tests leave the crux pool. The built-in rule is `core.rank.isTest`; an
    // override is one ERE the user wrote, so it keeps `grep -E`, the engine it
    // was written against.
    var tests_dropped: usize = 0;
    if (crux) {
        const override = env.get("SYNAPSE_TEST_PATH_RE");
        var impl: std.ArrayListUnmanaged([]const u8) = .empty;
        if (override) |re| {
            const kept = try filterOutMatching(gpa, io, arena, code.items, re);
            impl = kept;
        } else {
            for (code.items) |p| {
                if (!core.rank.isTest(p)) try impl.append(arena, p);
            }
        }
        tests_dropped = code.items.len - impl.items.len;
        code = impl;
    }

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    const code_rows = try rankCode(Ex, gpa, io, arena, env, registry, grammars_dir, root, code.items);
    const dsl_rows = if (usable.len != 0 and noncode.items.len != 0)
        try rankDsl(gpa, io, arena, root, noncode.items, usable)
    else
        &[_]Row{};

    const dsl_only = want != null and std.mem.eql(u8, want.?, "dsl");
    const code_only = want != null and std.mem.eql(u8, want.?, "code");
    if (!dsl_only) try emit(&out.interface, code_rows, top, .code);
    if (!code_only) try emit(&out.interface, dsl_rows, top, .dsl);
    try out.interface.flush();

    std.debug.print(
        "synapse-rank: pool {s}, {d} sources -> code {d}, dsl-consumers {d}, unranked {d}, tests-excluded {d}\n",
        .{ pool, all.items.len, code_rows.len, dsl_rows.len, noncode.items.len, tests_dropped },
    );
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse rank --sources <file> [--repo <path>] [--top N] [--tier code|dsl] [--pool summary|crux]
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

/// Definitions per KB, threaded. Every path is seeded at zero so a
/// parsed-but-empty file ranks last rather than vanishing from its tier, and a
/// file whose size cannot be read is dropped rather than scored as infinitely
/// dense.
fn rankCode(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    env: *std.process.Environ.Map,
    registry: treesitter.Registry,
    grammars_dir: []const u8,
    root: []const u8,
    paths: []const []const u8,
) ![]Row {
    if (paths.len == 0) return &[_]Row{};

    const Worker = struct {
        gpa: Allocator,
        io: Io,
        registry: treesitter.Registry,
        grammars_dir: []const u8,
        lock_tries: ?usize,
        root: []const u8,
        paths: []const []const u8,
        /// One count per path in `paths`, same order. Seeded at zero, so an
        /// untagged file is still present with a score of zero.
        defs: []usize,
        failed: bool = false,

        fn work(self: *@This()) void {
            self.run() catch {
                self.failed = true;
            };
        }

        fn run(self: *@This()) !void {
            var ex: Ex = .init(self.gpa, self.registry, self.grammars_dir);
            defer ex.deinit();
            if (self.lock_tries) |n| ex.lock_tries = n;

            const results = try ex.tagWithSpans(self.gpa, self.io, self.root, self.paths);
            defer {
                for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(self.gpa, r.tagged);
                self.gpa.free(results);
            }
            for (results, 0..) |r, i| {
                if (r != .tagged) continue;
                // Definitions, not all tags: a reference says the file USES
                // something, a definition says it DECLARES it, and a summary is
                // made of what a subsystem declares.
                for (r.tagged) |t| if (t.tag.role == .def) {
                    self.defs[i] += 1;
                };
            }
        }
    };

    const cores = std.Thread.getCpuCount() catch 4;
    const chunk = @max(200, (paths.len + cores - 1) / cores);
    const workers = @min(cores, (paths.len + chunk - 1) / chunk);

    const defs = try arena.alloc(usize, paths.len);
    @memset(defs, 0);

    const lock_tries: ?usize = if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |s|
        std.fmt.parseInt(usize, s, 10) catch 300
    else
        null;

    const slots = try gpa.alloc(Worker, workers);
    defer gpa.free(slots);
    const threads = try gpa.alloc(std.Thread, workers);
    defer gpa.free(threads);

    var assigned: usize = 0;
    for (slots, 0..) |*w, i| {
        const take = if (i + 1 == workers) paths.len - assigned else @min(chunk, paths.len - assigned);
        w.* = .{
            .gpa = gpa,
            .io = io,
            .registry = registry,
            .grammars_dir = grammars_dir,
            .lock_tries = lock_tries,
            .root = root,
            .paths = paths[assigned .. assigned + take],
            .defs = defs[assigned .. assigned + take],
        };
        assigned += take;
    }
    for (threads, slots) |*th, *w| th.* = try std.Thread.spawn(.{}, Worker.work, .{w});
    for (threads) |th| th.join();
    for (slots) |*w| if (w.failed) {
        std.debug.print("synapse-rank: a tagging worker failed\n", .{});
        return error.TaggingFailed;
    };

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (paths, defs) |p, n| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
        const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        if (st.size == 0) continue;
        // Rounded to three decimals *before* sorting, not after. The script
        // printed `%.3f` with awk and then sorted that text, so two files whose
        // true densities are 2.5481 and 2.5484 are tied for it and fall through
        // to path order. Sorting the unrounded value instead ordered them by a
        // difference the output does not show -- 78 adjacent swaps out of 1,278
        // rows on a real node, every one of them a pair with identical printed
        // scores. Formatted and parsed back rather than arithmetic, so this
        // rounds exactly the way the printed line will.
        var buf: [32]u8 = undefined;
        const shown = std.fmt.bufPrint(&buf, "{d:.3}", .{core.rank.density(n, st.size)}) catch continue;
        const rounded = std.fmt.parseFloat(f64, shown) catch continue;
        try rows.append(arena, .{ .score = rounded, .path = p });
    }
    std.mem.sort(Row, rows.items, {}, lessByScore);
    return rows.items;
}

/// Which code file consumes each declaration, and how many it serves.
///
/// Bucketed by module first, so a prefix comparison only ever runs against
/// candidates that could match. Unbucketed this is every declaration against
/// every code file in the repository -- 98k of them on a large one.
///
/// Consumers are searched repo-wide rather than within `sources`: the code that
/// uses a node's declarations is frequently the reason to read it, and is not
/// always a file the node itself owns.
fn rankDsl(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    root: []const u8,
    declarations: []const []const u8,
    usable: []const []const u8,
) ![]Row {
    const listed = adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{
        .cwd = .{ .path = root },
    }) catch return &[_]Row{};
    defer listed.deinit(gpa);
    if (!listed.ok()) return &[_]Row{};

    var by_module: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(core.rank.Key)) = .empty;
    var it = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trimEnd(u8, raw, "\r");
        if (p.len == 0) continue;
        if (!hasUsableExtension(p, usable)) continue;
        const owned = try arena.dupe(u8, p);
        const key = core.rank.keyOf(owned);
        const gop = try by_module.getOrPut(arena, key.module);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, key);
    }

    var served: std.StringHashMapUnmanaged(usize) = .empty;
    for (declarations) |d| {
        const dk = core.rank.keyOf(d);
        if (dk.stem.len < core.rank.min_stem) continue;
        const candidates = by_module.get(dk.module) orelse continue;
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
