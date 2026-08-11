//! `synapse tags-cache` -- the port of `claude/lib/synapse/synapse-tags-cache.sh`.
//!
//!   tags-cache --repo-root <dir> --cache <file> --paths <tsv>   bring up to date
//!   tags-cache --dump <file>                                    what it holds
//!   tags-cache --load <file>                                    the inverse of --dump
//!   tags-cache --refs <file>                                    `_refs.tsv` rows
//!
//! The update form is the script's, and its exit codes are unchanged: 0 when
//! the cache is current for every requested path -- including when nothing
//! needed doing -- and 1 for a usage error or a cache that could not be
//! written.
//!
//! **The two read forms are new, and they exist because the storage changed.**
//! `synapse-build-refs.sh` and `synapse-query.sh symbol` both read the cache
//! with `jq`, so a binary cache is unreadable to them until they have another
//! way in. `--dump` and `--refs` are that way: each replaces one `jq` block in
//! one script, which is a far smaller change than porting either script whole,
//! and neither script's own CLI contract moves.
//!
//! **What the parallel chunking became: nothing.** The script split the work
//! across `xargs -P` workers because CLI startup and grammar load dominated
//! per-file cost, and chunking was how it stopped paying that per file. In
//! process there is no startup to amortise -- a grammar is loaded once per
//! extension, for the life of the run -- so one extraction over every path
//! that needs one replaces the whole apparatus. Whether the lost CPU
//! parallelism costs anything on a cold repository is a real question and an
//! open one; see the task note's measurement item.

const std = @import("std");
const core = @import("core");
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
        // Split on the LAST tab, not the first: a repo-relative path may
        // contain one, and the hash never does.
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
        const p = line[0..tab];
        const hex = line[tab + 1 ..];
        if (p.len == 0) continue;
        const hash = core.model.SourceRef.hashFromHex(hex) catch continue;
        try requested.append(gpa, .{ .path = p, .hash = hash });
    }

    var cache = try Cache.open(io, cache_path);
    defer cache.close(io);

    const need = try cache.needsTagging(gpa, requested.items);
    defer gpa.free(need);
    // Nothing to do is a success, and it is the common case: the whole point
    // of the cache is that most calls end here.
    if (need.len == 0) {
        // An absent cache still has to exist afterwards, so a later reader
        // finds an empty cache rather than nothing at all -- the script
        // created one with `printf '{}'` for the same reason.
        if (cache.map == null) _ = try cache.commit(gpa, io, &.{}, &.{});
        return 0;
    }

    var paths = try gpa.alloc([]const u8, need.len);
    defer gpa.free(paths);
    for (need, 0..) |n, i| paths[i] = n.path;

    var registry = try loadRegistry(gpa, io, env);
    defer registry.deinit();
    const grammars_dir = try grammarsDir(gpa, env);
    defer gpa.free(grammars_dir);

    var ex: Ex = .init(gpa, registry, grammars_dir);
    defer ex.deinit();
    if (env.get("SYNAPSE_GRAMMAR_LOCK_TRIES")) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch 300;

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
                // The cache holds the extractor's *text*, not its structs.
                // That is transitional: `synapse-query.sh symbol` still reads
                // these lines and matches on their first field, so the payload
                // stays the bytes it has always been until that script is
                // ported. Re-parsing them in `writeRefs` is the price.
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

    _ = cache.commit(gpa, io, updates, &.{}) catch return 1;
    return 0;
}

/// One line per fact, marker first, so a consumer can read it with `awk`
/// without counting fields -- a tag line contains tabs of its own.
///
///   H <TAB> path <TAB> hash      every entry
///   U <TAB> path                 cached, but unparseable (no grammar)
///   P <TAB> path                 cached and parsed; tags follow, possibly none
///   T <TAB> path <TAB> tag line  one per tag
///
/// `H` is additional to what `synapse-query.sh`'s `jq` emitted, and its `awk`
/// ignores markers it does not know, so that script's join is unchanged.
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

/// Build a cache from `--dump`'s own output, read on stdin.
///
/// The inverse of `--dump`, and it exists for the tests: `synapse-build-refs`
/// and `synapse-callers` are checked against caches holding deliberately
/// awkward tag lines -- a padded name, a tab inside an expression, a malformed
/// row -- which they used to author as JSON by hand and no longer can. Making
/// the projection round-trip is a better answer than a bespoke fixture format,
/// and a dump that cannot be loaded back is a projection nobody can check.
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

/// `_refs.tsv` rows, unsorted. The caller sorts: that file is binary-searched
/// with `look`, which compares raw bytes, so its order is `LC_ALL=C sort`'s
/// and not this one's.
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
    const p = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-grammars.conf", .{home});
    defer gpa.free(p);
    return treesitter.Registry.load(gpa, io, p);
}

fn grammarsDir(gpa: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("SYNAPSE_GRAMMARS_DIR")) |d| return gpa.dupe(u8, d);
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.cache/synapse/grammars", .{home});
}

/// Shared with `tags`: the record `synapse-fake` writes so a test can assert
/// that N files cost one extraction. See `tags.zig`'s own `Trace`.
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
