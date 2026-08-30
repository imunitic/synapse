//! The bounded regular-expression dialect used by Vault note schemas.
//!
//! Schema patterns need character classes, escapes, and counted repetition
//! that `regex_lite` deliberately does not provide. This matcher stays small
//! and allocation-free while covering the v1 schema language: literals,
//! `.`, character classes (including ranges and negation), `*`/`+`/`?`,
//! `{n}`/`{n,}`/`{n,m}`, and `^`/`$` anchors. Groups, alternation, captures,
//! and backreferences are intentionally unsupported.

const std = @import("std");

const Quantifier = struct {
    min: usize = 1,
    max: usize = 1,
};

const Atom = union(enum) {
    literal: u8,
    any,
    class: Class,

    const Class = struct {
        source: []const u8,
        negated: bool,
    };

    fn matches(self: Atom, c: u8) bool {
        return switch (self) {
            .literal => |want| want == c,
            .any => true,
            .class => |class| classMatches(class, c),
        };
    }
};

const ParsedAtom = struct {
    atom: Atom,
    next: usize,
};

const ParsedQuantifier = struct {
    quantifier: Quantifier,
    next: usize,
};

pub const Error = error{
    InvalidEscape,
    UnterminatedClass,
    EmptyClass,
    InvalidRange,
    InvalidQuantifier,
    UnsupportedConstruct,
};

/// Validates the pattern's syntax without matching it.
pub fn validate(pattern: []const u8) Error!void {
    var i: usize = if (pattern.len != 0 and pattern[0] == '^') 1 else 0;
    while (i < pattern.len) {
        if (pattern[i] == '$' and i + 1 == pattern.len) return;
        if (pattern[i] == '(' or pattern[i] == ')' or pattern[i] == '|')
            return error.UnsupportedConstruct;
        const parsed = try parseAtom(pattern, i);
        const quant = try parseQuantifier(pattern, parsed.next);
        i = quant.next;
    }
}

/// Matches anywhere unless the pattern begins with `^`.
pub fn isMatch(pattern: []const u8, text: []const u8) Error!bool {
    try validate(pattern);
    const anchored = pattern.len != 0 and pattern[0] == '^';
    const start = if (anchored) @as(usize, 1) else 0;
    var offset: usize = 0;
    while (true) {
        if (try matchHere(pattern, start, text, offset)) return true;
        if (anchored or offset == text.len) return false;
        offset += 1;
    }
}

fn matchHere(pattern: []const u8, p_index: usize, text: []const u8, t_index: usize) Error!bool {
    if (p_index == pattern.len) return true;
    if (pattern[p_index] == '$' and p_index + 1 == pattern.len) return t_index == text.len;

    const parsed = try parseAtom(pattern, p_index);
    const parsed_q = try parseQuantifier(pattern, parsed.next);
    const q = parsed_q.quantifier;

    var count: usize = 0;
    while (t_index + count < text.len and count < q.max and parsed.atom.matches(text[t_index + count]))
        count += 1;
    if (count < q.min) return false;

    var used = count;
    while (true) {
        if (try matchHere(pattern, parsed_q.next, text, t_index + used)) return true;
        if (used == q.min) return false;
        used -= 1;
    }
}

fn parseAtom(pattern: []const u8, index: usize) Error!ParsedAtom {
    if (index >= pattern.len) return error.InvalidQuantifier;
    return switch (pattern[index]) {
        '\\' => blk: {
            if (index + 1 >= pattern.len) return error.InvalidEscape;
            break :blk .{ .atom = .{ .literal = pattern[index + 1] }, .next = index + 2 };
        },
        '.' => .{ .atom = .any, .next = index + 1 },
        '[' => parseClass(pattern, index),
        '*', '+', '?', '{', '}' => error.InvalidQuantifier,
        else => |c| .{ .atom = .{ .literal = c }, .next = index + 1 },
    };
}

fn parseClass(pattern: []const u8, index: usize) Error!ParsedAtom {
    var i = index + 1;
    var negated = false;
    if (i < pattern.len and pattern[i] == '^') {
        negated = true;
        i += 1;
    }
    const start = i;
    var escaped = false;
    while (i < pattern.len) : (i += 1) {
        if (!escaped and pattern[i] == ']') {
            if (i == start) return error.EmptyClass;
            return .{
                .atom = .{ .class = .{ .source = pattern[start..i], .negated = negated } },
                .next = i + 1,
            };
        }
        if (!escaped and pattern[i] == '\\') {
            escaped = true;
        } else {
            escaped = false;
        }
    }
    return error.UnterminatedClass;
}

