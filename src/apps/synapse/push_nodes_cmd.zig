//! `synapse push-nodes` -- `claude/lib/synapse/synapse-push-nodes.sh`.
//!
//!   push-nodes [NN ...]
//!
//! Writes one node per authored body, pairing `$SYNAPSE_WORK_DIR/b-NN.md` with
//! `lists/NN.txt` and `lists/NN.title`. With no arguments the target set is the
//! *union* of staged lists and authored bodies, so an un-authored node reports as a
//! SKIP rather than vanishing.
//!
//! ## The loop is a function call now
//!
//! The script spawned `synapse-write-node.sh` once per node, and that writer in turn
//! spawned `jq`, `git hash-object`, `paste`, `sed`, four `awk`s and `curl`. Only the
//! `curl` is left, once per node, because the PUT is the point. Nothing else about a
//! push crosses a process boundary.
//!
//! That also removes the sibling-resolution step and its check: the script resolved
//! the writer next to itself so an installed copy would not pick up whatever was on
//! `PATH`, and there is no longer a second file to find.
//!
//! ## Exit codes carry the outcome, and all-skipped is a failure
//!
//! Any failed node is exit 1. So is a run where nothing was pushed at all: the
//! caller asked for a push and got none, which would otherwise read as success.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const write_node_cmd = @import("write_node_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

const prog = "synapse-push-nodes";

const usage_text =
    \\usage: synapse push-nodes [NN ...]
    \\
    \\  NN   two-digit node numbers to push. Default: every b-NN.md and lists/NN.title.
    \\
;

pub fn run(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(gpa);
    var explicit = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (arg.len != 0 and arg[0] == '-') {
            std.debug.print("{s}", .{usage_text});
            return 2;
        }
        explicit = true;
        try targets.append(gpa, arg);
    }

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();

    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{ctx.work_dir});
    defer gpa.free(lists);
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, lists, .{})) |_| {} else |_| {
        std.debug.print(
            "{s}: no lists/ in {s} -- run synapse-build-lists.sh first\n",
            .{ prog, ctx.work_dir },
        );
        return 1;
    }

    var discovered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (discovered.items) |d| gpa.free(d);
        discovered.deinit(gpa);
    }
    if (!explicit) {
        try discover(gpa, io, &ctx, lists, &discovered);
        for (discovered.items) |d| try targets.append(gpa, d);
        if (targets.items.len == 0) {
            std.debug.print(
                "{s}: nothing to push (no lists/NN.title or b-NN.md in {s})\n",
                .{ prog, ctx.work_dir },
            );
            return 1;
        }
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    var pushed: usize = 0;
    var failed: usize = 0;

    for (targets.items) |nn| {
        const body_path = try std.fmt.allocPrint(gpa, "{s}/b-{s}.md", .{ ctx.work_dir, nn });
        defer gpa.free(body_path);
        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists, nn });
        defer gpa.free(list_path);
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists, nn });
        defer gpa.free(title_path);

        const body = cwd.readFileAlloc(io, body_path, gpa, .limited(64 << 20)) catch {
            try out.interface.print("{s}\tSKIP (no body)\n", .{nn});
            continue;
        };
        defer gpa.free(body);

        const list = cwd.readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch "";
        defer if (list.len != 0) gpa.free(list);
        const title_text = cwd.readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch {
            try out.interface.print("{s}\tSKIP (no list/title)\n", .{nn});
            continue;
        };
        defer gpa.free(title_text);
        // An *empty* list is a skip, not just a missing one: a node claiming no
        // files is not a node, and the writer would refuse it one step later with a
        // less useful message.
        if (list.len == 0) {
            try out.interface.print("{s}\tSKIP (no list/title)\n", .{nn});
            continue;
        }

        const summary = core.query.field(body, "summary") orelse "";
        if (summary.len == 0) {
            // A failure, not a skip: the body exists and was authored, so a missing
            // summary is a mistake in it rather than work not yet done.
            try out.interface.print(
                "{s}\tFAILED (no `summary:` frontmatter in b-{s}.md)\n",
                .{ nn, nn },
            );
            failed += 1;
            continue;
        }

        var line: Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        const code = write_node_cmd.write(Extractor, gpa, io, env, &ctx, .{
            .title = std.mem.trimEnd(u8, title_text, "\n"),
            .summary = summary,
            .paths_text = list,
            // Only what follows the frontmatter, so the summary is not repeated
            // inside the node's prose.
            .body_text = core.query.bodyAfterFrontmatter(body),
        }, &line.writer) catch 1;

        if (code == 0) {
            try out.interface.print("{s}\t{s}", .{ nn, line.written() });
            pushed += 1;
        } else {
            try out.interface.print("{s}\tFAILED\n", .{nn});
            failed += 1;
        }
    }
    try out.interface.flush();

    if (failed != 0) {
        std.debug.print("{s}: {d} node(s) failed\n", .{ prog, failed });
        return 1;
    }
    if (pushed == 0) {
        std.debug.print(
            "{s}: nothing to push (no node had both a list and a body)\n",
            .{prog},
        );
        return 1;
    }
    return 0;
}

/// The union of `lists/NN.title` and `b-NN.md`, byte-sorted and deduplicated.
///
/// The union rather than either side: a staged list with no body has to report as a
/// SKIP, and a body whose list was never built has to as well. Taking only the
/// bodies would make the first case vanish silently.
fn discover(
    gpa: Allocator,
    io: Io,
    ctx: *const Context,
    lists: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    try collect(gpa, io, lists, "", ".title", out);
    try collect(gpa, io, ctx.work_dir, "b-", ".md", out);
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var n: usize = 0;
    for (out.items) |item| {
        if (n != 0 and std.mem.eql(u8, out.items[n - 1], item)) {
            gpa.free(item);
            continue;
        }
        out.items[n] = item;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
}

/// Entries matching `<prefix>NN<suffix>`, yielding the `NN`.
///
/// Two digits exactly, as the script's `[0-9][0-9]` glob and its `sed -E` capture
/// required together -- a `b-1.md` or a `b-100.md` is not a node file.
fn collect(
    gpa: Allocator,
    io: Io,
    dir_path: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len != prefix.len + 2 + suffix.len) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (!std.mem.endsWith(u8, name, suffix)) continue;
        const nn = name[prefix.len .. prefix.len + 2];
        if (!std.ascii.isDigit(nn[0]) or !std.ascii.isDigit(nn[1])) continue;
        try out.append(gpa, try gpa.dupe(u8, nn));
    }
}
