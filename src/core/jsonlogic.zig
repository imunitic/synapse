//! A JsonLogic evaluator scoped to `search_query`'s own operator set --
//! `and`/`or`/`!`/`==`/`!=`/`in`/`<`/`<=`/`>`/`>=`/`var`/`glob`/`regexp` --
//! not the full published spec. JsonLogic itself is adopted as-is (an
//! existing, published, language-agnostic standard, not something to
//! subset down further) because Synapse's domain is fixed and small.
//! `glob`/`regexp` aren't part of the official spec -- they're the same two
//! operators a widely used vault-search plugin already added, kept
//! identical so a filter written against that plugin's own query language
//! needs no translation to run here.
//!
//! Purely a function of the two JSON trees it's given -- no allocation, no
//! I/O. Every result is either a `bool`, or a reference into `rule`/`data`
//! that already existed (a `var` lookup, an `and`/`or` operand) -- nothing
//! here ever constructs a new `std.json.Value`, so there's nothing for a
//! caller to free beyond what it already owned.

const std = @import("std");
const regex_lite = @import("regex_lite.zig");

const Value = std.json.Value;

pub const Error = error{
    /// A rule object has a key that isn't one of the operators above.
    UnknownOperator,
    /// An operator's arguments don't have the shape it requires (e.g. `in`
    /// given only one argument).
    InvalidArguments,
};

/// Evaluates `rule` against `data`. A rule is a single-key object naming a
/// known operator (`{"==": [a, b]}`); anything else -- a string, number,
/// bool, null, array, or a multi-key/unknown-key object -- is a literal,
/// returned as itself.
pub fn evaluate(rule: Value, data: Value) Error!Value {
    const obj = switch (rule) {
        .object => |o| o,
        else => return rule,
    };
    if (obj.count() != 1) return rule; // not operator-shaped: a literal object

    var it = obj.iterator();
    const entry = it.next().?;
    const op = entry.key_ptr.*;
    const raw_args = entry.value_ptr.*;
    // Every operator accepts either an args array or, for the unary ones,
    // a bare single argument -- normalize to a slice view either way.
    const args: []const Value = switch (raw_args) {
        .array => |a| a.items,
        else => &.{raw_args},
    };

    if (std.mem.eql(u8, op, "var")) return evalVar(args, data);
    if (std.mem.eql(u8, op, "and")) return evalAnd(args, data);
    if (std.mem.eql(u8, op, "or")) return evalOr(args, data);
    if (std.mem.eql(u8, op, "!")) return evalNot(args, data);
    if (std.mem.eql(u8, op, "==")) return evalEq(args, data, true);
    if (std.mem.eql(u8, op, "!=")) return evalEq(args, data, false);
    if (std.mem.eql(u8, op, "in")) return evalIn(args, data);
    if (std.mem.eql(u8, op, "<")) return evalCompare(args, data, .lt);
    if (std.mem.eql(u8, op, "<=")) return evalCompare(args, data, .le);
    if (std.mem.eql(u8, op, ">")) return evalCompare(args, data, .gt);
    if (std.mem.eql(u8, op, ">=")) return evalCompare(args, data, .ge);
    if (std.mem.eql(u8, op, "glob")) return evalPatternMatch(args, data, .glob);
    if (std.mem.eql(u8, op, "regexp")) return evalPatternMatch(args, data, .regexp);
    return Error.UnknownOperator;
}

/// JsonLogic truthiness: `false`, `0`, `""`, `null`, and `[]` are falsy;
/// everything else -- including an empty object -- is truthy.
pub fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |s| s.len != 0 and !std.mem.eql(u8, s, "0"),
        .string => |s| s.len != 0,
        .array => |a| a.items.len != 0,
        .object => true,
    };
}

fn evalVar(args: []const Value, data: Value) Error!Value {
    const path: []const u8 = switch (if (args.len != 0) args[0] else Value.null) {
        .string => |s| s,
        else => return data, // no path (or a non-string path): the whole data tree
    };
    const default: Value = if (args.len >= 2) args[1] else .null;
    if (path.len == 0) return data;

    var current = data;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |seg| {
        const obj = switch (current) {
            .object => |o| o,
            else => return default,
        };
        current = obj.get(seg) orelse return default;
    }
    return current;
}

