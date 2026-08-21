//! The tags-cache payload codec: `[]model.Tag` in, the bytes `Entry.tags`
//! actually stores, and back out again -- no truncation, no rendering.
//!
//! Before this codec existed, an entry's payload was `renderCliLine`'s
//! `tree-sitter tags`-CLI-mimicking display text (padded name, ` | kind`,
//! backtick-quoted, `expression` capped to 180 chars): a rendering decision
//! baked into storage. Every reader but `_refs.tsv` (via `writeRefsRow`,
//! which never touches column/end-position data) then had to parse that
//! text back into a `Tag` to get anything out of it -- and the truncation
//! was permanent, since nothing about the cache's own `Header.version`
//! tracked the text shape inside a payload, only the record table around it.
//!
//! Here a `Tag` is stored as itself: a small length-prefixed record, one
//! after another, no framing between them beyond their own lengths -- the
//! record table already knows each entry's total payload length
//! (`Record.tags_len`), so a decoder just reads records until the bytes run
//! out. A `Span`'s column/end-position fields never come along for the ride:
//! nothing downstream of the cache has ever read them (`model.Tag.line` is
//! the row `_refs.tsv` and every other consumer needs), so there is nothing
//! to lose by not storing what only a *rendering* wanted.

const std = @import("std");
const model = @import("model");

const Allocator = std.mem.Allocator;
const Tag = model.Tag;
const Role = model.Role;

/// One `Tag`, length-prefixed: role (1 byte), line (4), name (2 + bytes),
/// kind (2 + bytes), expression (4 + bytes). Names/kinds are short
/// identifiers -- a `u16` length is generous; `expression` is a whole
/// source line, so `u32`, matching `Record.tags_len`'s own width, to leave
/// no cap smaller than what a real source line could be.
///
/// Public so a caller already holding `[]Tagged` (`tag` plus a `Span` this
/// codec never stores) can encode `t.tag` field by field, one call per hit,
/// without building a throwaway `[]Tag` copy first just to call `encode`.
pub fn encodeOne(w: *std.Io.Writer, tag: Tag) !void {
    try w.writeByte(@intFromEnum(tag.role));
    try w.writeInt(u32, tag.line, .little);
    try w.writeInt(u16, @intCast(tag.name.len), .little);
    try w.writeAll(tag.name);
    try w.writeInt(u16, @intCast(tag.kind.len), .little);
    try w.writeAll(tag.kind);
    try w.writeInt(u32, @intCast(tag.expression.len), .little);
    try w.writeAll(tag.expression);
}

/// Every tag in `tags`, concatenated. Zero tags encodes to zero bytes,
/// matching `Entry.tags = ""`'s existing meaning: parsed, declared nothing.
pub fn encode(gpa: Allocator, tags: []const Tag) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (tags) |t| try encodeOne(&out.writer, t);
    return out.toOwnedSlice();
}

/// Decodes `bytes` (an `Entry.tags` payload) one `Tag` at a time. Every
/// slice a `Tag` carries borrows `bytes` directly -- no allocation, same as
/// reading straight out of the cache's memory map.
pub const Iterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    /// Null once every record has been read, or as soon as one is malformed
    /// (a length running past the end of `bytes`) -- a corrupt payload stops
    /// silently rather than reading garbage as the next record's framing.
    pub fn next(self: *Iterator) ?Tag {
        if (self.pos >= self.bytes.len) return null;
        var r: std.Io.Reader = .fixed(self.bytes[self.pos..]);

        const role_byte = r.takeByte() catch return null;
        const role: Role = switch (role_byte) {
            0 => .def,
            1 => .ref,
            else => return null,
        };
        const line = r.takeInt(u32, .little) catch return null;
        const name_len = r.takeInt(u16, .little) catch return null;
        const name = r.take(name_len) catch return null;
        const kind_len = r.takeInt(u16, .little) catch return null;
        const kind = r.take(kind_len) catch return null;
        const expr_len = r.takeInt(u32, .little) catch return null;
        const expr = r.take(expr_len) catch return null;

        self.pos += r.seek;
        return .{ .name = name, .role = role, .kind = kind, .line = line, .expression = expr };
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes };
}

const testing = std.testing;

