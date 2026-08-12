//! `synapse build-refs` and `synapse callers` -- the writer and the reader of
//! `_refs.tsv`.
//!
//!   build-refs [--cache <f>] [--out <f>]   project the tags cache into the index
//!   callers <name> [--all]                 repo-wide sites of an exact name
//!
//! One file, because they are one contract. `synapse-build-refs.sh` sorted under
//! `LC_ALL=C` and `synapse-callers.sh` binary-searched with `look`, and each
//! carried a comment shouting that the other must not change -- a disagreement
//! returns nothing, which is indistinguishable from "this name is never called".
//! Keeping them in one file makes that pairing visible rather than remembered; see
//! `core/refs.zig` for why byte order is no longer a thing anyone has to hold.
//!
//! ## What each one stopped spawning
//!
//! `build-refs` ran `tags-cache --refs` *and* `tags-cache --dump | grep -c`, which
//! read the whole cache twice -- 942 MB twice, on a large repo -- to obtain one
//! integer. Then `sort -u`, `wc -l`, `cut | sed | sort -u | wc -l`, and two `awk`
//! passes for the def and ref counts. All of it is one walk of the record table
//! now.
//!
//! `callers` ran `look` and `awk`. `look` is gone with a small gain rather than a
//! loss: it matched by *prefix*, so a query for `bet` returned every `beta` and the
//! exact match was left to the awk. Its absence also removes the fallback branch
//! that scanned the whole index when `look` was not installed -- correct but
//! O(index), and on a 1.4 GB index that was 26s against 0.235s.
//!
//! The script's own note about `grep` is worth keeping even though nothing here
//! greps: the same query measured 0.15s under ugrep and 8.3s under BSD
//! `/usr/bin/grep`, so *which* implementation is on `PATH` decided the answer. In
//! process there is one implementation and it is this one.

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

    // The work dir supplies whichever default is missing. Explicit flags make this
    // usable against a cache for a repo that is not checked out here at all, which
    // is what the tests do.
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

    // The projection first, unsorted, into memory. A 942 MB cache projects to
    // ~1.4 GB of rows and the script held them in a temp file for the same reason
    // it then sorted them: `sort` needs the whole set. Held here instead, which is
    // the one place this port trades memory for two fewer full passes over a file.
    var unsorted: Io.Writer.Allocating = .init(gpa);
    defer unsorted.deinit();
    _ = try cache.writeRefs(&unsorted.writer);

    // `unsupported` is a count of records, not of rows, and it exists so "no hits"
    // can be told apart from "never parsed". The script got it from a second full
    // read of the cache through `--dump | grep -c '^U\t'`.
    var unsupported: usize = 0;
    var i: u32 = 0;
    while (i < cache.count()) : (i += 1) {
        if (cache.view.record(i).unsupported()) unsupported += 1;
    }

    var sorted: Io.Writer.Allocating = .init(gpa);
    defer sorted.deinit();
    const counts = try core.refs.writeSorted(gpa, &sorted.writer, unsorted.written());

    // Rebuilt, never appended to, and via a rename: the reader binary-searches
    // this file, and a half-written index is a wrong answer rather than a missing
    // one.
    // `index_map.writeFile` is the tmp-plus-rename writer, and it creates the
    // directory itself -- named for the index it was written for, but it is the
    // general "publish these bytes atomically" step and this file needs exactly it.
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

    // Exit 1, not 0: a missing index is "could not run". Zero rows from a built
    // index means "checked, not called"; silence from a missing one would be
    // indistinguishable from it, which is the confusion this whole subcommand
    // exists to avoid.
    const index = Io.Dir.cwd().readFileAlloc(io, refs_path.?, gpa, .limited(4 << 30)) catch {
        std.debug.print(
            "{s}: no reference index at {s} -- run synapse-build-refs.sh\n",
            .{ callers_prog, refs_path.? },
        );
        return 1;
    };
    defer gpa.free(index);

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var it = core.refs.find(index, name);
    while (it.next()) |row| {
        if (all) {
            try out.interface.print("{s}\t{s}\t{s}\t{s}\n", .{ row.dir, row.kind, row.site, row.expr });
        } else if (row.isCall()) {
            try out.interface.print("{s}\t{s}\n", .{ row.site, row.expr });
        }
    }
    try out.interface.flush();
    // Always 0 when the index was readable, including for zero rows. The script
    // needed an explicit `exit 0` here because `look` exits non-zero on no match
    // and `pipefail` made that the pipeline's status -- so "never called" became
    // exit 1, indistinguishable from "could not run".
    return 0;
}

fn callersUsage() u8 {
    std.debug.print("{s}", .{callers_usage});
    return 2;
}
