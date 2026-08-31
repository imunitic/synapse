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
const context = @import("context.zig");

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

pub fn update(
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

    const listing = cwd.readFileAlloc(io, paths_file, gpa, context.maxListingBytes(env, 64 << 20)) catch return 1;
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
    const grammars_dir = try grammarsDir(gpa, io, env);
    defer gpa.free(grammars_dir);
    const kind_rules_path = try kindRulesPath(gpa, io, env);
    defer gpa.free(kind_rules_path);
    var kind_rules = try core.kind_synonyms.RuleList.load(gpa, io, kind_rules_path);
    defer kind_rules.deinit();

    var ex: Ex = .init(gpa, registry, grammars_dir, kind_rules);
    defer ex.deinit();
    // Both resolve through `core.conf.resolve` like `SYNAPSE_GRAMMARS_DIR`
    // above -- a real environment variable wins, then the first conf file
    // defining the key. They used to be bare `env.get`, which made a
    // `synapse.conf` line for either one silently inert.
    const lock_tries_raw = try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMAR_LOCK_TRIES");
    defer if (lock_tries_raw) |t| gpa.free(t);
    if (lock_tries_raw) |t|
        ex.lock_tries = std.fmt.parseInt(usize, t, 10) catch treesitter.grammar.default_lock_tries;
    // Owned now, where `env.get` returned a borrow into the environment:
    // `ex` holds this slice rather than copying it, so the free has to
    // outlive every `ex` call below. `Extractor.deinit` never reads it, so
    // the LIFO order against `defer ex.deinit()` is not a use-after-free.
    const query_override_dir = try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMARS_QUERY_PATH");
    defer if (query_override_dir) |d| gpa.free(d);
    ex.query_override_dir = query_override_dir;

    try writeTrace(io, trace, paths);

    const results = try ex.tagWithSpans(gpa, io, repo_root, paths);
    defer {
        for (results) |r| if (r == .tagged) treesitter.tagger.freeTagged(gpa, r.tagged);
        gpa.free(results);
    }

    var encoded: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (encoded.items) |b| gpa.free(b);
        encoded.deinit(gpa);
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
                // Structured data, not rendered display text -- see
                // core.tags_cache.payload's own docs for why. Every reader
                // (core.symbol.zig's matches(), rank_cmd, vocab_cmd,
                // Cache.writeRefs) decodes this directly now.
                var buf: std.Io.Writer.Allocating = .init(gpa);
                errdefer buf.deinit();
                for (tagged) |t| try core.tags_cache.payload.encodeOne(&buf.writer, t.tag);
                const bytes = try buf.toOwnedSlice();
                try encoded.append(gpa, bytes);
                updates[i] = .{
                    .path = n.path,
                    .entry = .{ .hash = n.hash, .tags = bytes },
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
///
/// The tag line is `tag_line.parse`'s own grammar (name, ` | `kind, role
/// `(row, col) - (row, col)` `` `expression` `` -- column/end-position are
/// always written as the row twice, since nothing decodes them back out of
/// storage any more). A name, kind, or expression containing a tab, newline,
/// or backtick cannot round-trip through this text form -- an inherent limit
/// of `tag_line`'s grammar, not new here; `Entry.tags` itself has no such
/// limit, since `--dump`/`--load` are a debug/test-fixture view onto it, not
/// how it is actually stored.
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
        var it = core.tags_cache.payload.iterate(cache.view.tags(r));
        while (it.next()) |tag| {
            try out.interface.print("T\t{s}\t{s}\t | {s}\t{s} ({d}, 0) - ({d}, 0) `{s}`\n", .{
                p, tag.name, tag.kind, tag.role.text(), tag.line, tag.line, tag.expression,
            });
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
    var tags_by_path: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(core.model.Tag)) = .empty;
    defer {
        var it = tags_by_path.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        tags_by_path.deinit(gpa);
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
                const tag = core.tag_line.parse(rest[tab + 1 ..]) orelse continue;
                const gop = try tags_by_path.getOrPut(gpa, p);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, tag);
            },
            else => {},
        }
    }

    var updates = try gpa.alloc(Update, order.items.len);
    defer gpa.free(updates);
    var encoded: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (encoded.items) |b| gpa.free(b);
        encoded.deinit(gpa);
    }
    for (order.items, 0..) |p, i| {
        var e = byPath.get(p).?;
        if (tags_by_path.getPtr(p)) |list| {
            const bytes = try core.tags_cache.payload.encode(gpa, list.items);
            try encoded.append(gpa, bytes);
            e.tags = bytes;
        }
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

fn grammarsDir(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ![]u8 {
    if (try core.conf.resolve(gpa, io, adapters.env.vars(env), "SYNAPSE_GRAMMARS_DIR")) |d| return d;
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

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");

/// A compile-time 40-hex-char hash from a small integer -- distinct fixture
/// files never need a real git hash, only distinct/stable ones, since
/// `Cache.needsTagging` only ever compares hash bytes for equality.
fn hx(comptime n: u32) []const u8 {
    return comptime std.fmt.comptimePrint("{x:0>40}", .{n});
}

/// A real `Fixture` plus `.ml` registered in a real `synapse-grammars.conf`
/// (matching `fake_grammar.FakeBackend`'s taggable extensions) -- `update`'s
/// own grammar resolution reads that file for real, so a `.ml` file with no
/// registry entry would score `.unsupported` before `FakeBackend.tagFile`
/// ever ran.
const TagsFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !TagsFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        try fx.writeGrammars();
        return .{ .fx = fx };
    }

    fn deinit(self: *TagsFixture) void {
        self.fx.deinit();
    }

    fn src(self: *TagsFixture, path: []const u8, content: []const u8) !void {
        try self.fx.writeRepoFile(path, content);
    }

    fn cachePath(self: *TagsFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/_tags_cache.bin", .{self.fx.work});
    }

    /// Writes an absolute `paths.tsv` from (path, hash-hex) pairs and calls
    /// `update` with `fake_grammar.FakeExtractor` -- `trace_path`, when
    /// given, is the same file `writeTrace` appends "tags ...\n"/"path
    /// ...\n" lines to for every real `synapse-fake` run, read back here
    /// directly instead of through a shelled-out log file.
    fn run(self: *TagsFixture, pairs: []const [2][]const u8, trace_path: ?[]const u8) !u8 {
        const gpa = self.fx.gpa;
        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        for (pairs) |p| try body.writer.print("{s}\t{s}\n", .{ p[0], p[1] });
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/paths.tsv", .data = body.written() });
        const paths_file = try std.fmt.allocPrint(gpa, "{s}/paths.tsv", .{self.fx.work});
        defer gpa.free(paths_file);
        const cache_path = try self.cachePath();
        defer gpa.free(cache_path);
        return update(fake_grammar.FakeExtractor, self.fx.gpa, self.fx.io(), &self.fx.env, self.fx.repo, cache_path, paths_file, trace_path);
    }

    /// `Cache.get`'s own slices point into the mapping, invalidated the
    /// instant this closes it -- returns an owned copy instead so a test
    /// can read `.tags` after this returns. Caller frees `.tags`.
    fn get(self: *TagsFixture, path: []const u8) !?core.tags_cache.Entry {
        const cache_path = try self.cachePath();
        defer self.fx.gpa.free(cache_path);
        var cache = try Cache.open(testing.io, cache_path);
        defer cache.close(testing.io);
        const e = cache.get(path) orelse return null;
        return .{ .hash = e.hash, .tags = try self.fx.gpa.dupe(u8, e.tags), .unsupported = e.unsupported };
    }

    fn tracePath(self: *TagsFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/trace.log", .{self.fx.work});
    }

    /// Count of lines starting with `prefix` (` ` included) in the trace
    /// file -- the native equivalent of bats' `grep -c '^path '`.
    fn traceCount(self: *TagsFixture, prefix: []const u8) !usize {
        const text = self.fx.tmp.dir.readFileAlloc(testing.io, "work/trace.log", self.fx.gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) return 0;
            return e;
        };
        defer self.fx.gpa.free(text);
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, prefix)) n += 1;
        }
        return n;
    }
};

