//! Strict YAML subset for versioned Vault note schema documents.
//!
//! This is intentionally not a general YAML reader. It accepts the shapes
//! the schema DSL needs (mappings, lists, strings, decimal integers,
//! booleans, and comments) and refuses the features that make YAML parsing
//! surprising or stateful: anchors/aliases, tags, block scalars, flow maps,
//! multiple documents, tabs, and implicit scalar types.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    key: []const u8,
    value: *Value,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    list: []const *Value,
    map: []const Entry,

    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        return switch (self.*) {
            .map => |entries| for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) break entry.value;
            } else null,
            else => null,
        };
    }

    pub fn asString(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asBool(self: *const Value) ?bool {
        return switch (self.*) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asInteger(self: *const Value) ?i64 {
        return switch (self.*) {
            .integer => |n| n,
            else => null,
        };
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    EmptyDocument,
    TabIndent,
    InvalidIndent,
    UnexpectedIndent,
    MixedCollection,
    MalformedMapping,
    DuplicateKey,
    EmptyValue,
    AnchorOrAlias,
    CustomTag,
    BlockScalar,
    FlowMap,
    MultipleDocuments,
    ImplicitType,
    UnterminatedString,
    InvalidEscape,
    InvalidInteger,
    InvalidFlowList,
} || Allocator.Error;

const SourceLine = struct {
    indent: usize,
    text: []const u8,
    number: usize,
};

const Parser = struct {
    allocator: Allocator,
    lines: []const SourceLine,
    index: usize = 0,

    fn value(self: *Parser, v: Value) Error!*Value {
        const out = try self.allocator.create(Value);
        out.* = v;
        return out;
    }

    fn parseBlock(self: *Parser, indent: usize) Error!*Value {
        if (self.index >= self.lines.len) return error.EmptyValue;
        if (self.lines[self.index].indent != indent) return error.UnexpectedIndent;
        return if (isListLine(self.lines[self.index].text))
            self.parseList(indent)
        else
            self.parseMap(indent);
    }

    fn parseMap(self: *Parser, indent: usize) Error!*Value {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.UnexpectedIndent;
            if (isListLine(line.text)) return error.MixedCollection;
            self.index += 1;
            const pair = try splitPair(line.text);
            if (findEntry(entries.items, pair.key) != null) return error.DuplicateKey;
            const child = if (pair.raw_value.len == 0) blk: {
                if (self.index >= self.lines.len or self.lines[self.index].indent <= indent)
                    return error.EmptyValue;
                break :blk try self.parseBlock(self.lines[self.index].indent);
            } else try self.parseScalar(pair.raw_value);
            try entries.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, pair.key),
                .value = child,
            });
        }
        return self.value(.{ .map = try entries.toOwnedSlice(self.allocator) });
    }

    fn parseList(self: *Parser, indent: usize) Error!*Value {
        var values: std.ArrayListUnmanaged(*Value) = .empty;
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.UnexpectedIndent;
            if (!isListLine(line.text)) return error.MixedCollection;
            self.index += 1;

            const rest = std.mem.trim(u8, line.text[1..], " ");
            if (rest.len == 0) return error.EmptyValue;
            if (splitPair(rest)) |first| {
                var entries: std.ArrayListUnmanaged(Entry) = .empty;
                const first_value = if (first.raw_value.len == 0) blk: {
                    if (self.index >= self.lines.len or self.lines[self.index].indent <= indent)
                        return error.EmptyValue;
                    break :blk try self.parseBlock(self.lines[self.index].indent);
                } else try self.parseScalar(first.raw_value);
                try entries.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, first.key),
                    .value = first_value,
                });

                // Remaining fields of this list item's mapping are indented
                // two columns beyond the dash itself.
                if (self.index < self.lines.len and self.lines[self.index].indent == indent + 2 and
                    !isListLine(self.lines[self.index].text))
                {
                    const remainder = try self.parseMap(indent + 2);
                    for (remainder.map) |entry| {
                        if (findEntry(entries.items, entry.key) != null) return error.DuplicateKey;
                        try entries.append(self.allocator, entry);
                    }
                }
                try values.append(self.allocator, try self.value(.{
                    .map = try entries.toOwnedSlice(self.allocator),
                }));
            } else |_| {
                try values.append(self.allocator, try self.parseScalar(rest));
            }
        }
        return self.value(.{ .list = try values.toOwnedSlice(self.allocator) });
    }

    fn parseScalar(self: *Parser, raw: []const u8) Error!*Value {
        const text = std.mem.trim(u8, raw, " ");
        if (text.len == 0) return error.EmptyValue;
        if (text[0] == '&' or text[0] == '*') return error.AnchorOrAlias;
        if (text[0] == '!') return error.CustomTag;
        if (text[0] == '|' or text[0] == '>') return error.BlockScalar;
        if (text[0] == '{') return error.FlowMap;
        if (text[0] == '[') return self.parseFlowList(text);
        if (text[0] == '\'' or text[0] == '"')
            return self.value(.{ .string = try parseQuoted(self.allocator, text) });
        if (std.mem.indexOfScalar(u8, text, '&') != null or std.mem.indexOfScalar(u8, text, '*') != null)
            return error.AnchorOrAlias;
        if (std.mem.eql(u8, text, "true")) return self.value(.{ .boolean = true });
        if (std.mem.eql(u8, text, "false")) return self.value(.{ .boolean = false });
        if (isAmbiguousImplicit(text)) return error.ImplicitType;
        if (looksNumeric(text)) {
            if (text.len > 1 and (text[0] == '0' or (text[0] == '-' and text.len > 2 and text[1] == '0')))
                return error.ImplicitType;
            const n = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger;
            return self.value(.{ .integer = n });
        }
        return self.value(.{ .string = try self.allocator.dupe(u8, text) });
    }

    fn parseFlowList(self: *Parser, text: []const u8) Error!*Value {
        if (text.len < 2 or text[text.len - 1] != ']') return error.InvalidFlowList;
        const inner = std.mem.trim(u8, text[1 .. text.len - 1], " ");
        var values: std.ArrayListUnmanaged(*Value) = .empty;
        if (inner.len != 0) {
            var start: usize = 0;
            var quote: ?u8 = null;
            var escaped = false;
            var i: usize = 0;
            while (i <= inner.len) : (i += 1) {
                if (i == inner.len or (quote == null and inner[i] == ',')) {
                    const item = std.mem.trim(u8, inner[start..i], " ");
                    if (item.len == 0) return error.InvalidFlowList;
                    try values.append(self.allocator, try self.parseScalar(item));
                    start = i + 1;
                    continue;
                }
                const c = inner[i];
                if (quote) |q| {
                    if (q == '"' and !escaped and c == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (!escaped and c == q) quote = null;
                    escaped = false;
                } else if (c == '\'' or c == '"') {
                    quote = c;
                } else if (c == '[' or c == ']' or c == '{' or c == '}') {
                    return error.InvalidFlowList;
                }
            }
            if (quote != null) return error.UnterminatedString;
        }
        return self.value(.{ .list = try values.toOwnedSlice(self.allocator) });
    }
};