fn parseQuantifier(pattern: []const u8, index: usize) Error!ParsedQuantifier {
    if (index >= pattern.len) return .{ .quantifier = .{}, .next = index };
    return switch (pattern[index]) {
        '*' => .{ .quantifier = .{ .min = 0, .max = std.math.maxInt(usize) }, .next = index + 1 },
        '+' => .{ .quantifier = .{ .min = 1, .max = std.math.maxInt(usize) }, .next = index + 1 },
        '?' => .{ .quantifier = .{ .min = 0, .max = 1 }, .next = index + 1 },
        '{' => parseCounted(pattern, index),
        else => .{ .quantifier = .{}, .next = index },
    };
}

fn parseCounted(pattern: []const u8, index: usize) Error!ParsedQuantifier {
    var i = index + 1;
    const min = try parseNumber(pattern, &i);
    if (i >= pattern.len) return error.InvalidQuantifier;
    if (pattern[i] == '}') return .{ .quantifier = .{ .min = min, .max = min }, .next = i + 1 };
    if (pattern[i] != ',') return error.InvalidQuantifier;
    i += 1;
    if (i >= pattern.len) return error.InvalidQuantifier;
    if (pattern[i] == '}') return .{
        .quantifier = .{ .min = min, .max = std.math.maxInt(usize) },
        .next = i + 1,
    };
    const max = try parseNumber(pattern, &i);
    if (i >= pattern.len or pattern[i] != '}' or max < min) return error.InvalidQuantifier;
    return .{ .quantifier = .{ .min = min, .max = max }, .next = i + 1 };
}

fn parseNumber(pattern: []const u8, index: *usize) Error!usize {
    const start = index.*;
    var value: usize = 0;
    while (index.* < pattern.len and std.ascii.isDigit(pattern[index.*])) : (index.* += 1) {
        value = std.math.mul(usize, value, 10) catch return error.InvalidQuantifier;
        value = std.math.add(usize, value, pattern[index.*] - '0') catch return error.InvalidQuantifier;
    }
    if (index.* == start) return error.InvalidQuantifier;
    return value;
}

fn classMatches(class: Atom.Class, c: u8) bool {
    var matched = false;
    var i: usize = 0;
    while (i < class.source.len) {
        const first = classChar(class.source, &i) orelse return false;
        if (i + 1 < class.source.len and class.source[i] == '-') {
            i += 1;
            const last = classChar(class.source, &i) orelse return false;
            if (first <= c and c <= last) matched = true;
        } else if (first == c) {
            matched = true;
        }
    }
    return if (class.negated) !matched else matched;
}

fn classChar(source: []const u8, index: *usize) ?u8 {
    if (index.* >= source.len) return null;
    if (source[index.*] == '\\') {
        index.* += 1;
        if (index.* >= source.len) return null;
    }
    const c = source[index.*];
    index.* += 1;
    return c;
}

const testing = std.testing;

test "schema id pattern" {
    const p = "^[a-z][a-z0-9-]*-[0-9]{3,}$";
    try testing.expect(try isMatch(p, "sb-081"));
    try testing.expect(try isMatch(p, "synapse-bard-0012"));
    try testing.expect(!try isMatch(p, "SB-081"));
    try testing.expect(!try isMatch(p, "sb-81"));
}

test "compiled-task backlink pattern" {
    const p = "^> Compiled task: \\[\\[[^\\]]+\\]\\]$";
    try testing.expect(try isMatch(p, "> Compiled task: [[Task title]]"));
    try testing.expect(!try isMatch(p, "> Compiled task: Task title"));
}

test "dated task summary pattern" {
    const p = "^[0-9]{4}-[0-9]{2}-[0-9]{2} — .+$";
    try testing.expect(try isMatch(p, "2026-08-30 — implementation"));
    try testing.expect(!try isMatch(p, "2026-8-30 — implementation"));
}

test "unsupported groups and alternation are refused" {
    try testing.expectError(error.UnsupportedConstruct, validate("^(a|b)$"));
}
