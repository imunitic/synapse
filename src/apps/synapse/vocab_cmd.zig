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
//! Prints groups / files / code files / pairs on stderr, so a repo that yielded
//! no vocabulary is a number rather than an empty file nobody looked at.
//!
//! ## distinctive.tsv: which words are distinctive, not just frequent -- synapse-001, step 8
//!
//! The orientation skill's actual work, stated plainly: "which words are
//! distinctive rather than merely frequent." `distinctive.tsv` answers it per
//! group, before any clustering exists, by reading back `groupwords.tsv`'s
//! own bytes (already in memory -- `writeGroupTable` returns what it wrote,
//! no disk round-trip) through `core.gate.judgeDistinctiveness`: the design's
//! saturation curve, `distinctiveness = D / (D + df)` with `D = max(2, N/K)`,
//! not `synapse gate`'s own cliff -- a *different* function in the same file,
//! kept apart deliberately so this evidence-at-orientation-time path can
//! never perturb `judge`'s already-calibrated, already-tested cluster verdict.
//! `--distinctive-top`/`--distinctive-k` default to 8/20, the same defaults
//! `judge` uses for `--top` and the value its own cliff already reproduces at
//! the curve's 0.5 point.
//!
//! ## parseable.tsv feeds synapse gate, not a human -- synapse-001, step 7
//!
//! The gate's rare-term rule cannot tell "owns no vocabulary" apart from
//! "produced none because nothing in the cluster has a grammar" -- both are
//! zero rare terms. `parseable.tsv` is `code.items`' membership, counted the
//! same list-row way `counts.tsv` already counts a group's total, so
//! `synapse gate --parseable parseable.tsv` can divide one by the other and
//! stop recommending dispersal for a cluster it never had real evidence
//! about. See `core/gate.zig` for what it does with the number.
//!
//! ## Why the extension and namespace tables are here and not in a command of their own
//!
//! Both answer a different question from the vocabulary -- what an area is
//! *made of*, and what it *calls itself* -- rather than what it talks about,
//! and neither needs tagging at all, so either could live anywhere.
//!
//! They live here because they must be keyed by exactly the same rule. Two
//! tables about the same groups, produced by two implementations of "which
//! group is this path in", is how a group comes to look like it has
//! vocabulary but no files. Sharing the map makes agreement structural
//! instead of a thing to keep checking.
//!
//! Counted over every kept path rather than the code subset, which is the
//! whole point: the interesting files for `groupexts.tsv` are the ones no
//! grammar can read, and a Rust crate's declared namespace lives in
//! `Cargo.toml`, a file no grammar tags either.
//!
//! ## Declared namespace is a rule, not a grammar query -- see `core/namespace.zig`
//!
//! `namespaces.tsv` answers the other hand-written orientation question: does
//! the name an ecosystem gives its own code match the directory holding it.
//! Nothing here knows what Java or OCaml is; `core.namespace.Registry` reads
//! `~/.claude/synapse-namespace-rules.conf` (`SYNAPSE_NAMESPACE_RULES_CONF`
//! overrides it), keyed by bare extension exactly like the grammar registry,
//! and an extension with no rule yet simply contributes nothing -- a config
//! edit away, never a code change. An empty or absent registry still writes
//! an empty `namespaces.tsv`, the same "supported state, not an error"
//! contract `groupwords.tsv` gives an ungrammared repo.
//!
//! ## The chunking apparatus is gone, and `--chunk` is now inert
//!
//! The script split the file list into one chunk per core and ran a generated
//! `worker.sh` under `xargs -P`, each worker spawning `synapse tags --paths` and
//! piping it through `awk`. Every part of that existed to amortise process
//! startup: `--chunk`'s own header said "Only a parallelism knob -- it is not
//! what makes this cheap."
//!
//! What disappears is the process apparatus, not the parallelism: no `split`, no
//! generated `worker.sh`, no `xargs`, no `synapse tags` spawn per chunk, no `awk`
//! per chunk, and no intermediate `words/*.tsv`. A grammar loads once per
//! extension per thread for the life of the run, and the reduction happens on the
//! tags as they arrive. `--chunk` still sets files-per-batch, which is still only
//! a parallelism knob.
//!
//! ## The parallelism is kept, and the measurement is why
//!
//! Stage 1 dropped the equivalent `xargs -P` apparatus from `tags-cache` because
//! it was amortising a CLI startup that no longer existed. That reasoning does
//! not transfer here, and the design said so in advance; measuring settled it.
//! On `syrius-querschnitt-basis` (3,642 code files) the bash's twelve-way version
//! took 1987ms and a sequential in-process pass took **4453ms** -- 2.2x slower,
//! with byte-identical output. Tree-sitter parsing thousands of files is real CPU
//! work, so twelve cores beat one even paying for twelve processes.
//!
//! So the chunking survives in shape while every process it needed disappears:
//! one thread per core, each with its own extractor, tagging its own slice of
//! files. Per-thread state rather than a shared map is not caution about
//! locking -- a `tree_sitter` parser is not safe to share, and neither is a
//! grammar handle mid-load, so the only sharing here is the immutable path list.
//!
//! ## Tagging fills the cache; the reduction reads it back
//!
//! These used to be the same loop: tag a file, split its tags into words,
//! discard the tags, keep the counts. They are two passes now, in service of
//! the same "raw tags never pile up" property the first version had.
//!
//! **Pass one tags only what the cache does not already hold at its current
//! hash**, via `Cache.needsTagging` -- so a repeat run against an unchanged repo
//! tags nothing and loads no grammar at all. What it *does* tag, it renders and
//! commits into `_tags_cache.bin` in the same loop that produced it, exactly as
//! before; see "Raw tags are held once, not twice" below.
//!
//! **Pass two reduces every code file's vocabulary from the cache**, which pass
//! one has just made complete and current for all of them, hit or miss alike.
//! It is single-threaded and reads a memory-mapped file rather than a symbol
//! table already in hand, but "splitting and counting is cheap; the parse was
//! the cost, and pass one already paid it" -- there is nothing here worth a
//! thread pool for.
//!
//! The split exists for iteration, not for a single cold-cache run: a first
//! build tags everything either way, so pass one costs what it always did, plus
//! one cheap hash-and-lookup per file to find that out. What changes is every
//! run after it -- a re-cluster, a re-run after `synapse-ignore-files.conf`
//! changes, the `--lists` call `/synapse-init` makes second against the same
//! files -- which now costs a scan of already-warm cache entries instead of a
//! second grammar parse of the whole repository.
//!
//! ## Raw tags are held once, not twice -- in the cache, never in this process
//!
//! ~942 MB of tags on a large repo against 6.9 MB of vocabulary, so this process
//! still never holds a whole repo's tags in memory at once. Pass one reduces
//! nothing and holds nothing but the rendered text of the file it is on, until
//! that is committed. Pass two holds one file's cached tag lines and one tag's
//! split words at a time, freed before the next.
//!
//! A cache-write failure from pass one is reported and does not fail the
//! command: the three tables below are the contract `/synapse-init` depends on.
//! Pass two still runs against whatever the cache holds afterward -- current
//! for everything on a successful commit, stale for this run's shortfall on a
//! failed one -- so a cache-layer failure degrades the vocabulary for the files
//! that needed tagging rather than failing the whole command.

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
        // `--help` exits 0, like every other subcommand: a request for help is not a
        // usage error, and a caller piping `--help` into a pager should not see 2.
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

    // Derived from the namespace of `--repo` (or the cwd) when neither `--out` nor the
    // environment names one -- the default the wrapper computed. Keyed on the *repo
    // being read*, not on where the command was run from, which are not always the same.
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

    // The repo root, and the cwd every relative path below is resolved against.
    // `--repo` is a directory to work in, not a prefix to join: the script did
    // `cd "$REPO_ROOT"` and every path in the lists is repo-relative.
    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("synapse-vocab: not inside a git repo\n", .{});
        return 1;
    }

    const home = env.get("HOME") orelse return 1;
    const registry_path = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
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
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-kind-synonyms.conf", .{home});
    defer gpa.free(kind_rules_path);
    var kind_rules = core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path) catch {
        std.debug.print("synapse-vocab: cannot read the kind-synonyms registry\n", .{});
        return 1;
    };
    defer kind_rules.deinit();

    // Which extensions have a usable grammar, from the registry rather than a
    // second hardcoded list. A hardcoded copy is how a real, already-registered
    // grammar stayed invisible to this script for every project that never got
    // its own copy of the list edited.
    const usable = try registry.usableExtensions(gpa);
    defer gpa.free(usable);

    // The declared-namespace rules, same discovery contract as the grammar
    // registry above: absent means "nothing configured yet," not an error.
    // `SYNAPSE_NAMESPACE_RULES_CONF` overrides for the same reason
    // `SYNAPSE_MODULE_BOILERPLATE_CONF` does -- so a test fixture never has to
    // touch the real `~/.claude`.
    const ns_rules_path = if (env.get("SYNAPSE_NAMESPACE_RULES_CONF")) |p|
        try gpa.dupe(u8, p)
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

