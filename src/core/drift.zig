//! What changed in the tree since a node was built, and what that means.
//!
//! `stale` re-hashes what a node claims; `drift` diffs its recorded `commit`
//! against HEAD. Only `drift` sees added, deleted and renamed paths, because a
//! hash comparison over a path list cannot notice a file that is no longer in the
//! list. Neither pulls.
//!
//! This file is the part that is a function of git's output rather than of git:
//! parsing `--name-status -M`, intersecting a node's paths with what moved, and
//! deciding which finding that is. The command runs git and the manifest match.
//!
//! ## Why renames are their own class
//!
//! Modified, deleted and renamed are three findings rather than one, and the
//! renames line says so explicitly: *"reseat sources, prose may still hold"*. It
//! is the only class fixable without re-authoring -- the concept did not change,
//! the paths did -- and collapsing it into "content changed" would send someone
//! to rewrite prose that is still correct.

const std = @import("std");

/// The four classes of change a node can care about, each already byte-sorted so
/// the intersections below are one merge pass.
pub const Diff = struct {
    modified: [][]const u8,
    deleted: [][]const u8,
    /// The *old* path of each rename. That is what a node still lists, so it is
    /// the side to intersect against -- `R100<TAB>old<TAB>new` and the node knows
    /// `old`.
    renamed_from: [][]const u8,
    added: [][]const u8,

    pub fn deinit(self: Diff, gpa: std.mem.Allocator) void {
        gpa.free(self.modified);
        gpa.free(self.deleted);
        gpa.free(self.renamed_from);
        gpa.free(self.added);
    }
};

/// Parse `git diff --name-status -M <base>..HEAD`.
///
/// Status letters can carry a similarity score (`R100`, `M`), so each class is a
/// prefix test rather than an equality -- which is what the awk's `$1 ~ /^R/`
/// meant. A rename line has three fields and every other class has two; taking
/// field 2 for a rename is deliberate and is the old path.
pub fn parseNameStatus(gpa: std.mem.Allocator, raw: []const u8) !Diff {
    var modified: std.ArrayListUnmanaged([]const u8) = .empty;
    var deleted: std.ArrayListUnmanaged([]const u8) = .empty;
    var renamed: std.ArrayListUnmanaged([]const u8) = .empty;
    var added: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const status = line[0..first_tab];
        if (status.len == 0) continue;
        const rest = line[first_tab + 1 ..];
        // For a rename the path we want is the first of the two remaining
        // fields; for everything else `rest` is the whole path, tabs and all --
        // a path may legally contain one, and git quotes such paths, so cutting
        // at the next tab unconditionally would truncate them.
        const path = switch (status[0]) {
            'R', 'C' => rest[0 .. std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len],
            else => rest,
        };
        switch (status[0]) {
            'M' => try modified.append(gpa, path),
            'D' => try deleted.append(gpa, path),
            'R' => try renamed.append(gpa, path),
            'A' => try added.append(gpa, path),
            // T (type change), C (copy), U (unmerged) and X are not classes the
            // script reported, and inventing a finding for them here would be a
            // behaviour change dressed as completeness.
            else => {},
        }
    }

    const out: Diff = .{
        .modified = try modified.toOwnedSlice(gpa),
        .deleted = try deleted.toOwnedSlice(gpa),
        .renamed_from = try renamed.toOwnedSlice(gpa),
        .added = try added.toOwnedSlice(gpa),
    };
    // Sorted here rather than by the caller, because every use is an
    // intersection and an unsorted side makes `comm` silently find nothing.
    for ([_][][]const u8{ out.modified, out.deleted, out.renamed_from, out.added }) |set|
        std.mem.sort([]const u8, set, {}, lessByBytes);
    return out;
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `comm -12 | grep -c .` over two byte-sorted lists.
///
/// The script needed `LC_ALL=C` on `comm` as well as on the sorts that fed it,
/// because `comm` validates order in the ambient collation and silently reports
/// nothing in common when a UTF-8 locale disagrees with C about case. In process
/// byte order is the only order there is, so that hazard cannot recur.
pub fn countIntersect(a: []const []const u8, b: []const []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        switch (std.mem.order(u8, a[i], b[j])) {
            .lt => i += 1,
            .gt => j += 1,
            .eq => {
                n += 1;
                i += 1;
                j += 1;
            },
        }
    }
    return n;
}

/// How one node's own paths intersect a diff.
pub const NodeDrift = struct {
    modified: usize,
    renamed: usize,
    deleted: usize,

    pub fn any(self: NodeDrift) bool {
        return self.modified > 0 or self.renamed > 0 or self.deleted > 0;
    }
};

/// `paths` must be byte-sorted, as `extract_source_paths | LC_ALL=C sort` left it.
pub fn nodeDrift(paths: []const []const u8, diff: Diff) NodeDrift {
    return .{
        .modified = countIntersect(paths, diff.modified),
        .renamed = countIntersect(paths, diff.renamed_from),
        .deleted = countIntersect(paths, diff.deleted),
    };
}

