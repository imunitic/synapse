//! The cluster-quality gate: does a candidate cluster own any vocabulary of its
//! own?
//!
//! `/synapse-init` could always *prove* coverage -- regex expansion plus `comm` --
//! but whether a cluster corresponds to a **concept** was judgment, discovered only
//! when someone tried to write its summary and found there was nothing to say. This
//! is that check, made mechanical.
//!
//! ```
//! rare  := df <= max(2, N/20)      # N = number of clusters, df over clusters
//! flag  := count of rare terms among the cluster's top TOP <= 1
//! ```
//!
//! ## Why counting rare terms and not weighing them
//!
//! Ranking a cluster's terms by tf-idf *sum* is the obvious thing and it fails: a
//! sum follows frequency rather than rarity, and it put two known-bad clusters near
//! the top of the list. What separates a real concept from a generic one is not how
//! much distinctive vocabulary it has in total, it is whether it has **any at all**.
//!
//! Measured against the four known-undifferentiated clusters in a large repo (46
//! nodes): tolerance 0 catches three with no false positives, tolerance 1 catches
//! all four with no false positives, tolerance 2 catches four but flags five good
//! clusters as well. `max(2, N/20)` reduces to the constant that worked at that
//! corpus size and scales with cluster count instead of needing recalibration.
//!
//! ## The input must be cluster-keyed, and that is the whole reason the threshold
//! ever looked unstable
//!
//! A few dozen candidate clusters, not the several hundred directory groups that
//! form the orientation evidence. Document frequency across 500 groups means
//! something entirely different from document frequency across 46 clusters, and
//! feeding the wrong table in is what made the threshold look like it needed tuning.
//!
//! ## The limit above, now narrowed rather than fixed -- synapse-001, step 7
//!
//! "Owns no distinctive vocabulary" and "produced no vocabulary at all" still
//! present identically to the rare-term count: both are zero. What changed is
//! that the gate no longer has to guess which one it is looking at. Given each
//! cluster's **parseable share** -- the fraction of its files with a usable
//! grammar, `synapse vocab`'s `parseable.tsv` -- a cluster with zero rare terms
//! *and* zero parseable files gets a third status, `unparseable`, instead of
//! `flagged`.
//!
//! Deliberately narrow: the cutoff is exactly zero, not a threshold below it.
//! A cluster that is *mostly* unparseable still has some real files
//! contributing real vocabulary, so the rare-term count still means something
//! for it; a threshold there would be exactly the kind of number step 8's own
//! reasoning warns against introducing without calibration data to back it.
//! Zero needs none: it is the one point where "no vocabulary" cannot mean
//! anything other than "nothing here could be read", which is `/synapse-init`'s
//! own documented override case (a language with no tree-sitter grammar), made
//! mechanical instead of left for the model to notice by hand.
//!
//! `unparseable` is not printed by default, same as `ok` -- the whole point is
//! that the gate stops recommending dispersal for it. `--all` still shows it,
//! labelled, so the fact is never hidden, only kept out of the actionable list.
//! Parseability is optional: `judge` without it behaves exactly as before, and
//! every existing calibration stays pinned to that path.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    ok,
    /// Zero or one rare term among the top ones: owns no vocabulary of its
    /// own, or looks that way.
    flagged,
    /// Would have been `flagged`, but every file in it was unparseable, so
    /// the rare-term count carries no information at all. See "The limit
    /// above, now narrowed rather than fixed" at the top of this file.
    unparseable,
};

/// One cluster's verdict.
pub const Verdict = struct {
    cluster: []const u8,
    /// How many of the top terms are rare across clusters.
    rare: usize,
    status: Status,
    /// The top terms, in rank order.
    top: []const []const u8,
};

pub const Options = struct {
    /// Terms per cluster the rule looks at.
    top: usize = 8,
    /// Cluster name -> share of its files with a usable grammar (`0.0` to
    /// `1.0`), from `synapse vocab`'s `parseable.tsv`. Null (the default)
    /// disables the `unparseable` status entirely, so every existing caller
    /// and every test written before this option existed sees the same
    /// `ok`/`flagged` behaviour it always did. A cluster this map has no
    /// entry for is judged the same way -- no data is not the same claim as
    /// zero-parseable data, so it is not treated as either.
    parseable: ?*const std.StringHashMapUnmanaged(f64) = null,
};

