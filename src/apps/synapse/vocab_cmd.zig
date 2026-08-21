//! `synapse vocab` -- the work half of `claude/lib/synapse/synapse-vocab.sh`.
//!
//!   vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>] [--lists <dir>]
//!        [--distinctive-top N] [--distinctive-k N]
//!
//! Writes six tables into `<out>`, all keyed by the same group:
//!
//!   counts.tsv        group <TAB> file count                          count descending
//!   groupwords.tsv    group <TAB> word <TAB> count                    group, then count desc
//!   groupexts.tsv     group <TAB> kind <TAB> count                    group, then count desc
//!   namespaces.tsv    group <TAB> namespace <TAB> agree <TAB> total   group ascending
//!   parseable.tsv     group <TAB> parseable <TAB> total               group ascending
//!   distinctive.tsv   group <TAB> distinctive <TAB> considered        group first-appearance
//!
//! Prints groups / files / code files / pairs on stderr, so a repo that
//! yielded no vocabulary is a number, not an unnoticed empty file.
//!
//! `distinctive.tsv` (synapse-001 step 8) scores each group's top terms via
//! `core.gate.judgeDistinctiveness`'s saturation curve
//! (`distinctiveness = D / (D + df)`, `D = max(2, N/K)`) -- deliberately a
//! different function from `synapse gate`'s own calibrated cliff, so this
//! pre-clustering evidence path can never perturb that verdict.
//! `--distinctive-top`/`--distinctive-k` default to 8/20, matching `judge`'s
//! own `--top`.
//!
//! `parseable.tsv` (synapse-001 step 7) is `code.items`' membership per
//! group, so `synapse gate --parseable` can tell "owns no vocabulary" apart
//! from "nothing in the cluster has a grammar" -- both are zero rare terms
//! otherwise. See `core/gate.zig`.
//!
//! The extension (`groupexts.tsv`) and namespace (`namespaces.tsv`) tables
//! live here, not in their own command, because they must share this file's
//! grouping map exactly -- two implementations of "which group is this path
//! in" is how a group ends up looking like it has vocabulary but no files.
//! Both are counted over every kept path, not the code subset: the
//! interesting files for `groupexts.tsv` are the ones no grammar reads, and
//! a Rust crate's namespace lives in `Cargo.toml`, untagged either way.
//! `namespaces.tsv` reads `core.namespace.Registry`
//! (`~/.claude/synapse-namespace-rules.conf`, `SYNAPSE_NAMESPACE_RULES_CONF`
//! overrides it) the same way the grammar registry works: an unconfigured
//! extension contributes nothing, and an empty registry still writes an
//! empty table rather than being skipped.
//!
//! `--chunk` is now just a files-per-batch knob: the script's `xargs -P`
//! apparatus (`split`, generated `worker.sh`, a `synapse tags`/`awk` spawn
//! per chunk) existed only to amortise process startup, which doesn't exist
//! in-process. The parallelism itself is kept -- measured, not assumed:
//! sequential in-process tagging of 3,642 files took 4453ms against the
//! bash twelve-way version's 1987ms, so twelve cores still beat one even
//! paying for twelve threads. One thread per core, each with its own
//! extractor (a `tree_sitter` parser can't be shared), tagging its own
//! slice.
//!
//! Tagging and reduction are two passes, not one, so raw tags never pile
//! up: pass one tags only what `Cache.needsTagging` says is missing,
//! committing into `_tags_cache.bin` as it goes; pass two reduces every
//! code file's vocabulary back out of the now-current cache, single
//! threaded (splitting and counting is cheap; the parse already paid the
//! real cost). This process never holds a whole repo's tags at once --
//! ~942 MB cached against 6.9 MB of vocabulary on a large repo. A pass-one
//! cache-write failure is reported but non-fatal; pass two still runs
//! against whatever the cache holds.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const treesitter = @import("treesitter");
const adapters = @import("adapters");
const enumerate_cmd = @import("enumerate_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = core.tags_cache.Cache;
const Update = core.tags_cache.Update;
const PathHash = core.tags_cache.PathHash;

pub fn run(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    trace: ?[]const u8,
) !u8 {
    var repo: ?[]const u8 = null;
    var depth: usize = 2;
    var out_dir: ?[]const u8 = null;
    var lists: ?[]const u8 = null;
    var chunk: ?usize = null;
    var distinctive_top: usize = 8;
    var distinctive_k: usize = 20;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        const value = struct {
            fn next(it: *std.process.Args.Iterator) ?[]const u8 {
                return it.next();
            }
        };
        if (std.mem.eql(u8, arg, "--repo")) {
            repo = value.next(args) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = value.next(args) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists = value.next(args) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--depth")) {
            const raw = value.next(args) orelse return usage();
            depth = std.fmt.parseInt(usize, raw, 10) catch return usage();
            if (depth < 1) return usage();
        } else if (std.mem.eql(u8, arg, "--chunk")) {
            const raw = value.next(args) orelse return usage();
            chunk = std.fmt.parseInt(usize, raw, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--distinctive-top")) {
            const raw = value.next(args) orelse return usage();
            distinctive_top = std.fmt.parseInt(usize, raw, 10) catch return usage();
            if (distinctive_top < 1) return usage();
        } else if (std.mem.eql(u8, arg, "--distinctive-k")) {
            const raw = value.next(args) orelse return usage();
            distinctive_k = std.fmt.parseInt(usize, raw, 10) catch return usage();
            if (distinctive_k < 1) return usage();
        } else return usage();
    }

    const cwd = Io.Dir.cwd();

    // Keyed on the repo being read, not where the command was run from.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (out_dir == null and env.get("SYNAPSE_WORK_DIR") == null) {
        derived = try context.workDirFor(gpa, io, env, repo orelse ".", "synapse-vocab");
    }
    const out = out_dir orelse env.get("SYNAPSE_WORK_DIR") orelse
        if (derived) |d| d.path else {
        std.debug.print("synapse-vocab: no --out and no SYNAPSE_WORK_DIR\n", .{});
        return 1;
    };
    cwd.createDirPath(io, out) catch {
        std.debug.print("synapse-vocab: cannot write {s}\n", .{out});
        return 1;
    };

    if (lists) |dir| {
        cwd.access(io, dir, .{}) catch {
            std.debug.print("synapse-vocab: no such lists dir: {s}\n", .{dir});
            return 1;
        };
    }

    // `--repo` is a directory to work in, not a prefix to join -- every list
    // path is repo-relative.
    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("synapse-vocab: not inside a git repo\n", .{});
        return 1;
    }

    const home = env.get("HOME") orelse return 1;
    const registry_path = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(registry_path);
    var registry = treesitter.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("synapse-vocab: cannot read the grammar registry\n", .{});
        return 1;
    };
    defer registry.deinit();

    const grammars_dir = if (env.get("SYNAPSE_GRAMMARS_DIR")) |d|
        try gpa.dupe(u8, d)
    else
        try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
    defer gpa.free(grammars_dir);

    const kind_rules_path = if (env.get("SYNAPSE_KIND_SYNONYMS_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-kind-synonyms.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-kind-synonyms.conf", .{home});
    defer gpa.free(kind_rules_path);
    var kind_rules = core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path) catch {
        std.debug.print("synapse-vocab: cannot read the kind-synonyms registry\n", .{});
        return 1;
    };
    defer kind_rules.deinit();

    const usable = try registry.usableExtensions(gpa);
    defer gpa.free(usable);

    // Same discovery contract as the grammar registry: absent means
    // "nothing configured yet," not an error.
    const ns_rules_path = if (env.get("SYNAPSE_NAMESPACE_RULES_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-namespace-rules.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-namespace-rules.conf", .{home});
    defer gpa.free(ns_rules_path);
    var ns_registry = core.namespace.Registry.load(gpa, io, ns_rules_path) catch {
        std.debug.print("synapse-vocab: cannot read the namespace-rules registry\n", .{});
        return 1;
    };
    defer ns_registry.deinit();

    return build(Ex, gpa, io, env, registry, grammars_dir, kind_rules, ns_registry, trace, .{
        .root = root,
        .out = out,
        .depth = depth,
        .lists = lists,
        .usable = usable,
        .chunk = chunk,
        .distinctive_top = distinctive_top,
        .distinctive_k = distinctive_k,
    });
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>] [--lists <dir>]
        \\                     [--distinctive-top N] [--distinctive-k N]
        \\
    , .{});
    return 2;
}

pub const Options = struct {
    root: []const u8,
    out: []const u8,
    depth: usize,
    lists: ?[]const u8,
    usable: []const []const u8,
    chunk: ?usize,
    /// Terms per group and the saturation curve's scaling constant -- see
    /// `core.gate.DistinctivenessOptions`.
    distinctive_top: usize,
    distinctive_k: usize,
};

