//! `synapse build-refs` and `synapse callers` -- the writer and the reader of
//! `_refs.tsv`.
//!
//!   build-refs [--cache <f>] [--out <f>]   project the tags cache into the index
//!   callers <name> [--all]                 repo-wide sites of an exact name
//!
//! One file: they share a contract (writer's sort order, reader's search)
//! that used to be held by matching comments in two scripts. See
//! `core/refs.zig` for why byte order is no longer load-bearing to remember.
//!
//! `build-refs` used to read a 942 MB cache twice (`--refs` plus `--dump |
//! grep -c`) plus several `sort`/`awk` passes for the counts -- now one walk
//! of the record table. `callers` used to shell out to `look` (prefix
//! match, exact match left to `awk`) with an O(index) fallback that took
//! 26s against this path's 0.235s on a 1.4 GB index.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

// --- build-refs -------------------------------------------------------------

const build_prog = "synapse-build-refs";

const build_usage =
    \\usage: synapse build-refs [--cache <path>] [--out <path>]
    \\
    \\  --cache  the tags cache to project. Default $SYNAPSE_WORK_DIR/_tags_cache.bin.
    \\  --out    where to write the index. Default $SYNAPSE_WORK_DIR/_refs.tsv.
    \\
;

pub fn runBuild(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var cache_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{build_usage});
            return 0;
        }
        const dest: *?[]const u8 =
            if (std.mem.eql(u8, arg, "--cache")) &cache_path
            else if (std.mem.eql(u8, arg, "--out")) &out_path
            else {
                std.debug.print("{s}", .{build_usage});
                return 2;
            };
        dest.* = args.next() orelse {
            std.debug.print("{s}", .{build_usage});
            return 2;
        };
    }

    return buildRefs(gpa, io, env, cache_path, out_path);
}

/// The projection itself, minus argument parsing -- separated so a test
/// can drive it against a real cache file without going through the CLI.
/// `cache_path`/`out_path` still resolve against `$SYNAPSE_WORK_DIR` when
/// null, same as `runBuild`'s own default.
pub fn buildRefs(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    cache_path_in: ?[]const u8,
    out_path_in: ?[]const u8,
) !u8 {
    var cache_path = cache_path_in;
    var out_path = out_path_in;

    // Work dir supplies whichever default is missing. Explicit flags make
    // this usable against a cache for a repo not checked out here at all.
    var owned_cache: ?[]u8 = null;
    defer if (owned_cache) |p| gpa.free(p);
    var owned_out: ?[]u8 = null;
    defer if (owned_out) |p| gpa.free(p);
    if (cache_path == null or out_path == null) {
        const resolved = (try context.workDir(gpa, io, env, build_prog)) orelse return 1;
        defer resolved.deinit(gpa);
        const work = resolved.path;
        if (cache_path == null) {
            owned_cache = try std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{work});
            cache_path = owned_cache.?;
        }
        if (out_path == null) {
            owned_out = try std.fmt.allocPrint(gpa, "{s}/_refs.tsv", .{work});
            out_path = owned_out.?;
        }
    }

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, cache_path.?, .{})) |_| {} else |_| {
        std.debug.print(
            "{s}: no tags cache at {s} -- run 'synapse tags-cache' first\n",
            .{ build_prog, cache_path.? },
        );
        return 1;
    }

    var cache = core.tags_cache.Cache.open(io, cache_path.?) catch {
        std.debug.print("{s}: unreadable cache: {s}\n", .{ build_prog, cache_path.? });
        return 1;
    };
    defer cache.close(io);
    if (cache.discarded != null) {
        std.debug.print("{s}: unreadable cache: {s}\n", .{ build_prog, cache_path.? });
        return 1;
    }

    // Projected unsorted into memory (~1.4 GB of rows for a 942 MB cache):
    // `sort` needs the whole set, and holding it here trades memory for
    // two fewer full passes over a file.
    var unsorted: Io.Writer.Allocating = .init(gpa);
    defer unsorted.deinit();
    _ = try cache.writeRefs(&unsorted.writer);

    // A count of records, not rows -- "no hits" vs "never parsed".
    var unsupported: usize = 0;
    var i: u32 = 0;
    while (i < cache.count()) : (i += 1) {
        if (cache.view.record(i).unsupported()) unsupported += 1;
    }

    var sorted: Io.Writer.Allocating = .init(gpa);
    defer sorted.deinit();
    const counts = try core.refs.writeSorted(gpa, &sorted.writer, unsorted.written());

    // Rebuilt via rename, never appended to: the reader binary-searches this
    // file, and a half-written index is a wrong answer, not a missing one.
    try core.index_map.writeFile(gpa, io, out_path.?, sorted.written());

    std.debug.print(
        "{s}: {d} tags ({d} def, {d} ref) over {d} files, {d} unsupported -> {s}\n",
        .{ build_prog, counts.tags, counts.defs, counts.refs, counts.files, unsupported, out_path.? },
    );
    return 0;
}