const Options = struct {
    root: []const u8,
    out: []const u8,
    depth: usize,
    lists: ?[]const u8,
    usable: []const []const u8,
    chunk: ?usize,
    /// Terms per group `distinctive.tsv` looks at, and the saturation
    /// curve's scaling constant -- see `core.gate.DistinctivenessOptions`.
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

/// `group <TAB> word` counted, and the file counts alongside it.
///
/// One pass: tag every code path, split each symbol, and increment the count for
/// every group the path belongs to. A path claimed by two node lists counts under
/// both -- a manifest may legitimately overlap, and silently picking one would
/// make the gate's verdict depend on directory order.
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

    // Every tracked path, minus the user's own exclusions -- the same two knobs
    // the graph itself honours, so a path excluded from the graph is also
    // excluded from the evidence used to design the graph.
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

    // path -> the groups it belongs to. With `--lists` that is every node title
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
        // Narrowed to what some list claims: tagging a file no node owns
        // produces vocabulary with nowhere to go.
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

    // The artifact mix, off the same `groups` map so its keys agree with
    // `counts.tsv` by construction rather than by two rules staying in step.
    //
    // Counted over every kept path, not over the `code` subset below. That is
    // the whole point: a group that is 60% JSON, `.bpmn` or `.sql` is telling
    // you something no module name will, and those are exactly the files a
    // grammar-keyed view cannot see. It needs no tagging, so it costs one more
    // pass over a list already in memory.
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

    // Declared-namespace divergence: does the name an ecosystem gives a file
    // (a Java `package`, a Rust crate `name`) match the group its path is in.
    // Also over every kept path, also needing no tagging -- an empty registry
    // (nothing configured for this repo yet) still writes an empty table
    // rather than being skipped, so a caller can rely on the file existing.
    const namespaces_path = try std.fmt.allocPrint(gpa, "{s}/namespaces.tsv", .{opts.out});
    defer gpa.free(namespaces_path);
    try writeNamespaceDivergence(gpa, arena, io, opts.root, kept.items, &groups, ns_registry, namespaces_path);

    // The code subset: a usable grammar, and not machine output that happens to
    // end in a code extension. `core.enumerate.isNoise` already knows the second
    // rule -- it is the same `.min.js`/`.map` set, and one definition beats two.
    //
    // `parseable` is counted in the same pass, off the same membership: how many
    // of a group's files (per `counts.tsv`'s own total, list-row-counted the same
    // way for `--lists`) made it into `code`. synapse-001, step 7 -- this is what
    // lets `synapse gate` tell "owns no vocabulary" apart from "produced none
    // because the language has no grammar", which today it cannot.
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

    // Pass one: tag only what the cache does not already hold at its current
    // hash. Every code path is hashed once, in parallel, and that hash is
    // reused both for the freshness check below and, for whatever needs
    // tagging, as the resulting cache entry's own hash -- never recomputed.
    const hashes = try parallelHash(gpa, io, opts.root, code.items);
    defer gpa.free(hashes);

    var requested = try gpa.alloc(PathHash, code.items.len);
    defer gpa.free(requested);
    var requested_len: usize = 0;
    for (code.items, hashes) |p, h| {
        // Unreadable right now (deleted since enumeration, a submodule
        // gitlink): left out of the request entirely, so it is neither
        // tagged nor read from the cache in pass two below -- the same
        // "quietly contributes nothing" outcome a plain cache miss gets.
        const hv = h orelse continue;
        requested[requested_len] = .{ .path = p, .hash = hv };
        requested_len += 1;
    }

    const need = try cache.needsTagging(gpa, requested[0..requested_len]);
    defer gpa.free(need);

    if (need.len != 0) {
        try writeTrace(io, trace, need);

        const cores = std.Thread.getCpuCount() catch 4;
        // One chunk per core, floor 500 -- the script's rule, kept because it
        // is the right shape: fewer, larger batches amortise a grammar load
        // per thread, and a floor stops a small shortfall spawning twelve
        // threads to tag forty files. Sized off the shortfall rather than
        // the whole code subset, so a warm cache with little left to tag
        // spawns little, not the pool a cold one would.
        const chunk = opts.chunk orelse @max(500, (need.len + cores - 1) / cores);
        const workers = @min(cores, (need.len + chunk - 1) / chunk);

        const Worker = struct {
            // Everything a thread needs, and nothing shared but the immutable
            // inputs. A `tree_sitter` parser cannot be shared and neither can
            // a grammar handle mid-load, so each thread gets its own
            // extractor; the commit is single-threaded afterwards.
            gpa: Allocator,
            io: Io,
            registry: treesitter.Registry,
            grammars_dir: []const u8,
            kind_rules: core.kind_synonyms.RuleList,
            lock_tries: ?usize,
            query_override_dir: ?[]const u8,
            root: []const u8,
            items: []const PathHash,
            /// One `Update` per file this worker tagged (or attempted to),
            /// for the tags-cache commit the caller does once every thread
            /// has joined. `path` and `entry.hash` borrow `self.items`;
            /// `entry.tags`, when present, borrows the matching entry in
            /// `cache_rendered` rather than owning its own copy -- see that
            /// field for why.
            cache_updates: std.ArrayListUnmanaged(Update) = .empty,
            /// The owned, untrimmed buffers `cache_updates[i].entry.tags`
            /// points into (a trimmed slice of one of these). Freed by the
            /// caller after the commit; kept separate from `cache_updates`
            /// because freeing a trimmed slice at the wrong length is the
            /// bug this split avoids.
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
            std.fmt.parseInt(usize, s, 10) catch 300
        else
            null;
        const query_override_dir = env.get("SYNAPSE_GRAMMARS_QUERY_PATH");

        const slots = try gpa.alloc(Worker, workers);
        defer gpa.free(slots);
        const threads = try gpa.alloc(std.Thread, workers);
        defer gpa.free(threads);

        var assigned: usize = 0;
        for (slots, 0..) |*w, i| {
            // The last worker takes the remainder, so no path is dropped when
            // the count does not divide evenly.
            const take = if (i + 1 == workers) need.len - assigned else @min(chunk, need.len - assigned);
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

        // Every worker's cache_updates, merged into one commit -- one write
        // to `_tags_cache.bin`, not one per file or one per worker. Non-fatal:
        // counts.tsv and groupexts.tsv are already on disk, and pass two below
        // still runs -- against a cache left stale for this shortfall rather
        // than current, but not absent.
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

    // Pass two: every code file's vocabulary, read from the cache pass one
    // just made current for all of them -- a cache hit that needed no
    // tagging above, or one this call's own shortfall pass just filled.
    // Single-threaded: a memory-mapped lookup and a string split are not
    // worth a thread pool, and `pairs`' keys are interned straight into the
    // arena, so there is no per-thread merge step to write.
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

    // Distinctiveness at orientation time -- synapse-001, step 8. Reads back
    // the exact bytes just written to groupwords.tsv (no disk round-trip:
    // `writeGroupTable` already built them in memory) and scores each
    // group's top terms with the saturation curve, not the gate's own cliff.
    // Evidence for the model while it is still clustering, not a verdict on
    // a clustering already made -- see core/gate.zig's own distinction
    // between `judge` (post-clustering, cliff, calibrated) and
    // `judgeDistinctiveness` (pre-clustering, curve, a repo-shape knob).
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

/// Every path's current blob hash, computed in parallel -- a plain read and an
/// in-process SHA1, not a tree-sitter parse, so this is worth doing even
/// though `code` gets read a second time doing it: pass one below cannot ask
/// the cache what needs tagging without a current hash for every candidate,
/// and this is the only place that hash comes from.
/// The record `synapse-fake` writes so a test can assert that N files, and no
/// more, actually reached the extractor -- shared shape with `tags` and
/// `tags-cache`'s own `writeTrace`, not shared code: each command's caller is
/// the one place that knows what it is about to tag.
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

/// The current blob hash of a repo file, or null if it cannot be read right
/// now -- deleted since enumeration, a submodule gitlink, or similar.
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

/// How many `NN.txt`/`NN.title` pairs a lists dir holds, for the "empty is an
/// error, not a silent empty result" check.
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
            // Counted off the list rows, not off the narrowed path set: a path
            // claimed by two nodes has two rows and must count once under each.
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
    const path = try std.fmt.allocPrint(arena, "{s}/.claude/synapse-prompt-stopwords.conf", .{home});
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
/// `counts` knows about, including a group with zero parseable files -- that
/// is the exact row `synapse gate --parseable` looks for, so it must be
/// present rather than omitted for having nothing to say.
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

/// `group <TAB> thing <TAB> count`, group ascending then count descending --
/// the script's `sort -k1,1 -k3,3nr`. The key already holds the tab, so the
/// group comparison is a prefix comparison of the whole key up to it.
///
/// Shared by `groupwords.tsv` and `groupexts.tsv`, which differ only in what
/// the middle column holds. One ordering rule rather than two means the two
/// tables can be read side by side without wondering whether a difference is
/// real or an artefact of how each was sorted.
/// Writes the table and also returns the exact bytes written, owned by the
/// caller -- `groupwords.tsv`'s call site reuses them to feed
/// `core.gate.judgeDistinctiveness` without a disk round-trip; a call site
/// that has no use for the text is free to discard it immediately.
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
            // `sort` is not stable on the untouched third key, but a total order
            // here keeps two runs over the same repo byte-identical.
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{d}\n", .{ r.key, r.count });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
    return body.toOwnedSlice();
}

/// `group <TAB> namespace <TAB> agree <TAB> total`, group ascending. One row
/// per group that had at least one file with a declared namespace: the
/// namespace most of them declared, how many agreed, and how many were
/// counted. Ties broken by namespace text, for a byte-identical rerun.
///
/// synapse-001, step 6. Runs over `kept`, not the code subset -- a Rust crate
/// declares its namespace in `Cargo.toml`, not in a file a grammar would ever
/// tag, so gating this on `hasUsableExtension` would silently drop the
/// ecosystems the build-file rule exists for.
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

    // Build-file rule -> its dir-keyed namespace map, built once per distinct
    // filename on first need rather than scanned for up front: most repos use
    // one ecosystem, and a rule nothing here ever needs costs nothing.
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

/// The dir-keyed namespace map for one build-file rule, memoized in `cache`
/// so a repo with many source files sharing the same rule (every `.ml` file
/// under one `dune`-per-directory convention) scans `kept` for that filename
/// exactly once, not once per source file.
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