fn collect(gpa: Allocator, bytes: []const u8) ![]Tag {
    var out: std.ArrayListUnmanaged(Tag) = .empty;
    errdefer out.deinit(gpa);
    var it = iterate(bytes);
    while (it.next()) |t| try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

test "round trip: one tag, every field intact" {
    const gpa = testing.allocator;
    const tag: Tag = .{ .name = "Token", .role = .def, .kind = "class", .line = 15, .expression = "public class Token {" };
    const bytes = try encode(gpa, &.{tag});
    defer gpa.free(bytes);

    const got = try collect(gpa, bytes);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("Token", got[0].name);
    try testing.expectEqual(Role.def, got[0].role);
    try testing.expectEqualStrings("class", got[0].kind);
    try testing.expectEqual(@as(u32, 15), got[0].line);
    try testing.expectEqualStrings("public class Token {", got[0].expression);
}

test "round trip: several tags, in order" {
    const gpa = testing.allocator;
    const tags = [_]Tag{
        .{ .name = "Ay", .role = .def, .kind = "class", .line = 0, .expression = "public class Ay {" },
        .{ .name = "call", .role = .ref, .kind = "call", .line = 3, .expression = "call();" },
    };
    const bytes = try encode(gpa, &tags);
    defer gpa.free(bytes);

    const got = try collect(gpa, bytes);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("Ay", got[0].name);
    try testing.expectEqualStrings("call", got[1].name);
    try testing.expectEqual(Role.ref, got[1].role);
}

test "an expression past the old 180-char CLI-display cap survives whole" {
    const gpa = testing.allocator;
    const long_expr = "x" ** 400;
    const tag: Tag = .{ .name = "n", .role = .ref, .kind = "call", .line = 1, .expression = long_expr };
    const bytes = try encode(gpa, &.{tag});
    defer gpa.free(bytes);

    const got = try collect(gpa, bytes);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 400), got[0].expression.len);
    try testing.expectEqualStrings(long_expr, got[0].expression);
}

test "zero tags encodes to zero bytes, and decodes to nothing" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{});
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);

    var it = iterate(bytes);
    try testing.expectEqual(@as(?Tag, null), it.next());
}

test "a name or kind containing a tab, newline, or backtick round-trips exactly" {
    // The whole point: the old text format's own delimiters (tab-separated
    // fields, backtick-quoted expression) could not have held these bytes
    // at all. A length-prefixed record does not care what the bytes are.
    const gpa = testing.allocator;
    const tag: Tag = .{
        .name = "weird\tname",
        .role = .def,
        .kind = "kind\nwith\nnewlines",
        .line = 7,
        .expression = "has `backticks` and \t tabs\nand newlines",
    };
    const bytes = try encode(gpa, &.{tag});
    defer gpa.free(bytes);

    const got = try collect(gpa, bytes);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("weird\tname", got[0].name);
    try testing.expectEqualStrings("kind\nwith\nnewlines", got[0].kind);
    try testing.expectEqualStrings("has `backticks` and \t tabs\nand newlines", got[0].expression);
}

test "a truncated payload decodes as far as it can, then stops rather than reading garbage" {
    const gpa = testing.allocator;
    const tags = [_]Tag{
        .{ .name = "First", .role = .def, .kind = "class", .line = 1, .expression = "e" },
        .{ .name = "Second", .role = .ref, .kind = "call", .line = 2, .expression = "f" },
    };
    const bytes = try encode(gpa, &tags);
    defer gpa.free(bytes);

    // Cut off partway through the second record's framing.
    const first_len = blk: {
        var it = iterate(bytes);
        _ = it.next();
        break :blk it.pos;
    };
    const truncated = bytes[0 .. first_len + 3];

    const got = try collect(gpa, truncated);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("First", got[0].name);
}

test "encode/decode round trip never crashes on arbitrary field bytes" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const gpa = testing.allocator;
            const name_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 30, 0));
            var name_buf: [30]u8 = undefined;
            smith.bytesWithHash(name_buf[0..name_len], 1);

            const kind_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 30, 2));
            var kind_buf: [30]u8 = undefined;
            smith.bytesWithHash(kind_buf[0..kind_len], 3);

            const expr_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 200, 4));
            var expr_buf: [200]u8 = undefined;
            smith.bytesWithHash(expr_buf[0..expr_len], 5);

            const tag: Tag = .{
                .name = name_buf[0..name_len],
                .role = if (smith.valueWithHash(bool, 6)) .def else .ref,
                .kind = kind_buf[0..kind_len],
                .line = smith.valueWithHash(u32, 7),
                .expression = expr_buf[0..expr_len],
            };

            const bytes = try encode(gpa, &.{tag});
            defer gpa.free(bytes);
            const got = try collect(gpa, bytes);
            defer gpa.free(got);
            try testing.expectEqual(@as(usize, 1), got.len);
            try testing.expectEqualStrings(tag.name, got[0].name);
            try testing.expectEqual(tag.role, got[0].role);
            try testing.expectEqualStrings(tag.kind, got[0].kind);
            try testing.expectEqual(tag.line, got[0].line);
            try testing.expectEqualStrings(tag.expression, got[0].expression);
        }
    }.testOne, .{});
}
