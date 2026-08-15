//! `_refs.tsv`: a flat, byte-sorted reference index, and the lookup over it.
//! One line per tag, so "who calls X" is a text lookup, not a traversal:
//!
//! ```
//! name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expression
//! ```
//!
//! `dir` is what tree-sitter calls the tag; `kind` is its syntactic category.
//! Both are kept: a `ref` isn't necessarily a call (`implements Foo` is
//! `ref | implementation`), so filtering on `ref` alone would over-report.
//!
//! A file, not a cache query: one `jq` pass over a 4.6 MB cache measured
//! 0.064s (~13s extrapolated at 942 MB); flat sorted lines measured 0.092s
//! against a 560 MB index. Byte order removes the sort-order contract two
//! scripts used to need (a disagreement there returned nothing, silently).
//! `find` below is the binary search that made this fast in the first
//! place -- 0.235s vs 26s for `awk` alone on a 1.4 GB index -- improving on
//! the old `look`-based version by matching exactly rather than by prefix
//! (`look bet` used to return every `beta` too).

const std = @import("std");

/// One row, already split. Every field is a slice into the index.
pub const Row = struct {
    name: []const u8,
    /// `def` or `ref`.
    dir: []const u8,
    /// `class`, `method`, `call`, `implementation`, …
    kind: []const u8,
    /// `path:line`, one field -- what a human pastes into an editor.
    site: []const u8,
    /// Source line the tag came from, usually enough to settle a receiver
    /// without opening the file.
    expr: []const u8,

    /// A call site: a reference whose kind is `call`. Not every `ref` is one.
    pub fn isCall(self: Row) bool {
        return std.mem.eql(u8, self.dir, "ref") and std.mem.eql(u8, self.kind, "call");
    }
};

/// Split one line, or null when it has too few fields. A truncated line
/// (from an interrupted write) is skipped, not fatal -- the index is derived
/// and rebuilt.
pub fn parseRow(line: []const u8) ?Row {
    var it = std.mem.splitScalar(u8, line, '\t');
    const name = it.next() orelse return null;
    const dir = it.next() orelse return null;
    const kind = it.next() orelse return null;
    const site = it.next() orelse return null;
    const expr = it.rest(); // takes the remainder, so a future widening upstream doesn't lose text
    return .{ .name = name, .dir = dir, .kind = kind, .site = site, .expr = expr };
}

/// Every row whose `name` is exactly `name`, found by binary search.
/// `index` must be the whole file, byte-sorted, `\n`-terminated -- what
/// `writeSorted` produces.
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
            // Sorted, so the first non-matching name ends the run -- O(log n),
            // not the O(n) scan this replaced.
            if (!std.mem.eql(u8, row.name, self.name)) return null;
            return row;
        }
        return null;
    }
};

/// Offset of the first line whose name field is >= `name`. Bisects on byte
/// offsets, then walks back to a line boundary.
fn firstAtOrAfter(index: []const u8, name: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = index.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const start = lineStart(index, mid);
        const nl = std.mem.indexOfScalarPos(u8, index, start, '\n') orelse index.len;
        const field = index[start .. start + (std.mem.indexOfScalar(u8, index[start..nl], '\t') orelse nl - start)];
        if (std.mem.order(u8, field, name) == .lt) {
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
/// Two identical tags on the same line of the same file are one fact.
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
    // File count needs the *paths* sorted; these rows sort by name, so the
    // same file recurs throughout -- needs its own pass.
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

/// Rows in byte order, as `writeSorted` leaves them. `bet` sits before
/// `beta` -- the pair that broke `look`'s old prefix matching.
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
    try testing.expectEqual(@as(?Row, null), it.next()); // no beta swept in
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
    // One of three is a call; filtering on `ref` alone would misreport `implements`.
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
    // Bisection's edge boundaries -- an off-by-one is invisible mid-file.
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
    const cut = "beta\tdef\tmethod\tsrc/b.java:3\tvoid beta() {\n" ++ "beta\tref"; // interrupted write
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
    try testing.expectEqual(@as(usize, 3), counts.files); // three distinct paths
}

test "the file count is distinct paths, not distinct rows" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Two names in one file, rows sort apart -- counting runs would answer 2.
    const unsorted =
        "aaa\tref\tcall\tsrc/one.java:1\ta();\n" ++
        "zzz\tref\tcall\tsrc/one.java:9\tz();\n";
    const counts = try writeSorted(gpa, &out.writer, unsorted);
    try testing.expectEqual(@as(usize, 2), counts.tags);
    try testing.expectEqual(@as(usize, 1), counts.files);
}

test "a windows-style path keeps its drive letter out of the line suffix" {
    const row = parseRow("n\tref\tcall\tC:/x/y.java:42\tn();").?; // cut at the last colon
    try testing.expectEqualStrings("C:/x/y.java:42", row.site);
}
