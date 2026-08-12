//! `synapse index` -- the read and write surface for `_index.bin`.
//!
//!   index build --unassigned <file> [--out <file>]   pairs on stdin
//!   index build --lists <dir> --unassigned <file>    pairs from lists/NN.txt
//!   build-index                                      the whole step, work dir derived
//!   index unassigned [--file <file>]                 every unclaimed path
//!   index lookup <path> [--file <file>]              the nodes claiming it
//!   index nodes [--file <file>]                      every node that claims anything
//!   index paths [--file <file>]                      every claimed path
//!   index add-unassigned <path> [--file <file>]      queue one path for the sweep
//!
//! **This subcommand is new, and it exists because the storage changed.**
//! `synapse-build-index.sh` authored `_index.json` with `jq` and PUT it to the
//! vault; `synapse-query.sh` and the staleness hook read it back with `jq`.
//! A binary index is unreadable to all three until they have another way in,
//! and these three forms are that way -- each replaces one `jq` block in one
//! script, which is a far smaller change than porting any of them whole, and
//! none of their own CLI contracts move.
//!
//! Bash calling this binary is the allowed direction of the port's ordering
//! rule: a Zig caller is never written against a bash callee, but a bash caller
//! against a Zig callee is how a leaf lands before the scripts around it.
//!
//! **The default path comes from `SYNAPSE_WORK_DIR` and nowhere else.** The
//! scripts already resolve the namespace -- `synapse-identity.sh` is still
//! bash, and will be until every sourcer of it is ported -- and they export the
//! work dir with the namespace already in it. Guessing it a second time here
//! would be a second implementation of the one thing that must not disagree
//! between components. With the variable unset, `--out`/`--file` is required.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = core.index_map.Map;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    const form = args.next() orelse return usage();

    var file: ?[]const u8 = null;
    var unassigned_file: ?[]const u8 = null;
    var lists_dir: ?[]const u8 = null;
    var positional: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--file")) {
            file = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--unassigned")) {
            unassigned_file = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = args.next() orelse return usage();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else if (positional == null) {
            positional = arg;
        } else return usage();
    }

    const path = file orelse (defaultPath(gpa, io, env) catch return noWorkDir()) orelse return noWorkDir();
    defer if (file == null) gpa.free(@constCast(path));

    if (std.mem.eql(u8, form, "build")) return buildIndex(gpa, io, path, unassigned_file, lists_dir);
    if (std.mem.eql(u8, form, "unassigned")) return listUnassigned(io, path);
    if (std.mem.eql(u8, form, "lookup")) return lookup(io, path, positional orelse return usage());
    if (std.mem.eql(u8, form, "nodes")) return listNodes(io, path);
    if (std.mem.eql(u8, form, "paths")) return listPaths(io, path);
    if (std.mem.eql(u8, form, "add-unassigned"))
        return addUnassigned(gpa, io, path, positional orelse return usage());
    return usage();
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse index build --unassigned <file> [--out <file>] [--lists <dir>]
        \\       (pairs on stdin unless --lists names the lists directory)
        \\       synapse index unassigned [--file <file>]
        \\       synapse index lookup <path> [--file <file>]
        \\       synapse index nodes [--file <file>]
        \\       synapse index paths [--file <file>]
        \\       synapse index add-unassigned <path> [--file <file>]
        \\
    , .{});
    return 1;
}

fn noWorkDir() u8 {
    std.debug.print("synapse-index: no SYNAPSE_WORK_DIR and no --out/--file\n", .{});
    return 1;
}

/// `$SYNAPSE_WORK_DIR/_index.bin`, or null when the variable is unset. The
/// namespace is already inside that variable -- the scripts put it there -- so
/// nothing here joins a repo name to a branch.
fn defaultPath(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !?[]const u8 {
    // Derived from identity when the environment does not name it, which is what the
    // wrapper did. Without this, `synapse index lookup <path>` run by hand in a
    // checkout would refuse for want of a variable it can work out itself.
    const work = (try context.workDir(gpa, io, env, "synapse-index")) orelse return null;
    defer work.deinit(gpa);
    return try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work.path});
}