fn repoRoot(gpa: Allocator, io: Io, repo: ?[]const u8) ![]u8 {
    const res = adapters.process.run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" }, .{
        .cwd = if (repo) |r| .{ .path = r } else .inherit,
    }) catch return gpa.dupe(u8, "");
    defer res.deinit(gpa);
    if (!res.ok()) return gpa.dupe(u8, "");
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

/// `group <TAB> word` counted, and the file counts alongside it. A path
/// claimed by two node lists counts under both -- a manifest may
/// legitimately overlap.
pub fn build(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    registry: treesitter.Registry,
    grammars_dir: []const u8,
    kind_rules: core.kind_synonyms.RuleList,
    ns_registry: core.namespace.Registry,
    trace: ?[]const u8,
    opts: Options,
) !u8 {
    const cwd = Io.Dir.cwd();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every tracked path, minus the user's own exclusions -- the same knobs
    // the graph itself honours.
    const listed = try adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{
        .cwd = .{ .path = opts.root },
    });
    defer listed.deinit(gpa);
    if (!listed.ok()) {
        std.debug.print("synapse-vocab: git ls-files failed in {s}\n", .{opts.root});
        return 1;
    }
    const kept_text = try enumerate_cmd.applyUserPatterns(gpa, io, env, listed.stdout);
    defer if (kept_text.ptr != listed.stdout.ptr) gpa.free(kept_text);

    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, kept_text, '\n');
    while (lines.next()) |p| {
        if (p.len != 0) try kept.append(arena, p);
    }

    // path -> groups it belongs to. With `--lists`, every node title
    // claiming it; otherwise the one directory prefix.
    var groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    var counts: std.StringHashMapUnmanaged(usize) = .empty;

    if (opts.lists) |dir| {
        const pairs = try readLists(arena, io, dir);
        if (pairs == 0) {
            std.debug.print("synapse-vocab: no NN.txt/NN.title pairs in {s}\n", .{dir});
            return 1;
        }
        try mapFromLists(arena, io, dir, &groups, &counts);
        // Narrowed to what some list claims -- an unowned file's vocabulary
        // has nowhere to go.
        var narrowed: std.ArrayListUnmanaged([]const u8) = .empty;
        for (kept.items) |p| {
            if (groups.contains(p)) try narrowed.append(arena, p);
        }
        kept = narrowed;
    } else {
        for (kept.items) |p| {
            const g = core.vocab.groupOf(p, opts.depth);
            const gop = try groups.getOrPut(arena, p);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, g);
            const c = try counts.getOrPut(arena, g);
            if (!c.found_existing) c.value_ptr.* = 0;
            c.value_ptr.* += 1;
        }
    }

    try writeCounts(gpa, io, opts.out, &counts);

    // Off the same `groups` map, so keys agree with counts.tsv by
    // construction. Over every kept path, not just `code` below -- a group
    // that's 60% JSON/.bpmn/.sql is telling you something a module name
    // can't, and needs no tagging either way.
    var mix: std.StringHashMapUnmanaged(usize) = .empty;
    for (kept.items) |p| {
        const in = groups.get(p) orelse continue;
        const kind = try core.vocab.artifactOf(arena, p);
        for (in.items) |g| {
            const key = try std.fmt.allocPrint(arena, "{s}\t{s}", .{ g, kind });
            const e = try mix.getOrPut(arena, key);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
    }
    const groupexts_path = try std.fmt.allocPrint(gpa, "{s}/groupexts.tsv", .{opts.out});
    defer gpa.free(groupexts_path);
    gpa.free(try writeGroupTable(gpa, io, groupexts_path, &mix));

    // Does a Java `package`/Rust crate `name` match the group its path is
    // in. An empty registry still writes an empty table, never skipped.
    const namespaces_path = try std.fmt.allocPrint(gpa, "{s}/namespaces.tsv", .{opts.out});
    defer gpa.free(namespaces_path);
    try writeNamespaceDivergence(gpa, arena, io, opts.root, kept.items, &groups, ns_registry, namespaces_path);

    // The code subset: a usable grammar, and not machine output that happens
    // to end in a code extension (`core.enumerate.isNoise`). `parseable` is
    // counted in the same pass, off the same membership.
    var code: std.ArrayListUnmanaged([]const u8) = .empty;
    var parseable_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (kept.items) |p| {
        if (core.enumerate.isNoise(p)) continue;
        if (!hasUsableExtension(p, opts.usable)) continue;
        try code.append(arena, p);
        if (groups.get(p)) |path_groups| {
            for (path_groups.items) |g| {
                const gop = try parseable_counts.getOrPut(arena, g);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }
    const parseable_path = try std.fmt.allocPrint(gpa, "{s}/parseable.tsv", .{opts.out});
    defer gpa.free(parseable_path);
    try writeParseableShare(gpa, io, &counts, &parseable_counts, parseable_path);

    const groupwords_path = try std.fmt.allocPrint(gpa, "{s}/groupwords.tsv", .{opts.out});
    defer gpa.free(groupwords_path);

    if (code.items.len == 0) {
        try cwd.writeFile(io, .{ .sub_path = groupwords_path, .data = "" });
        std.debug.print(
            "synapse-vocab: no files with a supported grammar -- use synapse-orientation instead\n",
            .{},
        );
        return 0;
    }

    const stopwords = try loadStopwords(arena, io, env);

    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{opts.out});
    defer gpa.free(cache_path);
    var cache = try Cache.open(io, cache_path);
    defer cache.close(io);

    // Pass one: tag only what the cache doesn't already hold at its current
    // hash. Each path is hashed once, in parallel; the hash is reused for
    // the freshness check and, if needed, as the cache entry's own hash.
    const hashes = try parallelHash(gpa, io, opts.root, code.items);
    defer gpa.free(hashes);

    var requested = try gpa.alloc(PathHash, code.items.len);
    defer gpa.free(requested);
    var requested_len: usize = 0;
    for (code.items, hashes) |p, h| {
        const hv = h orelse continue; // unreadable now (deleted, submodule gitlink): left out entirely
        requested[requested_len] = .{ .path = p, .hash = hv };
        requested_len += 1;
    }

    const need = try cache.needsTagging(gpa, requested[0..requested_len]);
    defer gpa.free(need);

    if (need.len != 0) {
        try writeTrace(io, trace, need);

        const cores = std.Thread.getCpuCount() catch 4;
        // One chunk per core, floor 500: sized off the shortfall, not the
        // whole code subset, so a warm cache spawns little.
        const chunk = opts.chunk orelse @max(500, (need.len + cores - 1) / cores);
        const workers = @min(cores, (need.len + chunk - 1) / chunk);

        const Worker = struct {
            // Nothing shared but immutable inputs -- a tree_sitter parser
            // can't be shared, so each thread gets its own extractor; the
            // commit is single-threaded afterwards.
            gpa: Allocator,
            io: Io,
            registry: treesitter.Registry,
            grammars_dir: []const u8,
            kind_rules: core.kind_synonyms.RuleList,
            lock_tries: ?usize,
            query_override_dir: ?[]const u8,
            root: []const u8,
            items: []const PathHash,
            /// One `Update` per tagged file, for the caller's commit once
            /// every thread joins. `path`/`entry.hash` borrow `self.items`;
            /// `entry.tags` borrows `cache_rendered`, not its own copy.
            cache_updates: std.ArrayListUnmanaged(Update) = .empty,
            /// Owned, untrimmed buffers `cache_updates[i].entry.tags` points
            /// into (a trimmed slice of one). Kept separate so freeing a
            /// trimmed slice at the wrong length can't happen.
            cache_rendered: std.ArrayListUnmanaged([]u8) = .empty,
            failed: bool = false,

            fn work(self: *@This()) void {
                self.run() catch {
                    self.failed = true;
                };
            }

            fn run(self: *@This()) !void {
                var ex: Ex = .init(self.gpa, self.registry, self.grammars_dir, self.kind_rules);
                defer ex.deinit();
                if (self.lock_tries) |n| ex.lock_tries = n;
                ex.query_override_dir = self.query_override_dir;

                var paths = try self.gpa.alloc([]const u8, self.items.len);
                defer self.gpa.free(paths);
                for (self.items, 0..) |ph, i| paths[i] = ph.path;

                const results = try ex.tagWithSpans(self.gpa, self.io, self.root, paths);
                defer {
                    for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(self.gpa, r.tagged);
                    self.gpa.free(results);
                }

                for (self.items, results) |ph, r| {
                    switch (r) {
                        .tagged => |tagged| {
                            var buf: std.Io.Writer.Allocating = .init(self.gpa);
                            for (tagged) |t| try treesitter.tagger.renderCliLine(&buf.writer, t.tag, t.span);
                            const text = try buf.toOwnedSlice();
                            try self.cache_rendered.append(self.gpa, text);
                            try self.cache_updates.append(self.gpa, .{
                                .path = ph.path,
                                .entry = .{ .hash = ph.hash, .tags = std.mem.trimEnd(u8, text, "\n") },
                            });
                        },
                        .unsupported => try self.cache_updates.append(self.gpa, .{
                            .path = ph.path,
                            .entry = .{ .hash = ph.hash, .tags = "", .unsupported = true },
                        }),
                    }
                }
            }
        };

        const lock_tries: ?usize = if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |s|
            std.fmt.parseInt(usize, s, 10) catch treesitter.grammar.default_lock_tries
        else
            null;
        const query_override_dir = env.get("SYNAPSE_GRAMMARS_QUERY_PATH");

        const slots = try gpa.alloc(Worker, workers);
        defer gpa.free(slots);
        const threads = try gpa.alloc(std.Thread, workers);
        defer gpa.free(threads);

        var assigned: usize = 0;
        for (slots, 0..) |*w, i| {
            const take = if (i + 1 == workers) need.len - assigned else @min(chunk, need.len - assigned); // last worker takes the remainder
            w.* = .{
                .gpa = gpa,
                .io = io,
                .registry = registry,
                .grammars_dir = grammars_dir,
                .kind_rules = kind_rules,
                .lock_tries = lock_tries,
                .query_override_dir = query_override_dir,
                .root = opts.root,
                .items = need[assigned .. assigned + take],
            };
            assigned += take;
        }

        for (threads, slots) |*th, *w| th.* = try std.Thread.spawn(.{}, Worker.work, .{w});
        for (threads) |th| th.join();

        defer for (slots) |*w| {
            for (w.cache_rendered.items) |t| gpa.free(t);
            w.cache_rendered.deinit(gpa);
            w.cache_updates.deinit(gpa);
        };

        for (slots) |*w| {
            if (w.failed) {
                std.debug.print("synapse-vocab: a tagging worker failed\n", .{});
                return 1;
            }
        }

        // One commit for every worker's updates. Non-fatal: counts.tsv/
        // groupexts.tsv are already on disk, and pass two still runs against
        // whatever the cache holds.
        var cache_total: usize = 0;
        for (slots) |*w| cache_total += w.cache_updates.items.len;
        if (cache_total != 0) {
            var updates = try gpa.alloc(Update, cache_total);
            defer gpa.free(updates);
            var n: usize = 0;
            for (slots) |*w| {
                for (w.cache_updates.items) |u| {
                    updates[n] = u;
                    n += 1;
                }
            }
            _ = cache.commit(gpa, io, updates, &.{}) catch
                std.debug.print("synapse-vocab: tags cache write failed (non-fatal)\n", .{});
        }
    }

    // Pass two: every code file's vocabulary, from the cache pass one just
    // made current. Single-threaded -- a memory-mapped lookup and string
    // split aren't worth a thread pool.
    var pairs: std.StringHashMapUnmanaged(usize) = .empty;
    {
        var words: std.ArrayListUnmanaged([]u8) = .empty;
        defer words.deinit(gpa);
        for (code.items) |path| {
            const path_groups = groups.get(path) orelse continue;
            const entry = cache.get(path) orelse continue;
            if (entry.unsupported) continue;
            var tag_lines = std.mem.splitScalar(u8, entry.tags, '\n');
            while (tag_lines.next()) |line| {
                const tag = core.tag_line.parse(line) orelse continue;
                words.clearRetainingCapacity();
                defer for (words.items) |w| gpa.free(w);
                try core.vocab.splitWords(gpa, tag.name, &words);
                for (words.items) |w| {
                    if (!core.vocab.keep(w, &stopwords)) continue;
                    for (path_groups.items) |g| {
                        const key = try std.fmt.allocPrint(arena, "{s}\t{s}", .{ g, w });
                        const gop = try pairs.getOrPut(arena, key);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
            }
        }
    }

    const groupwords_text = try writeGroupTable(gpa, io, groupwords_path, &pairs);
    defer gpa.free(groupwords_text);

    var distinctiveness = try core.gate.judgeDistinctiveness(gpa, groupwords_text, .{
        .top = opts.distinctive_top,
        .k = opts.distinctive_k,
    });
    defer distinctiveness.deinit(gpa);
    const distinctive_path = try std.fmt.allocPrint(gpa, "{s}/distinctive.tsv", .{opts.out});
    defer gpa.free(distinctive_path);
    {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        for (distinctiveness.items) |r| try core.gate.writeDistinctiveness(&body.writer, r);
        try cwd.writeFile(io, .{ .sub_path = distinctive_path, .data = body.written() });
    }

    std.debug.print("synapse-vocab: groups {d}, files {d}, code {d}, pairs {d} -> {s}\n", .{
        counts.count(),
        kept.items.len,
        code.items.len,
        pairs.count(),
        opts.out,
    });
    return 0;
}

/// The record `synapse-fake` writes so a test can assert N files, no more,
/// reached the extractor -- shared shape with `tags`/`tags-cache`'s own
/// `writeTrace`, not shared code.
fn writeTrace(io: Io, trace: ?[]const u8, items: []const PathHash) !void {
    const path = trace orelse return;
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    w.pos = (try f.stat(io)).size;
    try w.interface.writeAll("tags");
    for (items) |it| try w.interface.print(" {s}", .{it.path});
    try w.interface.writeAll("\n");
    for (items) |it| try w.interface.print("path {s}\n", .{it.path});
    try w.interface.flush();
}

/// Every path's current blob hash, computed in parallel -- a plain read and
/// SHA1, not a tree-sitter parse, needed by pass one to ask the cache
/// what's stale.
fn parallelHash(gpa: Allocator, io: Io, root: []const u8, paths: []const []const u8) ![]?[20]u8 {
    const out = try gpa.alloc(?[20]u8, paths.len);
    errdefer gpa.free(out);

    const cores = std.Thread.getCpuCount() catch 4;
    const chunk = @max(500, (paths.len + cores - 1) / cores);
    const workers = @min(cores, (paths.len + chunk - 1) / chunk);

    const Job = struct {
        gpa: Allocator,
        io: Io,
        root: []const u8,
        paths: []const []const u8,
        out: []?[20]u8,

        fn work(self: *@This()) void {
            for (self.paths, 0..) |p, i| self.out[i] = hashOf(self.gpa, self.io, self.root, p);
        }
    };

    if (workers <= 1) {
        var job: Job = .{ .gpa = gpa, .io = io, .root = root, .paths = paths, .out = out };
        job.work();
        return out;
    }

    const jobs = try gpa.alloc(Job, workers);
    defer gpa.free(jobs);
    const threads = try gpa.alloc(std.Thread, workers);
    defer gpa.free(threads);

    var assigned: usize = 0;
    for (jobs, 0..) |*j, i| {
        const take = if (i + 1 == workers) paths.len - assigned else @min(chunk, paths.len - assigned);
        j.* = .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .paths = paths[assigned .. assigned + take],
            .out = out[assigned .. assigned + take],
        };
        assigned += take;
    }
    for (threads, jobs) |*th, *j| th.* = try std.Thread.spawn(.{}, Job.work, .{j});
    for (threads) |th| th.join();
    return out;
}

/// Blob hash of a repo file, or null if unreadable right now (deleted,
/// submodule gitlink).
fn hashOf(gpa: Allocator, io: Io, root: []const u8, path: []const u8) ?[20]u8 {
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, path }) catch return null;
    defer gpa.free(full);
    const content = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 << 20)) catch return null;
    defer gpa.free(content);
    return core.verify.blobHashRaw(content);
}