/// Every cluster's terms, and how many clusters each word appears in --
/// what `judge` and `judgeDistinctiveness` both need out of the raw table,
/// parsed exactly once. Interned per (cluster, word) so a repeated pair
/// cannot double-count: the awk this replaces keyed on `cl SUBSEP w` for the
/// same reason, and the comment above it named both consequences -- `df`
/// counts *clusters* containing a word, and a term list must not carry a
/// duplicate into top-N selection.
const Parsed = struct {
    clusters: std.ArrayListUnmanaged(Cluster) = .empty,
    /// Word -> how many clusters contain it.
    df: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *Parsed, gpa: Allocator) void {
        for (self.clusters.items) |*c| c.deinit(gpa);
        self.clusters.deinit(gpa);
        self.df.deinit(gpa);
    }
};

fn parseTable(gpa: Allocator, table: []const u8) !Parsed {
    var result: Parsed = .{};
    errdefer result.deinit(gpa);

    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_name.deinit(gpa);

    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // `NF < 3 { next }`: a short row is skipped, not an error. The table is
        // derived and a truncated last line must not fail the judgment.
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const word = fields.next() orelse continue;
        const count_text = fields.next() orelse continue;
        if (name.len == 0 or word.len == 0) continue;
        // `$3 + 0` in awk: a non-numeric count reads as zero rather than skipping
        // the row, because the row still proves the word occurs in the cluster.
        const count = std.fmt.parseInt(usize, std.mem.trim(u8, count_text, " \t"), 10) catch 0;

        const slot = try by_name.getOrPut(gpa, name);
        if (!slot.found_existing) {
            slot.value_ptr.* = result.clusters.items.len;
            try result.clusters.append(gpa, .{ .name = name, .terms = .empty, .index = .empty });
        }
        const c = &result.clusters.items[slot.value_ptr.*];

        const term = try c.index.getOrPut(gpa, word);
        if (!term.found_existing) {
            term.value_ptr.* = c.terms.items.len;
            try c.terms.append(gpa, .{ .word = word, .count = count });
            const d = try result.df.getOrPut(gpa, word);
            if (!d.found_existing) d.value_ptr.* = 0;
            d.value_ptr.* += 1;
        } else {
            // A repeated pair keeps the larger count, as `else if (n > cnt[key])`
            // did -- the table can legitimately list one word twice for a cluster
            // when two of its lists share a file.
            const existing = &c.terms.items[term.value_ptr.*];
            if (count > existing.count) existing.count = count;
        }
    }
    return result;
}

/// Judge every cluster in a `cluster <TAB> word <TAB> count` table.
///
/// Clusters come back in first-appearance order, which is the order the table
/// lists them and therefore the order `synapse-vocab.sh --lists` produced. Not
/// sorted: a report a human reads next to the list of clusters must follow it.
pub fn judge(gpa: Allocator, table: []const u8, opts: Options) !std.ArrayListUnmanaged(Verdict) {
    var parsed = try parseTable(gpa, table);
    defer parsed.deinit(gpa);

    var out: std.ArrayListUnmanaged(Verdict) = .empty;
    errdefer {
        for (out.items) |v| gpa.free(v.top);
        out.deinit(gpa);
    }
    if (parsed.clusters.items.len == 0) return out;

    // The threshold scales with cluster count and floors at the measured constant:
    // `N/20` is 2 for anything up to 40 clusters, so small corpora get the value
    // the calibration was done at.
    const rare_max = @max(@as(usize, 2), parsed.clusters.items.len / 20);

    for (parsed.clusters.items) |*c| {
        const top = try selectTop(gpa, c.terms.items, opts.top);
        var rare: usize = 0;
        for (top) |w| {
            if ((parsed.df.get(w) orelse 0) <= rare_max) rare += 1;
        }
        const would_flag = rare <= 1;
        const share = if (opts.parseable) |m| m.get(c.name) else null;
        const status: Status = if (!would_flag)
            .ok
        else if (share != null and share.? == 0.0)
            .unparseable
        else
            .flagged;
        try out.append(gpa, .{
            .cluster = c.name,
            .rare = rare,
            .status = status,
            .top = top,
        });
    }
    return out;
}