test "cold cache: tags every requested file, records hash and tags" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("sample_1.ml", "let x_1 = 1\n");
    try tf.src("sample_2.ml", "let x_2 = 2\n");
    try tf.src("sample_3.ml", "let x_3 = 3\n");

    const trace_path = try tf.tracePath();
    defer gpa.free(trace_path);
    const code = try tf.run(&.{
        .{ "sample_1.ml", hx(1) },
        .{ "sample_2.ml", hx(2) },
        .{ "sample_3.ml", hx(3) },
    }, trace_path);
    try testing.expectEqual(@as(u8, 0), code);

    const e1 = (try tf.get("sample_1.ml")).?;
    defer gpa.free(e1.tags);
    try testing.expect(std.mem.indexOf(u8, e1.tags, "FAKE_NAME") != null);
    try testing.expect(!e1.unsupported);
    try testing.expectEqualSlices(u8, &(try core.model.SourceRef.hashFromHex(hx(1))), &e1.hash);
    // Every requested file was tagged in one extraction pass, not three
    // separate ones -- grammar load is nearly all of the per-file cost.
    try testing.expectEqual(@as(usize, 3), try tf.traceCount("path "));
    try testing.expectEqual(@as(usize, 1), try tf.traceCount("tags "));
}

test "unchanged hashes: no re-tagging on a second run" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("sample_1.ml", "let x_1 = 1\n");
    _ = try tf.run(&.{.{ "sample_1.ml", hx(1) }}, null);

    const trace_path = try tf.tracePath();
    defer gpa.free(trace_path);
    const code = try tf.run(&.{.{ "sample_1.ml", hx(1) }}, trace_path);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 0), try tf.traceCount("path "));
}