fn hasUsableExtension(path: []const u8, usable: []const []const u8) bool {
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| path[at + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    const ext = name[dot + 1 ..];
    for (usable) |u| if (std.mem.eql(u8, ext, u)) return true;
    return false;
}

/// How many `NN.txt`/`NN.title` pairs a lists dir holds.
fn readLists(arena: Allocator, io: Io, dir: []const u8) !usize {
    var found: usize = 0;
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const txt = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.txt", .{ dir, n });
        const title = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.title", .{ dir, n });
        const has_txt = Io.Dir.cwd().access(io, txt, .{}) != error.FileNotFound;
        const has_title = Io.Dir.cwd().access(io, title, .{}) != error.FileNotFound;
        if (has_txt and has_title) found += 1;
    }
    return found;
}

fn mapFromLists(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    groups: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    counts: *std.StringHashMapUnmanaged(usize),
) !void {
    const cwd = Io.Dir.cwd();
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const txt_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.txt", .{ dir, n });
        const title_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.title", .{ dir, n });
        const title_raw = cwd.readFileAlloc(io, title_path, arena, .limited(64 << 10)) catch continue;
        const title = std.mem.trim(u8, firstLine(title_raw), " \t\r");
        if (title.len == 0) continue;
        const body = cwd.readFileAlloc(io, txt_path, arena, .limited(64 << 20)) catch continue;

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const p = std.mem.trimEnd(u8, raw, "\r");
            if (p.len == 0) continue;
            const gop = try groups.getOrPut(arena, p);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, title);
            // Off the list rows, not the narrowed path set -- a path claimed
            // by two nodes counts once under each.
            const c = try counts.getOrPut(arena, title);
            if (!c.found_existing) c.value_ptr.* = 0;
            c.value_ptr.* += 1;
        }
    }
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

