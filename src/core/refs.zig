//! `_refs.tsv`: a flat, byte-sorted reference index, and the lookup over it.
//!
//! One line per tag, so "who calls X" is a text lookup rather than a traversal:
//!
//! ```
//! name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expression
//! ```
//!
//! `def|ref` is what tree-sitter calls the tag; `kind` is its syntactic category
//! (`class`, `method`, `call`, `implementation`, …). Both are kept because they
//! answer different questions: a `ref` is not necessarily a call -- an
//! `implements Foo` clause is `ref | implementation` -- so a callers query that
//! filtered on `ref` alone would over-report.
//!
//! ## Why a file rather than a query against the cache
//!
//! The constraint is format, not size. Querying JSON at scale is what bit: one
//! `jq` pass over a 4.6 MB cache measured 0.064s, extrapolating to ~13s per query
//! at a large repo's 942 MB, for something meant to feel interactive. The same data
//! as flat sorted lines is a different regime -- 0.092s against a 560 MB index.
//!
//! ## The sort order was a contract between two scripts, and now it is arithmetic
//!
//! `synapse-build-refs.sh` sorted under `LC_ALL=C` and `synapse-callers.sh`
//! binary-searched with `look`, which compares raw bytes when given neither `-d`
//! nor `-f`. Both halves carried a shouting comment saying the other must not
//! change, because a disagreement returns *nothing* -- indistinguishable from
//! "this name is never called".
//!
//! In one process byte order is the only order available, so the hazard is gone by
//! construction rather than by agreement. What is left is the reason the binary
//! search existed at all: measured on a large repo's 1.4 GB index, `look` plus
//! `awk` answered in 0.235s where `awk` alone took 26s. `find` below is that
//! binary search, and it improves on `look` in one respect -- `look` matches by
//! *prefix*, so asking for `bet` returned every `beta`, and the exact match was
//! left to a second pass.

const std = @import("std");

/// One row, already split. Every field is a slice into the index.
pub const Row = struct {
    name: []const u8,
    /// `def` or `ref`.
    dir: []const u8,
    /// `class`, `method`, `call`, `implementation`, …
    kind: []const u8,
    /// `path:line`, kept as one field because that is what a human pastes into an
    /// editor.
    site: []const u8,
    /// The source line the tag came from, which is what usually settles a receiver
    /// without opening the file.
    expr: []const u8,

    /// A call site, as `callers` means it by default: a reference whose kind is
    /// `call`. Not every `ref` is one, which is the whole point of keeping `kind`.
    pub fn isCall(self: Row) bool {
        return std.mem.eql(u8, self.dir, "ref") and std.mem.eql(u8, self.kind, "call");
    }
};

/// Split one line, or null when it has too few fields.
///
/// A short line is skipped rather than reported: the index is derived and
/// rebuilt, so a truncated last line from an interrupted write must not make the
/// whole lookup fail.
pub fn parseRow(line: []const u8) ?Row {
    var it = std.mem.splitScalar(u8, line, '\t');
    const name = it.next() orelse return null;
    const dir = it.next() orelse return null;
    const kind = it.next() orelse return null;
    const site = it.next() orelse return null;
    // The expression is the rest, tabs included: `tag_line.parse` already
    // truncates a source line at its first tab, so a row cannot legitimately have
    // more fields -- but taking the remainder means a future widening there does
    // not silently lose text here.
    const expr = it.rest();
    return .{ .name = name, .dir = dir, .kind = kind, .site = site, .expr = expr };
}

/// Every row whose `name` is exactly `name`, found by binary search.
///
/// `index` must be the whole file, byte-sorted, with `\n`-terminated lines --
/// which is what `writeSorted` produces.
pub fn find(index: []const u8, name: []const u8) RowIterator {
    return .{ .rest = index[firstAtOrAfter(index, name)..], .name = name };
}

pub const RowIterator = struct {
    rest: []const u8,
    name: []const u8,

    pub fn next(self: *RowIterator) ?Row {
        while (self.rest.len != 0) {
            const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const line = self.rest[0..nl];
            self.rest = if (nl == self.rest.len) self.rest[nl..] else self.rest[nl + 1 ..];
            const row = parseRow(line) orelse continue;
            // Sorted, so the first name that is not ours ends the run. This is what
            // makes the whole lookup O(log n) rather than O(n) -- a scan to the end
            // of the file "just to be sure" would give the 26s answer back.
            if (!std.mem.eql(u8, row.name, self.name)) return null;
            return row;
        }
        return null;
    }
};

