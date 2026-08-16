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
    const registry_path = (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-grammars.conf")) orelse
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
    else if (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-kind-synonyms.conf")) |p|
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
    else if (try core.conf.resolveConfPath(gpa, io, envVars(env), "synapse-namespace-rules.conf")) |p|
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
        \\usage: synapse vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>] [--lists <dir>]
        \\                     [--distinctive-top N] [--distinctive-k N]
        \\
    , .{});
    return 2;
}

const Options = struct {
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
fn build(
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
    const path = (try core.conf.resolveConfPath(arena, io, envVars(env), "synapse-prompt-stopwords.conf")) orelse
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
