//! `synapse link-graph` -- the node-to-node link graph, computed before any
//! prose is written (synapse-001 step 9). Rule in `core/links.zig`; this is
//! the file-in/file-out wrapper.
//!
//!   link-graph --refs <_refs.tsv> --lists <dir> [--top N] [--out <dir>]
//!
//! Distinct from `synapse query links "{Node}"`, which traverses a node's
//! already-written `## Links`; this computes candidates before any node
//! exists, from `_refs.tsv` and the cluster path lists alone. Needs no
//! vault or git: every input is a file `build-refs`/`build-lists` produced.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-link-graph";

const usage_text =
    \\usage: synapse link-graph --refs <_refs.tsv> --lists <dir> [--top N] [--out <dir>]
    \\
    \\  --refs   synapse build-refs's index. Default $SYNAPSE_WORK_DIR/_refs.tsv.
    \\  --lists  the NN.txt/NN.title path lists synapse build-lists wrote.
    \\  --top    edges kept per node, strongest first, default 8. 0 means no cap.
    \\  --out    where to write links.tsv. Default $SYNAPSE_WORK_DIR.
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var refs_path: ?[]const u8 = null;
    var lists_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var top: usize = 8;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--refs")) {
            refs_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--top")) {
            const text = args.next() orelse return usage();
            top = std.fmt.parseInt(usize, text, 10) catch return usage();
        } else return usage();
    }
    const lists = lists_dir orelse return usage();

    const cwd = Io.Dir.cwd();
    cwd.access(io, lists, .{}) catch {
        std.debug.print("{s}: no such lists dir: {s}\n", .{ prog, lists });
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Work dir supplies whichever of --refs/--out is missing (as build-refs
    // does for --cache/--out); resolved only if needed. Kept alive for the
    // rest of the function since `refs_path`/`out_dir` borrow its `path`.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (refs_path == null or out_dir == null) {
        derived = (try context.workDir(gpa, io, env, prog)) orelse return 1;
        if (refs_path == null) {
            refs_path = try std.fmt.allocPrint(arena, "{s}/_refs.tsv", .{derived.?.path});
        }
        if (out_dir == null) out_dir = derived.?.path;
    }

    const refs_table = cwd.readFileAlloc(io, refs_path.?, arena, .limited(1 << 30)) catch {
        std.debug.print(
            "{s}: no reference index at {s} -- run `synapse build-refs`\n",
            .{ prog, refs_path.? },
        );
        return 1;
    };

    var path_to_nodes: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    const node_count = try readLists(arena, io, lists, &path_to_nodes);
    if (node_count == 0) {
        std.debug.print("{s}: no NN.txt/NN.title pairs in {s}\n", .{ prog, lists });
        return 1;
    }

    var edges = try core.links.compute(gpa, refs_table, &path_to_nodes, node_count, .{ .top = top });
    defer core.links.free(gpa, &edges);

    cwd.createDirPath(io, out_dir.?) catch {
        std.debug.print("{s}: cannot write {s}\n", .{ prog, out_dir.? });
        return 1;
    };
    const out_path = try std.fmt.allocPrint(gpa, "{s}/links.tsv", .{out_dir.?});
    defer gpa.free(out_path);
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (edges.items) |e| try core.links.writeEdge(&body.writer, e);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = body.written() });

    var nodes_covered: std.StringHashMapUnmanaged(void) = .empty;
    for (edges.items) |e| try nodes_covered.put(arena, e.from, {});

    std.debug.print(
        "{s}: {d} nodes, {d} edges, {d} nodes with at least one -> {s}\n",
        .{ prog, node_count, edges.items.len, nodes_covered.count(), out_path },
    );
    return 0;
}

/// Same `NN.txt`/`NN.title` reading as `vocab_cmd.zig`'s `mapFromLists`,
/// minus the `counts.tsv` side table. Returns 0 if the dir was empty or
/// malformed -- the caller treats that as an error.
fn readLists(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    out: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !usize {
    const cwd = Io.Dir.cwd();
    var titles: std.StringHashMapUnmanaged(void) = .empty;
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const txt_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.txt", .{ dir, n });
        const title_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.title", .{ dir, n });
        const title_raw = cwd.readFileAlloc(io, title_path, arena, .limited(64 << 10)) catch continue;
        const title = std.mem.trim(u8, firstLine(title_raw), " \t\r");
        if (title.len == 0) continue;
        const body = cwd.readFileAlloc(io, txt_path, arena, .limited(64 << 20)) catch continue;

        try titles.put(arena, title, {});
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const p = std.mem.trimEnd(u8, raw, "\r");
            if (p.len == 0) continue;
            const gop = try out.getOrPut(arena, p);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, title);
        }
    }
    return titles.count();
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}