/// The offset of the first line whose name field is >= `name`.
///
/// Bisects on byte offsets and then walks back to a line boundary, which is the
/// standard trick for binary-searching a line-oriented file without an index of
/// line starts.
fn firstAtOrAfter(index: []const u8, name: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = index.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const start = lineStart(index, mid);
        const nl = std.mem.indexOfScalarPos(u8, index, start, '\n') orelse index.len;
        const field = index[start .. start + (std.mem.indexOfScalar(u8, index[start..nl], '\t') orelse nl - start)];
        if (std.mem.order(u8, field, name) == .lt) {
            // Past this line: `nl + 1` is the next line's start, and it is strictly
            // greater than `lo` because `start >= lo` -- so the loop terminates.
            lo = if (nl == index.len) index.len else nl + 1;
        } else {
            hi = start;
        }
    }
    return lo;
}

fn lineStart(index: []const u8, at: usize) usize {
    if (at == 0) return 0;
    const before = std.mem.lastIndexOfScalar(u8, index[0..at], '\n') orelse return 0;
    return before + 1;
}

/// `sort -u`: byte order, duplicates dropped, one trailing newline per line.
///
/// `-u` and not just `sort`: the projection walks the cache's record table, and
/// two identical tags on the same line of the same file are one fact. The script
/// deduplicated for that reason and the row count it reports is the deduplicated
/// one.
pub fn writeSorted(gpa: std.mem.Allocator, w: *std.Io.Writer, unsorted: []const u8) !Counts {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, unsorted, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(gpa, line);
    }
    std.mem.sort([]const u8, lines.items, {}, lessByBytes);

    var counts: Counts = .{ .tags = 0, .defs = 0, .refs = 0, .files = 0 };
    var prev: ?[]const u8 = null;
    for (lines.items) |line| {
        if (prev) |p| if (std.mem.eql(u8, p, line)) continue;
        prev = line;
        try w.writeAll(line);
        try w.writeAll("\n");
        counts.tags += 1;
        const row = parseRow(line) orelse continue;
        if (std.mem.eql(u8, row.dir, "def")) counts.defs += 1;
        if (std.mem.eql(u8, row.dir, "ref")) counts.refs += 1;
    }
    // The file count needs the *paths* sorted, and these rows are sorted by name,
    // so the same file recurs throughout the listing. A running count of runs here
    // would report every recurrence; it takes its own pass.
    counts.files = try countDistinctFiles(gpa, lines.items);
    return counts;
}

fn countDistinctFiles(gpa: std.mem.Allocator, lines: []const []const u8) !usize {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(gpa);
    var prev: ?[]const u8 = null;
    for (lines) |line| {
        if (prev) |p| if (std.mem.eql(u8, p, line)) continue;
        prev = line;
        const row = parseRow(line) orelse continue;
        try files.append(gpa, row.site[0 .. std.mem.lastIndexOfScalar(u8, row.site, ':') orelse row.site.len]);
    }
    std.mem.sort([]const u8, files.items, {}, lessByBytes);
    var n: usize = 0;
    var last: ?[]const u8 = null;
    for (files.items) |f| {
        if (last) |l| if (std.mem.eql(u8, l, f)) continue;
        last = f;
        n += 1;
    }
    return n;
}

pub const Counts = struct {
    tags: usize,
    defs: usize,
    refs: usize,
    files: usize,
};

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

/// Rows in byte order, as `writeSorted` leaves them. `bet` sits before `beta`,
/// which is the pair that made `look`'s prefix matching a problem.
const sample =
    "bet\tref\tcall\tsrc/a.java:10\tbet();\n" ++
    "beta\tdef\tmethod\tsrc/b.java:3\tvoid beta() {\n" ++
    "beta\tref\tcall\tsrc/a.java:20\tbeta(1);\n" ++
    "beta\tref\timplementation\tsrc/c.java:5\tclass X implements beta {\n" ++
    "zeta\tref\tcall\tsrc/z.java:1\tzeta();\n";

test "an exact name is found, and a prefix of it is not swept in" {
    var it = find(sample, "bet");
    const row = it.next().?;
    try testing.expectEqualStrings("bet", row.name);
    try testing.expectEqualStrings("src/a.java:10", row.site);
    // `look` would have returned every `beta` here too, and the script filtered
    // them out in a second pass. This does not need one.
    try testing.expectEqual(@as(?Row, null), it.next());
}