/// The saturation-curve distinctiveness score for a word appearing in `df`
/// clusters out of `n`, scaled by `k` -- the design's addendum, superseding
/// the `df <= max(2, N/20)` cliff for anything computed at orientation time
/// (not for `judge` above, which keeps the cliff its own calibration was
/// measured against).
///
/// `D = max(2, n / k)` is the half-distinctive point: the `df` at which a
/// word scores exactly 0.5. At `k = 20` that point equals the old cliff, so
/// the old threshold becomes this curve's midpoint rather than being
/// discarded. Scale-free by construction -- `n` is already inside `D`, so a
/// word in one twentieth of the groups is half-distinctive whether there are
/// 46 groups or 500 -- which is what makes `k` a repo-*shape* knob rather
/// than a per-scale threshold to re-derive.
pub fn distinctivenessScore(df: usize, n: usize, k: usize) f64 {
    const d: f64 = @floatFromInt(@max(@as(usize, 2), n / k));
    return d / (d + @as(f64, @floatFromInt(df)));
}

pub const DistinctivenessOptions = struct {
    /// Terms per cluster the rule looks at, same default as `judge`'s `top`.
    top: usize = 8,
    /// The scaling constant. Encodes repo *shape*: a single-domain repo
    /// where every group shares one product's vocabulary may want this
    /// larger, so a word has to be rarer to count; a monorepo of unrelated
    /// projects may want it smaller. `20` reproduces `judge`'s own cliff at
    /// the curve's 0.5 point, and is the value the design's calibration
    /// against syrius3 is anchored to.
    k: usize = 20,
};

/// One group's distinctiveness summary: how many of its top terms scored
/// above 0.5, out of how many were considered. Count-like, not a sum --
/// see "Two rules survive the change" below for why summing scores is
/// exactly the failure `core/gate.zig`'s own calibration already ruled out
/// once, for a different aggregation over the same shape of data.
pub const DistinctivenessRow = struct {
    group: []const u8,
    distinctive: usize,
    considered: usize,
};

/// Score every group's top terms in a `group <TAB> word <TAB> count` table
/// (the same shape `judge` reads -- typically the directory-keyed table
/// `synapse vocab` writes before any clustering exists, which is the whole
/// point: this is evidence for the model to read *during* clustering, not a
/// verdict on a clustering already made).
///
/// Groups come back in first-appearance order, same reporting convention as
/// `judge`. Every group appears, even one with zero distinctive terms --
/// omitting it would read as "not computed" rather than "computed as zero",
/// and the two are a different fact.
pub fn judgeDistinctiveness(
    gpa: Allocator,
    table: []const u8,
    opts: DistinctivenessOptions,
) !std.ArrayListUnmanaged(DistinctivenessRow) {
    var parsed = try parseTable(gpa, table);
    defer parsed.deinit(gpa);

    var out: std.ArrayListUnmanaged(DistinctivenessRow) = .empty;
    errdefer out.deinit(gpa);
    if (parsed.clusters.items.len == 0) return out;

    const n = parsed.clusters.items.len;
    for (parsed.clusters.items) |*c| {
        const top = try selectTop(gpa, c.terms.items, opts.top);
        defer gpa.free(top);
        var distinctive: usize = 0;
        for (top) |w| {
            const df = parsed.df.get(w) orelse 0;
            if (distinctivenessScore(df, n, opts.k) > 0.5) distinctive += 1;
        }
        try out.append(gpa, .{ .group = c.name, .distinctive = distinctive, .considered = top.len });
    }
    return out;
}

/// Frees what `judge` returned.
pub fn free(gpa: Allocator, verdicts: *std.ArrayListUnmanaged(Verdict)) void {
    for (verdicts.items) |v| gpa.free(v.top);
    verdicts.deinit(gpa);
}

const Cluster = struct {
    name: []const u8,
    terms: std.ArrayListUnmanaged(Term),
    index: std.StringHashMapUnmanaged(usize),

    fn deinit(self: *Cluster, gpa: Allocator) void {
        self.terms.deinit(gpa);
        self.index.deinit(gpa);
    }
};

const Term = struct {
    word: []const u8,
    count: usize,
};

/// The `n` highest-count terms, ties broken by name ascending.
///
/// Selection rather than a sort, as the awk did and for its stated reason: `n` is 8
/// and a cluster has thousands of terms, so a full sort per cluster is work with no
/// answer attached to it. Ties by name so the output is reproducible run to run --
/// two words with the same count would otherwise order by hash iteration.
fn selectTop(gpa: Allocator, terms: []const Term, n: usize) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var taken = try gpa.alloc(bool, terms.len);
    defer gpa.free(taken);
    @memset(taken, false);

    var round: usize = 0;
    while (round < n) : (round += 1) {
        var best: ?usize = null;
        for (terms, 0..) |t, i| {
            if (taken[i]) continue;
            const b = best orelse {
                best = i;
                continue;
            };
            if (t.count > terms[b].count) {
                best = i;
            } else if (t.count == terms[b].count and std.mem.order(u8, t.word, terms[b].word) == .lt) {
                best = i;
            }
        }
        const pick = best orelse break;
        taken[pick] = true;
        try out.append(gpa, terms[pick].word);
    }
    return out.toOwnedSlice(gpa);
}