/// A `node <TAB> reason` row. `(repo)` is used as the node name for findings
/// about the repository rather than about one node, which is how the script
/// distinguished them in one stream.
pub const repo_scope = "(repo)";

/// The per-node lines a drift produces, in the script's order: modified, then
/// renamed, then deleted.
///
/// Order is not cosmetic. A node can report all three, and renames carry the one
/// remedy that does not involve re-reading anything, so they come before the
/// deletions that might otherwise be the only line someone reads.
pub fn writeNodeFindings(
    w: *std.Io.Writer,
    node_without_md: []const u8,
    d: NodeDrift,
) !void {
    if (d.modified > 0)
        try w.print("{s}\tcontent changed in {d} of its files\n", .{ node_without_md, d.modified });
    if (d.renamed > 0)
        try w.print(
            "{s}\t{d} of its files were renamed -- reseat sources, prose may still hold\n",
            .{ node_without_md, d.renamed },
        );
    if (d.deleted > 0)
        try w.print("{s}\t{d} of its files are gone\n", .{ node_without_md, d.deleted });
}

/// Why a node could not be diffed at all, as opposed to having drifted.
///
/// Each one points at `stale` instead, because a node with no usable baseline can
/// still be verified by re-hashing -- the two subcommands answer different
/// questions and one being unavailable does not make the other useless.
pub const Undiffable = union(enum) {
    node_file_missing,
    no_commit_recorded,
    /// The recorded commit is not in this clone's history: a shallow clone, or a
    /// baseline from a branch that was never fetched.
    baseline_absent: []const u8,

    pub fn write(self: Undiffable, w: *std.Io.Writer, node_without_md: []const u8) !void {
        switch (self) {
            .node_file_missing => try w.print(
                "{s}\tnode file missing from the vault\n",
                .{node_without_md},
            ),
            .no_commit_recorded => try w.print(
                "{s}\tno commit recorded, so nothing to diff against -- verify with `stale`\n",
                .{node_without_md},
            ),
            .baseline_absent => |commit| try w.print(
                "{s}\tbaseline {s} not in local history -- verify with `stale`\n",
                .{ node_without_md, shortCommit(commit) },
            ),
        }
    }
};

/// The first twelve characters, matching the script's `cut -c1-12`. Shorter input
/// is returned whole rather than padded.
pub fn shortCommit(commit: []const u8) []const u8 {
    return commit[0..@min(12, commit.len)];
}

const testing = std.testing;

test "name-status parsing splits the four classes and sorts each" {
    const gpa = testing.allocator;
    const raw =
        "M\tsrc/b.java\n" ++
        "A\tsrc/new.java\n" ++
        "D\tsrc/gone.java\n" ++
        "R100\tsrc/old.java\tsrc/moved.java\n" ++
        "M\tsrc/a.java\n";
    const d = try parseNameStatus(gpa, raw);
    defer d.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), d.modified.len);
    // Sorted, because every consumer intersects and an unsorted side finds
    // nothing.
    try testing.expectEqualStrings("src/a.java", d.modified[0]);
    try testing.expectEqualStrings("src/b.java", d.modified[1]);
    try testing.expectEqualStrings("src/gone.java", d.deleted[0]);
    try testing.expectEqualStrings("src/new.java", d.added[0]);
    // The OLD path of the rename -- what the node still lists.
    try testing.expectEqual(@as(usize, 1), d.renamed_from.len);
    try testing.expectEqualStrings("src/old.java", d.renamed_from[0]);
}

test "a status letter with a similarity score is still its class" {
    const gpa = testing.allocator;
    const d = try parseNameStatus(gpa, "R087\ta\tb\nM\tc\n");
    defer d.deinit(gpa);
    try testing.expectEqualStrings("a", d.renamed_from[0]);
    try testing.expectEqualStrings("c", d.modified[0]);
}

test "classes the script never reported are ignored, not invented" {
    // A type change or an unmerged path would need a finding nobody wrote, and
    // guessing one is a behaviour change wearing completeness as a disguise.
    const gpa = testing.allocator;
    const d = try parseNameStatus(gpa, "T\tsrc/link\nU\tsrc/conflict\n");
    defer d.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), d.modified.len);
    try testing.expectEqual(@as(usize, 0), d.deleted.len);
    try testing.expectEqual(@as(usize, 0), d.added.len);
    try testing.expectEqual(@as(usize, 0), d.renamed_from.len);
}

test "countIntersect is a merge pass over two sorted lists" {
    const a = [_][]const u8{ "a", "c", "e", "g" };
    const b = [_][]const u8{ "b", "c", "d", "e" };
    try testing.expectEqual(@as(usize, 2), countIntersect(&a, &b));
    try testing.expectEqual(@as(usize, 0), countIntersect(&a, &.{}));
    try testing.expectEqual(@as(usize, 0), countIntersect(&.{}, &b));
    try testing.expectEqual(@as(usize, 4), countIntersect(&a, &a));
}

