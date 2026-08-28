//! A repository reduced to its symbol vocabulary: `group <TAB> word <TAB> count`.
//! Evidence for `/synapse-init`'s clustering step. This file is the
//! reduction only -- splitting a symbol into words, deciding which survive,
//! naming a path's group. Tagging/chunking/files are the command's business.
//!
//! Word-splitting follows identifier conventions, not English: `getUserName`
//! -> get/user/name, `user_name` -> user/name, and a run of capitals stays
//! with what follows (`HTTPServer` is one word) -- an acronym split apart
//! matches the wrong things. Ported from the awk's single regex,
//! `/[A-Z]+[a-z0-9]*|[a-z0-9]+/`, written as a scan since that alternation
//! *is* one.
//!
//! Dropped: words under four characters, all-digit words, and anything in
//! `~/.claude/synapse-prompt-stopwords.conf` -- shared with the (now
//! deleted) prompt tokenizer so the two never disagree on what's noise.

const std = @import("std");
const conf = @import("conf.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Words a symbol contributes, appended to `out` in order, case-folded to
/// lowercase. Filtering is the caller's job (`keep`) -- the stopword set
/// loads once per run, this runs once per symbol.
pub fn splitWords(
    gpa: std.mem.Allocator,
    symbol: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var i: usize = 0;
    while (i < symbol.len) {
        const start = i;
        if (isUpper(symbol[i])) {
            // `[A-Z]+[a-z0-9]*`: run of capitals, then lowercase/digits.
            // `HTTPServer` matches `HTTPS` then `erver` (one word), matching the awk.
            while (i < symbol.len and isUpper(symbol[i])) i += 1;
            while (i < symbol.len and isLowerOrDigit(symbol[i])) i += 1;
        } else if (isLowerOrDigit(symbol[i])) {
            while (i < symbol.len and isLowerOrDigit(symbol[i])) i += 1;
        } else {
            i += 1; // separator: `_`, `-`, `.`, punctuation
            continue;
        }
        const word = try gpa.alloc(u8, i - start);
        for (symbol[start..i], 0..) |c, k| word[k] = std.ascii.toLower(c);
        try out.append(gpa, word);
    }
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLowerOrDigit(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// Whether a split word becomes evidence: >= 4 chars, not all digits, not a stopword.
pub fn keep(word: []const u8, stopwords: *const std.StringHashMapUnmanaged(void)) bool {
    if (word.len < 4) return false;
    if (allDigits(word)) return false;
    if (stopwords.contains(word)) return false;
    return true;
}

fn allDigits(word: []const u8) bool {
    for (word) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The stopword set from `synapse-prompt-stopwords.conf`, resolved the same
/// tiered way every other `synapse-*.conf` file resolves. Takes a resolver
/// (`vars`), not a path or a raw environment map -- a caller with no real
/// environment to offer (`conf.Vars.none`) gets a harmless empty set back
/// rather than needing a special case of its own. `gpa` owns every key
/// this allocates; free with `freeStopwords`, not a bare `.deinit`.
pub fn loadStopwords(gpa: Allocator, io: Io, vars: conf.Vars) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    const home = vars.get("HOME") orelse return set;
    const path = (try conf.resolveConfPath(gpa, io, vars, "synapse-prompt-stopwords.conf")) orelse
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-prompt-stopwords.conf", .{home});
    defer gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return set;
    defer gpa.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const lowered = try gpa.alloc(u8, line.len);
        for (line, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
        try set.put(gpa, lowered, {});
    }
    return set;
}

/// Frees every key `loadStopwords` allocated, then the map itself.
pub fn freeStopwords(gpa: Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
}

/// The directory prefix a path is grouped under: the first `depth` segments.
/// `src/main` from `src/main/java/Foo.java` at depth 2. Shallower paths
/// group by whatever prefix they have; a repo-root file groups as
/// `(repo root)`, named rather than dropped so it stays visible.
pub fn groupOf(path: []const u8, depth: usize) []const u8 {
    // Segment count capped at n-1 so the filename itself is never a group.
    var segments: usize = 1;
    for (path) |c| {
        if (c == '/') segments += 1;
    }

    const limit = @min(segments - 1, depth);
    if (limit < 1) return "(repo root)";

    var seen: usize = 0;
    for (path, 0..) |c, at| {
        if (c != '/') continue;
        seen += 1;
        if (seen == limit) return path[0..at];
    }
    return path;
}

/// Group name for a repository-root file. Exported because the command's
/// `counts.tsv` uses the same rule and the two keys must agree.
pub const repo_root_group = "(repo root)";

/// What kind of artifact a path is, for the per-group mix: lowercased
/// extension, or lowercased filename when there's none -- `dune`,
/// `Makefile`, `Dockerfile` are real evidence, not noise to fold into one
/// bucket. A leading dot is an extension, not an empty name: `.gitignore`
/// is `gitignore`.
pub fn artifactOf(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // Basename by hand, not `std.fs.path`: core may not name that
    // namespace, and these paths from `git ls-files` always use `/`.
    const base = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse break :blk path;
        break :blk path[slash + 1 ..];
    };
    const from = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse break :blk base;
        const ext = base[dot + 1 ..];
        break :blk if (ext.len == 0) base else ext;
    };
    const out = try gpa.alloc(u8, from.len);
    for (from, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

const testing = std.testing;

fn wordsOf(gpa: std.mem.Allocator, symbol: []const u8) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    try splitWords(gpa, symbol, &out);
    return out.toOwnedSlice(gpa);
}

fn freeWords(gpa: std.mem.Allocator, words: [][]u8) void {
    for (words) |w| gpa.free(w);
    gpa.free(words);
}

fn expectWords(symbol: []const u8, expected: []const []const u8) !void {
    const gpa = testing.allocator;
    const got = try wordsOf(gpa, symbol);
    defer freeWords(gpa, got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "CamelCase splits at each capital, snake_case at the underscore" {
    try expectWords("getUserName", &.{ "get", "user", "name" });
    try expectWords("premium_rate_table", &.{ "premium", "rate", "table" });
    try expectWords("getUser_name", &.{ "get", "user", "name" });
}

test "a run of capitals stays with what follows it, as one word" {
    // `[A-Z]+[a-z0-9]*` is greedy on both halves: `HTTPServer` is a single
    // match (`HTTPS` then `erver`), reducing to `httpserver`, not two words.
    try expectWords("HTTPServer", &.{"httpserver"});
    try expectWords("HTTP", &.{"http"});
    try expectWords("IOError", &.{"ioerror"});
    // Capital followed by lowercase is ordinary CamelCase, and splits.
    try expectWords("HttpClient", &.{ "http", "client" });
}

test "digits attach to the word they follow" {
    try expectWords("utf8Decoder", &.{ "utf8", "decoder" });
    try expectWords("base64", &.{"base64"});
    try expectWords("Level2Cache", &.{ "level2", "cache" });
}

test "separators outside both alternatives are skipped, not emitted" {
    try expectWords("__init__", &.{"init"});
    try expectWords("a-b-c", &.{ "a", "b", "c" });
    try expectWords("Foo.Bar", &.{ "foo", "bar" });
    try expectWords("", &.{});
    try expectWords("___", &.{});
}

test "keep drops short words, pure digits and stopwords" {
    const gpa = testing.allocator;
    var stop: std.StringHashMapUnmanaged(void) = .empty;
    defer stop.deinit(gpa);
    try stop.put(gpa, "with", {});

    try testing.expect(keep("premium", &stop));
    // Three chars is out, four is in.
    try testing.expect(!keep("get", &stop));
    try testing.expect(keep("name", &stop));
    try testing.expect(!keep("2026", &stop));
    try testing.expect(keep("utf8", &stop));
    try testing.expect(!keep("with", &stop));
}

const TestVars = struct {
    pairs: []const [2][]const u8,

    fn vars(self: *const TestVars) conf.Vars {
        return .{ .ctx = @ptrCast(@constCast(self)), .getFn = lookup };
    }

    fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "loadStopwords reads the real conf file, lowercased, comments and blank lines skipped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".claude");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".claude/synapse-prompt-stopwords.conf",
        .data = "# a comment\n\nTHE\nwith\n",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const tv: TestVars = .{ .pairs = &.{.{ "HOME", home }} };

    var stop = try loadStopwords(gpa, testing.io, tv.vars());
    defer freeStopwords(gpa, &stop);
    try testing.expect(stop.contains("the"));
    try testing.expect(stop.contains("with"));
    try testing.expectEqual(@as(usize, 2), stop.count());
}

test "loadStopwords with no HOME and no XDG config returns an empty set, not an error" {
    const gpa = testing.allocator;
    var stop = try loadStopwords(gpa, testing.io, conf.Vars.none);
    defer freeStopwords(gpa, &stop);
    try testing.expectEqual(@as(usize, 0), stop.count());
}

test "groupOf takes the first depth segments, and never the filename" {
    try testing.expectEqualStrings("src/main", groupOf("src/main/java/Foo.java", 2));
    try testing.expectEqualStrings("src", groupOf("src/main/java/Foo.java", 1));
    // Shallower than depth: whatever prefix exists, never the file itself.
    try testing.expectEqualStrings("src", groupOf("src/Foo.java", 2));
    try testing.expectEqualStrings("a/b/c", groupOf("a/b/c/d/e.java", 3));
}

test "a repository-root file is named, not dropped" {
    try testing.expectEqualStrings("(repo root)", groupOf("README.md", 2));
    try testing.expectEqualStrings("(repo root)", groupOf("Makefile", 1));
    try testing.expectEqualStrings(repo_root_group, groupOf("build.zig", 2));
}

test "the artifact kind is the extension, or the filename when there is none" {
    const gpa = testing.allocator;

    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "src/main/java/Foo.java", .want = "java" },
        .{ .path = "db/Schema.SQL", .want = "sql" }, // lowercased
        .{ .path = "widget_edn/src/dune", .want = "dune" }, // no dot: filename stands
        .{ .path = "Makefile", .want = "makefile" },
        .{ .path = ".gitignore", .want = "gitignore" }, // leading dot is an extension
        .{ .path = "weird.", .want = "weird." }, // trailing dot: nothing after it
        .{ .path = "app/bundle.min.js", .want = "js" }, // only the last dot counts
        .{ .path = "a.b/c", .want = "c" }, // directory's dots aren't the file's
    };

    for (cases) |case| {
        const got = try artifactOf(gpa, case.path);
        defer gpa.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "a deeper depth than the path has does not run off the end" {
    try testing.expectEqualStrings("a/b", groupOf("a/b/c.java", 99));
    try testing.expectEqualStrings("(repo root)", groupOf("c.java", 99));
}