fn loadStopwords(
    arena: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    const home = env.get("HOME") orelse return set;
    const path = (try core.conf.resolveConfPath(arena, io, adapters.env.vars(env), "synapse-prompt-stopwords.conf")) orelse
        try std.fmt.allocPrint(arena, "{s}/.claude/synapse-prompt-stopwords.conf", .{home});
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return set;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const lowered = try arena.alloc(u8, line.len);
        for (line, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
        try set.put(arena, lowered, {});
    }
    return set;
}

const CountRow = struct { group: []const u8, count: usize };

/// `group <TAB> count`, count descending then group ascending -- the script's
/// `sort -k2,2nr -k1,1`.
fn writeCounts(
    gpa: Allocator,
    io: Io,
    out: []const u8,
    counts: *std.StringHashMapUnmanaged(usize),
) !void {
    var rows = try gpa.alloc(CountRow, counts.count());
    defer gpa.free(rows);
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |e| : (i += 1) rows[i] = .{ .group = e.key_ptr.*, .count = e.value_ptr.* };
    std.mem.sort(CountRow, rows, {}, struct {
        fn less(_: void, a: CountRow, b: CountRow) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.group, b.group) == .lt;
        }
    }.less);

    const path = try std.fmt.allocPrint(gpa, "{s}/counts.tsv", .{out});
    defer gpa.free(path);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{d}\n", .{ r.group, r.count });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

/// `group <TAB> parseable <TAB> total`, group ascending. One row per group
/// `counts` knows about, including zero-parseable groups -- the exact row
/// `synapse gate --parseable` looks for.
fn writeParseableShare(
    gpa: Allocator,
    io: Io,
    counts: *const std.StringHashMapUnmanaged(usize),
    parseable_counts: *const std.StringHashMapUnmanaged(usize),
    path: []const u8,
) !void {
    const Row = struct { group: []const u8, parseable: usize, total: usize };
    var rows = try gpa.alloc(Row, counts.count());
    defer gpa.free(rows);
    var i: usize = 0;
    var it = counts.iterator();
    while (it.next()) |e| : (i += 1) {
        rows[i] = .{
            .group = e.key_ptr.*,
            .parseable = parseable_counts.get(e.key_ptr.*) orelse 0,
            .total = e.value_ptr.*,
        };
    }
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return std.mem.order(u8, a.group, b.group) == .lt;
        }
    }.less);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{d}\t{d}\n", .{ r.group, r.parseable, r.total });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

const PairRow = struct { key: []const u8, count: usize };

/// `group <TAB> thing <TAB> count`, group ascending then count descending.
/// Shared by `groupwords.tsv` and `groupexts.tsv`. Returns the bytes written
/// too, owned by the caller -- `groupwords.tsv`'s call site reuses them for
/// `judgeDistinctiveness` with no disk round-trip.
fn writeGroupTable(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    pairs: *std.StringHashMapUnmanaged(usize),
) ![]u8 {
    var rows = try gpa.alloc(PairRow, pairs.count());
    defer gpa.free(rows);
    var i: usize = 0;
    var it = pairs.iterator();
    while (it.next()) |e| : (i += 1) rows[i] = .{ .key = e.key_ptr.*, .count = e.value_ptr.* };
    std.mem.sort(PairRow, rows, {}, struct {
        fn groupOfKey(key: []const u8) []const u8 {
            return key[0 .. std.mem.indexOfScalar(u8, key, '\t') orelse key.len];
        }
        fn less(_: void, a: PairRow, b: PairRow) bool {
            const ga = groupOfKey(a.key);
            const gb = groupOfKey(b.key);
            switch (std.mem.order(u8, ga, gb)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.key, b.key) == .lt; // total order keeps reruns byte-identical
        }
    }.less);

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{d}\n", .{ r.key, r.count });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
    return body.toOwnedSlice();
}

/// `group <TAB> namespace <TAB> agree <TAB> total`, group ascending. One row
/// per group with at least one declared namespace: the namespace most files
/// declared, how many agreed, how many counted (synapse-001 step 6). Runs
/// over `kept`, not the code subset -- a Rust crate declares its namespace
/// in `Cargo.toml`, untagged by any grammar.
fn writeNamespaceDivergence(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    groups: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    ns_registry: core.namespace.Registry,
    path: []const u8,
) !void {
    if (ns_registry.isEmpty()) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
        return;
    }

    // Build-file rule -> dir-keyed namespace map, built lazily per filename.
    var build_maps: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;

    // group -> (namespace -> file count), reduced to one row per group below.
    var by_group: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(usize)) = .empty;

    for (kept) |p| {
        const base = core.namespace.baseOf(p);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse continue;
        if (dot == 0) continue; // a leading-dot file has no extension, same rule `hasUsableExtension` uses
        const ext = base[dot + 1 ..];
        const rule = ns_registry.ruleFor(ext) orelse continue;

        const declared: ?[]const u8 = switch (rule.kind) {
            .in_file => blk: {
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
                const content = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(4 << 20)) catch break :blk null;
                break :blk core.namespace.extractField(content, rule.prefix, rule.terminator);
            },
            .build_file => blk: {
                const file_name = rule.file.?;
                const map = try buildFileMap(arena, io, root, kept, file_name, rule.prefix, rule.terminator, &build_maps);
                break :blk core.namespace.nearestNamespace(map, core.namespace.dirOf(p));
            },
        };
        const namespace = declared orelse continue;

        const path_groups = groups.get(p) orelse continue;
        for (path_groups.items) |g| {
            const gop = try by_group.getOrPut(arena, g);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const nop = try gop.value_ptr.getOrPut(arena, namespace);
            if (!nop.found_existing) nop.value_ptr.* = 0;
            nop.value_ptr.* += 1;
        }
    }

    const Row = struct { group: []const u8, namespace: []const u8, agree: usize, total: usize };
    var rows = try gpa.alloc(Row, by_group.count());
    defer gpa.free(rows);
    var i: usize = 0;
    var git = by_group.iterator();
    while (git.next()) |ge| : (i += 1) {
        var best: []const u8 = "";
        var best_count: usize = 0;
        var total: usize = 0;
        var nit = ge.value_ptr.iterator();
        while (nit.next()) |ne| {
            total += ne.value_ptr.*;
            const better = ne.value_ptr.* > best_count or
                (ne.value_ptr.* == best_count and std.mem.order(u8, ne.key_ptr.*, best) == .lt);
            if (better) {
                best = ne.key_ptr.*;
                best_count = ne.value_ptr.*;
            }
        }
        rows[i] = .{ .group = ge.key_ptr.*, .namespace = best, .agree = best_count, .total = total };
    }
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return std.mem.order(u8, a.group, b.group) == .lt;
        }
    }.less);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{s}\t{d}\t{d}\n", .{ r.group, r.namespace, r.agree, r.total });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

/// Dir-keyed namespace map for one build-file rule, memoized in `cache` so
/// a repo with many source files sharing one rule scans `kept` once.
fn buildFileMap(
    arena: Allocator,
    io: Io,
    root: []const u8,
    kept: []const []const u8,
    file_name: []const u8,
    prefix: []const u8,
    terminator: ?[]const u8,
    cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
) !*const std.StringHashMapUnmanaged([]const u8) {
    if (cache.getPtr(file_name)) |m| return m;

    var m: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (kept) |p| {
        if (!std.mem.eql(u8, core.namespace.baseOf(p), file_name)) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, p });
        const content = Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(4 << 20)) catch continue;
        const namespace = core.namespace.extractField(content, prefix, terminator) orelse continue;
        try m.put(arena, core.namespace.dirOf(p), namespace);
    }
    try cache.put(arena, file_name, m);
    return cache.getPtr(file_name).?;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");