fn evalAnd(args: []const Value, data: Value) Error!Value {
    if (args.len == 0) return .{ .bool = true };
    var last: Value = .{ .bool = true };
    for (args) |a| {
        last = try evaluate(a, data);
        if (!truthy(last)) return last;
    }
    return last;
}

fn evalOr(args: []const Value, data: Value) Error!Value {
    var last: Value = .{ .bool = false };
    for (args) |a| {
        last = try evaluate(a, data);
        if (truthy(last)) return last;
    }
    return last;
}

fn evalNot(args: []const Value, data: Value) Error!Value {
    if (args.len == 0) return .{ .bool = true };
    const v = try evaluate(args[0], data);
    return .{ .bool = !truthy(v) };
}

fn evalEq(args: []const Value, data: Value, want_equal: bool) Error!Value {
    if (args.len < 2) return Error.InvalidArguments;
    const a = try evaluate(args[0], data);
    const b = try evaluate(args[1], data);
    const eq = deepEqual(a, b);
    return .{ .bool = if (want_equal) eq else !eq };
}

fn deepEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| numEqual(@floatFromInt(x), b),
        .float => |x| numEqual(x, b),
        .number_string => |x| switch (b) {
            .number_string => |y| std.mem.eql(u8, x, y),
            .integer, .float => if (digitsToNumber(x)) |nx| numEqual(nx, b) else false,
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            .integer, .float => if (digitsToNumber(x)) |nx| numEqual(nx, b) else false,
            else => false,
        },
        .array => |x| switch (b) {
            .array => |y| blk: {
                if (x.items.len != y.items.len) break :blk false;
                for (x.items, y.items) |ea, eb| if (!deepEqual(ea, eb)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .object => |x| switch (b) {
            .object => |y| blk: {
                if (x.count() != y.count()) break :blk false;
                var it = x.iterator();
                while (it.next()) |entry| {
                    const other = y.get(entry.key_ptr.*) orelse break :blk false;
                    if (!deepEqual(entry.value_ptr.*, other)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

fn numEqual(x: f64, b: Value) bool {
    return switch (b) {
        .integer => |i| x == @as(f64, @floatFromInt(i)),
        .float => |f| x == f,
        .string => |s| if (digitsToNumber(s)) |n| x == n else false,
        .number_string => |s| if (digitsToNumber(s)) |n| x == n else false,
        else => false,
    };
}

/// `s` coerces to a number only when every byte is an ASCII digit --
/// deliberately narrower than JsonLogic's own spec-mandated coercion
/// (which also accepts leading/trailing whitespace, a sign, a decimal
/// point, and treats `""` as `0`). A digit-only string has one obvious
/// numeric reading; anything looser imports the spec's own well-known
/// coercion quirks for a case nothing here has needed yet.
fn digitsToNumber(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn evalIn(args: []const Value, data: Value) Error!Value {
    if (args.len < 2) return Error.InvalidArguments;
    const needle = try evaluate(args[0], data);
    const haystack = try evaluate(args[1], data);
    switch (haystack) {
        .array => |items| {
            for (items.items) |item| if (deepEqual(needle, item)) return .{ .bool = true };
            return .{ .bool = false };
        },
        .string => |hs| {
            const n = switch (needle) {
                .string => |s| s,
                else => return .{ .bool = false },
            };
            return .{ .bool = std.mem.indexOf(u8, hs, n) != null };
        },
        else => return .{ .bool = false },
    }
}

const CompareOp = enum { lt, le, gt, ge };

fn evalCompare(args: []const Value, data: Value, op: CompareOp) Error!Value {
    if (args.len < 2) return Error.InvalidArguments;
    const a = try evaluate(args[0], data);
    const b = try evaluate(args[1], data);

    // Checked before numeric coercion: two plain strings compare
    // lexicographically even when both happen to be digit-only ("9" < "10"
    // stays false) -- coercion is only for a genuinely mixed pair.
    if (a == .string and b == .string) return .{ .bool = compareOrder([]const u8, a.string, b.string, op) };
    if (asNumber(a)) |na| if (asNumber(b)) |nb| return .{ .bool = compareOrder(f64, na, nb, op) };
    return .{ .bool = false };
}

fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .string => |s| digitsToNumber(s),
        .number_string => |s| digitsToNumber(s),
        else => null,
    };
}

fn compareOrder(comptime T: type, a: T, b: T, op: CompareOp) bool {
    const order = if (T == f64)
        std.math.order(a, b)
    else
        std.mem.order(u8, a, b);
    return switch (op) {
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
    };
}

const PatternKind = enum { glob, regexp };

fn evalPatternMatch(args: []const Value, data: Value, kind: PatternKind) Error!Value {
    if (args.len < 2) return Error.InvalidArguments;
    const pattern_v = try evaluate(args[0], data);
    const value_v = try evaluate(args[1], data);
    const pattern = switch (pattern_v) {
        .string => |s| s,
        else => return .{ .bool = false },
    };
    const value = switch (value_v) {
        .string => |s| s,
        else => return .{ .bool = false },
    };
    return .{ .bool = switch (kind) {
        .glob => globMatch(pattern, value),
        .regexp => regex_lite.isMatch(pattern, value),
    } };
}

/// `*` matches any run of characters, slashes included -- matching how this
/// vault's own `search_query` calls use it (`"designs/*"` matching
/// `"designs/synapse/sb-001.md"`, a path two segments deeper), not
/// shell-style single-segment globbing.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    // Without this, `lastNonEmptySegment("")` resolves to `""`, and
    // `endsWith(text, "")` is true for any `text` -- an empty pattern
    // matched every string. An empty pattern matches only empty text, same
    // as a literal-string comparison would.
    if (pattern.len == 0) return text.len == 0;
    var p_it = std.mem.splitScalar(u8, pattern, '*');
    var pos: usize = 0;
    var first = true;
    const last_was_star = pattern.len != 0 and pattern[pattern.len - 1] == '*';

    while (p_it.next()) |segment| {
        if (segment.len == 0) {
            first = false;
            continue;
        }
        if (first) {
            if (!std.mem.startsWith(u8, text, segment)) return false;
            pos = segment.len;
            first = false;
            continue;
        }
        const found = std.mem.indexOfPos(u8, text, pos, segment) orelse return false;
        pos = found + segment.len;
    }
    if (!last_was_star and pos != text.len) {
        // No trailing '*': the final literal segment must reach the end.
        return std.mem.endsWith(u8, text, lastNonEmptySegment(pattern));
    }
    return true;
}

fn lastNonEmptySegment(pattern: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, pattern, '*');
    var last: []const u8 = "";
    while (it.next()) |s| {
        if (s.len != 0) last = s;
    }
    return last;
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

fn parse(gpa: Allocator, text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, text, .{});
}

test "a literal value evaluates to itself" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "42");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expectEqual(@as(i64, 42), got.integer);
}

test "var looks up a dotted path in the data" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"var\": \"frontmatter.status\"}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"frontmatter\": {\"status\": \"TODO\"}}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expectEqualStrings("TODO", got.string);
}

test "var with a missing path and a default returns the default" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"var\": [\"frontmatter.missing\", \"fallback\"]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"frontmatter\": {}}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expectEqualStrings("fallback", got.string);
}

