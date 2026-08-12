//! `synapse gate` -- `claude/lib/synapse/synapse-gate.sh`'s rule.
//!
//!   gate --vocab <groupwords.tsv> [--all] [--top N]
//!
//! The whole subcommand is one file in and a few lines out, and the rule itself is
//! `core/gate.zig`. The script was already one `awk` pass with no subprocess per
//! cluster and nothing re-reading the repo, so this port buys no measurable time --
//! what it buys is that the rule is now testable against its own calibration
//! instead of embedded in a 60-line awk program inside a heredoc.
//!
//! Needs no vault, no namespace and no git: the input is a table `synapse vocab`
//! produced. That is why the wrapper has no identity preamble either.

const std = @import("std");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-gate";

const usage_text =
    \\usage: synapse gate --vocab <groupwords.tsv> [--all] [--top N]
    \\
    \\  --vocab  cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`
    \\  --all    print every cluster with its score, not only the flagged ones
    \\  --top    terms per cluster the rule looks at, default 8
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
        } else if (std.mem.eql(u8, arg, "--top")) {
            const text = args.next() orelse return usage();
            // Digits only and at least one, as `case "$TOP" in ''|*[!0-9]*)` plus
            // `[ "$TOP" -ge 1 ]` required.
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
    if (table.len == 0) {
        // Distinct from "no such file", and the distinction is the message: an
        // empty table means nothing was tagged, so cluster quality is not
        // judgeable rather than good.
        std.debug.print(
            "{s}: {s} is empty -- nothing was tagged, so cluster quality cannot be judged\n",
            .{ prog, vocab },
        );
        return 1;
    }

    var verdicts = try core.gate.judge(gpa, table, .{ .top = top });
    defer core.gate.free(gpa, &verdicts);

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    for (verdicts.items) |v| {
        if (!v.flagged and !all) continue;
        try core.gate.writeVerdict(&out.interface, v);
    }
    try out.interface.flush();
    // Always 0: a flag is advice to re-cluster or disperse, never a hard stop.
    return 0;
}
