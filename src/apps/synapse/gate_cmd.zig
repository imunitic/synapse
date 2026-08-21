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

    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    const code = try write(gpa, io, vocab, parseable_path, top, all, &out.interface);
    try out.interface.flush();
    return code;
}

/// The rule itself, minus argument parsing -- separated so a test can drive
/// it against real files without going through the CLI or capturing stdout.
pub fn write(
    gpa: Allocator,
    io: Io,
    vocab: []const u8,
    parseable_path: ?[]const u8,
    top: usize,
    all: bool,
    result: *Io.Writer,
) !u8 {
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

    for (verdicts.items) |v| {
        if (v.status != .flagged and !all) continue;
        try core.gate.writeVerdict(result, v);
    }
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

const testing = std.testing;

/// A real `groupwords.tsv`, built up in memory and written to a real temp
/// dir on demand -- `write()` reads its vocab argument as a path, not as
/// content, same as the real binary.
const Vocab = struct {
    tmp: testing.TmpDir,
    content: Io.Writer.Allocating,
    gpa: Allocator,

    fn init(gpa: Allocator) Vocab {
        return .{ .tmp = testing.tmpDir(.{}), .content = .init(gpa), .gpa = gpa };
    }

    fn deinit(self: *Vocab) void {
        self.content.deinit();
        self.tmp.cleanup();
    }

    /// One cluster's terms, highest count first -- `n` starts at
    /// `words.len + 10` and counts down, matching the bats fixture's own
    /// `cluster()` helper exactly.
    fn cluster(self: *Vocab, name: []const u8, words: []const []const u8) !void {
        var n = words.len + 10;
        for (words) |w| {
            try self.content.writer.print("{s}\t{s}\t{d}\n", .{ name, w, n });
            n -= 1;
        }
    }

    /// One raw `name<TAB>word<TAB>count` row, for fixtures that need an
    /// exact count rather than the descending-from-N shape `cluster` gives.
    fn row(self: *Vocab, name: []const u8, word: []const u8, count: usize) !void {
        try self.content.writer.print("{s}\t{s}\t{d}\n", .{ name, word, count });
    }

    /// Writes everything accumulated so far to a real file, returning its
    /// path. Caller frees.
    fn path(self: *Vocab) ![]const u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "groupwords.tsv", .data = self.content.written() });
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        return std.fmt.allocPrint(self.gpa, "{s}/groupwords.tsv", .{root});
    }

    /// A second real file in the same temp dir, for `--parseable`.
    fn extraFile(self: *Vocab, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ root, name });
    }
};

/// Three differentiated clusters sharing a common tail, plus one built
/// entirely from that tail -- the shape the four undifferentiated syrius3
/// clusters had.
fn writeFourClusters(v: *Vocab) !void {
    try v.cluster("Billing", &.{ "invoice", "dunning", "description", "identifier", "bundle", "resource" });
    try v.cluster("Shipping", &.{ "parcel", "carrier", "description", "identifier", "bundle", "resource" });
    try v.cluster("Pricing", &.{ "tariff", "premium", "description", "identifier", "bundle", "resource" });
    try v.cluster("Generic", &.{ "description", "identifier", "bundle", "resource" });
}

fn runGate(gpa: Allocator, vocab: []const u8, parseable: ?[]const u8, top: usize, all: bool) !struct { code: u8, out: []u8 } {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, testing.io, vocab, parseable, top, all, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

test "a cluster whose top terms are all corpus-common is flagged" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "\n"));
    try testing.expect(std.mem.startsWith(u8, r.out, "Generic"));
    try testing.expect(std.mem.indexOf(u8, r.out, "flagged") != null);
}

test "the differentiated clusters are not flagged" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Billing") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "Shipping") == null);
    try testing.expect(std.mem.indexOf(u8, r.out, "Pricing") == null);
}

test "empty output means every cluster is differentiated" {
    // The reporting convention the rest of the toolkit uses: a clean run
    // says nothing rather than saying 'clean' on every line.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "invoice", "dunning", "ledger" });
    try v.cluster("Shipping", &.{ "parcel", "carrier", "manifest" });
    try v.cluster("Pricing", &.{ "tariff", "premium", "discount" });
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "--all reports every cluster in the same shape, with a verdict column" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, true);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, r.out, "\n"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.out, "\tok\t"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "\tflagged\t"));
    // Same field positions either way, so one parser reads both modes.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.out, "\n"), '\n');
    while (lines.next()) |line| try testing.expectEqual(@as(usize, 3), std.mem.count(u8, line, "\t"));
}