/// `cluster <TAB> rare <TAB> flagged|ok <TAB> top terms`.
///
/// One line per flagged cluster, so empty output means every cluster is
/// differentiated -- the same reporting convention as `query stale`/`drift`/
/// `grounding`. `--all` adds the `ok` rows in the *same* shape rather than a second
/// one, so the same field positions parse either way.
pub fn writeVerdict(w: *std.Io.Writer, v: Verdict) !void {
    const status_text = switch (v.status) {
        .ok => "ok",
        .flagged => "flagged",
        .unparseable => "unparseable",
    };
    try w.print("{s}\t{d}\t{s}\t", .{ v.cluster, v.rare, status_text });
    for (v.top, 0..) |t, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(t);
    }
    try w.writeAll("\n");
}

/// `group <TAB> distinctive <TAB> considered`.
pub fn writeDistinctiveness(w: *std.Io.Writer, row: DistinctivenessRow) !void {
    try w.print("{s}\t{d}\t{d}\n", .{ row.group, row.distinctive, row.considered });
}

const testing = std.testing;

test "a cluster whose top terms are all common is flagged" {
    const gpa = testing.allocator;
    // Three clusters all sharing `service` and `impl`: df 3 each, and with 3
    // clusters rare_max is 2, so neither is rare.
    const table =
        "a\tservice\t10\na\timpl\t9\n" ++
        "b\tservice\t8\nb\timpl\t7\n" ++
        "c\tservice\t6\nc\timpl\t5\n";
    var v = try judge(gpa, table, .{});
    defer free(gpa, &v);
    try testing.expectEqual(@as(usize, 3), v.items.len);
    for (v.items) |item| {
        try testing.expectEqual(@as(usize, 0), item.rare);
        try testing.expectEqual(Status.flagged, item.status);
    }
}

test "one distinctive term is not enough, two are" {
    const gpa = testing.allocator;
    // `tolerance 1` is the measured rule: flagged when rare <= 1. So a cluster
    // owning exactly one rare word is still flagged -- that calibration caught all
    // four known-bad clusters with no false positives.
    const table =
        "one\tservice\t10\none\tunique1\t9\n" ++
        "two\tservice\t8\ntwo\tuniqueA\t7\ntwo\tuniqueB\t6\n" ++
        "three\tservice\t5\n";
    var v = try judge(gpa, table, .{});
    defer free(gpa, &v);
    try testing.expectEqualStrings("one", v.items[0].cluster);
    try testing.expectEqual(@as(usize, 1), v.items[0].rare);
    try testing.expectEqual(Status.flagged, v.items[0].status);
    try testing.expectEqualStrings("two", v.items[1].cluster);
    try testing.expectEqual(@as(usize, 2), v.items[1].rare);
    try testing.expectEqual(Status.ok, v.items[1].status);
}

test "clusters keep the order the table listed them in" {
    const gpa = testing.allocator;
    const table = "zeta\tw\t1\nalpha\tw\t1\nmid\tw\t1\n";
    var v = try judge(gpa, table, .{});
    defer free(gpa, &v);
    try testing.expectEqualStrings("zeta", v.items[0].cluster);
    try testing.expectEqualStrings("alpha", v.items[1].cluster);
    try testing.expectEqualStrings("mid", v.items[2].cluster);
}

test "a repeated pair counts once for df and keeps the larger count" {
    const gpa = testing.allocator;
    // `w` listed twice for cluster `a`: df must be 1, not 2, or the word stops
    // looking rare and the cluster's own duplicate would hide its distinctiveness.
    const table = "a\tw\t3\na\tw\t9\na\tother\t1\nb\tz\t1\n";
    var v = try judge(gpa, table, .{});
    defer free(gpa, &v);
    // Two rare terms for `a` (`w` and `other`, df 1 each), so not flagged.
    try testing.expectEqual(@as(usize, 2), v.items[0].rare);
    try testing.expectEqual(Status.ok, v.items[0].status);
    // And the larger count won, so `w` outranks `other`.
    try testing.expectEqualStrings("w", v.items[0].top[0]);
}