/// Read `path<TAB>node` pairs on stdin, group them, and replace the index.
///
/// Prints one line of counts on success, which is what
/// `synapse-build-index.sh` needs to keep printing its own stats line: the
/// script owns the wording, this owns the numbers.
fn buildIndex(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    unassigned_file: ?[]const u8,
    lists_dir: ?[]const u8,
) !u8 {
    var pairs: std.ArrayListUnmanaged(core.index_map.Pair) = .empty;
    defer pairs.deinit(gpa);
    // Owns whatever `--lists` read, since the pairs slice into it.
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |b| gpa.free(b);
        owned.deinit(gpa);
    }

    var text: []u8 = &.{};
    defer gpa.free(text);
    if (lists_dir) |dir| {
        if (try pairsFromLists(gpa, io, dir, &pairs, &owned) == 0) {
            std.debug.print("synapse-index: no (path, node) pairs\n", .{});
            return 1;
        }
    } else {
        var in_buf: [256 * 1024]u8 = undefined;
        var in = Io.File.stdin().reader(io, &in_buf);
        text = in.interface.allocRemaining(gpa, .limited(512 << 20)) catch return 1;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            // Split on the LAST tab, not the first: a repo-relative path may
            // contain one, and a node filename is what follows the final field
            // separator. Same rule `tags-cache` applies to its own pairs.
            const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
            if (tab == 0 or tab + 1 == line.len) continue;
            try pairs.append(gpa, .{ .path = line[0..tab], .node = line[tab + 1 ..] });
        }
    }

    // Absent is empty, not an error: a namespace where every file is claimed
    // has no unassigned list, and `synapse-build-index.sh` requires the file
    // to exist for its own reasons rather than this one's.
    var unassigned_text: []u8 = &.{};
    defer gpa.free(unassigned_text);
    if (unassigned_file) |uf| {
        unassigned_text = Io.Dir.cwd().readFileAlloc(io, uf, gpa, .limited(64 << 20)) catch {
            std.debug.print("synapse-index: cannot read --unassigned {s}\n", .{uf});
            return 1;
        };
    }

    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);
    var un_lines = std.mem.splitScalar(u8, unassigned_text, '\n');
    while (un_lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        try unassigned.append(gpa, line);
    }

    const bytes = core.index_map.build(gpa, pairs.items, unassigned.items) catch |e| {
        std.debug.print("synapse-index: cannot build index ({t})\n", .{e});
        return 1;
    };
    defer gpa.free(bytes);

    core.index_map.writeFile(gpa, io, path, bytes) catch {
        std.debug.print("synapse-index: cannot write {s}\n", .{path});
        return 1;
    };

    // Reopen rather than counting what went in: this reports what a reader
    // will actually find, which is the only number worth printing.
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: wrote an index that will not read back ({t})\n", .{e});
        return 1;
    }

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    try out.interface.print("keys={d} unassigned={d} bytes={d}\n", .{
        map.count(),
        map.unassignedCount(),
        bytes.len,
    });
    try out.interface.flush();
    return 0;
}

/// Every unclaimed path, one per line, in the order the index holds them.
///
/// Replaces `jq -r '._unassigned[]'` in `skills/synapse-node/SKILL.md`, and
/// serves that skill's stated reason for shelling out rather than reading the
/// file: tens of megabytes must not reach a context window.
fn listUnassigned(io: Io, path: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var it = map.unassignedIter();
    while (it.next()) |p| try out.interface.print("{s}\n", .{p});
    try out.interface.flush();
    return 0;
}

/// Queue `newly` for the `_unassigned` sweep, if it is not already there.
///
/// Replaces the `jq`-then-PUT block at `synapse-staleness.sh:135-149`, which
/// read 27 MB of JSON, rewrote it and pushed the whole thing back over HTTPS to
/// add one string. Exit 0 whether or not anything changed -- the hook's contract
/// is that a missing precondition is silence, and "already queued" is the
/// common case rather than a fault.
///
/// An unreadable index is exit 0 too, not 1. The old code refused to PUT an
/// empty body over a 27 MB index for exactly this reason; here the refusal is
/// structural, because there is nothing to re-encode from.
fn addUnassigned(gpa: Allocator, io: Io, path: []const u8, newly: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded != null) return 0;
    if (map.count() == 0 and map.unassignedCount() == 0 and map.map == null) return 0;

    const grown = core.index_map.withUnassigned(gpa, map.view, newly) catch |e| {
        std.debug.print("synapse-index: cannot re-encode index ({t})\n", .{e});
        return 1;
    } orelse return 0;
    defer gpa.free(grown);

    core.index_map.writeFile(gpa, io, path, grown) catch {
        std.debug.print("synapse-index: cannot write {s}\n", .{path});
        return 1;
    };
    return 0;
}

/// Every node that claims at least one path, one per line, ascending.
///
/// Replaces `jq -r 'to_entries | map(select(.key != "_unassigned")) |
/// map(.value[]) | unique | .[]'` at `synapse-query.sh:392` and `:468`, where it
/// is the authoritative list of which nodes exist. `unique` sorted its output;
/// the node table is already sorted by name, so this is the same order for free.
fn listNodes(io: Io, path: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var id: u32 = 0;
    while (id < map.nodeCount()) : (id += 1)
        try out.interface.print("{s}\n", .{map.view.nodeName(id)});
    try out.interface.flush();
    return 0;
}