const Pair = struct {
    key: []const u8,
    raw_value: []const u8,
};

pub fn parse(gpa: Allocator, source: []const u8) Error!Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var lines: std.ArrayListUnmanaged(SourceLine) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (it.next()) |raw_with_cr| {
        number += 1;
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        if (std.mem.indexOfScalar(u8, raw, '\t') != null) return error.TabIndent;
        const without_comment = stripComment(raw);
        const trimmed_end = std.mem.trimEnd(u8, without_comment, " ");
        if (std.mem.trim(u8, trimmed_end, " ").len == 0) continue;
        const trimmed = std.mem.trim(u8, trimmed_end, " ");
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "..."))
            return error.MultipleDocuments;
        const indent = trimmed_end.len - std.mem.trimStart(u8, trimmed_end, " ").len;
        if (indent % 2 != 0) return error.InvalidIndent;
        try lines.append(allocator, .{
            .indent = indent,
            .text = try allocator.dupe(u8, trimmed_end[indent..]),
            .number = number,
        });
    }
    if (lines.items.len == 0) return error.EmptyDocument;
    if (lines.items[0].indent != 0) return error.UnexpectedIndent;

    var parser: Parser = .{ .allocator = allocator, .lines = lines.items };
    const root = try parser.parseBlock(0);
    if (parser.index != parser.lines.len) return error.UnexpectedIndent;
    return .{ .arena = arena, .root = root };
}