test "ties break by name so a run is reproducible" {
    const gpa = testing.allocator;
    const table = "a\tbeta\t5\na\talpha\t5\na\tgamma\t5\n";
    var v = try judge(gpa, table, .{ .top = 3 });
    defer free(gpa, &v);
    try testing.expectEqualStrings("alpha", v.items[0].top[0]);
    try testing.expectEqualStrings("beta", v.items[0].top[1]);
    try testing.expectEqualStrings("gamma", v.items[0].top[2]);
}

test "top is a cap, not a requirement" {
    const gpa = testing.allocator;
    const table = "a\tone\t1\na\ttwo\t2\n";
    var v = try judge(gpa, table, .{ .top = 8 });
    defer free(gpa, &v);
    try testing.expectEqual(@as(usize, 2), v.items[0].top.len);
    try testing.expectEqualStrings("two", v.items[0].top[0]);
}

test "the rare threshold scales past forty clusters" {
    const gpa = testing.allocator;
    // 60 clusters: rare_max becomes 3, so a word in three clusters is still rare.
    var table: std.ArrayListUnmanaged(u8) = .empty;
    defer table.deinit(gpa);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var buf: [64]u8 = undefined;
        // Every cluster shares `common`; the first three share `triple`.
        const line = try std.fmt.bufPrint(&buf, "c{d}\tcommon\t5\n", .{i});
        try table.appendSlice(gpa, line);
        if (i < 3) {
            const l2 = try std.fmt.bufPrint(&buf, "c{d}\ttriple\t9\n", .{i});
            try table.appendSlice(gpa, l2);
        }
    }
    var v = try judge(gpa, table.items, .{});
    defer free(gpa, &v);
    try testing.expectEqual(@as(usize, 60), v.items.len);
    // `triple` has df 3 <= 3, so the first three clusters each have one rare term
    // -- still flagged, since the rule needs more than one.
    try testing.expectEqual(@as(usize, 1), v.items[0].rare);
    try testing.expectEqual(Status.flagged, v.items[0].status);
    // `common` has df 60, so a cluster with only it has none.
    try testing.expectEqual(@as(usize, 0), v.items[59].rare);
}

test "a short row is skipped rather than fatal" {
    const gpa = testing.allocator;
    var v = try judge(gpa, "a\tw\t1\nnot-a-row\na\tonly-two-fields\n", .{});
    defer free(gpa, &v);
    try testing.expectEqual(@as(usize, 1), v.items.len);
    try testing.expectEqual(@as(usize, 1), v.items[0].top.len);
}

test "an empty table judges nothing" {
    const gpa = testing.allocator;
    var v = try judge(gpa, "", .{});
    defer free(gpa, &v);
    try testing.expectEqual(@as(usize, 0), v.items.len);
}

test "the line shape is the same for flagged and ok rows" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeVerdict(&out.writer, .{
        .cluster = "lists/01",
        .rare = 0,
        .status = .flagged,
        .top = &.{ "service", "impl" },
    });
    try writeVerdict(&out.writer, .{
        .cluster = "lists/02",
        .rare = 4,
        .status = .ok,
        .top = &.{"statemachine"},
    });
    try testing.expectEqualStrings(
        "lists/01\t0\tflagged\tservice impl\n" ++
            "lists/02\t4\tok\tstatemachine\n",
        out.written(),
    );
}

// --- distinctivenessScore / judgeDistinctiveness ----------------------------
// synapse-001, addendum: the saturation curve replacing the cliff.

test "distinctivenessScore reproduces the addendum's own worked table" {
    // 500 groups, K = 20: D = max(2, 500/20) = 25.
    const cases = [_]struct { df: usize, want: f64 }{
        .{ .df = 1, .want = 0.96 },
        .{ .df = 5, .want = 0.83 },
        .{ .df = 25, .want = 0.50 },
        .{ .df = 50, .want = 0.33 },
        .{ .df = 500, .want = 0.05 },
    };
    for (cases) |c| {
        try testing.expectApproxEqAbs(c.want, distinctivenessScore(c.df, 500, 20), 0.005);
    }
}

test "distinctivenessScore: K = 20 reproduces judge's own cliff as the 0.5 point" {
    // At N groups, judge's rare_max is max(2, N/20) -- the same D this curve
    // computes at K = 20. A word right at that df scores exactly 0.5.
    try testing.expectApproxEqAbs(@as(f64, 0.5), distinctivenessScore(25, 500, 20), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), distinctivenessScore(2, 40, 20), 1e-9);
}