/// A real git repo (`.java`/`.py`/`.ml` registered, matching the bats
/// fixture's own registry) plus `build()`, called directly with
/// `fake_grammar.FakeExtractor` -- avoids the real thread pool's only real
/// dependency, a usable `comptime Ex: type`, without needing a shelled-out
/// tree-sitter at all.
const VocabFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !VocabFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        try fx.writeGrammarsJson(
            \\{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
            \\ "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
            \\ "ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}
        );
        return .{ .fx = fx };
    }

    fn deinit(self: *VocabFixture) void {
        self.fx.deinit();
    }

    /// A file with one `symbol:<Name>` line per symbol -- `FakeBackend`
    /// tags FAKE_NAME plus one tag per such line, matching the bats
    /// fixture's own `src` helper.
    fn src(self: *VocabFixture, path: []const u8, symbols: []const []const u8) !void {
        var body: Io.Writer.Allocating = .init(self.fx.gpa);
        defer body.deinit();
        for (symbols) |s| try body.writer.print("symbol:{s}\n", .{s});
        try self.fx.writeRepoFile(path, body.written());
    }

    fn plain(self: *VocabFixture, path: []const u8, content: []const u8) !void {
        try self.fx.writeRepoFile(path, content);
    }

    fn writeIgnoreFiles(self: *VocabFixture, pattern: []const u8) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-ignore-files.conf",
            .data = pattern,
        });
    }

    fn writeStopwords(self: *VocabFixture, words: []const u8) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-prompt-stopwords.conf",
            .data = words,
        });
    }

    fn writeNamespaceRules(self: *VocabFixture, json: []const u8) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "home/.claude");
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "home/.claude/synapse-namespace-rules.conf",
            .data = json,
        });
    }

    /// `{nn}.txt`/`{nn}.title` under a real `lists/` dir in the fixture's
    /// work tree, matching `synapse-build-lists.sh`'s own shape.
    fn writeList(self: *VocabFixture, nn: []const u8, title: []const u8, paths: []const []const u8) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "work/lists");
        const title_sub = try std.fmt.allocPrint(self.fx.gpa, "work/lists/{s}.title", .{nn});
        defer self.fx.gpa.free(title_sub);
        const title_line = try std.fmt.allocPrint(self.fx.gpa, "{s}\n", .{title});
        defer self.fx.gpa.free(title_line);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = title_sub, .data = title_line });

        var body: Io.Writer.Allocating = .init(self.fx.gpa);
        defer body.deinit();
        for (paths) |p| try body.writer.print("{s}\n", .{p});
        const txt_sub = try std.fmt.allocPrint(self.fx.gpa, "work/lists/{s}.txt", .{nn});
        defer self.fx.gpa.free(txt_sub);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_sub, .data = body.written() });
    }

    fn listsDir(self: *VocabFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/lists", .{self.fx.work});
    }

    fn commit(self: *VocabFixture) !void {
        try self.fx.gitCommit("fixture");
    }

    const RunOpts = struct {
        depth: usize = 2,
        lists: ?[]const u8 = null,
        chunk: ?usize = null,
        distinctive_top: usize = 8,
        distinctive_k: usize = 20,
        trace: ?[]const u8 = null,
    };

    /// Loads a fresh registry/kind-rules/namespace-registry from the
    /// fixture's HOME and calls `build` directly -- the same setup `run()`
    /// itself does after its own arg parsing, minus the CLI layer.
    fn run(self: *VocabFixture, opts: RunOpts) !u8 {
        const gpa = self.fx.gpa;
        const registry_path = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{self.fx.home});
        defer gpa.free(registry_path);
        var registry = try treesitter.Registry.load(gpa, self.fx.io(), registry_path);
        defer registry.deinit();
        const usable = try registry.usableExtensions(gpa);
        defer gpa.free(usable);

        var kind_rules = try core.kind_synonyms.RuleList.load(gpa, self.fx.io(), "/nonexistent");
        defer kind_rules.deinit();

        const ns_path = if (self.fx.env.get("SYNAPSE_NAMESPACE_RULES_CONF")) |p|
            try gpa.dupe(u8, p)
        else if (try core.conf.resolveConfPath(gpa, self.fx.io(), adapters.env.vars(&self.fx.env), "synapse-namespace-rules.conf")) |p|
            p
        else
            try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-namespace-rules.conf", .{self.fx.home});
        defer gpa.free(ns_path);
        var ns_registry = try core.namespace.Registry.load(gpa, self.fx.io(), ns_path);
        defer ns_registry.deinit();

        // Kept out of `out` (the work dir): a cloned grammar's `repos/` dir
        // would otherwise show up as an unexpected entry to the test that
        // checks the work dir holds only the six reductions plus the cache.
        const grammars_dir = try std.fmt.allocPrint(gpa, "{s}/grammars", .{self.fx.root});
        defer gpa.free(grammars_dir);

        return build(fake_grammar.FakeExtractor, gpa, self.fx.io(), &self.fx.env, registry, grammars_dir, kind_rules, ns_registry, opts.trace, .{
            .root = self.fx.repo,
            .out = self.fx.work,
            .depth = opts.depth,
            .lists = opts.lists,
            .usable = usable,
            .chunk = opts.chunk,
            .distinctive_top = opts.distinctive_top,
            .distinctive_k = opts.distinctive_k,
        });
    }

    /// A `.tsv` under the fixture's work dir, or null if it doesn't exist.
    fn readOut(self: *VocabFixture, gpa: Allocator, name: []const u8) !?[]u8 {
        const sub = try std.fmt.allocPrint(gpa, "work/{s}", .{name});
        defer gpa.free(sub);
        return self.fx.tmp.dir.readFileAlloc(testing.io, sub, gpa, .limited(4 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    /// `groupwords.tsv`'s count for one `(group, word)` pair, or null if
    /// the pair never appears.
    fn countOf(self: *VocabFixture, gpa: Allocator, group: []const u8, word: []const u8) !?usize {
        const text = (try self.readOut(gpa, "groupwords.tsv")) orelse return null;
        defer gpa.free(text);
        return tsvCount(text, group, word);
    }
};

/// The `count` field of the first row whose first two tab-separated fields
/// equal `a`/`b`, or null if no row matches.
fn tsvCount(text: []const u8, a: []const u8, b: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const fa = fields.next() orelse continue;
        const fb = fields.next() orelse continue;
        const fc = fields.next() orelse continue;
        if (std.mem.eql(u8, fa, a) and std.mem.eql(u8, fb, b)) return std.fmt.parseInt(usize, fc, 10) catch null;
    }
    return null;
}

/// The row (as raw tab-separated text, no trailing newline) whose first
/// field equals `group`, or null if absent.
fn tsvRow(text: []const u8, group: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], group)) return line;
    }
    return null;
}

/// Two modules with deliberately disjoint domain vocabulary, plus one term
/// ("Shared") every module uses -- the corpus-common case the quality gate
/// later has to be able to see.
fn makeTwoModuleRepo(vf: *VocabFixture) !void {
    try vf.src("billing/src/InvoiceCalculator.java", &.{ "InvoiceCalculator", "SharedRegistry" });
    try vf.src("billing/src/DunningSchedule.java", &.{ "DunningSchedule", "SharedRegistry" });
    try vf.src("shipping/src/ParcelRouter.java", &.{ "ParcelRouter", "SharedRegistry" });
    try vf.src("shipping/src/CarrierManifest.java", &.{ "CarrierManifest", "SharedRegistry" });
    try vf.commit();
}

test "vocab: two modules with different symbols yield disjoint top terms" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try makeTwoModuleRepo(&vf);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));

    try testing.expect((try vf.countOf(gpa, "billing/src", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "billing/src", "dunning")) != null);
    try testing.expect((try vf.countOf(gpa, "billing/src", "parcel")) == null);
    try testing.expect((try vf.countOf(gpa, "billing/src", "carrier")) == null);
    try testing.expect((try vf.countOf(gpa, "shipping/src", "parcel")) != null);
    try testing.expect((try vf.countOf(gpa, "shipping/src", "carrier")) != null);
    try testing.expect((try vf.countOf(gpa, "shipping/src", "invoice")) == null);
}

test "vocab: a term used by every module is present in every group, so its df is visible" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try makeTwoModuleRepo(&vf);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    try testing.expectEqual(@as(?usize, 2), try vf.countOf(gpa, "billing/src", "shared"));
    try testing.expectEqual(@as(?usize, 2), try vf.countOf(gpa, "shipping/src", "shared"));

    const gw = (try vf.readOut(gpa, "groupwords.tsv")).?;
    defer gpa.free(gw);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, gw, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        const w = fields.next() orelse continue;
        if (std.mem.eql(u8, w, "registry")) n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
}

test "vocab: CamelCase and snake_case split into words; a run of capitals stays whole" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{ "getUserName", "premium_rate_table", "HTTPServer" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    try testing.expect((try vf.countOf(gpa, "core/src", "user")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "name")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "premium")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "rate")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "table")) != null);
    // Under four characters, never survives regardless.
    try testing.expect((try vf.countOf(gpa, "core/src", "get")) == null);
    // An acronym run absorbs what follows it -- documented behavior, not a
    // bug: the alternative needs lookahead.
    try testing.expect((try vf.countOf(gpa, "core/src", "httpserver")) != null);
}

