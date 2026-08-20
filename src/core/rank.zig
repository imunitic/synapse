//! Which of a node's sources are worth READING when authoring its prose.
//! Reading order only -- `sources` stays exhaustive, so coverage/staleness/
//! vault search are unaffected. Three pure decisions live here: is a path a
//! test, what stem/module does it key under, which code file consumes a
//! declaration. Tagging, sizing and output belong to the command.
//!
//! `$SYNAPSE_TEST_PATH_RE` overrides the built-in test heuristic with one
//! ERE for projects that name tests differently. The default is a scan, not
//! a regex, so its boundary cases are pinned by tests. The capital-letter
//! check in `[a-z0-9](Tests?|Spec)` matters: without it `Latest.java` reads
//! as a test and silently drops a real file from the crux pool.
//!
//! A declaration resolves to its consumer by stem prefix (`Adresse.domvo` ->
//! `AdresseHandler.java`), scoped to its own module -- a generic stem like
//! `Adresse` matches dozens of unrelated classes repo-wide otherwise.

const std = @import("std");

/// A path segment that names a test directory, whole-segment only.
const test_dirs = [_][]const u8{
    "test", "tests", "spec", "specs", "__tests__", "testing",
};

/// Built-in test heuristic, path/filename only, five alternatives:
///
///   1. a path segment named test/tests/spec/specs/__tests__/testing
///   2. a basename ending `<lower-or-digit-or-.>Test`, `Tests` or `Spec`, then `.ext`
///      (the `.` case is .NET's dot-segment convention, `Foo.Tests.cs`)
///   3. a basename ending `[._-]test`, `[._-]tests` or `[._-]spec`, then `.ext`
///      (the plural `tests` case is Erlang EUnit's own convention, `mymodule_tests.erl`)
///   4. a basename beginning `test_` or `Test_`
///   5. a basename ending `_SUITE`, then `.ext` -- Erlang Common Test, case-sensitive
///      and its own word, not a variant of `test`/`spec`
pub fn isTest(path: []const u8) bool {
    if (hasTestSegment(path)) return true;
    const name = basename(path);
    // Remaining branches all need a trailing extension.
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const stem = name[0..dot];
    if (endsWithCapitalisedTest(stem)) return true;
    if (endsWithSeparatedTest(stem)) return true;
    if (startsWithTestUnderscore(name)) return true;
    if (endsWithSuite(stem)) return true;
    return false;
}

fn hasTestSegment(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        // Last component is a filename, not a directory.
        if (it.rest().len == 0 and !std.mem.endsWith(u8, path, "/")) break;
        for (test_dirs) |d| if (std.mem.eql(u8, seg, d)) return true;
    }
    return false;
}

