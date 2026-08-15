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

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var it = core.refs.find(index.bytes, name);
    while (it.next()) |row| {
        if (all) {
            try out.interface.print("{s}\t{s}\t{s}\t{s}\n", .{ row.dir, row.kind, row.site, row.expr });
        } else if (row.isCall()) {
            try out.interface.print("{s}\t{s}\n", .{ row.site, row.expr });
        }
    }
    try out.interface.flush();
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
