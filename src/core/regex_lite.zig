//! A small, unanchored-by-default regex matcher -- enough for
//! `search_query`'s own `regexp` operator, not a general-purpose engine.
//! Supports literal characters, `.` (any char), `*`/`+`/`?` quantifiers on
//! the immediately preceding atom, and `^`/`$` anchors. No character
//! classes, no groups, no alternation, no backreferences -- checked
//! directly against every real `regexp` pattern this vault's own
//! `search_query` calls have ever used (plain literal text plus `\n`), none
//! of which needs any of those. The classic Kernighan-style recursive
//! matcher, extended with `+`/`?` alongside `*`.

const std = @import("std");

/// True if `pattern` matches anywhere in `text` -- `search_query`'s own
/// `regexp` semantics (a substring search, not a full-string match), unless
/// `pattern` is anchored with a leading `^` (start only) and/or trailing
/// `$` (end only).
pub fn isMatch(pattern: []const u8, text: []const u8) bool {
    const anchored_start = pattern.len != 0 and pattern[0] == '^';
    const p = if (anchored_start) pattern[1..] else pattern;

    var i: usize = 0;
    while (true) {
        if (matchHere(p, text[i..])) return true;
        if (anchored_start or i >= text.len) return false;
        i += 1;
    }
}

/// `p` must match a prefix of `t`, consuming all of `p` exactly (a trailing
/// `$` in `p` additionally requires consuming all of `t`).
fn matchHere(p: []const u8, t: []const u8) bool {
    if (p.len == 0) return true;
    if (p.len == 1 and p[0] == '$') return t.len == 0;

    // Look ahead for a quantifier on the first atom.
    if (p.len >= 2 and p[1] == '*') return matchStar(p[0], p[2..], t);
    if (p.len >= 2 and p[1] == '+') return matchPlus(p[0], p[2..], t);
    if (p.len >= 2 and p[1] == '?') return matchQuestion(p[0], p[2..], t);

    if (t.len == 0) return false;
    if (matchAtom(p[0], t[0])) return matchHere(p[1..], t[1..]);
    return false;
}

fn matchAtom(atom: u8, c: u8) bool {
    return atom == '.' or atom == c;
}

/// Zero or more of `atom`, greedy with backtracking: try the longest
/// possible run first, shrinking until the rest of the pattern matches.
fn matchStar(atom: u8, rest: []const u8, t: []const u8) bool {
    var count: usize = 0;
    while (count < t.len and matchAtom(atom, t[count])) count += 1;
    while (true) {
        if (matchHere(rest, t[count..])) return true;
        if (count == 0) return false;
        count -= 1;
    }
}

/// One or more of `atom` -- same backtracking as `*`, floored at 1 instead of 0.
fn matchPlus(atom: u8, rest: []const u8, t: []const u8) bool {
    var count: usize = 0;
    while (count < t.len and matchAtom(atom, t[count])) count += 1;
    while (count >= 1) {
        if (matchHere(rest, t[count..])) return true;
        count -= 1;
    }
    return false;
}

/// Zero or one of `atom`.
fn matchQuestion(atom: u8, rest: []const u8, t: []const u8) bool {
    if (t.len != 0 and matchAtom(atom, t[0]) and matchHere(rest, t[1..])) return true;
    return matchHere(rest, t);
}

const testing = std.testing;

test "a plain literal matches as a substring anywhere in the text" {
    try testing.expect(isMatch("Discussing", "## Status\nDiscussing"));
    try testing.expect(!isMatch("Ready", "## Status\nDiscussing"));
}

test "a literal newline in the pattern matches a real newline in the text" {
    try testing.expect(isMatch("## Status\nDiscussing", "# Title\n\n## Status\nDiscussing\n"));
}

test "a leading ^ anchors the match to the very start of the text" {
    try testing.expect(isMatch("^Hello", "Hello world"));
    try testing.expect(!isMatch("^world", "Hello world"));
}

test "a trailing $ requires the match to reach the end of the text" {
    try testing.expect(isMatch("world$", "Hello world"));
    try testing.expect(!isMatch("Hello$", "Hello world"));
}

test "^ and $ together require a full match" {
    try testing.expect(isMatch("^Hello world$", "Hello world"));
    try testing.expect(!isMatch("^Hello$", "Hello world"));
}

test "'.' matches any single character" {
    try testing.expect(isMatch("h.llo", "hello"));
    try testing.expect(isMatch("h.llo", "hallo"));
    try testing.expect(!isMatch("h.llo", "hllo"));
}

test "'*' matches zero or more of the preceding atom, greedily" {
    try testing.expect(isMatch("ab*c", "ac"));
    try testing.expect(isMatch("ab*c", "abc"));
    try testing.expect(isMatch("ab*c", "abbbbc"));
    try testing.expect(!isMatch("ab*c", "abd"));
}

test "'+' requires at least one of the preceding atom" {
    try testing.expect(isMatch("ab+c", "abc"));
    try testing.expect(isMatch("ab+c", "abbc"));
    try testing.expect(!isMatch("ab+c", "ac"));
}

test "'?' matches zero or one of the preceding atom" {
    try testing.expect(isMatch("colou?r", "color"));
    try testing.expect(isMatch("colou?r", "colour"));
    try testing.expect(!isMatch("colou?r", "colouur"));
}

test "an empty pattern matches anything, including an empty text" {
    try testing.expect(isMatch("", "anything"));
    try testing.expect(isMatch("", ""));
}

test "a pattern longer than the text simply doesn't match" {
    try testing.expect(!isMatch("^much longer than this$", "short"));
}