/// `FooTest`, `FooTests`, `FooSpec` -- only when preceded by a lowercase
/// letter, digit, or `.`, which keeps `Latest` out. The `.` case is .NET's
/// dot-segment convention, `Foo.Tests.cs`.
fn endsWithCapitalisedTest(stem: []const u8) bool {
    for ([_][]const u8{ "Tests", "Test", "Spec" }) |suffix| {
        if (!std.mem.endsWith(u8, stem, suffix)) continue;
        const at = stem.len - suffix.len;
        if (at == 0) continue;
        const prev = stem[at - 1];
        if ((prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9') or prev == '.') return true;
    }
    return false;
}

/// `foo.test`, `foo_test`, `foo-spec` as the stem, i.e. `foo.test.js`. The
/// plural `tests` word is Erlang EUnit's own convention (`mymodule_tests.erl`).
fn endsWithSeparatedTest(stem: []const u8) bool {
    for ([_][]const u8{ "test", "tests", "spec" }) |word| {
        if (!std.mem.endsWith(u8, stem, word)) continue;
        const at = stem.len - word.len;
        if (at == 0) continue;
        switch (stem[at - 1]) {
            '.', '_', '-' => return true,
            else => {},
        }
    }
    return false;
}

fn startsWithTestUnderscore(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "test_") or std.mem.startsWith(u8, name, "Test_");
}

/// Erlang Common Test: `mymodule_SUITE.erl`. Case-sensitive and its own
/// word -- `SUITE` isn't a `test`/`spec` variant, so it gets its own check
/// rather than folding into `endsWithSeparatedTest`'s lowercase word list.
fn endsWithSuite(stem: []const u8) bool {
    const suffix = "_SUITE";
    return stem.len > suffix.len and std.mem.endsWith(u8, stem, suffix);
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| return path[at + 1 ..];
    return path;
}

/// How a path is keyed for the declaration-to-consumer hop.
pub const Key = struct {
    /// Basename with its final extension removed.
    stem: []const u8,
    /// First two path segments, or a shallower path's whole prefix.
    /// `(repo root)` for a file with none -- root files resolve only
    /// against each other.
    module: []const u8,
    path: []const u8,
};

pub const repo_root_module = "(repo root)";

pub fn keyOf(path: []const u8) Key {
    const name = basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |at| name[0..at] else name;

    var segments: usize = 1;
    for (path) |c| {
        if (c == '/') segments += 1;
    }
    const limit = @min(segments - 1, 2);
    const module = if (limit < 1) repo_root_module else blk: {
        var seen: usize = 0;
        for (path, 0..) |c, at| {
            if (c != '/') continue;
            seen += 1;
            if (seen == limit) break :blk path[0..at];
        }
        break :blk path;
    };
    // A leading `/` puts the first slash at index 0, so `path[0..0]` comes
    // back empty -- not a real module name, the same "nothing to key on"
    // case `limit < 1` already has a name for. No real caller produces an
    // absolute path (`git ls-files` is always repo-relative), but `keyOf`
    // shouldn't have a silent empty-string case for one that does.
    return .{ .stem = stem, .module = if (module.len == 0) repo_root_module else module, .path = path };
}

/// Below this, a stem prefixes half the repo and isn't a hop worth making.
pub const min_stem = 3;

/// Whether `declaration`'s stem prefixes `code`'s stem, within one module.
/// Prefix, not equality (`Kunde.gui` -> `KundeController.java`); direction
/// matters -- the declaration's stem is always the prefix.
pub fn consumes(declaration: Key, code: Key) bool {
    if (declaration.stem.len < min_stem) return false;
    if (!std.mem.eql(u8, declaration.module, code.module)) return false;
    return std.mem.startsWith(u8, code.stem, declaration.stem);
}

/// Definitions per kilobyte, the code tier's score. Not raw counts, which
/// rank generated constant tables first -- normalising by size moved a
/// known crux from rank 17 to rank 7 of 574 on a real node.
pub fn density(definitions: usize, size_bytes: u64) f64 {
    std.debug.assert(size_bytes > 0); // callers must not ask about a zero-size file
    return (@as(f64, @floatFromInt(definitions)) * 1000.0) / @as(f64, @floatFromInt(size_bytes));
}

const testing = std.testing;

test "a test directory segment is matched whole, not as a substring" {
    for ([_][]const u8{
        "test/Foo.java",           "src/test/java/Foo.java",
        "spec/thing.rb",           "app/__tests__/x.js",
        "lib/testing/helper.go",   "a/specs/b.py",
    }) |p| try testing.expect(isTest(p));

    // `testdata`/`latest` aren't `test` -- a segment must be the whole word.
    for ([_][]const u8{
        "testdata/fixture.bin",    "src/testutil/Helper.java",
        "contest/Entry.java",      "src/main/java/Foo.java",
    }) |p| try testing.expect(!isTest(p));
}

test "a capitalised Test suffix needs a lowercase, digit, or . before it" {
    try testing.expect(isTest("src/FooTest.java"));
    try testing.expect(isTest("src/FooTests.java"));
    try testing.expect(isTest("src/FooSpec.scala"));
    try testing.expect(isTest("src/Foo2Test.java"));
    // .NET's dot-segment convention: `Foo.Tests.cs`, stem is `Foo.Tests`.
    try testing.expect(isTest("src/Foo.Tests.cs"));

    try testing.expect(!isTest("src/Latest.java"));
    try testing.expect(!isTest("src/Greatest.java"));
    // Bare `Test.java` has nothing before the capital.
    try testing.expect(!isTest("src/Test.java"));
}

test "a separated test, tests, or spec suffix is matched on any of . _ -" {
    try testing.expect(isTest("src/foo.test.js"));
    try testing.expect(isTest("src/foo_test.go"));
    try testing.expect(isTest("src/foo-spec.ts"));
    try testing.expect(isTest("src/foo.spec.ts"));
    // Erlang EUnit's plural convention.
    try testing.expect(isTest("src/mymodule_tests.erl"));

    // No separator and no capital -- neither branch applies.
    try testing.expect(!isTest("src/footest.go"));
    try testing.expect(!isTest("src/protest.py"));
}

test "an Erlang Common Test _SUITE suffix counts" {
    try testing.expect(isTest("src/mymodule_SUITE.erl"));
    // Bare `_SUITE.erl` has nothing before the suffix.
    try testing.expect(!isTest("src/_SUITE.erl"));
    // Lowercase `_suite` isn't the real convention.
    try testing.expect(!isTest("src/mymodule_suite.erl"));
}

test "a test_ prefix counts, in either case" {
    try testing.expect(isTest("src/test_thing.py"));
    try testing.expect(isTest("src/Test_thing.py"));
    try testing.expect(!isTest("src/tested_thing.py"));
    try testing.expect(!isTest("src/attest_thing.py"));
}

test "a basename with no extension matches no filename branch" {
    try testing.expect(!isTest("bin/footest"));
    try testing.expect(!isTest("Makefile"));
    // The directory branch still applies (no extension needed there).
    try testing.expect(isTest("test/runner"));
}

test "keyOf takes the stem and the first two segments" {
    const k = keyOf("core/src/main/Kunde.java");
    try testing.expectEqualStrings("Kunde", k.stem);
    try testing.expectEqualStrings("core/src", k.module);

    const shallow = keyOf("core/Kunde.java");
    try testing.expectEqualStrings("Kunde", shallow.stem);
    try testing.expectEqualStrings("core", shallow.module);

    const root = keyOf("Kunde.java");
    try testing.expectEqualStrings("Kunde", root.stem);
    try testing.expectEqualStrings(repo_root_module, root.module);

    // A leading `/` would otherwise put the first slash at index 0,
    // computing an empty module -- falls back to repo_root_module instead.
    const absolute = keyOf("/a");
    try testing.expectEqualStrings("a", absolute.stem);
    try testing.expectEqualStrings(repo_root_module, absolute.module);

    // Only the final extension is stripped.
    try testing.expectEqualStrings("Adresse.domvo", keyOf("a/b/Adresse.domvo.bak").stem);
    try testing.expectEqualStrings("Makefile", keyOf("a/b/Makefile").stem);
}

test "a declaration consumes a code file by stem prefix within one module" {
    const decl = keyOf("core/src/Kunde.gui");
    try testing.expect(consumes(decl, keyOf("core/src/KundeController.java")));
    try testing.expect(consumes(decl, keyOf("core/src/Kunde.java")));

    // Wrong direction.
    try testing.expect(!consumes(keyOf("core/src/KundeController.gui"), keyOf("core/src/Kunde.java")));
    // Different module.
    try testing.expect(!consumes(decl, keyOf("other/src/KundeController.java")));
    // Unrelated stem.
    try testing.expect(!consumes(decl, keyOf("core/src/Adresse.java")));
}

test "a stem under three characters makes no hop" {
    // `Id.gui` would prefix IdGenerator/Identity/Idle -- half the repo.
    try testing.expect(!consumes(keyOf("core/src/Id.gui"), keyOf("core/src/IdGenerator.java")));
    try testing.expect(consumes(keyOf("core/src/Kdn.gui"), keyOf("core/src/KdnHandler.java")));
}

test "density normalises by size, which is the whole point of the tier" {
    // Raw counts would rank the generated table above the dense impl file.
    const table = density(40, 40_000);
    const impl = density(10, 2_000);
    try testing.expect(impl > table);
    try testing.expectApproxEqAbs(@as(f64, 1.0), density(40, 40_000), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 5.0), density(10, 2_000), 0.001);
}