test "one rare term is still flagged; two is not" {
    // The measured tolerance. Against the four known-bad syrius3 clusters,
    // tolerance 0 caught three, 1 caught all four with no false positives,
    // and 2 caught four but flagged five good clusters too. `description`
    // and `identifier` are in every cluster, so only the leading terms are
    // rare -- one for OneRare, two for TwoRare.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "invoice", "dunning", "description", "identifier" });
    try v.cluster("Shipping", &.{ "parcel", "carrier", "description", "identifier" });
    try v.cluster("Pricing", &.{ "tariff", "premium", "description", "identifier" });
    try v.cluster("OneRare", &.{ "solitary", "description", "identifier" });
    try v.cluster("TwoRare", &.{ "alpha", "beta", "description", "identifier" });
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "OneRare") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "TwoRare") == null);
}

test "rarity is document frequency across clusters, not frequency within one" {
    // The failure mode the rule exists to avoid: ranking by tf-idf *sum*
    // follows frequency rather than rarity. Here the generic cluster has by
    // far the biggest counts, and must still be flagged -- a size-weighted
    // rule would rank it as the healthiest one.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "invoice", "dunning", "description", "identifier" });
    try v.cluster("Shipping", &.{ "parcel", "carrier", "description", "identifier" });
    try v.cluster("Pricing", &.{ "tariff", "premium", "description", "identifier" });
    try v.row("Huge", "description", 99999);
    try v.row("Huge", "identifier", 88888);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Huge") != null);
}

test "the rare threshold scales with cluster count, and floors at 2" {
    // max(2, N/20): at 60 clusters the threshold is 3, so a term shared by
    // three of them still counts as rare. Below 40 clusters it is the
    // constant 2 that was measured to work.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    var i: usize = 1;
    while (i <= 60) : (i += 1) {
        // Every cluster gets a term shared by exactly three clusters, plus
        // filler shared by all sixty.
        const trio = try std.fmt.allocPrint(gpa, "trio{d}", .{(i - 1) / 3});
        defer gpa.free(trio);
        const name = try std.fmt.allocPrint(gpa, "C{d}", .{i});
        defer gpa.free(name);
        try v.cluster(name, &.{ trio, "common", "alpha", "beta" });
    }
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, true);
    defer gpa.free(r.out);
    // df(trioK) == 3 <= 60/20, so each cluster has exactly one rare term and
    // is flagged at tolerance 1. With the floor-only rule (threshold 2) df 3
    // would not be rare and every cluster would score 0 -- also flagged, so
    // assert the score, which is what actually distinguishes the two.
    try testing.expectEqual(@as(usize, 60), std.mem.count(u8, r.out, "\t1\t"));
}

test "--top changes how many terms the rule looks at" {
    // A cluster whose only distinctive terms sit below the cut is flagged
    // at a small --top and not at a large one.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "description", "identifier", "bundle", "resource", "invoice", "dunning" });
    try v.cluster("Shipping", &.{ "description", "identifier", "bundle", "resource", "parcel", "carrier" });
    try v.cluster("Pricing", &.{ "description", "identifier", "bundle", "resource", "tariff", "premium" });
    const path = try v.path();
    defer gpa.free(path);

    const small = try runGate(gpa, path, null, 4, false);
    defer gpa.free(small.out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, small.out, "\n"));

    const large = try runGate(gpa, path, null, 6, false);
    defer gpa.free(large.out);
    try testing.expectEqual(@as(usize, 0), large.out.len);
}

test "a repeated cluster/word pair counts once toward document frequency" {
    // Two nodes claiming the same file is legitimate, so `synapse vocab` can
    // emit a pair more than once. Double-counting it would inflate df and
    // make a distinctive term look corpus-common. Three clusters, so
    // `description` (df 3) is not rare and Billing's two rare terms are
    // exactly `invoice` and `dunning`.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "invoice", "dunning", "description" });
    try v.cluster("Shipping", &.{ "parcel", "carrier", "description" });
    try v.cluster("Pricing", &.{ "tariff", "premium", "description" });
    try v.row("Billing", "invoice", 40);
    try v.row("Billing", "invoice", 40);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, true);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Billing\t2\t") != null);
    // And it appears once in the term list, not three times.
    const billing_line_at = std.mem.indexOf(u8, r.out, "Billing\t").?;
    const line_end = std.mem.indexOfScalarPos(u8, r.out, billing_line_at, '\n').?;
    const billing_line = r.out[billing_line_at..line_end];
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, billing_line, "invoice"));
}