// --- callers ----------------------------------------------------------------

const callers_prog = "synapse-callers";

const callers_usage =
    \\usage: synapse callers <name> [--all]
    \\
    \\  <name>     exact symbol name (not a prefix, not a regex)
    \\  (default)  calls only, as path:line<TAB>calling expression
    \\  --all      every def and ref, as def|ref<TAB>kind<TAB>path:line<TAB>expression
    \\
;

pub fn runCallers(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var name: []const u8 = "";
    var all = false;
    var refs_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{callers_usage});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--refs")) {
            refs_path = args.next() orelse return callersUsage();
        } else if (arg.len != 0 and arg[0] == '-') {
            return callersUsage();
        } else if (name.len == 0) {
            name = arg;
        } else return callersUsage();
    }
    if (name.len == 0) return callersUsage();

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    const code = try callers(gpa, io, env, name, all, refs_path, &out.interface);
    try out.interface.flush();
    return code;
}

/// The lookup itself, minus argument parsing -- separated so a test can
/// drive it against a real index without going through the CLI or
/// capturing stdout. `refs_path` still resolves against
/// `$SYNAPSE_WORK_DIR` when null, same as `runCallers`'s own default.
pub fn callers(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    name: []const u8,
    all: bool,
    refs_path_in: ?[]const u8,
    result: *Io.Writer,
) !u8 {
    var refs_path = refs_path_in;
    var owned: ?[]u8 = null;
    defer if (owned) |p| gpa.free(p);
    if (refs_path == null) {
        const resolved = (try context.workDir(gpa, io, env, callers_prog)) orelse return 1;
        defer resolved.deinit(gpa);
        owned = try std.fmt.allocPrint(gpa, "{s}/_refs.tsv", .{resolved.path});
        refs_path = owned.?;
    }

    // Exit 1, not 0: a missing index is "could not run", distinct from zero
    // rows from a built one ("checked, not called").
    var index = openIndex(io, gpa, refs_path.?) catch {
        std.debug.print(
            "{s}: no reference index at {s} -- run `synapse build-refs`\n",
            .{ callers_prog, refs_path.? },
        );
        return 1;
    };
    defer index.deinit(io, gpa);

    var it = core.refs.find(index.bytes, name);
    while (it.next()) |row| {
        if (all) {
            try result.print("{s}\t{s}\t{s}\t{s}\n", .{ row.dir, row.kind, row.site, row.expr });
        } else if (row.isCall()) {
            try result.print("{s}\t{s}\n", .{ row.site, row.expr });
        }
    }
    return 0; // always 0 when the index was readable, including for zero rows
}

fn callersUsage() u8 {
    std.debug.print("{s}", .{callers_usage});
    return 2;
}

/// The index, mapped when that works, read when it does not.
const Index = struct {
    bytes: []const u8,
    map: ?Io.File.MemoryMap = null,
    owned: ?[]u8 = null,

    fn deinit(self: *Index, io: Io, gpa: Allocator) void {
        if (self.map) |*m| {
            m.file.close(io);
            m.destroy(io);
        }
        if (self.owned) |b| gpa.free(b);
        self.* = .{ .bytes = "" };
    }
};