test "a node's drift counts each class separately" {
    const gpa = testing.allocator;
    const d = try parseNameStatus(
        gpa,
        "M\tsrc/a.java\nD\tsrc/b.java\nR100\tsrc/c.java\tsrc/moved.java\nA\tsrc/z.java\n",
    );
    defer d.deinit(gpa);

    // Byte-sorted, as `extract_source_paths | LC_ALL=C sort` leaves them.
    const paths = [_][]const u8{ "src/a.java", "src/b.java", "src/c.java" };
    const nd = nodeDrift(&paths, d);
    try testing.expectEqual(@as(usize, 1), nd.modified);
    try testing.expectEqual(@as(usize, 1), nd.deleted);
    try testing.expectEqual(@as(usize, 1), nd.renamed);
    try testing.expect(nd.any());

    // A node claiming none of the changed files has not drifted, and an added
    // path is never a node's drift -- it is the repository's.
    const untouched = [_][]const u8{"src/other.java"};
    try testing.expect(!nodeDrift(&untouched, d).any());
}

test "findings come out modified, renamed, deleted" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeNodeFindings(&out.writer, "Foo Node", .{ .modified = 2, .renamed = 1, .deleted = 3 });
    try testing.expectEqualStrings(
        "Foo Node\tcontent changed in 2 of its files\n" ++
            "Foo Node\t1 of its files were renamed -- reseat sources, prose may still hold\n" ++
            "Foo Node\t3 of its files are gone\n",
        out.written(),
    );
}

test "a clean node produces no lines at all" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeNodeFindings(&out.writer, "Foo", .{ .modified = 0, .renamed = 0, .deleted = 0 });
    // Silence is the signal every reporting subcommand here relies on.
    try testing.expectEqualStrings("", out.written());
}

test "an undiffable node points at stale rather than reporting drift" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try (Undiffable{ .no_commit_recorded = {} }).write(&out.writer, "Foo");
    try (Undiffable{ .baseline_absent = "0123456789abcdef0123" }).write(&out.writer, "Bar");
    try testing.expectEqualStrings(
        "Foo\tno commit recorded, so nothing to diff against -- verify with `stale`\n" ++
            "Bar\tbaseline 0123456789ab not in local history -- verify with `stale`\n",
        out.written(),
    );
}

test "shortCommit is twelve characters, and shorter input survives" {
    try testing.expectEqualStrings("0123456789ab", shortCommit("0123456789abcdef"));
    try testing.expectEqualStrings("abc", shortCommit("abc"));
}

/// The bash's four `awk`+`LC_ALL=C sort` passes, re-emitted so one digest can
/// stand for every path in every class.
///
/// Counting per class would pass while two paths were swapped between them; a
/// digest over the whole labelled listing cannot.
fn digestOfClasses(gpa: std.mem.Allocator, raw: []const u8) ![32]u8 {
    const d = try parseNameStatus(gpa, raw);
    defer d.deinit(gpa);
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    for ([_]struct { c: u8, set: [][]const u8 }{
        .{ .c = 'M', .set = d.modified },
        .{ .c = 'D', .set = d.deleted },
        .{ .c = 'R', .set = d.renamed_from },
        .{ .c = 'A', .set = d.added },
    }) |cls| for (cls.set) |p| {
        sha.update(&.{ cls.c, '\t' });
        sha.update(p);
        sha.update("\n");
    };
    return sha.finalResult();
}

test "differential: 492 real name-status rows, against the awk they replace" {
    const gpa = testing.allocator;
    const raw = @embedFile("drift/testdata/name-status.txt");
    const d = try parseNameStatus(gpa, raw);
    defer d.deinit(gpa);

    // The fixture is the shape of three real repositories' `HEAD~400..HEAD`
    // diffs -- every distinct status letter and field count they produced, plus
    // a sample of the ordinary rows -- with each path segment replaced by a
    // stable pseudonym. Structure is what this parser reads (status letters, the
    // similarity scores from `R054` to `R100`, the three-field rename rows, the
    // directory depth), and structure is what survived; the paths themselves are
    // a closed-source employer's and do not belong in this repository.
    //
    // The differential over the *unanonymised* diffs was run once, on
    // 2026-08-12: fw-core (1,739 rows), syrius-querschnitt-basis (1,019) and
    // syrius3 (18,814, of which 6,160 renames), all three digest-identical to
    // the bash. That is the run that proved the parser; this is the part of it a
    // public repository can keep.
    try testing.expectEqual(@as(usize, 261), d.modified.len);
    try testing.expectEqual(@as(usize, 15), d.deleted.len);
    try testing.expectEqual(@as(usize, 162), d.renamed_from.len);
    try testing.expectEqual(@as(usize, 54), d.added.len);

    // sha256 of the four `awk`+`LC_ALL=C sort` passes over this same file:
    //   for c in M D R A; do awk -F'\t' -v c="$c" '$1 ~ "^"c { print $2 }' \
    //     name-status.txt | LC_ALL=C sort | sed "s/^/$c\t/"; done | shasum -a 256
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&try digestOfClasses(gpa, raw)}) catch unreachable;
    try testing.expectEqualStrings(
        "62a0f823f224e06aa77136a9b9b48feb348998b8d4d5c484369af085a876b6c1",
        &hex,
    );
}