test "density: monotonic in definitions, always finite and non-negative, for any size > 0" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const size = smith.valueRangeAtMostWithHash(u64, 1, 1 << 40, 0);
            const a = smith.valueRangeAtMostWithHash(u64, 0, 1_000_000, 1);
            const b = smith.valueRangeAtMostWithHash(u64, 0, 1_000_000, 2);
            const lo: usize = @intCast(@min(a, b));
            const hi: usize = @intCast(@max(a, b));

            const d_lo = density(lo, size);
            const d_hi = density(hi, size);
            try testing.expect(std.math.isFinite(d_lo) and d_lo >= 0);
            try testing.expect(std.math.isFinite(d_hi) and d_hi >= 0);
            try testing.expect(d_hi >= d_lo);
        }
    }.testOne, .{});
}

test "isTest: a _test.<ext> suffix is caught whatever the stem, as long as it stays one path segment" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 1, 40, 0));
            var buf: [40]u8 = undefined;
            for (buf[0..len], 0..) |*c, i| {
                c.* = smith.valueRangeAtMostWithHash(u8, 'a', 'z', @intCast(i + 1));
            }
            const stem = buf[0..len];
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "src/{s}_test.go", .{stem});
            try testing.expect(isTest(path));
        }
    }.testOne, .{});
}

