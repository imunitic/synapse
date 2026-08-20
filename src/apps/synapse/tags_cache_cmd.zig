//! `synapse tags-cache` -- the port of `claude/lib/synapse/synapse-tags-cache.sh`.
//!
//!   tags-cache --repo-root <dir> --cache <file> --paths <tsv>   bring up to date
//!   tags-cache --dump <file>                                    what it holds
//!   tags-cache --load <file>                                    the inverse of --dump
//!   tags-cache --refs <file>                                    `_refs.tsv` rows
//!
//! Update form's exit codes are the script's, unchanged: 0 when the cache
//! is current for every requested path (including when nothing needed
//! doing), 1 for a usage error or a write failure.
//!
//! `--dump`/`--refs` are new: the storage changed to binary, so
//! `synapse-build-refs.sh`/`synapse-query.sh symbol` (both `jq` readers)
//! needed another way in, each replacing one `jq` block.
//!
//! The script's `xargs -P` chunking is gone: it existed to amortise CLI
//! startup and grammar load per file, and in-process there's no startup to
//! amortise (a grammar loads once per extension for the run's life), so one
//! extraction over every path replaces it.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const treesitter = @import("treesitter");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = core.tags_cache.Cache;
const PathHash = core.tags_cache.PathHash;
const Update = core.tags_cache.Update;

pub fn run(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    trace: ?[]const u8,
) !u8 {
    var repo_root: ?[]const u8 = null;
    var cache_path: ?[]const u8 = null;
    var paths_file: ?[]const u8 = null;
    var dump: ?[]const u8 = null;
    var load: ?[]const u8 = null;
    var refs: ?[]const u8 = null;

    while (args.next()) |arg| {
        // Help must not need an environment.
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        const target: *?[]const u8 =
            if (std.mem.eql(u8, arg, "--repo-root")) &repo_root
            else if (std.mem.eql(u8, arg, "--cache")) &cache_path
            else if (std.mem.eql(u8, arg, "--paths")) &paths_file
            else if (std.mem.eql(u8, arg, "--dump")) &dump
            else if (std.mem.eql(u8, arg, "--load")) &load
            else if (std.mem.eql(u8, arg, "--refs")) &refs
            else return usage();
        target.* = args.next() orelse return usage();
    }

    if (dump) |p| return dumpCache(io, p);
    if (load) |p| return loadCache(gpa, io, p);
    if (refs) |p| return refsFrom(io, p);

    const root = repo_root orelse return usage();
    const cache_file = cache_path orelse return usage();
    const list = paths_file orelse return usage();
    return update(Ex, gpa, io, env, root, cache_file, list, trace);
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse tags-cache --repo-root <dir> --cache <file> --paths <tsv>
        \\       synapse tags-cache --dump <file>
        \\       synapse tags-cache --load <file>   (reads --dump's format on stdin)
        \\       synapse tags-cache --refs <file>
        \\
    , .{});
    return 1;
}

fn update(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo_root: []const u8,
    cache_path: []const u8,
    paths_file: []const u8,
    trace: ?[]const u8,
) !u8 {
    const cwd = Io.Dir.cwd();
    cwd.access(io, repo_root, .{}) catch return 1;

    const listing = cwd.readFileAlloc(io, paths_file, gpa, .limited(64 << 20)) catch return 1;
    defer gpa.free(listing);

    var requested: std.ArrayListUnmanaged(PathHash) = .empty;
    defer requested.deinit(gpa);
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue; // last tab: a path may contain one
        const p = line[0..tab];
        const hex = line[tab + 1 ..];
        if (p.len == 0) continue;
        const hash = core.model.SourceRef.hashFromHex(hex) catch continue;
        try requested.append(gpa, .{ .path = p, .hash = hash });
    }

    var cache = try Cache.open(io, cache_path);
    defer cache.close(io);

    backfill(Ex, gpa, io, env, repo_root, &cache, requested.items, trace) catch {
        // `backfill` stays silent -- it also backs write-node's/query symbol's
        // non-fatal refresh. This is the one fatal caller, so it prints here.
        std.debug.print("synapse-tags-cache: could not bring the cache up to date\n", .{});
        return 1;
    };
    return 0;
}

