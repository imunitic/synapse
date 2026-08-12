//! `synapse vocab` -- the work half of `claude/lib/synapse/synapse-vocab.sh`.
//!
//!   vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>] [--lists <dir>]
//!
//! Writes `<out>/groupwords.tsv` (`group <TAB> word <TAB> count`, group then
//! count descending) and `<out>/counts.tsv` (`group <TAB> file count`, count
//! descending). Prints groups / files / code files / pairs on stderr, so a repo
//! that yielded no vocabulary is a number rather than an empty file nobody
//! looked at.
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
//! one thread per core, each with its own extractor and its own local counts,
//! merged at the end. Per-thread state rather than a shared map is not caution
//! about locking -- a `tree_sitter` parser is not safe to share, and neither is a
//! grammar handle mid-load, so the only sharing here is the immutable path list.
//!
//! ## Raw tags are still never stored
//!
//! ~942 MB of tags on a large repo against 6.9 MB of vocabulary. The script piped
//! each worker's tags straight into the reduction for that reason; here they are
//! reduced in the same loop that produces them and only `group <TAB> word` counts
//! survive.

const std = @import("std");
const core = @import("core");
const treesitter = @import("treesitter");
const adapters = @import("adapters");
const enumerate_cmd = @import("enumerate_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var repo: ?[]const u8 = null;
    var depth: usize = 2;
    var out_dir: ?[]const u8 = null;
    var lists: ?[]const u8 = null;
    var chunk: ?usize = null;

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
        } else return usage();
    }

    const cwd = Io.Dir.cwd();

    const out = out_dir orelse env.get("SYNAPSE_WORK_DIR") orelse {
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

    var ex: Ex = .init(gpa, registry, grammars_dir);
    defer ex.deinit();
    if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch 300;

    // Which extensions have a usable grammar, from the registry rather than a
    // second hardcoded list. A hardcoded copy is how a real, already-registered
    // grammar stayed invisible to this script for every project that never got
    // its own copy of the list edited.
    const usable = try registry.usableExtensions(gpa);
    defer gpa.free(usable);

    return build(Ex, gpa, io, env, registry, grammars_dir, .{
        .root = root,
        .out = out,
        .depth = depth,
        .lists = lists,
        .usable = usable,
        .chunk = chunk,
    });
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>] [--lists <dir>]
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

    // The code subset: a usable grammar, and not machine output that happens to
    // end in a code extension. `core.enumerate.isNoise` already knows the second
    // rule -- it is the same `.min.js`/`.map` set, and one definition beats two.
    var code: std.ArrayListUnmanaged([]const u8) = .empty;
    for (kept.items) |p| {
        if (core.enumerate.isNoise(p)) continue;
        if (!hasUsableExtension(p, opts.usable)) continue;
        try code.append(arena, p);
    }

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

    // `group <TAB> word` -> count, interned into the arena so a key outlives the
    // tag it came from.
    var pairs: std.StringHashMapUnmanaged(usize) = .empty;

    const cores = std.Thread.getCpuCount() catch 4;
    // One chunk per core, floor 500 -- the script's rule, kept because it is the
    // right shape: fewer, larger batches amortise a grammar load per thread, and
    // a floor stops a small repo spawning twelve threads to tag forty files.
    const chunk = opts.chunk orelse @max(500, (code.items.len + cores - 1) / cores);
    const workers = @min(cores, (code.items.len + chunk - 1) / chunk);

    const Worker = struct {
        // Everything a thread needs, and nothing shared but the immutable inputs.
        // A `tree_sitter` parser cannot be shared and neither can a grammar
        // handle mid-load, so each thread gets its own extractor and its own
        // counts; the merge is single-threaded afterwards.
        gpa: Allocator,
        io: Io,
        registry: treesitter.Registry,
        grammars_dir: []const u8,
        lock_tries: ?usize,
        root: []const u8,
        paths: []const []const u8,
        groups: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
        stopwords: *const std.StringHashMapUnmanaged(void),
        /// Owned by the thread, drained by the caller. Keys are owned too, so a
        /// merge can take them without a second copy.
        local: std.StringHashMapUnmanaged(usize) = .empty,
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

            var words: std.ArrayListUnmanaged([]u8) = .empty;
            defer words.deinit(self.gpa);

            for (self.paths, results) |path, r| {
                if (r != .tagged) continue;
                const path_groups = self.groups.get(path) orelse continue;
                for (r.tagged) |tg| {
                    words.clearRetainingCapacity();
                    defer for (words.items) |w| self.gpa.free(w);
                    try core.vocab.splitWords(self.gpa, tg.tag.name, &words);
                    for (words.items) |w| {
                        if (!core.vocab.keep(w, self.stopwords)) continue;
                        for (path_groups.items) |g| {
                            const key = try std.fmt.allocPrint(self.gpa, "{s}\t{s}", .{ g, w });
                            const gop = try self.local.getOrPut(self.gpa, key);
                            if (gop.found_existing) {
                                self.gpa.free(key);
                            } else gop.value_ptr.* = 0;
                            gop.value_ptr.* += 1;
                        }
                    }
                }
            }
        }
    };

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
        // The last worker takes the remainder, so no path is dropped when the
        // count does not divide evenly.
        const take = if (i + 1 == workers) code.items.len - assigned else @min(chunk, code.items.len - assigned);
        w.* = .{
            .gpa = gpa,
            .io = io,
            .registry = registry,
            .grammars_dir = grammars_dir,
            .lock_tries = lock_tries,
            .root = opts.root,
            .paths = code.items[assigned .. assigned + take],
            .groups = &groups,
            .stopwords = &stopwords,
        };
        assigned += take;
    }

    for (threads, slots) |*th, *w| th.* = try std.Thread.spawn(.{}, Worker.work, .{w});
    for (threads) |th| th.join();

    for (slots) |*w| {
        if (w.failed) {
            std.debug.print("synapse-vocab: a tagging worker failed\n", .{});
            return 1;
        }
        var it = w.local.iterator();
        while (it.next()) |e| {
            const gop = try pairs.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += e.value_ptr.*;
        }
    }
    defer for (slots) |*w| {
        var it = w.local.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        w.local.deinit(gpa);
    };

    try writeGroupwords(gpa, io, groupwords_path, &pairs);

    std.debug.print("synapse-vocab: groups {d}, files {d}, code {d}, pairs {d} -> {s}\n", .{
        counts.count(),
        kept.items.len,
        code.items.len,
        pairs.count(),
        opts.out,
    });
    return 0;
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

const PairRow = struct { key: []const u8, count: usize };

/// `group <TAB> word <TAB> count`, group ascending then count descending -- the
/// script's `sort -k1,1 -k3,3nr`. The key already holds the tab, so the group
/// comparison is a prefix comparison of the whole key up to it.
fn writeGroupwords(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    pairs: *std.StringHashMapUnmanaged(usize),
) !void {
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
    defer body.deinit();
    for (rows) |r| try body.writer.print("{s}\t{d}\n", .{ r.key, r.count });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}