test "var with a missing path and no default returns null" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"var\": \"nope\"}");
    defer rule.deinit();
    var data = try parse(gpa, "{}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expectEqual(Value.null, got);
}

test "== compares two evaluated values" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"==\": [{\"var\": \"status\"}, \"REVIEW\"]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"status\": \"REVIEW\"}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(got.bool);
}

test "!= is the negation of ==" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"!=\": [1, 2]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expect(got.bool);
}

test "and short-circuits on the first falsy value" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"and\": [true, false, true]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expect(!got.bool);
}

test "and returns the last value when every operand is truthy" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"and\": [1, 2, 3]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expectEqual(@as(i64, 3), got.integer);
}

test "or returns the first truthy value" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"or\": [false, 0, \"found\", \"unreached\"]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expectEqualStrings("found", got.string);
}

test "! negates truthiness, bare-value form" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"!\": true}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expect(!got.bool);
}

test "in checks array membership" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"in\": [{\"var\": \"status\"}, [\"TODO\", \"IN-PROGRESS\"]]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"status\": \"IN-PROGRESS\"}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(got.bool);
}

test "in checks substring containment on a string haystack" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"in\": [\"log\", \"catalog\"]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expect(got.bool);
}

test "numeric comparisons" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"<\": [1, 2]}");
    defer rule.deinit();
    const got = try evaluate(rule.value, .null);
    try testing.expect(got.bool);

    var rule2 = try parse(gpa, "{\">=\": [2, 2]}");
    defer rule2.deinit();
    const got2 = try evaluate(rule2.value, .null);
    try testing.expect(got2.bool);
}