/// Tags whatever the cache is missing for `requested`, and commits it. Split
/// out of `update` since `synapse query symbol` needs exactly this. A later
/// `cache.get`'s slices point into the mapping this may have replaced, so
/// callers read the cache after this returns, never across it.
pub fn backfill(
    comptime Ex: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo_root: []const u8,
    cache: *Cache,
    requested: []const PathHash,
    trace: ?[]const u8,
) !void {
    const need = try cache.needsTagging(gpa, requested);
    defer gpa.free(need);
    if (need.len == 0) { // the common case: most calls end here
        if (cache.map == null) _ = try cache.commit(gpa, io, &.{}, &.{}); // absent must still exist afterward

        return;
    }

    var paths = try gpa.alloc([]const u8, need.len);
    defer gpa.free(paths);
    for (need, 0..) |n, i| paths[i] = n.path;

    var registry = try loadRegistry(gpa, io, env);
    defer registry.deinit();
    const grammars_dir = try grammarsDir(gpa, env);
    defer gpa.free(grammars_dir);
    const kind_rules_path = try kindRulesPath(gpa, io, env);
    defer gpa.free(kind_rules_path);
    var kind_rules = try core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path);
    defer kind_rules.deinit();

    var ex: Ex = .init(gpa, registry, grammars_dir, kind_rules);
    defer ex.deinit();
    if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch treesitter.grammar.default_lock_tries;
    ex.query_override_dir = env.get("SYNAPSE_GRAMMARS_QUERY_PATH");

    try writeTrace(io, trace, paths);

    const results = try ex.tagWithSpans(gpa, io, repo_root, paths);
    defer {
        for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(gpa, r.tagged);
        gpa.free(results);
    }

    var rendered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (rendered.items) |b| gpa.free(b);
        rendered.deinit(gpa);
    }
    var updates = try gpa.alloc(Update, need.len);
    defer gpa.free(updates);

    for (need, results, 0..) |n, r, i| {
        switch (r) {
            .unsupported => updates[i] = .{
                .path = n.path,
                .entry = .{ .hash = n.hash, .tags = "", .unsupported = true },
            },
            .tagged => |tagged| {
                // Text, not structs -- core.symbol.zig's matches() field-splits
                // these lines directly (query_cmd's native `symbol` port kept
                // this dependency rather than resolving it), and Cache.writeRefs
                // needs this exact rendering for _refs.tsv's look-compat bytes.
                var buf: std.Io.Writer.Allocating = .init(gpa);
                errdefer buf.deinit();
                for (tagged) |t| try treesitter.tagger.renderCliLine(&buf.writer, t.tag, t.span);
                const text = try buf.toOwnedSlice();
                try rendered.append(gpa, text);
                updates[i] = .{
                    .path = n.path,
                    .entry = .{ .hash = n.hash, .tags = std.mem.trimEnd(u8, text, "\n") },
                };
            },
        }
    }

    _ = try cache.commit(gpa, io, updates, &.{});
}