test "distinctivenessScore floors D at 2, same floor judge uses" {
    // N = 10, K = 20: N/K = 0, floored to 2 -- not zero, which would make
    // every word maximally distinctive regardless of df.
    try testing.expectApproxEqAbs(@as(f64, 0.5), distinctivenessScore(2, 10, 20), 1e-9);
}

test "judgeDistinctiveness: a word shared by every group scores low and is not counted" {
    const gpa = testing.allocator;
    // 3 groups, all sharing `service`/`impl`: D = max(2, 3/20) = 2,
    // score(df=3) = 2/5 = 0.4, below 0.5 -- not distinctive.
    const table =
        "a\tservice\t10\na\timpl\t9\n" ++
        "b\tservice\t8\nb\timpl\t7\n" ++
        "c\tservice\t6\nc\timpl\t5\n";
    var rows = try judgeDistinctiveness(gpa, table, .{});
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), rows.items.len);
    for (rows.items) |r| {
        try testing.expectEqual(@as(usize, 0), r.distinctive);
        try testing.expectEqual(@as(usize, 2), r.considered);
    }
}

test "judgeDistinctiveness: a word unique to one group scores high and is counted" {
    const gpa = testing.allocator;
    const table =
        "a\tservice\t10\na\tunique1\t9\n" ++
        "b\tservice\t8\nb\tuniqueA\t7\nb\tuniqueB\t6\n" ++
        "c\tservice\t5\n";
    var rows = try judgeDistinctiveness(gpa, table, .{});
    defer rows.deinit(gpa);
    try testing.expectEqualStrings("a", rows.items[0].group);
    try testing.expectEqual(@as(usize, 1), rows.items[0].distinctive);
    try testing.expectEqualStrings("b", rows.items[1].group);
    try testing.expectEqual(@as(usize, 2), rows.items[1].distinctive);
}

test "judgeDistinctiveness: groups keep first-appearance order, same as judge" {
    const gpa = testing.allocator;
    const table = "zeta\tw\t1\nalpha\tw\t1\nmid\tw\t1\n";
    var rows = try judgeDistinctiveness(gpa, table, .{});
    defer rows.deinit(gpa);
    try testing.expectEqualStrings("zeta", rows.items[0].group);
    try testing.expectEqualStrings("alpha", rows.items[1].group);
    try testing.expectEqualStrings("mid", rows.items[2].group);
}

test "judgeDistinctiveness: every group appears, including one scoring zero" {
    const gpa = testing.allocator;
    const table = "a\tcommon\t1\nb\tcommon\t1\n";
    var rows = try judgeDistinctiveness(gpa, table, .{});
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
}

test "judgeDistinctiveness: an empty table judges nothing" {
    const gpa = testing.allocator;
    var rows = try judgeDistinctiveness(gpa, "", .{});
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "judgeDistinctiveness: --top caps how many terms are considered" {
    const gpa = testing.allocator;
    const table = "a\tone\t5\na\ttwo\t4\na\tthree\t3\na\tfour\t2\n";
    var rows = try judgeDistinctiveness(gpa, table, .{ .top = 2 });
    defer rows.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), rows.items[0].considered);
}

test "judgeDistinctiveness: a larger K makes a word have to be rarer to count" {
    const gpa = testing.allocator;
    // 20 groups. At K = 20, D = max(2, 1) = 2; a word in 3 groups scores
    // 2/5 = 0.4, not distinctive. At K = 5, D = max(2, 4) = 4; the same word
    // scores 4/7 ~= 0.57, distinctive -- the same data, a different verdict,
    // purely from the shape knob.
    var table: std.ArrayListUnmanaged(u8) = .empty;
    defer table.deinit(gpa);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "c{d}\tfiller\t1\n", .{i});
        try table.appendSlice(gpa, line);
        if (i < 3) {
            const l2 = try std.fmt.bufPrint(&buf, "c{d}\trare3\t9\n", .{i});
            try table.appendSlice(gpa, l2);
        }
    }
    var narrow = try judgeDistinctiveness(gpa, table.items, .{ .top = 1, .k = 20 });
    defer narrow.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), narrow.items[0].distinctive);

    var wide = try judgeDistinctiveness(gpa, table.items, .{ .top = 1, .k = 5 });
    defer wide.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), wide.items[0].distinctive);
}

test "writeDistinctiveness is tab-separated, group then distinctive then considered" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeDistinctiveness(&out.writer, .{ .group = "core/src", .distinctive = 3, .considered = 8 });
    try testing.expectEqualStrings("core/src\t3\t8\n", out.written());
}