test "one file's hash changes: only that file is re-tagged, others untouched" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("sample_1.ml", "let x_1 = 1\n");
    try tf.src("sample_2.ml", "let x_2 = 2\n");
    try tf.src("sample_3.ml", "let x_3 = 3\n");
    _ = try tf.run(&.{
        .{ "sample_1.ml", hx(1) },
        .{ "sample_2.ml", hx(2) },
        .{ "sample_3.ml", hx(3) },
    }, null);
    const before_2 = (try tf.get("sample_2.ml")).?;
    defer gpa.free(before_2.tags);
    const before_3 = (try tf.get("sample_3.ml")).?;
    defer gpa.free(before_3.tags);

    try tf.src("sample_1.ml", "let x_1 = 999 (* changed *)\n");
    const trace_path = try tf.tracePath();
    defer gpa.free(trace_path);
    const code = try tf.run(&.{
        .{ "sample_1.ml", hx(11) },
        .{ "sample_2.ml", hx(2) },
        .{ "sample_3.ml", hx(3) },
    }, trace_path);
    try testing.expectEqual(@as(u8, 0), code);
    // Which file was tagged, not how many calls happened.
    try testing.expectEqual(@as(usize, 1), try tf.traceCount("path "));

    const e1 = (try tf.get("sample_1.ml")).?;
    defer gpa.free(e1.tags);
    try testing.expectEqualSlices(u8, &(try core.model.SourceRef.hashFromHex(hx(11))), &e1.hash);
    const after_2 = (try tf.get("sample_2.ml")).?;
    defer gpa.free(after_2.tags);
    const after_3 = (try tf.get("sample_3.ml")).?;
    defer gpa.free(after_3.tags);
    try testing.expectEqualSlices(u8, &before_2.hash, &after_2.hash);
    try testing.expectEqualStrings(before_2.tags, after_2.tags);
    try testing.expectEqualSlices(u8, &before_3.hash, &after_3.hash);
    try testing.expectEqualStrings(before_3.tags, after_3.tags);
}

test "unsupported file: recorded as unsupported, never retried while unchanged" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("sample.unknownext", "no grammar for this\n");
    // No registry entry for "unknownext" at all -- the same outcome as a
    // grammar that fails to build.

    const code = try tf.run(&.{.{ "sample.unknownext", hx(1) }}, null);
    try testing.expectEqual(@as(u8, 0), code);
    const e = (try tf.get("sample.unknownext")).?;
    defer gpa.free(e.tags);
    try testing.expect(e.unsupported);
    try testing.expectEqualStrings("", e.tags);

    const trace_path = try tf.tracePath();
    defer gpa.free(trace_path);
    const code2 = try tf.run(&.{.{ "sample.unknownext", hx(1) }}, trace_path);
    try testing.expectEqual(@as(u8, 0), code2);
    try testing.expectEqual(@as(usize, 0), try tf.traceCount("path "));
}

test "a file that parsed to no tags is NOT recorded as unsupported" {
    // The distinction the batched shell form once lost: an unparseable file
    // is absent from a grammar entirely, while a file that parsed and
    // simply had nothing in it still gets its path recorded, tags empty.
    // Conflating them would make `synapse query symbol` report a perfectly
    // readable file as "not checked", and re-tag it on every call.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("empty.ml", "notags\n");
    try tf.src("full.ml", "let x = 1\n");
    try tf.src("other.unknownext", "no grammar for this\n");

    const code = try tf.run(&.{
        .{ "empty.ml", hx(1) },
        .{ "full.ml", hx(2) },
        .{ "other.unknownext", hx(3) },
    }, null);
    try testing.expectEqual(@as(u8, 0), code);

    const empty = (try tf.get("empty.ml")).?;
    defer gpa.free(empty.tags);
    try testing.expect(!empty.unsupported);
    try testing.expectEqualStrings("", empty.tags);
    const full = (try tf.get("full.ml")).?;
    defer gpa.free(full.tags);
    try testing.expect(std.mem.indexOf(u8, full.tags, "FAKE_NAME") != null);
    const other = (try tf.get("other.unknownext")).?;
    defer gpa.free(other.tags);
    try testing.expect(other.unsupported);

    // All three are current: none is re-attempted.
    const trace_path = try tf.tracePath();
    defer gpa.free(trace_path);
    _ = try tf.run(&.{
        .{ "empty.ml", hx(1) },
        .{ "full.ml", hx(2) },
        .{ "other.unknownext", hx(3) },
    }, trace_path);
    try testing.expectEqual(@as(usize, 0), try tf.traceCount("path "));
}