test "output is reproducible: ties among equal counts break by name" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try v.cluster("Billing", &.{ "alpha", "bravo", "charlie", "delta" });
    try v.cluster("Shipping", &.{ "alpha", "bravo", "charlie", "delta" });
    try v.row("Tied", "zulu", 5);
    try v.row("Tied", "yankee", 5);
    try v.row("Tied", "xray", 5);
    const path = try v.path();
    defer gpa.free(path);

    const first = try runGate(gpa, path, null, 8, true);
    defer gpa.free(first.out);
    const second = try runGate(gpa, path, null, 8, true);
    defer gpa.free(second.out);
    try testing.expectEqualStrings(first.out, second.out);
    var found = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, first.out, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Tied\t")) {
            try testing.expect(std.mem.endsWith(u8, line, "\txray yankee zulu"));
            found = true;
        }
    }
    try testing.expect(found);
}

test "an empty or missing vocabulary file exits 1 rather than reporting all clear" {
    // The dangerous silent case: nothing was tagged, so no cluster has any
    // vocabulary, and a rule that just counted rare terms would flag every
    // one of them -- or, printing nothing, would read as a clean bill of
    // health.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    const path = try v.path(); // empty table
    defer gpa.free(path);

    const empty = try runGate(gpa, path, null, 8, false);
    defer gpa.free(empty.out);
    try testing.expectEqual(@as(u8, 1), empty.code);

    const missing = try runGate(gpa, "/nonexistent/nope.tsv", null, 8, false);
    defer gpa.free(missing.out);
    try testing.expectEqual(@as(u8, 1), missing.code);
}

test "a would-be-flagged cluster with zero parseable files is unparseable, not flagged" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const vocab_path = try v.path();
    defer gpa.free(vocab_path);
    const parseable_path = try v.extraFile(
        "parseable.tsv",
        "Billing\t5\t5\nShipping\t5\t5\nPricing\t5\t5\nGeneric\t0\t5\n",
    );
    defer gpa.free(parseable_path);

    // Not in the default listing -- the whole point is the gate stops
    // recommending dispersal for a cluster it has no real evidence about.
    const r = try runGate(gpa, vocab_path, parseable_path, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "Generic") == null);

    const all = try runGate(gpa, vocab_path, parseable_path, 8, true);
    defer gpa.free(all.out);
    try testing.expect(std.mem.indexOf(u8, all.out, "Generic\t0\tunparseable\t") != null);
    // The other three are unaffected: real evidence, real verdict.
    try testing.expect(std.mem.indexOf(u8, all.out, "Billing\t2\tok\t") != null);
}

test "a would-be-flagged cluster with even one parseable file stays flagged" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const vocab_path = try v.path();
    defer gpa.free(vocab_path);
    const parseable_path = try v.extraFile("parseable.tsv", "Generic\t1\t5\n");
    defer gpa.free(parseable_path);

    const r = try runGate(gpa, vocab_path, parseable_path, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.startsWith(u8, r.out, "Generic"));
    try testing.expect(std.mem.indexOf(u8, r.out, "flagged") != null);
}

test "a cluster --parseable has no row for is judged as if --parseable were absent" {
    // Absence of data is not the same claim as zero-parseable data -- a
    // cluster this file never mentions gets the ordinary rare-term verdict,
    // not a free pass and not a suppression.
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const vocab_path = try v.path();
    defer gpa.free(vocab_path);
    const parseable_path = try v.extraFile("parseable.tsv", "Billing\t5\t5\n");
    defer gpa.free(parseable_path);

    const r = try runGate(gpa, vocab_path, parseable_path, 8, false);
    defer gpa.free(r.out);
    try testing.expect(std.mem.startsWith(u8, r.out, "Generic"));
    try testing.expect(std.mem.indexOf(u8, r.out, "flagged") != null);
}

test "without --parseable, behaviour is exactly the old flagged/ok split" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, null, 8, true);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, r.out, "unparseable"));
}

test "a missing --parseable file is an error, not a silently ignored flag" {
    const gpa = testing.allocator;
    var v: Vocab = .init(gpa);
    defer v.deinit();
    try writeFourClusters(&v);
    const path = try v.path();
    defer gpa.free(path);

    const r = try runGate(gpa, path, "/nonexistent/nope.tsv", 8, false);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}
