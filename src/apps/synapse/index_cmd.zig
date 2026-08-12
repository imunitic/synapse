//! `synapse index` -- the read and write surface for `_index.bin`.
//!
//!   index build --unassigned <file> [--out <file>]   pairs on stdin
//!   index unassigned [--file <file>]                 every unclaimed path
//!   index lookup <path> [--file <file>]              the nodes claiming it
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
    var positional: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--file")) {
            file = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--unassigned")) {
            unassigned_file = args.next() orelse return usage();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else if (positional == null) {
            positional = arg;
        } else return usage();
    }

    const path = file orelse (defaultPath(gpa, env) catch return noWorkDir()) orelse return noWorkDir();
    defer if (file == null) gpa.free(@constCast(path));

    if (std.mem.eql(u8, form, "build")) return buildIndex(gpa, io, path, unassigned_file);
    if (std.mem.eql(u8, form, "unassigned")) return listUnassigned(io, path);
    if (std.mem.eql(u8, form, "lookup")) return lookup(io, path, positional orelse return usage());
    return usage();
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse index build --unassigned <file> [--out <file>]   (path<TAB>node on stdin)
        \\       synapse index unassigned [--file <file>]
        \\       synapse index lookup <path> [--file <file>]
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
fn defaultPath(gpa: Allocator, env: *std.process.Environ.Map) !?[]const u8 {
    const dir = env.get("SYNAPSE_WORK_DIR") orelse return null;
    if (dir.len == 0) return null;
    return try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{dir});
}

/// Read `path<TAB>node` pairs on stdin, group them, and replace the index.
///
/// Prints one line of counts on success, which is what
/// `synapse-build-index.sh` needs to keep printing its own stats line: the
/// script owns the wording, this owns the numbers.
fn buildIndex(gpa: Allocator, io: Io, path: []const u8, unassigned_file: ?[]const u8) !u8 {
    var in_buf: [256 * 1024]u8 = undefined;
    var in = Io.File.stdin().reader(io, &in_buf);
    const text = in.interface.allocRemaining(gpa, .limited(512 << 20)) catch return 1;
    defer gpa.free(text);

    var pairs: std.ArrayListUnmanaged(core.index_map.Pair) = .empty;
    defer pairs.deinit(gpa);

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