test "vocab: stopwords come from the tokenizer's own list, and short words are dropped" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.writeStopwords("another\nbecause\n");
    // "Another"/"Because" are ordinary English function words and would
    // otherwise be perfectly good-looking domain terms.
    try vf.src("core/src/A.java", &.{ "AnotherThing", "BecauseInvoice", "Fee" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    try testing.expect((try vf.countOf(gpa, "core/src", "another")) == null);
    try testing.expect((try vf.countOf(gpa, "core/src", "because")) == null);
    try testing.expect((try vf.countOf(gpa, "core/src", "fee")) == null); // three characters
    try testing.expect((try vf.countOf(gpa, "core/src", "thing")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "invoice")) != null);
}

test "vocab: groupexts.tsv names what an area is made of, grammar or not" {
    // Counts every kept path, not the code subset -- the files that carry
    // the orientation answer are usually the ones no grammar can read.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.plain("core/src/b.xml", "x\n");
    try vf.plain("core/src/c.xml", "y\n");
    try vf.plain("core/src/dune", "z\n"); // no dot at all
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ge = (try vf.readOut(gpa, "groupexts.tsv")).?;
    defer gpa.free(ge);
    try testing.expectEqual(@as(?usize, 2), tsvCount(ge, "core/src", "xml"));
    try testing.expectEqual(@as(?usize, 1), tsvCount(ge, "core/src", "java"));
    try testing.expectEqual(@as(?usize, 1), tsvCount(ge, "core/src", "dune"));
    // Most common first within a group, matching groupwords.tsv.
    const first_row = tsvRow(ge, "core/src").?;
    var fields = std.mem.splitScalar(u8, first_row, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("xml", fields.next().?);
}

test "vocab: groupexts.tsv and counts.tsv agree, group for group" {
    // One shared map for "which group is this path in," not two rules that
    // can silently disagree -- a group can never appear to hold more kinds
    // of file than it holds files.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("other/src/B.java", &.{"Beta"});
    try vf.plain("core/src/b.xml", "x\n");
    try vf.plain("top.md", "y\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ge = (try vf.readOut(gpa, "groupexts.tsv")).?;
    defer gpa.free(ge);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);

    var sums: std.StringHashMapUnmanaged(usize) = .empty;
    defer sums.deinit(gpa);
    var lines = std.mem.splitScalar(u8, ge, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const g = fields.next().?;
        _ = fields.next();
        const c = try std.fmt.parseInt(usize, fields.next().?, 10);
        const gop = try sums.getOrPut(gpa, g);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += c;
    }
    var clines = std.mem.splitScalar(u8, counts, '\n');
    while (clines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const g = fields.next().?;
        const c = try std.fmt.parseInt(usize, fields.next().?, 10);
        try testing.expectEqual(c, sums.get(g).?);
    }
}

test "vocab: parseable.tsv's total agrees with counts.tsv, group for group" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.plain("core/src/b.xml", "x\n");
    try vf.plain("core/src/c.xml", "y\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const parseable = (try vf.readOut(gpa, "parseable.tsv")).?;
    defer gpa.free(parseable);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);

    const p_row = tsvRow(parseable, "core/src").?;
    var pf = std.mem.splitScalar(u8, p_row, '\t');
    _ = pf.next();
    _ = pf.next(); // parseable count
    const p_total = pf.next().?;
    const c_row = tsvRow(counts, "core/src").?;
    var cf = std.mem.splitScalar(u8, c_row, '\t');
    _ = cf.next();
    try testing.expectEqualStrings(cf.next().?, p_total);
}

test "vocab: a group with no parseable files reports zero, not an absent row" {
    // The exact row `synapse gate --parseable` looks for: it cannot tell
    // "owns no vocabulary" from "nothing here has a grammar" without it.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.plain("config/settings.properties", "a=1\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const parseable = (try vf.readOut(gpa, "parseable.tsv")).?;
    defer gpa.free(parseable);
    try testing.expectEqualStrings("config\t0\t1", tsvRow(parseable, "config").?);
}

test "vocab: a mixed group reports the real share, not all-or-nothing" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("core/src/B.java", &.{"Beta"});
    try vf.plain("core/src/c.xml", "x\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const parseable = (try vf.readOut(gpa, "parseable.tsv")).?;
    defer gpa.free(parseable);
    try testing.expectEqualStrings("core/src\t2\t3", tsvRow(parseable, "core/src").?);
}

test "vocab: distinctive.tsv reports every group, including one scoring entirely zero" {
    // synapse-001, step 8. A word shared by every group is common, not
    // distinctive, and the group still gets a row -- 0 is a computed
    // answer, not the absence of one.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Shared"});
    try vf.src("shipping/src/B.java", &.{"Shared"});
    try vf.src("pricing/src/C.java", &.{"Shared"});
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const distinctive = (try vf.readOut(gpa, "distinctive.tsv")).?;
    defer gpa.free(distinctive);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, distinctive, "\n"));
    var fields = std.mem.splitScalar(u8, tsvRow(distinctive, "core/src").?, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("0", fields.next().?);
}

test "vocab: a word unique to one group is distinctive; a word shared by every group is not" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{ "Invoice", "Shared" });
    try vf.src("shipping/src/B.java", &.{ "Parcel", "Shared" });
    try vf.src("pricing/src/C.java", &.{ "Tariff", "Shared" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    // N = 3, D = max(2, 3/20) = 2. df(invoice) = 1: score 2/3 > 0.5, counted.
    // df(shared) = 3: score 2/5 < 0.5, not counted.
    const distinctive = (try vf.readOut(gpa, "distinctive.tsv")).?;
    defer gpa.free(distinctive);
    var fields = std.mem.splitScalar(u8, tsvRow(distinctive, "core/src").?, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("1", fields.next().?);
}

test "vocab: --distinctive-top limits how many terms are considered per group" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{ "One", "Two", "Three", "Four" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .distinctive_top = 2 }));
    const two = (try vf.readOut(gpa, "distinctive.tsv")).?;
    defer gpa.free(two);
    var tf = std.mem.splitScalar(u8, tsvRow(two, "core/src").?, '\t');
    _ = tf.next();
    _ = tf.next();
    try testing.expectEqualStrings("2", tf.next().?);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .distinctive_top = 8 }));
    const eight = (try vf.readOut(gpa, "distinctive.tsv")).?;
    defer gpa.free(eight);
    var ef = std.mem.splitScalar(u8, tsvRow(eight, "core/src").?, '\t');
    _ = ef.next();
    _ = ef.next();
    try testing.expectEqualStrings("4", ef.next().?);
}

test "vocab: counts.tsv counts every tracked file, not only the ones with a grammar" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.plain("core/src/b.xml", "x\n");
    try vf.plain("core/src/c.xml", "y\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    var fields = std.mem.splitScalar(u8, tsvRow(counts, "core/src").?, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("3", fields.next().?);
}

test "vocab: a repo-root file groups as (repo root) rather than vanishing" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.plain("README.md", "readme\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    var fields = std.mem.splitScalar(u8, tsvRow(counts, "(repo root)").?, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("1", fields.next().?);
}

test "vocab: --depth changes the group key, and counts.tsv keys agree with groupwords.tsv" {
    // The two files keyed differently is the failure that makes a group
    // look like it has vocabulary but no files, or the reverse -- the
    // grouping rule is shared textually and this pins that it stays shared.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("alpha/one/deep/A.java", &.{"Invoice"});
    try vf.src("alpha/two/deep/B.java", &.{"Parcel"});
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .depth = 1 }));
    try testing.expect((try vf.countOf(gpa, "alpha", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "alpha", "parcel")) != null);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .depth = 2 }));
    try testing.expect((try vf.countOf(gpa, "alpha/one", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "alpha/one", "parcel")) == null);

    // Every group named in groupwords.tsv exists in counts.tsv.
    const gw = (try vf.readOut(gpa, "groupwords.tsv")).?;
    defer gpa.free(gw);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    var lines = std.mem.splitScalar(u8, gw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const g = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse continue];
        try testing.expect(tsvRow(counts, g) != null);
    }
}

test "vocab: an extension with no registry entry is excluded before tagging, not warned about" {
    // CODE_RE is built once, up front, from the registry's own usable
    // extensions, rather than a hardcoded guess -- an extension the
    // registry has never heard of never reaches the code subset, so it
    // never reaches the extractor (and its cache) at all.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("core/src/B.java", &.{"Beta"});
    // `.rb` looks like a code extension but has no registry entry in this
    // fixture -- exactly the case a hardcoded CODE_RE would slip through.
    try vf.plain("core/src/c.rb", "x\n");
    try vf.plain("core/src/d.rb", "y\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .chunk = 1 }));
    try testing.expect((try vf.countOf(gpa, "core/src", "alpha")) != null);
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{vf.fx.work});
    defer gpa.free(cache_path);
    var cache = try core.tags_cache.Cache.open(testing.io, cache_path);
    defer cache.close(testing.io);
    try testing.expect(cache.get("core/src/c.rb") == null);
    try testing.expect(cache.get("core/src/d.rb") == null);
}