test "keyOf: the path field always round-trips, the module is never empty" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 1, 40, 0));
            var buf: [40]u8 = undefined;
            for (buf[0..len], 0..) |*c, i| {
                // `/` and `.` included -- keyOf must cope with arbitrary
                // segment/extension shapes, not just the alphabet.
                c.* = smith.valueRangeAtMostWithHash(u8, '-', 'z', @intCast(i + 1));
            }
            const path = buf[0..len];
            const key = keyOf(path);
            try testing.expectEqualStrings(path, key.path);
            try testing.expect(key.module.len != 0);
        }
    }.testOne, .{});
}

test "consumes: a real prefix relationship in the same module is always caught" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const decl_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, min_stem, 20, 0));
            const suffix_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 20, 1));
            var decl_buf: [20]u8 = undefined;
            var suffix_buf: [20]u8 = undefined;
            for (decl_buf[0..decl_len], 0..) |*c, i| {
                c.* = smith.valueRangeAtMostWithHash(u8, 'a', 'z', @intCast(i + 2));
            }
            for (suffix_buf[0..suffix_len], 0..) |*c, i| {
                c.* = smith.valueRangeAtMostWithHash(u8, 'a', 'z', @intCast(i + 22));
            }

            var decl_path_buf: [40]u8 = undefined;
            var code_path_buf: [64]u8 = undefined;
            const decl_stem = decl_buf[0..decl_len];
            const decl_path = try std.fmt.bufPrint(&decl_path_buf, "core/src/{s}.gui", .{decl_stem});
            const code_path = try std.fmt.bufPrint(
                &code_path_buf,
                "core/src/{s}{s}.java",
                .{ decl_stem, suffix_buf[0..suffix_len] },
            );

            try testing.expect(consumes(keyOf(decl_path), keyOf(code_path)));
        }
    }.testOne, .{});
}