/// Maps the index rather than reading it: `find` binary-searches, touching a
/// handful of pages, but `readFileAlloc` paid for the whole file first --
/// 1.4 GB of I/O to reach twenty pages, on a large repo's index.
fn openIndex(io: Io, gpa: Allocator, path: []const u8) !Index {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    var close_file = true;
    defer if (close_file) file.close(io);

    // Empty is not missing -- a projection that ran and found nothing, exit
    // 0 with no rows. A zero-length mapping is refused by the OS, so that
    // case never reaches one.
    const size = (try file.stat(io)).size;
    if (size == 0) return .{ .bytes = "" };

    if (file.createMemoryMap(io, .{
        .len = @intCast(size),
        .protection = .{ .read = true, .write = false },
        .populate = false, // a binary search faults in only the pages it lands on
    })) |map| {
        close_file = false; // the mapping keeps its own reference to the file
        return .{ .bytes = map.memory, .map = map };
    } else |_| {}

    // Mapping can fail where reading still works (some filesystems); falling
    // back keeps the query answerable.
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 30));
    return .{ .bytes = bytes, .owned = bytes };
}

const testing = std.testing;

/// One tag, encoded as `Entry.tags` actually stores it -- what `Cache.writeRefs`
/// decodes via `payload.iterate`. `padded_name`/`kind` keep their old
/// table-padding spelling (trimmed here) so every call site below reads the
/// same as it did when this built a rendered CLI line. Caller frees.
fn tagline(gpa: Allocator, padded_name: []const u8, kind: []const u8, role: []const u8, row: u32, expr: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try core.tags_cache.payload.encodeOne(&out.writer, .{
        .name = std.mem.trim(u8, padded_name, " "),
        .role = core.model.Role.parse(role) orelse unreachable,
        .kind = std.mem.trim(u8, kind, " "),
        .line = row,
        .expression = expr,
    });
    return out.toOwnedSlice();
}

/// A real `_tags_cache.bin` in a real temp dir, built directly through
/// `core.tags_cache.Cache.commit` -- the same call `tags-cache --load`
/// makes, minus that command's own dump-text round trip, which exists so a
/// *bats* test can author a cache without a bespoke fixture format. A
/// native test doesn't need the round trip: it can hand `Entry` values
/// straight to `commit`.
const CacheFixture = struct {
    tmp: testing.TmpDir,
    gpa: Allocator,

    fn init(gpa: Allocator) !CacheFixture {
        return .{ .tmp = testing.tmpDir(.{}), .gpa = gpa };
    }

    fn deinit(self: *CacheFixture) void {
        self.tmp.cleanup();
    }

    fn build(self: *CacheFixture, updates: []const core.tags_cache.Update) ![]const u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "_tags_cache.bin", .data = "" });
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        const path = try std.fmt.allocPrint(self.gpa, "{s}/_tags_cache.bin", .{root});

        var cache = try core.tags_cache.Cache.open(testing.io, path);
        defer cache.close(testing.io);
        _ = try cache.commit(self.gpa, testing.io, updates, &.{});
        return path;
    }

    fn absPath(self: *CacheFixture, rel: []const u8) ![]const u8 {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ root, rel });
    }
};

fn h(hex: []const u8) [20]u8 {
    return core.model.SourceRef.hashFromHex(hex) catch unreachable;
}

const H1 = "1111111111111111111111111111111111111111";
const H2 = "2222222222222222222222222222222222222222";

test "build-refs: emits name/reftype/kind/path:line/expression, tab separated" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const tags = try tagline(gpa, "Token     ", "class  ", "def", 15, "public class Token {");
    defer gpa.free(tags);
    const cache_path = try fx.build(&.{.{ .path = "src/Token.java", .entry = .{ .hash = h(H1), .tags = tags } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try buildRefs(gpa, testing.io, &env, cache_path, out_path);
    try testing.expectEqual(@as(u8, 0), code);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    // Name trimmed of its padding; row taken from the first coordinate.
    try testing.expectEqualStrings(
        "Token\tdef\tclass\tsrc/Token.java:15\tpublic class Token {\n",
        out,
    );
}

test "build-refs: a short padded name is trimmed, so exact lookup finds it" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const tags = try tagline(gpa, "execute   ", "call   ", "ref", 42, "foo.execute();");
    defer gpa.free(tags);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = tags } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "execute\t"));
}