test "a digit-only string coerces to a number against a real number, both for compare and equality" {
    const gpa = testing.allocator;
    var lt = try parse(gpa, "{\"<\": [1, \"2\"]}");
    defer lt.deinit();
    try testing.expect((try evaluate(lt.value, .null)).bool);

    var eq = try parse(gpa, "{\"==\": [1, \"1\"]}");
    defer eq.deinit();
    try testing.expect((try evaluate(eq.value, .null)).bool);
}

test "a non-digit-only string never coerces, even one that starts with digits" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"<\": [1, \"2px\"]}");
    defer rule.deinit();
    try testing.expect(!(try evaluate(rule.value, .null)).bool);
}

test "two digit-only strings still compare lexicographically, not numerically" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"<\": [\"9\", \"10\"]}");
    defer rule.deinit();
    // Lexicographic: "9" > "10" (byte '9' > byte '1'), so "9" < "10" is false.
    try testing.expect(!(try evaluate(rule.value, .null)).bool);
}

test "glob matches a wildcard pattern against a path" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"glob\": [\"designs/*\", {\"var\": \"path\"}]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"path\": \"designs/synapse/sb-001.md\"}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(got.bool);
}

test "an empty glob pattern matches only empty text, not everything" {
    try testing.expect(!globMatch("", "anything"));
    try testing.expect(globMatch("", ""));
}

test "glob rejects a path outside the pattern's prefix" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"glob\": [\"designs/*\", {\"var\": \"path\"}]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"path\": \"tasks/synapse/sb-001.md\"}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(!got.bool);
}

test "regexp matches a literal substring in the content field" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"regexp\": [\"## Status\\nReady\", {\"var\": \"content\"}]}");
    defer rule.deinit();
    var data = try parse(gpa, "{\"content\": \"# Title\\n\\n## Status\\nReady\\n\"}");
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(got.bool);
}

test "a full and/glob/regexp compound rule, matching the vault's own real synapse-status shape" {
    const gpa = testing.allocator;
    var rule = try parse(gpa,
        \\{"and": [
        \\  {"glob": ["designs/*", {"var": "path"}]},
        \\  {"regexp": ["## Status\nDiscussing", {"var": "content"}]}
        \\]}
    );
    defer rule.deinit();
    var data = try parse(gpa,
        \\{"path": "designs/synapse/sb-001.md", "content": "# Title\n\n## Status\nDiscussing\n"}
    );
    defer data.deinit();
    const got = try evaluate(rule.value, data.value);
    try testing.expect(got.bool);
}

test "an unknown operator key errors rather than silently matching or not" {
    const gpa = testing.allocator;
    var rule = try parse(gpa, "{\"whatever\": [1, 2]}");
    defer rule.deinit();
    try testing.expectError(Error.UnknownOperator, evaluate(rule.value, .null));
}

test "truthy: JsonLogic's own falsy set -- false, 0, empty string, null, empty array" {
    try testing.expect(!truthy(.{ .bool = false }));
    try testing.expect(!truthy(.{ .integer = 0 }));
    try testing.expect(!truthy(.{ .string = "" }));
    try testing.expect(!truthy(.null));
    const gpa = testing.allocator;
    var empty_arr = try parse(gpa, "[]");
    defer empty_arr.deinit();
    try testing.expect(!truthy(empty_arr.value));

    try testing.expect(truthy(.{ .integer = 1 }));
    try testing.expect(truthy(.{ .string = "x" }));
    var empty_obj = try parse(gpa, "{}");
    defer empty_obj.deinit();
    try testing.expect(truthy(empty_obj.value)); // an empty object is truthy, unlike an empty array
}