/// `path<TAB>node.md` for every (list, path) pair, from `lists/NN.txt`.
///
/// A list with no `NN.title` is skipped: the title is the node's identity, and a
/// list without one is a build that has not finished rather than a node claiming
/// nothing. Returns the number of pairs authored.
///
/// The `.md` extension is part of the value, not decoration: the staleness hook and
/// the read-time procedure both use it directly as a vault path with no extension
/// handling of their own.
///
/// Order is not this function's problem, and that is deliberate -- `index_map.build`
/// groups and sorts, because the format needs paths ascending with each path's nodes
/// ascending, and getting that wrong encodes fine while making every later binary
/// search wrong.
fn pairsFromLists(
    gpa: Allocator,
    io: Io,
    lists_dir: []const u8,
    pairs: *std.ArrayListUnmanaged(core.index_map.Pair),
    owned: *std.ArrayListUnmanaged([]u8),
) !usize {
    var dir = Io.Dir.cwd().openDir(io, lists_dir, .{ .iterate = true }) catch {
        std.debug.print("synapse-index: cannot read --lists {s}\n", .{lists_dir});
        return 0;
    };
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - 4]));
    }
    // Sorted so a rebuild of the same lists produces the same bytes, which is what
    // makes "the index changed" a signal rather than noise.
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var count: usize = 0;
    for (names.items) |nn| {
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists_dir, nn });
        defer gpa.free(title_path);
        const title = Io.Dir.cwd().readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(title);

        // The same sanitisation the writer applies to a title before using it as a
        // filename, so the index names the file the vault actually holds.
        const sanitised = try core.emit.fileTitle(gpa, std.mem.trimEnd(u8, title, "\n"));
        defer gpa.free(sanitised);
        const node = try std.fmt.allocPrint(gpa, "{s}.md", .{sanitised});
        try owned.append(gpa, node);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists_dir, nn });
        defer gpa.free(list_path);
        const list = Io.Dir.cwd().readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch continue;
        try owned.append(gpa, list);

        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |raw| {
            // `awk 'NF'`: a blank line is not a path.
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try pairs.append(gpa, .{ .path = line, .node = node });
            count += 1;
        }
    }
    return count;
}

/// Every claimed path, one per line, in `LC_ALL=C` byte order.
///
/// Replaces `jq -r 'keys[]'` at `synapse-query.sh:547`, whose output was piped
/// through `LC_ALL=C sort` before a `comm`. The record table is already in that
/// order, so the sort downstream is now redundant rather than load-bearing.
///
/// It also drops something: `keys[]` included `_unassigned` itself, so the
/// literal string was treated as a claimed path by that `comm`. Harmless, since
/// no real file is named that, but the separate region removes the case rather
/// than relying on it staying harmless.
fn listPaths(io: Io, path: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    var i: u32 = 0;
    while (i < map.count()) : (i += 1)
        try out.interface.print("{s}\n", .{map.view.path(map.view.record(i))});
    try out.interface.flush();
    return 0;
}

/// The nodes claiming `wanted`, one per line, ascending.
///
/// Exit 1 with no output when no node claims it -- which covers both "the path
/// is unassigned" and "the path was never enumerated". A caller that needs to
/// tell those apart asks `unassigned`; the staleness hook does not, because
/// either way there is nothing to flag.
fn lookup(io: Io, path: []const u8, wanted: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const nodes = map.nodesFor(wanted, &names) orelse return 1;

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    for (nodes) |n| try out.interface.print("{s}\n", .{n});
    try out.interface.flush();
    return 0;
}


/// `synapse build-index` -- `index build --lists` with every path derived.
///
/// The step `synapse-build-index.sh` performed: the lists directory, the unassigned
/// list and the output file all sit in the work dir, which the binary now resolves for
/// itself, so the wrapper's only remaining job was spelling three paths and printing a
/// prefix. It exists as its own subcommand rather than as flags a caller has to
/// remember, because the caller is `/synapse-init`'s step 3 and that step has no
/// choices to make.
pub fn runBuildIndex(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse build-index\n", .{});
            return 0;
        }
        std.debug.print("usage: synapse build-index\n", .{});
        return 2;
    }

    var ctx = (try context.resolve(gpa, io, env, "synapse-build-index")) orelse return 1;
    defer ctx.deinit();

    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{ctx.work_dir});
    defer gpa.free(lists);
    const unassigned = try std.fmt.allocPrint(gpa, "{s}/unassigned.txt", .{ctx.work_dir});
    defer gpa.free(unassigned);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{ctx.work_dir});
    defer gpa.free(out_path);

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, lists, .{})) |_| {} else |_| {
        std.debug.print("synapse-build-index: no lists/ in {s}\n", .{ctx.work_dir});
        return 1;
    }
    if (cwd.statFile(io, unassigned, .{})) |_| {} else |_| {
        std.debug.print("synapse-build-index: no unassigned.txt in {s}\n", .{ctx.work_dir});
        return 1;
    }

    // The wrapper owned this wording and took the numbers from the binary; with one
    // process there is one place to say it.
    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll("_index.bin written: ");
    try out.interface.flush();
    return buildIndex(gpa, io, out_path, unassigned, lists);
}