test "build-refs: unsupported files contribute nothing and are counted separately" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const tags = try tagline(gpa, "Kept      ", "class  ", "def", 1, "class Kept {}");
    defer gpa.free(tags);
    const cache_path = try fx.build(&.{
        .{ .path = "src/Kept.java", .entry = .{ .hash = h(H1), .tags = tags } },
        .{ .path = "src/data.sql", .entry = .{ .hash = h(H2), .tags = "", .unsupported = true } },
    });
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var out_writer: Io.Writer.Allocating = .init(gpa);
    defer out_writer.deinit();
    const code = try buildRefs(gpa, testing.io, &env, cache_path, out_path);
    try testing.expectEqual(@as(u8, 0), code);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "data.sql") == null);
}

test "build-refs: multiple tag lines in one file all become rows" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const a = try tagline(gpa, "A         ", "class  ", "def", 1, "class A {}");
    defer gpa.free(a);
    const b = try tagline(gpa, "run       ", "call   ", "ref", 7, "a.run();");
    defer gpa.free(b);
    const both = try std.mem.concat(gpa, u8, &.{ a, b });
    defer gpa.free(both);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = both } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
}

test "build-refs: output is LC_ALL=C sorted" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const a = try tagline(gpa, "Zebra     ", "class  ", "def", 1, "class Zebra {}");
    defer gpa.free(a);
    const b = try tagline(gpa, "apple     ", "call   ", "ref", 2, "apple();");
    defer gpa.free(b);
    const c = try tagline(gpa, "Apple     ", "class  ", "def", 3, "class Apple {}");
    defer gpa.free(c);
    const all = try std.mem.concat(gpa, u8, &.{ a, b, c });
    defer gpa.free(all);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = all } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    var prev: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (prev) |p| try testing.expect(std.mem.order(u8, p, line) != .gt);
        prev = line;
    }
}

test "build-refs: a tab inside the expression survives intact, no longer truncated" {
    // The old rendered-text storage format used tabs as its own field
    // delimiters, so an embedded tab in the expression silently truncated
    // it on the way back out. The structured payload has no such limit --
    // this is the exact bug sb-026 exists to fix.
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const tags = try tagline(gpa, "weird     ", "call   ", "ref", 5, "a\tb();");
    defer gpa.free(tags);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = tags } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "a\tb();") != null);
}

test "build-refs: a malformed tag line is skipped, not emitted half-parsed" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = "no tabs here at all" } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "build-refs: missing cache is exit 1 with a pointer to the fix" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try buildRefs(gpa, testing.io, &env, "/nonexistent/nope.bin", out_path);
    try testing.expectEqual(@as(u8, 1), code);
}

test "build-refs: unreadable cache is exit 1, not a silently empty index" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.bin", .data = "this is not a cache" });
    const cache_path = try fx.absPath("bad.bin");
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try buildRefs(gpa, testing.io, &env, cache_path, out_path);
    try testing.expectEqual(@as(u8, 1), code);
}

test "build-refs: rebuilds rather than appending" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const tags = try tagline(gpa, "Once      ", "class  ", "def", 1, "class Once {}");
    defer gpa.free(tags);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = tags } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const out = try fx.tmp.dir.readFileAlloc(testing.io, "_refs.tsv", gpa, .limited(1 << 20));
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

/// A cache with one definition, one call, and one non-call reference -- the
/// three cases the default filter has to tell apart.
fn seedIndex(gpa: Allocator, fx: *CacheFixture) ![]const u8 {
    const d = try tagline(gpa, "doThing   ", "method ", "def", 10, "public void doThing() {");
    defer gpa.free(d);
    const c = try tagline(gpa, "doThing   ", "call   ", "ref", 20, "svc.doThing();");
    defer gpa.free(c);
    const i = try tagline(gpa, "doThing   ", "implementation", "ref", 30, "class Impl implements doThing {");
    defer gpa.free(i);
    const all = try std.mem.concat(gpa, u8, &.{ d, c, i });
    defer gpa.free(all);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = all } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);
    return fx.absPath("_refs.tsv");
}

