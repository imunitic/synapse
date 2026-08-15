//! `synapse brief` -- one self-contained data file per node (sb-011 stage 3's
//! precondition), bundling everything a concurrent author needs except the
//! prose itself: [[sb — Parallel node authoring]].
//!
//!   brief --lists <dir> [--rank <dir>] [--links <file>] [--repo <path>] [--out <dir>]
//!
//! Reshapes stage 1 (`rank --lists`) and stage 2 (`build-refs` +
//! `link-graph`) output, per node, into `{out}/brief/NN.md`: sources list
//! path/count (not content), both ranked pools verbatim, this node's
//! `links.tsv` rows, and every node's title (for judging `part_of`, still a
//! judgement call, never computed here). Data, not instructions -- what an
//! author does with it lives in the `synapse-node-authoring` skill.
//!
//! Missing `--rank`/`--links` is advice-level: empty pool sections plus a
//! warning. A missing/empty `--lists` dir is fatal.

const std = @import("std");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-brief";

const usage_text =
    \\usage: synapse brief --lists <dir> [--rank <dir>] [--links <file>] [--repo <path>] [--out <dir>]
    \\
    \\  --lists  the NN.txt/NN.title path lists synapse build-lists wrote.
    \\  --rank   where synapse rank --lists wrote NN.summary.tsv/NN.crux.tsv.
    \\           Default $SYNAPSE_WORK_DIR/rank.
    \\  --links  synapse link-graph's output. Default $SYNAPSE_WORK_DIR/links.tsv.
    \\           A missing file warns and leaves every node's edges empty.
    \\  --out    where to write brief/NN.md. Default $SYNAPSE_WORK_DIR.
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
    var lists_dir: ?[]const u8 = null;
    var rank_dir: ?[]const u8 = null;
    var links_path: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--rank")) {
            rank_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--links")) {
            links_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usage();
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

    // Explicit flags win, otherwise the namespace of --repo (or cwd). Kept
    // alive for the rest of the function -- out_dir/rank_dir/links_path borrow it.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (out_dir == null or rank_dir == null or links_path == null) {
        derived = try context.workDirFor(gpa, io, env, repo orelse ".", prog);
        if (derived == null) return 1;
    }
    if (out_dir == null) out_dir = derived.?.path;
    if (rank_dir == null) rank_dir = try std.fmt.allocPrint(arena, "{s}/rank", .{derived.?.path});
    if (links_path == null) links_path = try std.fmt.allocPrint(arena, "{s}/links.tsv", .{derived.?.path});

    const root = try repoRoot(arena, io, repo);
    if (root.len == 0) {
        std.debug.print("{s}: not inside a git repo: {s}\n", .{ prog, repo orelse "." });
        return 1;
    }

    const nodes = try readLists(arena, io, lists);
    if (nodes.len == 0) {
        std.debug.print("{s}: no NN.txt/NN.title pairs in {s}\n", .{ prog, lists });
        return 1;
    }

    const links_text = cwd.readFileAlloc(io, links_path.?, arena, .limited(1 << 30)) catch blk: {
        std.debug.print(
            "{s}: no link graph at {s} -- every brief's candidate links will be empty; run synapse build-refs and synapse link-graph first\n",
            .{ prog, links_path.? },
        );
        break :blk "";
    };

    const brief_dir = try std.fmt.allocPrint(arena, "{s}/brief", .{out_dir.?});
    cwd.createDirPath(io, brief_dir) catch {
        std.debug.print("{s}: cannot write {s}\n", .{ prog, brief_dir });
        return 1;
    };

    var rank_missing: usize = 0;
    for (nodes) |n| {
        const summary_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.summary.tsv", .{ rank_dir.?, n.n });
        const crux_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.crux.tsv", .{ rank_dir.?, n.n });
        const summary = cwd.readFileAlloc(io, summary_path, arena, .limited(16 << 20)) catch blk: {
            rank_missing += 1;
            break :blk "";
        };
        const crux = cwd.readFileAlloc(io, crux_path, arena, .limited(16 << 20)) catch "";

        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const w = &body.writer;

        try w.print("# {s}\n\n", .{n.title});
        try w.print("Repo root: {s}\n", .{root});
        try w.print("Sources list: {s} ({d} files, exhaustive -- do not re-enumerate; `write-node` reads this list directly)\n\n", .{ n.txt_path, n.count });

        try w.writeAll("## Summary pool (ranked, read the top few)\n");
        try writeTsvBlock(w, summary);

        try w.writeAll("\n## Crux pool (ranked, tests excluded)\n");
        try writeTsvBlock(w, crux);

        try w.writeAll("\n## Candidate links (from the link graph; weight = distinct rare shared symbols)\n");
        try writeLinksFor(w, links_text, n.title);

        try w.writeAll("\n## Every node in this namespace (for judging part_of)\n");
        for (nodes) |other| try w.print("- {s}\n", .{other.title});

        const out_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.md", .{ brief_dir, n.n });
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = body.written() });
    }

    if (rank_missing != 0) {
        std.debug.print(
            "{s}: {d}/{d} nodes had no rank output at {s} -- their pool sections are empty; run synapse rank --lists first\n",
            .{ prog, rank_missing, nodes.len, rank_dir.? },
        );
    }
    std.debug.print("{s}: {d} briefs -> {s}\n", .{ prog, nodes.len, brief_dir });
    return 0;
}

fn writeTsvBlock(w: *Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("(none)\n");
        return;
    }
    try w.writeAll("```\n");
    try w.writeAll(trimmed);
    try w.writeAll("\n```\n");
}

/// Rows of `links.tsv` whose `from` is this node -- already strongest-first
/// per node, so filtered order is preserved, not re-sorted.
fn writeLinksFor(w: *Io.Writer, links_text: []const u8, title: []const u8) !void {
    var any = false;
    var lines = std.mem.splitScalar(u8, links_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[0..tab], title)) continue;
        if (!any) try w.writeAll("```\n");
        try w.writeAll(line);
        try w.writeAll("\n");
        any = true;
    }
    if (any) {
        try w.writeAll("```\n");
    } else {
        try w.writeAll("(none)\n");
    }
}

const NodeInfo = struct {
    n: usize,
    title: []const u8,
    txt_path: []const u8,
    count: usize,
};

fn repoRoot(gpa: Allocator, io: Io, repo: ?[]const u8) ![]u8 {
    const res = adapters.process.run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" }, .{
        .cwd = if (repo) |r| .{ .path = r } else .inherit,
    }) catch return gpa.dupe(u8, "");
    defer res.deinit(gpa);
    if (!res.ok()) return gpa.dupe(u8, "");
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

/// Every `NN.txt`/`NN.title` pair in `dir`, ascending. A node missing either
/// half is skipped.
fn readLists(arena: Allocator, io: Io, dir: []const u8) ![]NodeInfo {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayListUnmanaged(NodeInfo) = .empty;
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const title_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.title", .{ dir, n });
        const title_raw = cwd.readFileAlloc(io, title_path, arena, .limited(64 << 10)) catch continue;
        const title = std.mem.trim(u8, firstLine(title_raw), " \t\r");
        if (title.len == 0) continue;

        const txt_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.txt", .{ dir, n });
        const body = cwd.readFileAlloc(io, txt_path, arena, .limited(64 << 20)) catch continue;

        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            if (std.mem.trim(u8, raw, " \t\r").len != 0) count += 1;
        }

        try out.append(arena, .{
            .n = n,
            .title = title,
            .txt_path = txt_path,
            .count = count,
        });
    }
    return out.items;
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}
