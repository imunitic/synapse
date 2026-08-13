//! A repository reduced to its symbol vocabulary: `group <TAB> word <TAB> count`.
//!
//! Evidence for the clustering step of `/synapse-init`, so that deciding what a
//! subsystem is about costs symbol names rather than source lines. This file is
//! the reduction only -- splitting a symbol into words, deciding which words
//! survive, and naming the group a path belongs to. Tagging, chunking and the
//! files are the command's business.
//!
//! ## The word-splitting rule follows identifier conventions, not English
//!
//! `getUserName` gives get/user/name, `user_name` gives user/name, and a run of
//! capitals stays with what follows it, so `HTTPServer` is one word rather than
//! `http` plus `server`. That last one is the interesting case and it is
//! deliberate: an acronym split apart matches the wrong things, and a repo's
//! `HTTPServer` and `HttpClient` are not the same subsystem evidence.
//!
//! Ported from the awk this replaces, whose rule was one regex --
//! `/[A-Z]+[a-z0-9]*|[a-z0-9]+/`, applied repeatedly from the left. Written out
//! as a scan here rather than as a regex, because that alternation *is* a scan
//! and spelling it directly is both faster and readable without a regex in hand.
//! Every case the awk produced is pinned by a test below, including the ones its
//! author probably did not intend.
//!
//! ## What is dropped, and why the stopword list is shared
//!
//! Words shorter than four characters, words that are all digits, and anything
//! in `~/.claude/synapse-prompt-stopwords.conf`. That file is the same list the
//! prompt tokenizer read before it was deleted, and sharing it is deliberate:
//! two stopword lists that disagree is how two mechanisms start giving different
//! answers about what a background word is.

const std = @import("std");

/// Words a symbol contributes, appended to `out` in the order they appear.
///
/// Case-folded to lowercase, so `getUserName` and `GetUserName` reduce to the
/// same evidence. Filtering is the caller's -- `keep` decides what survives --
/// because the stopword set is loaded once per run and this is called once per
/// symbol.
pub fn splitWords(
    gpa: std.mem.Allocator,
    symbol: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var i: usize = 0;
    while (i < symbol.len) {
        const start = i;
        if (isUpper(symbol[i])) {
            // `[A-Z]+[a-z0-9]*`: the run of capitals, then whatever lowercase
            // and digits follow it. `HTTPServer` matches `HTTPS` then `erver`
            // -- which is what the awk did too, and is why the acronym case is
            // asserted below rather than assumed.
            while (i < symbol.len and isUpper(symbol[i])) i += 1;
            while (i < symbol.len and isLowerOrDigit(symbol[i])) i += 1;
        } else if (isLowerOrDigit(symbol[i])) {
            while (i < symbol.len and isLowerOrDigit(symbol[i])) i += 1;
        } else {
            // Anything else -- `_`, `-`, `.`, punctuation -- is a separator, by
            // being outside both alternatives of the original regex.
            i += 1;
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

/// Whether a split word becomes evidence: at least four characters, not all
/// digits, not a stopword. The order is the awk's, and it is the cheap-first
/// order anyway.
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

/// The directory prefix a path is grouped under: the first `depth` segments.
///
/// `src/main` from `src/main/java/Foo.java` at the default depth of 2. A path
/// shallower than `depth` groups by whatever prefix it has, and a file at the
/// repository root groups as `(repo root)` -- named rather than dropped, because
/// a root file that vanished from the evidence would be invisible rather than
/// obviously ungrouped.
pub fn groupOf(path: []const u8, depth: usize) []const u8 {
    // The awk counted segments of the whole path and then took `depth` of them,
    // capped at `n - 1` so the filename itself is never a group. A path with no
    // separator has `n - 1 == 0` and falls to the root name.
    var segments: usize = 1;
    // Braced deliberately: `for (path) |c| if (c == '/') segments += 1;` parses
    // the loop body as the expression `if (c == '/') segments` and then tries to
    // assign to it, which is a compile error rather than a subtle bug -- but only
    // because assignment is not an expression in Zig.
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

/// The group name for a repository-root file. Exported because the command
/// writes `counts.tsv` from the same rule and the two keys must agree -- a
/// mismatch is what makes a group look like it has vocabulary but no files.
pub const repo_root_group = "(repo root)";

/// What kind of artifact a path is, for the per-group mix: the lowercased
/// extension, or the lowercased filename when there is no extension.
///
/// The filename fallback is the point rather than a tidy-up. Files with no dot
/// are not noise -- `dune`, `Makefile`, `Dockerfile`, `BUILD` -- and a group
/// made largely of them is exactly the kind of answer this table exists to
/// give. Folding them all into one "none" bucket would report that something
/// unusual is there while hiding what it is.
///
/// A leading dot is an extension, not an empty name: `.gitignore` is
/// `gitignore`. That matches how the tags layer reads extensions, and it is
/// also the more useful answer, since a group full of dotfiles is described by
/// which dotfiles they are.
pub fn artifactOf(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // The basename by hand rather than through `std.fs.path`, for the reason
    // core may not name that namespace at all: these paths come from
    // `git ls-files` and always use `/`, while `std.fs.path` would also split on
    // `\` when built for Windows and turn `a\b.java` into a different answer on
    // one platform than on another.
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
    // Checked against the awk rather than reasoned about, because my first guess
    // here was wrong: `[A-Z]+[a-z0-9]*` is greedy on both halves, so `HTTPServer`
    // is a single match -- `HTTPS` then `erver` -- and reduces to one word,
    // `httpserver`, not two. `tests/synapse-vocab.bats` asserts exactly that
    // (`count_of core/src httpserver`), which is what makes it the contract
    // rather than an accident.
    //
    // It is also the right answer for the purpose: an acronym pulled apart
    // matches the wrong things, and `HTTPServer` and `HttpClient` are not the
    // same subsystem evidence.
    try expectWords("HTTPServer", &.{"httpserver"});
    try expectWords("HTTP", &.{"http"});
    try expectWords("IOError", &.{"ioerror"});
    // A capital followed by lowercase is the ordinary CamelCase case, and splits.
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
    // Three characters is out, four is in -- the boundary the awk drew.
    try testing.expect(!keep("get", &stop));
    try testing.expect(keep("name", &stop));
    try testing.expect(!keep("2026", &stop));
    try testing.expect(keep("utf8", &stop));
    try testing.expect(!keep("with", &stop));
}

test "groupOf takes the first depth segments, and never the filename" {
    try testing.expectEqualStrings("src/main", groupOf("src/main/java/Foo.java", 2));
    try testing.expectEqualStrings("src", groupOf("src/main/java/Foo.java", 1));
    // Shallower than depth: whatever prefix there is, never the file itself.
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
        // Lowercased, so one group does not report .SQL and .sql separately.
        .{ .path = "db/Schema.SQL", .want = "sql" },
        // No dot is a filename, not a blank. A group full of `dune` files is a
        // finding; a group full of "none" is not.
        .{ .path = "eon_edn/src/dune", .want = "dune" },
        .{ .path = "Makefile", .want = "makefile" },
        // A leading dot names an extension rather than an empty one.
        .{ .path = ".gitignore", .want = "gitignore" },
        // A trailing dot leaves nothing after it, so the filename stands.
        .{ .path = "weird.", .want = "weird." },
        // Only the last dot counts.
        .{ .path = "app/bundle.min.js", .want = "js" },
        // The directory's dots are not the file's.
        .{ .path = "a.b/c", .want = "c" },
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