fn callersHelper(gpa: Allocator, refs_path: ?[]const u8, name: []const u8, all: bool) !struct { code: u8, out: []u8 } {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try callers(gpa, testing.io, &env, name, all, refs_path, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "callers: default returns call sites only, as path:line<TAB>expression" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const refs_path = try seedIndex(gpa, &fx);
    defer gpa.free(refs_path);

    const r = try callersHelper(gpa, refs_path, "doThing", false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("src/A.java:20\tsvc.doThing();\n", r.out);
}

test "callers: a non-call reference is not reported as a caller" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const refs_path = try seedIndex(gpa, &fx);
    defer gpa.free(refs_path);

    const r = try callersHelper(gpa, refs_path, "doThing", false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "implements") == null);
}

test "callers: --all returns defs and every ref, with reftype and kind columns" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const refs_path = try seedIndex(gpa, &fx);
    defer gpa.free(refs_path);

    const r = try callersHelper(gpa, refs_path, "doThing", true);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.out, "\n"));
    try testing.expect(std.mem.indexOf(u8, r.out, "def\t") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "ref\t") != null);
}

test "callers: a missing index is exit 1 naming the fix, not silent success" {
    const r = try callersHelper(testing.allocator, "/nonexistent/_refs.tsv", "doThing", false);
    defer testing.allocator.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "callers: an empty index is 'checked, not called', not a missing index" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "_refs.tsv", .data = "" });
    const refs_path = try fx.absPath("_refs.tsv");
    defer gpa.free(refs_path);

    const r = try callersHelper(gpa, refs_path, "doThing", false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "callers: a name that is present but never called is silent, exit 0" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const d = try tagline(gpa, "lonely    ", "method ", "def", 3, "void lonely() {");
    defer gpa.free(d);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = d } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const r = try callersHelper(gpa, out_path, "lonely", false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "callers: matching is exact, not prefix" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const a = try tagline(gpa, "run       ", "call   ", "ref", 5, "a.run();");
    defer gpa.free(a);
    const b = try tagline(gpa, "runFast   ", "call   ", "ref", 6, "a.runFast();");
    defer gpa.free(b);
    const both = try std.mem.concat(gpa, u8, &.{ a, b });
    defer gpa.free(both);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = both } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const r = try callersHelper(gpa, out_path, "run", false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "\n"));
    try testing.expect(std.mem.indexOf(u8, r.out, "a.run();") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "runFast") == null);
}

test "callers: the look fast path agrees with a full scan over the index" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const names = [_][]const u8{ "alpha", "Beta", "gamma", "_under", "zz9", "Aardvark", "run", "runFast" };
    var all: Io.Writer.Allocating = .init(gpa);
    defer all.deinit();
    for (names) |n| {
        var padded_buf: [10]u8 = undefined;
        @memset(&padded_buf, ' ');
        @memcpy(padded_buf[0..n.len], n);
        const expr = try std.fmt.allocPrint(gpa, "x.{s}();", .{n});
        defer gpa.free(expr);
        const t = try tagline(gpa, &padded_buf, "call   ", "ref", 5, expr);
        defer gpa.free(t);
        try all.writer.writeAll(t);
    }
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = all.written() } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    for (names) |n| {
        const r = try callersHelper(gpa, out_path, n, false);
        defer gpa.free(r.out);
        const expected = try std.fmt.allocPrint(gpa, "src/A.java:5\tx.{s}();\n", .{n});
        defer gpa.free(expected);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "callers: a name containing regex metacharacters is matched literally" {
    const gpa = testing.allocator;
    var fx = try CacheFixture.init(gpa);
    defer fx.deinit();
    const a = try tagline(gpa, "a.b       ", "call   ", "ref", 5, "x.a.b();");
    defer gpa.free(a);
    const cache_path = try fx.build(&.{.{ .path = "src/A.java", .entry = .{ .hash = h(H1), .tags = a } }});
    defer gpa.free(cache_path);
    const out_path = try fx.absPath("_refs.tsv");
    defer gpa.free(out_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    _ = try buildRefs(gpa, testing.io, &env, cache_path, out_path);

    const hit = try callersHelper(gpa, out_path, "a.b", false);
    defer gpa.free(hit.out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, hit.out, "\n"));

    const miss = try callersHelper(gpa, out_path, "axb", false);
    defer gpa.free(miss.out);
    try testing.expectEqual(@as(usize, 0), miss.out.len);
}
