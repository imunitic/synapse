//! `synapse gate` -- `claude/lib/synapse/synapse-gate.sh`'s rule, now
//! testable (`core/gate.zig`) instead of embedded in an awk heredoc.
//!
//!   gate --vocab <groupwords.tsv> [--all] [--top N]
//!
//! Needs no vault, namespace or git: input is a table `synapse vocab` produced.

const std = @import("std");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-gate";

const usage_text =
    \\usage: synapse gate --vocab <groupwords.tsv> [--parseable <parseable.tsv>] [--all] [--top N]
    \\
    \\  --vocab       cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`
    \\  --parseable   synapse vocab's `parseable.tsv`: `cluster <TAB> parseable <TAB> total`.
    \\                A cluster with zero rare terms and zero parseable files is reported
    \\                `unparseable` instead of `flagged` -- see core/gate.zig.
    \\  --all         print every cluster with its score, not only the flagged ones
    \\  --top         terms per cluster the rule looks at, default 8
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
    _ = env;
    var vocab: []const u8 = "";
    var parseable_path: ?[]const u8 = null;
    var top: usize = 8;
    var all = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--vocab")) {
            vocab = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--parseable")) {
            parseable_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--top")) {
            const text = args.next() orelse return usage();
            top = std.fmt.parseInt(usize, text, 10) catch return usage();
            if (top < 1) return usage();
        } else return usage();
    }
    if (vocab.len == 0) return usage();

    const table = Io.Dir.cwd().readFileAlloc(io, vocab, gpa, .limited(1 << 30)) catch {
        std.debug.print("{s}: no such vocabulary file: {s}\n", .{ prog, vocab });
        return 1;
    };
    defer gpa.free(table);
    if (table.len == 0) { // distinct from "no such file": nothing was tagged
        std.debug.print(
            "{s}: {s} is empty -- nothing was tagged, so cluster quality cannot be judged\n",
            .{ prog, vocab },
        );
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parseable: std.StringHashMapUnmanaged(f64) = .empty;
    if (parseable_path) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 << 20)) catch {
            std.debug.print("{s}: no such parseable-share file: {s}\n", .{ prog, p });
            return 1;
        };
        try loadParseable(arena, text, &parseable);
    }

    var verdicts = try core.gate.judge(gpa, table, .{
        .top = top,
        .parseable = if (parseable_path != null) &parseable else null,
    });
    defer core.gate.free(gpa, &verdicts);

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    for (verdicts.items) |v| {
        if (v.status != .flagged and !all) continue;
        try core.gate.writeVerdict(&out.interface, v);
    }
    try out.interface.flush();
    return 0; // always 0: a flag is advice, never a hard stop
}

/// `cluster <TAB> parseable <TAB> total` -> `cluster -> parseable/total`.
/// Zero-total rows are skipped, not divided: an empty cluster has no share
/// to report, and zero-parseable must never be produced by accident.
fn loadParseable(arena: Allocator, text: []const u8, out: *std.StringHashMapUnmanaged(f64)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const parseable_text = fields.next() orelse continue;
        const total_text = fields.next() orelse continue;
        const parseable_count = std.fmt.parseInt(usize, parseable_text, 10) catch continue;
        const total = std.fmt.parseInt(usize, total_text, 10) catch continue;
        if (total == 0) continue;
        try out.put(arena, name, @as(f64, @floatFromInt(parseable_count)) / @as(f64, @floatFromInt(total)));
    }
}