test "tags are attributed to the right file, never bleeding into a neighbor" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("a.ml", "symbol:AlphaOnly\n");
    try tf.src("b.ml", "symbol:BetaOnly\n");
    try tf.src("c.ml", "notags\n");

    _ = try tf.run(&.{
        .{ "a.ml", hx(1) },
        .{ "b.ml", hx(2) },
        .{ "c.ml", hx(3) },
    }, null);

    const a = (try tf.get("a.ml")).?;
    defer gpa.free(a.tags);
    try testing.expect(std.mem.indexOf(u8, a.tags, "AlphaOnly") != null);
    try testing.expect(std.mem.indexOf(u8, a.tags, "BetaOnly") == null);
    const b = (try tf.get("b.ml")).?;
    defer gpa.free(b.tags);
    try testing.expect(std.mem.indexOf(u8, b.tags, "BetaOnly") != null);
    try testing.expect(std.mem.indexOf(u8, b.tags, "AlphaOnly") == null);
    const c = (try tf.get("c.ml")).?;
    defer gpa.free(c.tags);
    try testing.expectEqualStrings("", c.tags);
}

test "a cached tag's name decodes trimmed, with no tree-sitter table padding" {
    // Consumers decode the payload and read `tag.name` as the symbol; any
    // leftover padding would corrupt it, making `synapse query symbol`
    // silently miss a file it did read.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("a.ml", "symbol:AlphaOnly\n");
    _ = try tf.run(&.{.{ "a.ml", hx(1) }}, null);

    const a = (try tf.get("a.ml")).?;
    defer gpa.free(a.tags);
    var it = core.tags_cache.payload.iterate(a.tags);
    var matched: usize = 0;
    while (it.next()) |tag| {
        if (std.mem.eql(u8, tag.name, "AlphaOnly")) matched += 1;
    }
    try testing.expectEqual(@as(usize, 1), matched);
}

test "several files needing tagging at once: every one ends up correctly cached" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    var pairs: [6][2][]const u8 = undefined;
    inline for (1..7) |i| {
        const path = std.fmt.comptimePrint("sample_{d}.ml", .{i});
        try tf.src(path, "let x = 1\n");
        pairs[i - 1] = .{ path, hx(i) };
    }

    const code = try tf.run(&pairs, null);
    try testing.expectEqual(@as(u8, 0), code);
    inline for (1..7) |i| {
        const path = std.fmt.comptimePrint("sample_{d}.ml", .{i});
        const e = (try tf.get(path)).?;
        defer gpa.free(e.tags);
        try testing.expect(std.mem.indexOf(u8, e.tags, "FAKE_NAME") != null);
    }
}

test "a path containing a space is cached correctly" {
    // A regression in the old shell implementation's per-file `xargs -L 1`
    // dispatch (which word-split on spaces as well as tabs) -- the Zig port
    // parses paths.tsv by explicit tab, never by word-splitting, so this is
    // now a plain correctness check rather than a targeted regression test.
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    try tf.src("src/some dir/spaced.ml", "let spaced = 1\n");
    try tf.src("plain.ml", "let plain = 2\n");

    const code = try tf.run(&.{
        .{ "src/some dir/spaced.ml", hx(1) },
        .{ "plain.ml", hx(2) },
    }, null);
    try testing.expectEqual(@as(u8, 0), code);
    const spaced = (try tf.get("src/some dir/spaced.ml")).?;
    defer gpa.free(spaced.tags);
    try testing.expect(std.mem.indexOf(u8, spaced.tags, "FAKE_NAME") != null);
    try testing.expectEqualSlices(u8, &(try core.model.SourceRef.hashFromHex(hx(1))), &spaced.hash);
}

test "nonexistent paths file: exit 1" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();
    const cache_path = try tf.cachePath();
    defer gpa.free(cache_path);
    const missing = try std.fmt.allocPrint(gpa, "{s}/does-not-exist.tsv", .{tf.fx.work});
    defer gpa.free(missing);

    const code = try update(fake_grammar.FakeExtractor, gpa, tf.fx.io(), &tf.fx.env, tf.fx.repo, cache_path, missing, null);
    try testing.expectEqual(@as(u8, 1), code);
}

test "empty paths file: nothing to do, exit 0, cache created but empty" {
    const gpa = testing.allocator;
    var tf = try TagsFixture.init(gpa);
    defer tf.deinit();

    const code = try tf.run(&.{}, null);
    try testing.expectEqual(@as(u8, 0), code);
    const cache_path = try tf.cachePath();
    defer gpa.free(cache_path);
    var cache = try Cache.open(testing.io, cache_path);
    defer cache.close(testing.io);
    try testing.expectEqual(@as(u32, 0), cache.count());
}
