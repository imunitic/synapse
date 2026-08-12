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
//! ## Known limit, deliberately unfixed
//!
//! The rule cannot distinguish "owns no distinctive vocabulary" from "produced no
//! vocabulary". Both present as zero rare terms. In a single-language repo the
//! ambiguity cannot arise; in a mixed repo a cluster whose language has no grammar
//! is flagged when it should be left alone. Treat a flag as "look at it", which is
//! all a flag ever means here.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One cluster's verdict.
pub const Verdict = struct {
    cluster: []const u8,
    /// How many of the top terms are rare across clusters.
    rare: usize,
    flagged: bool,
    /// The top terms, in rank order.
    top: []const []const u8,
};

pub const Options = struct {
    /// Terms per cluster the rule looks at.
    top: usize = 8,
};

/// Judge every cluster in a `cluster <TAB> word <TAB> count` table.
///
/// Clusters come back in first-appearance order, which is the order the table
/// lists them and therefore the order `synapse-vocab.sh --lists` produced. Not
/// sorted: a report a human reads next to the list of clusters must follow it.
pub fn judge(gpa: Allocator, table: []const u8, opts: Options) !std.ArrayListUnmanaged(Verdict) {
    // Interned per (cluster, word) so a repeated pair cannot double-count. The awk
    // keyed on `cl SUBSEP w` for the same reason, and the comment above it named
    // both consequences: df counts *clusters* containing a word, and the term list
    // must not carry a duplicate into the top-N selection.
    var clusters: std.ArrayListUnmanaged(Cluster) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_name.deinit(gpa);
    // Word -> how many clusters contain it.
    var df: std.StringHashMapUnmanaged(usize) = .empty;
    defer df.deinit(gpa);

    errdefer {
        for (clusters.items) |*c| c.deinit(gpa);
        clusters.deinit(gpa);
    }

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
            slot.value_ptr.* = clusters.items.len;
            try clusters.append(gpa, .{ .name = name, .terms = .empty, .index = .empty });
        }
        const c = &clusters.items[slot.value_ptr.*];

        const term = try c.index.getOrPut(gpa, word);
        if (!term.found_existing) {
            term.value_ptr.* = c.terms.items.len;
            try c.terms.append(gpa, .{ .word = word, .count = count });
            const d = try df.getOrPut(gpa, word);
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

    var out: std.ArrayListUnmanaged(Verdict) = .empty;
    errdefer {
        for (out.items) |v| gpa.free(v.top);
        out.deinit(gpa);
    }
    if (clusters.items.len == 0) {
        for (clusters.items) |*c| c.deinit(gpa);
        clusters.deinit(gpa);
        return out;
    }

    // The threshold scales with cluster count and floors at the measured constant:
    // `N/20` is 2 for anything up to 40 clusters, so small corpora get the value
    // the calibration was done at.
    const rare_max = @max(@as(usize, 2), clusters.items.len / 20);

    for (clusters.items) |*c| {
        const top = try selectTop(gpa, c.terms.items, opts.top);
        var rare: usize = 0;
        for (top) |w| {
            if ((df.get(w) orelse 0) <= rare_max) rare += 1;
        }
        try out.append(gpa, .{
            .cluster = c.name,
            .rare = rare,
            .flagged = rare <= 1,
            .top = top,
        });
    }
    for (clusters.items) |*c| c.deinit(gpa);
    clusters.deinit(gpa);
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
    try w.print("{s}\t{d}\t{s}\t", .{ v.cluster, v.rare, if (v.flagged) "flagged" else "ok" });
    for (v.top, 0..) |t, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(t);
    }
    try w.writeAll("\n");
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
        try testing.expect(item.flagged);
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
    try testing.expect(v.items[0].flagged);
    try testing.expectEqualStrings("two", v.items[1].cluster);
    try testing.expectEqual(@as(usize, 2), v.items[1].rare);
    try testing.expect(!v.items[1].flagged);
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
    try testing.expect(!v.items[0].flagged);
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
    try testing.expect(v.items[0].flagged);
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
        .flagged = true,
        .top = &.{ "service", "impl" },
    });
    try writeVerdict(&out.writer, .{
        .cluster = "lists/02",
        .rare = 4,
        .flagged = false,
        .top = &.{"statemachine"},
    });
    try testing.expectEqualStrings(
        "lists/01\t0\tflagged\tservice impl\n" ++
            "lists/02\t4\tok\tstatemachine\n",
        out.written(),
    );
}