fn splitPair(text: []const u8) Error!Pair {
    var quote: ?u8 = null;
    var escaped = false;
    var bracket_depth: usize = 0;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (q == '"' and !escaped and c == '\\') {
                escaped = true;
                continue;
            }
            if (!escaped and c == q) quote = null;
            escaped = false;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '[') bracket_depth += 1;
        if (c == ']') {
            if (bracket_depth == 0) return error.InvalidFlowList;
            bracket_depth -= 1;
        }
        if (c != ':' or bracket_depth != 0) continue;
        const key = std.mem.trim(u8, text[0..i], " ");
        if (!validKey(key)) return error.MalformedMapping;
        return .{ .key = key, .raw_value = std.mem.trim(u8, text[i + 1 ..], " ") };
    }
    return error.MalformedMapping;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or (!std.ascii.isAlphabetic(key[0]) and key[0] != '_')) return false;
    for (key[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

fn isListLine(text: []const u8) bool {
    return text.len != 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

fn findEntry(entries: []const Entry, key: []const u8) ?usize {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, entry.key, key)) return i;
    return null;
}

fn stripComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (quote) |q| {
            if (q == '"' and !escaped and c == '\\') {
                escaped = true;
                continue;
            }
            if (!escaped and c == q) quote = null;
            escaped = false;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '#' and (i == 0 or std.ascii.isWhitespace(line[i - 1]))) {
            return line[0..i];
        }
    }
    return line;
}

fn parseQuoted(allocator: Allocator, text: []const u8) Error![]const u8 {
    const quote = text[0];
    if (text.len < 2 or text[text.len - 1] != quote) return error.UnterminatedString;
    const inner = text[1 .. text.len - 1];
    if (quote == '\'') {
        if (std.mem.indexOfScalar(u8, inner, '\'') != null) return error.InvalidEscape;
        return allocator.dupe(u8, inner);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\') {
            try out.append(allocator, inner[i]);
            continue;
        }
        i += 1;
        if (i >= inner.len) return error.InvalidEscape;
        const c: u8 = switch (inner[i]) {
            '\\', '"', '/' => inner[i],
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidEscape,
        };
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn isAmbiguousImplicit(text: []const u8) bool {
    const values = [_][]const u8{
        "null", "Null", "NULL", "~",   "yes", "Yes", "YES",  "no",   "No",   "NO",
        "on",   "On",   "ON",   "off", "Off", "OFF", ".inf", ".Inf", ".INF", ".nan",
        ".NaN", ".NAN",
    };
    for (values) |v| if (std.mem.eql(u8, text, v)) return true;
    return false;
}

fn looksNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = if (text[0] == '-') 1 else 0;
    if (i == text.len) return false;
    while (i < text.len) : (i += 1) if (!std.ascii.isDigit(text[i])) return false;
    return true;
}

const testing = std.testing;

test "parses the schema DSL's maps, list objects, flow lists, comments, scalars" {
    const source =
        "schema: synapse-note-schema/v1\n" ++
        "id: vault-note/v1\n" ++
        "frontmatter:\n" ++
        "  fields:\n" ++
        "    title:\n" ++
        "      type: string\n" ++
        "      required: true\n" ++
        "body:\n" ++
        "  sections:\n" ++
        "    - title: Summary\n" ++
        "      level: 2\n" ++
        "checks:\n" ++
        "  - equals: [filename.stem, frontmatter.title] # same title\n";
    var doc = try parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqualStrings("synapse-note-schema/v1", doc.root.get("schema").?.asString().?);
    const sections = doc.root.get("body").?.get("sections").?.list;
    try testing.expectEqualStrings("Summary", sections[0].get("title").?.asString().?);
    try testing.expectEqual(@as(i64, 2), sections[0].get("level").?.asInteger().?);
}

test "refuses YAML features outside the schema subset" {
    try testing.expectError(error.AnchorOrAlias, parse(testing.allocator, "x: &anchor value\n"));
    try testing.expectError(error.CustomTag, parse(testing.allocator, "x: !thing value\n"));
    try testing.expectError(error.BlockScalar, parse(testing.allocator, "x: |\n  value: here\n"));
    try testing.expectError(error.FlowMap, parse(testing.allocator, "x: {a: b}\n"));
    try testing.expectError(error.MultipleDocuments, parse(testing.allocator, "x: y\n---\nz: q\n"));
    try testing.expectError(error.ImplicitType, parse(testing.allocator, "x: yes\n"));
    try testing.expectError(error.TabIndent, parse(testing.allocator, "x:\n\ty: z\n"));
}

test "duplicate keys fail closed" {
    try testing.expectError(error.DuplicateKey, parse(testing.allocator, "x: one\nx: two\n"));
}