test "vocab: nothing with a usable grammar: empty groupwords.tsv and exit 0, not an error" {
    // The signal to fall back to synapse-orientation. An exit 1 here would
    // read as "the script is broken" in a repo simply written in a
    // language with no grammar installed, which is a supported state.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.plain("core/src/a.txt", "x\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const gw = (try vf.readOut(gpa, "groupwords.tsv")).?;
    defer gpa.free(gw);
    try testing.expectEqual(@as(usize, 0), gw.len);
}

test "vocab: synapse-ignore-files.conf excludes a path from the evidence as well as the graph" {
    // Vendored/generated trees would otherwise dominate the vocabulary of
    // whatever group they sit in, and a path excluded from the graph has
    // no node for that vocabulary to describe.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("vendor/lib/B.java", &.{"Vendored"});
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    try testing.expect((try vf.countOf(gpa, "vendor/lib", "vendored")) != null);

    try vf.writeIgnoreFiles("(^|/)vendor/\n");
    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    try testing.expect((try vf.countOf(gpa, "vendor/lib", "vendored")) == null);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    try testing.expect(tsvRow(counts, "vendor/lib") == null);
    try testing.expect((try vf.countOf(gpa, "core/src", "alpha")) != null);
}

// --- --lists: keyed by cluster rather than by directory ---------------------
//
// The quality gate scores clusters, and a cluster is not generally a union
// of directories, so its vocabulary cannot be derived from the
// directory-keyed table after the fact.

test "vocab: --lists keys vocabulary by node title, cutting across directories" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("alpha/src/InvoiceCalculator.java", &.{"InvoiceCalculator"});
    try vf.src("beta/src/DunningSchedule.java", &.{"DunningSchedule"});
    try vf.src("beta/src/ParcelRouter.java", &.{"ParcelRouter"});
    try vf.commit();
    // Deliberately not a union of directories: one node takes a file from each.
    try vf.writeList("01", "Billing", &.{ "alpha/src/InvoiceCalculator.java", "beta/src/DunningSchedule.java" });
    try vf.writeList("02", "Shipping", &.{"beta/src/ParcelRouter.java"});
    const lists_dir = try vf.listsDir();
    defer gpa.free(lists_dir);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .lists = lists_dir }));
    try testing.expect((try vf.countOf(gpa, "Billing", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "Billing", "dunning")) != null);
    try testing.expect((try vf.countOf(gpa, "Billing", "parcel")) == null);
    try testing.expect((try vf.countOf(gpa, "Shipping", "parcel")) != null);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    var fields = std.mem.splitScalar(u8, tsvRow(counts, "Billing").?, '\t');
    _ = fields.next();
    try testing.expectEqualStrings("2", fields.next().?);
}

test "vocab: the --lists run against an already-warm cache tags nothing at all" {
    // synapse-001, step 3: /synapse-init runs plain vocab first (directory-
    // keyed) then vocab --lists (cluster-keyed) against the same files.
    // Once the first call warms the cache for the whole code subset, the
    // second call's list-narrowed slice should already be entirely
    // covered -- it neither re-tags nor even needs the grammar registry
    // entry it would otherwise have to have.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("alpha/src/InvoiceCalculator.java", &.{"InvoiceCalculator"});
    try vf.src("beta/src/DunningSchedule.java", &.{"DunningSchedule"});
    try vf.src("beta/src/ParcelRouter.java", &.{"ParcelRouter"});
    try vf.commit();

    const trace1 = try std.fmt.allocPrint(gpa, "{s}/trace1.log", .{vf.fx.root});
    defer gpa.free(trace1);
    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .trace = trace1 }));
    const t1 = try vf.fx.tmp.dir.readFileAlloc(testing.io, "trace1.log", gpa, .limited(1 << 20));
    defer gpa.free(t1);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, t1, "path "));

    try vf.writeList("01", "Billing", &.{ "alpha/src/InvoiceCalculator.java", "beta/src/DunningSchedule.java" });
    try vf.writeList("02", "Shipping", &.{"beta/src/ParcelRouter.java"});
    const lists_dir = try vf.listsDir();
    defer gpa.free(lists_dir);

    const trace2 = try std.fmt.allocPrint(gpa, "{s}/trace2.log", .{vf.fx.root});
    defer gpa.free(trace2);
    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .lists = lists_dir, .trace = trace2 }));
    try testing.expectEqual(error.FileNotFound, vf.fx.tmp.dir.access(testing.io, "trace2.log", .{}));

    try testing.expect((try vf.countOf(gpa, "Billing", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "Billing", "dunning")) != null);
    try testing.expect((try vf.countOf(gpa, "Billing", "parcel")) == null);
    try testing.expect((try vf.countOf(gpa, "Shipping", "parcel")) != null);
}

test "vocab: --lists a file claimed by two nodes contributes to both" {
    // Node manifests may legitimately overlap -- keeping one membership
    // would make the gate's verdict depend on the order lists were read in.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/Shared.java", &.{"InvoiceCalculator"});
    try vf.commit();
    try vf.writeList("01", "Billing", &.{"core/src/Shared.java"});
    try vf.writeList("02", "Reporting", &.{"core/src/Shared.java"});
    const lists_dir = try vf.listsDir();
    defer gpa.free(lists_dir);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .lists = lists_dir }));
    try testing.expect((try vf.countOf(gpa, "Billing", "invoice")) != null);
    try testing.expect((try vf.countOf(gpa, "Reporting", "invoice")) != null);
    const counts = (try vf.readOut(gpa, "counts.tsv")).?;
    defer gpa.free(counts);
    var bf = std.mem.splitScalar(u8, tsvRow(counts, "Billing").?, '\t');
    _ = bf.next();
    try testing.expectEqualStrings("1", bf.next().?);
    var rf = std.mem.splitScalar(u8, tsvRow(counts, "Reporting").?, '\t');
    _ = rf.next();
    try testing.expectEqualStrings("1", rf.next().?);
}

test "vocab: --lists a file no node claims contributes nothing" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/Claimed.java", &.{"InvoiceCalculator"});
    try vf.src("core/src/Orphan.java", &.{"OrphanRegistry"});
    try vf.commit();
    try vf.writeList("01", "Billing", &.{"core/src/Claimed.java"});
    const lists_dir = try vf.listsDir();
    defer gpa.free(lists_dir);

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .lists = lists_dir }));
    try testing.expect((try vf.countOf(gpa, "Billing", "invoice")) != null);
    const gw = (try vf.readOut(gpa, "groupwords.tsv")).?;
    defer gpa.free(gw);
    try testing.expect(std.mem.indexOf(u8, gw, "orphan") == null);
}

test "vocab: --lists a missing or empty lists dir is an error, not a silent empty result" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try makeTwoModuleRepo(&vf);

    const missing = try std.fmt.allocPrint(gpa, "{s}/nope", .{vf.fx.work});
    defer gpa.free(missing);
    try testing.expectEqual(@as(u8, 1), try vf.run(.{ .lists = missing }));

    try vf.fx.tmp.dir.createDirPath(testing.io, "work/empty-lists");
    const empty = try std.fmt.allocPrint(gpa, "{s}/empty-lists", .{vf.fx.work});
    defer gpa.free(empty);
    try testing.expectEqual(@as(u8, 1), try vf.run(.{ .lists = empty }));
}

test "vocab: test classes contribute vocabulary, because a summary is made of names" {
    // The other half of the summary/crux pool split (`rank --pool`). Tests
    // are excluded from the crux pool -- a crux is concentrated logic --
    // but must keep feeding the summary: on a real node, terms came only
    // from test class names, at zero read cost. Excluding tests here too
    // would silently cost those concepts.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("src/main/java/Service.java", &.{"Alpha"});
    try vf.src("src/test/java/GegenparteiTest.java", &.{ "GegenparteiTest", "Frist" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .depth = 1 }));
    try testing.expect((try vf.countOf(gpa, "src", "frist")) != null);
    try testing.expect((try vf.countOf(gpa, "src", "gegenpartei")) != null);
}