test "every row for a name comes back, in index order" {
    var it = find(sample, "beta");
    const a = it.next().?;
    try testing.expectEqualStrings("def", a.dir);
    const b = it.next().?;
    try testing.expectEqualStrings("call", b.kind);
    const c = it.next().?;
    try testing.expectEqualStrings("implementation", c.kind);
    try testing.expectEqual(@as(?Row, null), it.next());
}

test "an implements clause is a ref but not a call" {
    var it = find(sample, "beta");
    var calls: usize = 0;
    var total: usize = 0;
    while (it.next()) |row| {
        total += 1;
        if (row.isCall()) calls += 1;
    }
    // Three rows, one of which is a call: filtering on `ref` alone would report
    // the `implements` clause as a caller.
    try testing.expectEqual(@as(usize, 3), total);
    try testing.expectEqual(@as(usize, 1), calls);
}

test "a name before the first row and after the last both find nothing" {
    var before = find(sample, "aaa");
    try testing.expectEqual(@as(?Row, null), before.next());
    var after = find(sample, "zzz");
    try testing.expectEqual(@as(?Row, null), after.next());
    var missing = find(sample, "gamma");
    try testing.expectEqual(@as(?Row, null), missing.next());
}

test "the first and last rows are reachable" {
    // The bisection's boundaries: an off-by-one at either end is invisible in the
    // middle of a file and total at its edges.
    var first = find(sample, "bet");
    try testing.expect(first.next() != null);
    var last = find(sample, "zeta");
    try testing.expectEqualStrings("src/z.java:1", last.next().?.site);
}

test "an empty index finds nothing rather than misbehaving" {
    var it = find("", "anything");
    try testing.expectEqual(@as(?Row, null), it.next());
}

test "a truncated final line is skipped, not fatal" {
    // An interrupted write leaves one short line. The index is derived and
    // rebuilt, so the lookup must survive it.
    const cut = "beta\tdef\tmethod\tsrc/b.java:3\tvoid beta() {\n" ++ "beta\tref";
    var it = find(cut, "beta");
    try testing.expect(it.next() != null);
    try testing.expectEqual(@as(?Row, null), it.next());
}

test "an index with no trailing newline yields its last row" {
    const no_nl = "beta\tref\tcall\tsrc/a.java:1\tbeta();";
    var it = find(no_nl, "beta");
    try testing.expectEqualStrings("src/a.java:1", it.next().?.site);
}

test "sort -u drops duplicates and counts what survives" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const unsorted =
        "zeta\tref\tcall\tsrc/z.java:1\tzeta();\n" ++
        "beta\tdef\tmethod\tsrc/b.java:3\tvoid beta() {\n" ++
        "zeta\tref\tcall\tsrc/z.java:1\tzeta();\n" ++ // exact duplicate
        "beta\tref\tcall\tsrc/a.java:20\tbeta(1);\n";
    const counts = try writeSorted(gpa, &out.writer, unsorted);
    try testing.expectEqualStrings(
        "beta\tdef\tmethod\tsrc/b.java:3\tvoid beta() {\n" ++
            "beta\tref\tcall\tsrc/a.java:20\tbeta(1);\n" ++
            "zeta\tref\tcall\tsrc/z.java:1\tzeta();\n",
        out.written(),
    );
    try testing.expectEqual(@as(usize, 3), counts.tags);
    try testing.expectEqual(@as(usize, 1), counts.defs);
    try testing.expectEqual(@as(usize, 2), counts.refs);
    // Three distinct paths across three rows.
    try testing.expectEqual(@as(usize, 3), counts.files);
}

test "the file count is distinct paths, not distinct rows" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Two names in one file, and the rows sort apart -- which is why counting runs
    // rather than sorting the paths would answer 2.
    const unsorted =
        "aaa\tref\tcall\tsrc/one.java:1\ta();\n" ++
        "zzz\tref\tcall\tsrc/one.java:9\tz();\n";
    const counts = try writeSorted(gpa, &out.writer, unsorted);
    try testing.expectEqual(@as(usize, 2), counts.tags);
    try testing.expectEqual(@as(usize, 1), counts.files);
}

test "a windows-style path keeps its drive letter out of the line suffix" {
    // `path:line` is cut at the *last* colon, so a path containing one survives.
    const row = parseRow("n\tref\tcall\tC:/x/y.java:42\tn();").?;
    try testing.expectEqualStrings("C:/x/y.java:42", row.site);
}