/// One line per fact, marker first, since a tag line contains tabs of its own:
///
///   H <TAB> path <TAB> hash      every entry
///   U <TAB> path                 cached, but unparseable (no grammar)
///   P <TAB> path                 cached and parsed; tags follow, possibly none
///   T <TAB> path <TAB> tag line  one per tag
fn dumpCache(io: Io, path: []const u8) !u8 {
    var cache = try Cache.open(io, path);
    defer cache.close(io);
    if (cache.discarded) |e| {
        std.debug.print("synapse-tags-cache: unreadable cache ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var i: u32 = 0;
    while (i < cache.count()) : (i += 1) {
        const r = cache.view.record(i);
        const p = cache.view.path(r);
        try out.interface.print("H\t{s}\t{s}\n", .{ p, &core.model.SourceRef.hashToHex(r.hash) });
        if (r.unsupported()) {
            try out.interface.print("U\t{s}\n", .{p});
            continue;
        }
        try out.interface.print("P\t{s}\n", .{p});
        var lines = std.mem.splitScalar(u8, cache.view.tags(r), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try out.interface.print("T\t{s}\t{s}\n", .{ p, line });
        }
    }
    try out.interface.flush();
    return 0;
}

/// Builds a cache from `--dump`'s own output, read on stdin -- the inverse,
/// so tests can construct caches with awkward tag lines without a bespoke
/// fixture format.
fn loadCache(gpa: Allocator, io: Io, path: []const u8) !u8 {
    var in_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().reader(io, &in_buf);
    const text = in.interface.allocRemaining(gpa, .limited(64 << 20)) catch return 1;
    defer gpa.free(text);

    // Entries accumulate in input order; `commit` sorts them.
    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer order.deinit(gpa);
    var byPath: std.StringHashMapUnmanaged(core.tags_cache.Entry) = .empty;
    defer byPath.deinit(gpa);
    var tag_text: std.StringHashMapUnmanaged(std.Io.Writer.Allocating) = .empty;
    defer {
        var it = tag_text.valueIterator();
        while (it.next()) |w| w.deinit();
        tag_text.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 2 or line[1] != '\t') continue;
        const rest = line[2..];
        switch (line[0]) {
            'H' => {
                const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
                const p = rest[0..tab];
                const hash = core.model.SourceRef.hashFromHex(rest[tab + 1 ..]) catch continue;
                const gop = try byPath.getOrPut(gpa, p);
                if (!gop.found_existing) {
                    try order.append(gpa, p);
                    gop.value_ptr.* = .{ .hash = hash, .tags = "" };
                } else gop.value_ptr.hash = hash;
            },
            'U' => if (byPath.getPtr(rest)) |e| {
                e.unsupported = true;
            },
            'P' => {},
            'T' => {
                const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
                const p = rest[0..tab];
                if (!byPath.contains(p)) continue;
                const gop = try tag_text.getOrPut(gpa, p);
                if (!gop.found_existing) gop.value_ptr.* = .init(gpa);
                if (gop.value_ptr.written().len != 0) try gop.value_ptr.writer.writeAll("\n");
                try gop.value_ptr.writer.writeAll(rest[tab + 1 ..]);
            },
            else => {},
        }
    }

    var updates = try gpa.alloc(Update, order.items.len);
    defer gpa.free(updates);
    for (order.items, 0..) |p, i| {
        var e = byPath.get(p).?;
        if (tag_text.getPtr(p)) |w| e.tags = w.written();
        updates[i] = .{ .path = p, .entry = e };
    }

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = cache.commit(gpa, io, updates, &.{}) catch return 1;
    return 0;
}

/// `_refs.tsv` rows, unsorted -- the caller sorts, since that file is
/// binary-searched in `LC_ALL=C sort` order, not this one's.
fn refsFrom(io: Io, path: []const u8) !u8 {
    var cache = try Cache.open(io, path);
    defer cache.close(io);
    if (cache.discarded) |e| {
        std.debug.print("synapse-tags-cache: unreadable cache ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    _ = try cache.writeRefs(&out.interface);
    try out.interface.flush();
    return 0;
}

fn loadRegistry(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !treesitter.Registry {
    const home = env.get("HOME") orelse return error.NoHome;
    const p = (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-grammars.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(p);
    return treesitter.Registry.load(gpa, io, p);
}

fn grammarsDir(gpa: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("SYNAPSE_GRAMMARS_DIR")) |d| return gpa.dupe(u8, d);
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
}

/// `~/.claude/synapse-kind-synonyms.conf` (`SYNAPSE_KIND_SYNONYMS_CONF`
/// overrides it); absent is a supported state.
fn kindRulesPath(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("SYNAPSE_KIND_SYNONYMS_CONF")) |p| return gpa.dupe(u8, p);
    if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-kind-synonyms.conf")) |p| return p;
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.claude/synapse-kind-synonyms.conf", .{home});
}

/// Shared with `tags`: the record `synapse-fake` writes so a test can
/// assert N files cost one extraction. See `tags.zig`'s `Trace`.
fn writeTrace(io: Io, trace: ?[]const u8, paths: []const []const u8) !void {
    const path = trace orelse return;
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    w.pos = (try f.stat(io)).size;
    try w.interface.writeAll("tags");
    for (paths) |p| try w.interface.print(" {s}", .{p});
    try w.interface.writeAll("\n");
    for (paths) |p| try w.interface.print("path {s}\n", .{p});
    try w.interface.flush();
}