test "vocab: the output directory holds only the six reductions plus the tags cache, never a raw dump" {
    // 98k code files produce ~942 MB of tags against 6.9 MB of vocabulary,
    // so this process must never hold or write the whole repo's tags at
    // once. The allowlist is meant to be widened by hand: adding an output
    // should fail this test once and be added here on purpose, which is
    // what stops a debug dump of raw tags from arriving unnoticed.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{ "getUserName", "premium_rate_table" });
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    var it = (try vf.fx.tmp.dir.openDir(testing.io, "work", .{ .iterate = true }));
    defer it.close(testing.io);
    var walker = it.iterate();
    while (try walker.next(testing.io)) |entry| {
        const allowed = std.mem.eql(u8, entry.name, "counts.tsv") or
            std.mem.eql(u8, entry.name, "groupwords.tsv") or
            std.mem.eql(u8, entry.name, "groupexts.tsv") or
            std.mem.eql(u8, entry.name, "namespaces.tsv") or
            std.mem.eql(u8, entry.name, "parseable.tsv") or
            std.mem.eql(u8, entry.name, "distinctive.tsv") or
            std.mem.eql(u8, entry.name, "_tags_cache.bin");
        try testing.expect(allowed);
    }
}

test "vocab: fills the tags cache from the same tagging pass, not a second one" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("core/src/B.java", &.{"Beta"});
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{vf.fx.work});
    defer gpa.free(cache_path);
    {
        var cache = try core.tags_cache.Cache.open(testing.io, cache_path);
        defer cache.close(testing.io);
        try testing.expectEqual(@as(u32, 2), cache.count());
        const a = cache.get("core/src/A.java").?;
        try testing.expect(!a.unsupported);
        try testing.expect(std.mem.indexOf(u8, a.tags, "FAKE_NAME") != null);
    }

    // write-node's own backfill finds both already current and does
    // nothing -- the whole point of filling the cache here.
    var pairs: [2]core.tags_cache.PathHash = undefined;
    {
        const content_a = try vf.fx.tmp.dir.readFileAlloc(testing.io, "repo/core/src/A.java", gpa, .limited(1 << 20));
        defer gpa.free(content_a);
        pairs[0] = .{ .path = "core/src/A.java", .hash = core.verify.blobHashRaw(content_a) };
        const content_b = try vf.fx.tmp.dir.readFileAlloc(testing.io, "repo/core/src/B.java", gpa, .limited(1 << 20));
        defer gpa.free(content_b);
        pairs[1] = .{ .path = "core/src/B.java", .hash = core.verify.blobHashRaw(content_b) };
    }
    var cache = try core.tags_cache.Cache.open(testing.io, cache_path);
    defer cache.close(testing.io);
    var kind_rules = try core.kind_synonyms.RuleList.load(gpa, testing.io, "/nonexistent");
    defer kind_rules.deinit();
    try tags_cache_cmd.backfill(fake_grammar.FakeExtractor, gpa, testing.io, &vf.fx.env, vf.fx.repo, &cache, &pairs, null);
    try testing.expectEqual(@as(u32, 2), cache.count());
}

test "vocab: a file outside the code subset is not added to the tags cache" {
    // vocab only ever tags the code subset (a usable grammar); a file
    // counted in groupexts.tsv purely as artifact-mix evidence was never
    // parsed and has nothing to cache.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.plain("core/src/b.xml", "x\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{vf.fx.work});
    defer gpa.free(cache_path);
    var cache = try core.tags_cache.Cache.open(testing.io, cache_path);
    defer cache.close(testing.io);
    try testing.expectEqual(@as(u32, 1), cache.count());
    try testing.expect(cache.get("core/src/b.xml") == null);
}

test "vocab: a second run against an unchanged repo tags nothing" {
    // synapse-001, step 2: the directory-keyed reduction comes from the
    // cache, not from re-tagging. A repeat run with nothing changed should
    // reach the extractor for zero files.
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("core/src/B.java", &.{"Beta"});
    try vf.commit();

    const trace1 = try std.fmt.allocPrint(gpa, "{s}/trace1.log", .{vf.fx.root});
    defer gpa.free(trace1);
    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .trace = trace1 }));
    const t1 = try vf.fx.tmp.dir.readFileAlloc(testing.io, "trace1.log", gpa, .limited(1 << 20));
    defer gpa.free(t1);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, t1, "path "));

    const trace2 = try std.fmt.allocPrint(gpa, "{s}/trace2.log", .{vf.fx.root});
    defer gpa.free(trace2);
    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .trace = trace2 }));
    try testing.expectEqual(error.FileNotFound, vf.fx.tmp.dir.access(testing.io, "trace2.log", .{}));

    try testing.expect((try vf.countOf(gpa, "core/src", "alpha")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "beta")) != null);
}

test "vocab: only a changed file is re-tagged on a second run, the rest come from the cache" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.src("core/src/A.java", &.{"Alpha"});
    try vf.src("core/src/B.java", &.{"Beta"});
    try vf.commit();
    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));

    // A symbol sharing no CamelCase sub-word with "Alpha", so a surviving
    // "alpha" count could only mean a stale read, not a coincidence.
    try vf.src("core/src/A.java", &.{"GammaRenamed"});
    const trace = try std.fmt.allocPrint(gpa, "{s}/trace.log", .{vf.fx.root});
    defer gpa.free(trace);
    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .trace = trace }));
    const t = try vf.fx.tmp.dir.readFileAlloc(testing.io, "trace.log", gpa, .limited(1 << 20));
    defer gpa.free(t);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, t, "path "));
    try testing.expect(std.mem.indexOf(u8, t, "path core/src/A.java\n") != null);

    try testing.expect((try vf.countOf(gpa, "core/src", "gamma")) != null);
    try testing.expect((try vf.countOf(gpa, "core/src", "alpha")) == null);
    try testing.expect((try vf.countOf(gpa, "core/src", "beta")) != null);
}

// --- namespaces.tsv: does the code's own name match the directory holding it ---
//
// synapse-001, step 6. Rules live in `$HOME/.claude/synapse-namespace-rules.conf`,
// same discovery contract as the grammar registry: absent means nothing
// configured yet, not an error.

test "vocab: namespaces.tsv is empty when no rules are configured, not an error" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.plain("core/src/A.java", "package com.example.billing;\nclass A {}\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqual(@as(usize, 0), ns.len);
}

const in_file_java_rule =
    \\{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}
;

test "vocab: an in-file rule captures a package declaration, and full agreement shows agree == total" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.writeNamespaceRules(in_file_java_rule);
    try vf.plain("core/src/A.java", "package com.example.billing;\nclass A {}\n");
    try vf.plain("core/src/B.java", "package com.example.billing;\nclass B {}\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqualStrings("core/src\tcom.example.billing\t2\t2", tsvRow(ns, "core/src").?);
}

test "vocab: a divergence shows the majority namespace, not an average of the two" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.writeNamespaceRules(in_file_java_rule);
    try vf.plain("core/src/A.java", "package com.example.billing;\n");
    try vf.plain("core/src/B.java", "package com.example.billing;\n");
    try vf.plain("core/src/C.java", "package com.example.legacy;\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqualStrings("core/src\tcom.example.billing\t2\t3", tsvRow(ns, "core/src").?);
}

test "vocab: a build-file rule resolves via the nearest ancestor, not just a same-directory sibling" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.writeNamespaceRules(
        \\{"ml": {"kind": "build-file", "file": "dune", "prefix": "(name ", "terminator": ")"}}
    );
    try vf.plain("eon_edn/src/dune", "(name eon_edn)\n");
    try vf.plain("eon_edn/src/foo.ml", "let x = 1\n");
    try vf.plain("eon_edn/src/nested/bar.ml", "let y = 2\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{ .depth = 1 }));
    // Both foo.ml (same directory as dune) and bar.ml (one level deeper, no
    // dune of its own) resolve to the same declared namespace via the
    // ancestor walk.
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqualStrings("eon_edn\teon_edn\t2\t2", tsvRow(ns, "eon_edn").?);
}

test "vocab: an extension with no rule contributes nothing, even alongside one that has a rule" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    try vf.writeNamespaceRules(in_file_java_rule);
    try vf.plain("core/src/A.java", "package com.example.billing;\n");
    try vf.plain("core/src/A.py", "class A: pass\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqualStrings("core/src\tcom.example.billing\t1\t1", tsvRow(ns, "core/src").?);
}

test "vocab: SYNAPSE_NAMESPACE_RULES_CONF overrides the default path" {
    const gpa = testing.allocator;
    var vf = try VocabFixture.init(gpa);
    defer vf.deinit();
    const custom = try std.fmt.allocPrint(gpa, "{s}/custom-rules.conf", .{vf.fx.root});
    defer gpa.free(custom);
    try vf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "custom-rules.conf", .data = in_file_java_rule });
    try vf.fx.env.put("SYNAPSE_NAMESPACE_RULES_CONF", custom);
    try vf.plain("core/src/A.java", "package com.example.billing;\n");
    try vf.commit();

    try testing.expectEqual(@as(u8, 0), try vf.run(.{}));
    const ns = (try vf.readOut(gpa, "namespaces.tsv")).?;
    defer gpa.free(ns);
    try testing.expectEqualStrings("core/src\tcom.example.billing\t1\t1", tsvRow(ns, "core/src").?);
}
