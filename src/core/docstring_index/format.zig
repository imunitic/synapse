//! The on-disk docstring index: bytes in, bytes out. No files, no paths, no `Io`.
//!
//! Inspired by `tags_cache/format.zig`'s layout, not identical to it: that
//! format keys one record per *file*; this one needs one record per
//! *docstring*, since a file can hold many. The key is
//! `(path, declaration name, declaration kind)` rather than path alone --
//! name+kind survives an edit elsewhere in the file without falsely
//! re-baselining an untouched docstring, at the cost of a genuine rename
//! looking like a brand-new entry (a trigger for a fresh look, not a
//! verdict -- see the design note this implements).
//!
//! ## Layout
//!
//! ```
//! 0                     header, 32 bytes
//! 32                    record table, entry_count * Record.wire_size bytes, sorted by (path, name, kind)
//! strings_off           string region: every record's path, name, and kind bytes, concatenated
//! ```
//!
//! Unlike the tags cache, there is no separate payload region: a record's
//! only real data is two fixed 32-byte hashes plus two fixed line ranges,
//! all of which fit directly in the row, so no out-of-line codec is
//! needed. The checksum therefore covers the whole file, not a
//! payload-excluding prefix.
//!
//! ## Line ranges
//!
//! Each record also stores the 1-based, inclusive line range the docstring
//! and the declaration each occupied when the pair was last derived --
//! `core.verify.slice`'s own convention. This is what lets Tier 1 (the
//! `synapse-hook` binary, which never links libtree-sitter and must not:
//! see the design note) re-hash "whatever is currently at this range" with
//! pure bytes -- `core.verify.slice` plus `sha256Raw`, the same trick
//! `grounded_in` staleness already uses -- without re-deriving pairs via a
//! real parse. Tier 2 (the `synapse` CLI, which does link treesitter) is
//! the only thing that ever calls `docstring_pairs.findPairs` and is
//! therefore the only place index entries, ranges included, get written.
//!
//! ## Hashes
//!
//! Both hashes are raw SHA-256 (`core.verify.sha256Raw`), not the tags
//! cache's git-blob SHA-1: a docstring and its enclosing declaration are
//! both *sub-ranges* of a file, the same shape a node's `grounded_in`
//! digest already covers, which the codebase already hashes with SHA-256,
//! not a git blob hash.
//!
//! ## Architecture independence
//!
//! Every multi-byte field is read/written one at a time with an explicit
//! `.little` -- no `@bitCast`, `packed struct`, or struct-typed `@ptrCast`.
//!
//! ## Versioning
//!
//! A header that doesn't match is discarded and rebuilt -- an index, so
//! nothing in it can't be recomputed from source.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic: [8]u8 = "SYNDOCS\x00".*;

pub const version: u32 = 1;

pub const Header = struct {
    version: u32,
    entry_count: u32,
    strings_off: u64,
    crc32: u32,

    /// 32, not the 24 the fields add to: four reserved bytes, written zero
    /// and unread, keep the record table 8-byte aligned.
    pub const wire_size = 32;

    fn write(self: Header, out: *[wire_size]u8) void {
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.version, .little);
        std.mem.writeInt(u32, out[12..16], self.entry_count, .little);
        std.mem.writeInt(u64, out[16..24], self.strings_off, .little);
        std.mem.writeInt(u32, out[24..28], self.crc32, .little);
        std.mem.writeInt(u32, out[28..32], 0, .little);
    }

    fn read(in: *const [wire_size]u8) Header {
        return .{
            .version = std.mem.readInt(u32, in[8..12], .little),
            .entry_count = std.mem.readInt(u32, in[12..16], .little),
            .strings_off = std.mem.readInt(u64, in[16..24], .little),
            .crc32 = std.mem.readInt(u32, in[24..28], .little),
        };
    }
};

/// One tracked docstring/declaration pair. Fixed width so the table is
/// indexable, sorted by `(path, name, kind)` bytes so it is searchable, and
/// so every entry for one file is a contiguous range.
pub const Record = struct {
    /// Into the string region, not the file.
    path_off: u64,
    path_len: u16,
    name_off: u64,
    name_len: u16,
    kind_off: u64,
    kind_len: u8,
    /// Raw 32-byte SHA-256 of the docstring's own comment text.
    docstring_hash: [32]u8,
    /// Raw 32-byte SHA-256 of the enclosing declaration's body.
    decl_hash: [32]u8,
    /// 1-based, inclusive -- `core.verify.slice`'s own convention -- as of
    /// the last time this pair was derived. Lets Tier 1 re-hash "whatever
    /// is here now" without re-parsing; see the module doc comment.
    docstring_start_line: u32,
    docstring_end_line: u32,
    decl_start_line: u32,
    decl_end_line: u32,

    pub const wire_size = 8 + 2 + 8 + 2 + 8 + 1 + 32 + 32 + 4 + 4 + 4 + 4;

    fn write(self: Record, out: *[wire_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.path_off, .little);
        std.mem.writeInt(u16, out[8..10], self.path_len, .little);
        std.mem.writeInt(u64, out[10..18], self.name_off, .little);
        std.mem.writeInt(u16, out[18..20], self.name_len, .little);
        std.mem.writeInt(u64, out[20..28], self.kind_off, .little);
        out[28] = self.kind_len;
        @memcpy(out[29..61], &self.docstring_hash);
        @memcpy(out[61..93], &self.decl_hash);
        std.mem.writeInt(u32, out[93..97], self.docstring_start_line, .little);
        std.mem.writeInt(u32, out[97..101], self.docstring_end_line, .little);
        std.mem.writeInt(u32, out[101..105], self.decl_start_line, .little);
        std.mem.writeInt(u32, out[105..109], self.decl_end_line, .little);
    }

    fn read(in: *const [wire_size]u8) Record {
        return .{
            .path_off = std.mem.readInt(u64, in[0..8], .little),
            .path_len = std.mem.readInt(u16, in[8..10], .little),
            .name_off = std.mem.readInt(u64, in[10..18], .little),
            .name_len = std.mem.readInt(u16, in[18..20], .little),
            .kind_off = std.mem.readInt(u64, in[20..28], .little),
            .kind_len = in[28],
            .docstring_hash = in[29..61].*,
            .decl_hash = in[61..93].*,
            .docstring_start_line = std.mem.readInt(u32, in[93..97], .little),
            .docstring_end_line = std.mem.readInt(u32, in[97..101], .little),
            .decl_start_line = std.mem.readInt(u32, in[101..105], .little),
            .decl_end_line = std.mem.readInt(u32, in[105..109], .little),
        };
    }
};

/// What `encode` takes: a whole entry, key fields included. The reader's
/// equivalent has no key, because you found it by one.
pub const Entry = struct {
    path: []const u8,
    name: []const u8,
    kind: []const u8,
    docstring_hash: [32]u8,
    decl_hash: [32]u8,
    docstring_start_line: u32,
    docstring_end_line: u32,
    decl_start_line: u32,
    decl_end_line: u32,
};

pub const EncodeError = error{
    /// Unsorted input would encode fine and make every binary search wrong.
    Unsorted,
    PathTooLong,
    NameTooLong,
    KindTooLong,
    TooManyEntries,
} || Allocator.Error;

pub const ParseError = error{
    NotACache,
    VersionMismatch,
    Truncated,
    ChecksumMismatch,
    OffsetOutOfRange,
};

/// Compares two entries' sort key: path, then name, then kind, all byte
/// order. This is the format's own promise `find`/`pathRange` rest on.
fn order(a_path: []const u8, a_name: []const u8, a_kind: []const u8, b_path: []const u8, b_name: []const u8, b_kind: []const u8) std.math.Order {
    const path_order = std.mem.order(u8, a_path, b_path);
    if (path_order != .eq) return path_order;
    const name_order = std.mem.order(u8, a_name, b_name);
    if (name_order != .eq) return name_order;
    return std.mem.order(u8, a_kind, b_kind);
}

/// The whole file as one buffer. This index has no large payload region
/// the way the tags cache does, so unlike that format there is no reason
/// to stream -- a repository's total docstring count is a small multiple
/// of its declaration count, not its file count.
pub fn encode(gpa: Allocator, entries: []const Entry) EncodeError![]u8 {
    if (entries.len > std.math.maxInt(u32)) return error.TooManyEntries;

    var strings_len: u64 = 0;
    for (entries, 0..) |e, i| {
        if (e.path.len > std.math.maxInt(u16)) return error.PathTooLong;
        if (e.name.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (e.kind.len > std.math.maxInt(u8)) return error.KindTooLong;
        if (i > 0) {
            const prev = entries[i - 1];
            if (order(prev.path, prev.name, prev.kind, e.path, e.name, e.kind) != .lt)
                return error.Unsorted;
        }
        strings_len += e.path.len + e.name.len + e.kind.len;
    }

    const table_len: u64 = @as(u64, entries.len) * Record.wire_size;
    const strings_off: u64 = Header.wire_size + table_len;
    const total: u64 = strings_off + strings_len;

    const out = try gpa.alloc(u8, @intCast(total));
    errdefer gpa.free(out);

    var str_at: u64 = 0;
    for (entries, 0..) |e, i| {
        const rec: Record = .{
            .path_off = str_at,
            .path_len = @intCast(e.path.len),
            .name_off = str_at + e.path.len,
            .name_len = @intCast(e.name.len),
            .kind_off = str_at + e.path.len + e.name.len,
            .kind_len = @intCast(e.kind.len),
            .docstring_hash = e.docstring_hash,
            .decl_hash = e.decl_hash,
            .docstring_start_line = e.docstring_start_line,
            .docstring_end_line = e.docstring_end_line,
            .decl_start_line = e.decl_start_line,
            .decl_end_line = e.decl_end_line,
        };
        const at = Header.wire_size + i * Record.wire_size;
        rec.write(out[at..][0..Record.wire_size]);

        const base: usize = @intCast(strings_off + str_at);
        @memcpy(out[base..][0..e.path.len], e.path);
        @memcpy(out[base + e.path.len ..][0..e.name.len], e.name);
        @memcpy(out[base + e.path.len + e.name.len ..][0..e.kind.len], e.kind);
        str_at += e.path.len + e.name.len + e.kind.len;
    }

    // The table and string region (out[Header.wire_size..]) is already
    // fully written above, so the checksum over it can be computed before
    // the header itself is written -- the header isn't part of what it
    // covers.
    const header: Header = .{
        .version = version,
        .entry_count = @intCast(entries.len),
        .strings_off = strings_off,
        .crc32 = std.hash.Crc32.hash(out[Header.wire_size..]),
    };
    header.write(out[0..Header.wire_size]);

    return out;
}

/// A validated file. Borrows the bytes (expected to be a mapping) --
/// nothing here copies or owns.
pub const View = struct {
    bytes: []const u8,
    header: Header,

    pub fn count(self: View) u32 {
        return self.header.entry_count;
    }

    pub fn record(self: View, i: u32) Record {
        const at = Header.wire_size + @as(usize, i) * Record.wire_size;
        return .read(self.bytes[at..][0..Record.wire_size]);
    }

    pub fn path(self: View, r: Record) []const u8 {
        const at: usize = @intCast(self.header.strings_off + r.path_off);
        return self.bytes[at..][0..r.path_len];
    }

    pub fn name(self: View, r: Record) []const u8 {
        const at: usize = @intCast(self.header.strings_off + r.name_off);
        return self.bytes[at..][0..r.name_len];
    }

    pub fn kind(self: View, r: Record) []const u8 {
        const at: usize = @intCast(self.header.strings_off + r.kind_off);
        return self.bytes[at..][0..r.kind_len];
    }

    /// Index of the exact `(path, name, kind)` triple, or null.
    pub fn find(self: View, wanted_path: []const u8, wanted_name: []const u8, wanted_kind: []const u8) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.record(mid);
            switch (order(self.path(r), self.name(r), self.kind(r), wanted_path, wanted_name, wanted_kind)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// `[start, end)` indices of every entry for `wanted_path` -- a
    /// contiguous range, since path is the primary sort key. Empty range
    /// (start == end) when the file has no tracked docstrings.
    pub fn pathRange(self: View, wanted_path: []const u8) struct { start: u32, end: u32 } {
        var lo: u32 = 0;
        var hi: u32 = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.path(self.record(mid)), wanted_path) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const start = lo;
        hi = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.path(self.record(mid)), wanted_path) == .gt) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return .{ .start = start, .end = lo };
    }
};

/// Validates `bytes`. Every offset a `View` accessor uses is checked here,
/// so accessors themselves need no bounds checks.
pub fn parse(bytes: []const u8) ParseError!View {
    if (bytes.len < Header.wire_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.NotACache;

    const header: Header = .read(bytes[0..Header.wire_size]);
    if (header.version != version) return error.VersionMismatch;

    const table_end: u64 = Header.wire_size + @as(u64, header.entry_count) * Record.wire_size;
    if (table_end > bytes.len) return error.Truncated;
    if (header.strings_off > bytes.len) return error.OffsetOutOfRange;
    if (header.strings_off < table_end) return error.OffsetOutOfRange;

    // crc32 lives inside the header (bytes 24..28), entirely before
    // wire_size (32) -- the hashed range starts after the header ends, so
    // it never includes the crc32 field itself. No self-reference to work
    // around.
    if (std.hash.Crc32.hash(bytes[Header.wire_size..]) != header.crc32)
        return error.ChecksumMismatch;

    const view: View = .{ .bytes = bytes, .header = header };
    var prev: ?Record = null;
    var i: u32 = 0;
    while (i < header.entry_count) : (i += 1) {
        const r = view.record(i);

        const path_end = std.math.add(u64, r.path_off, @as(u64, r.path_len)) catch return error.OffsetOutOfRange;
        const name_end = std.math.add(u64, r.name_off, @as(u64, r.name_len)) catch return error.OffsetOutOfRange;
        const kind_end = std.math.add(u64, r.kind_off, @as(u64, r.kind_len)) catch return error.OffsetOutOfRange;
        const strings_len = bytes.len - @as(usize, @intCast(header.strings_off));
        if (path_end > strings_len or name_end > strings_len or kind_end > strings_len)
            return error.OffsetOutOfRange;

        if (prev) |p| {
            if (order(view.path(p), view.name(p), view.kind(p), view.path(r), view.name(r), view.kind(r)) != .lt)
                return error.OffsetOutOfRange;
        }
        prev = r;
    }
    return view;
}

const testing = std.testing;

fn hash32(byte: u8) [32]u8 {
    return .{byte} ** 32;
}

test "one entry encodes to exactly the bytes this file documents" {
    // Written against the layout comment at the top, field by field -- not
    // by printing what the encoder produced, which could only ever agree
    // with itself.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{
        .path = "a.ml",
        .name = "foo",
        .kind = "fn",
        .docstring_hash = hash32(0x01),
        .decl_hash = hash32(0x02),
        .docstring_start_line = 1,
        .docstring_end_line = 2,
        .decl_start_line = 3,
        .decl_end_line = 5,
    }});
    defer gpa.free(bytes);

    // 32 header + 109 record + 4 path + 3 name + 2 kind
    try testing.expectEqual(@as(usize, 150), bytes.len);

    try testing.expectEqualSlices(u8, "SYNDOCS\x00", bytes[0..8]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[8..12]); // version 1
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[12..16]); // entry_count 1
    try testing.expectEqualSlices(u8, &.{ 141, 0, 0, 0, 0, 0, 0, 0 }, bytes[16..24]); // strings_off 32+109
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[28..32]); // reserved

    const rec = bytes[32..141];
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, rec[0..8]); // path_off
    try testing.expectEqualSlices(u8, &.{ 4, 0 }, rec[8..10]); // path_len
    try testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 0, 0, 0 }, rec[10..18]); // name_off
    try testing.expectEqualSlices(u8, &.{ 3, 0 }, rec[18..20]); // name_len
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0, 0, 0, 0 }, rec[20..28]); // kind_off
    try testing.expectEqual(@as(u8, 2), rec[28]); // kind_len
    try testing.expectEqualSlices(u8, &hash32(0x01), rec[29..61]);
    try testing.expectEqualSlices(u8, &hash32(0x02), rec[61..93]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, rec[93..97]); // docstring_start_line
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, rec[97..101]); // docstring_end_line
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, rec[101..105]); // decl_start_line
    try testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, rec[105..109]); // decl_end_line

    try testing.expectEqualStrings("a.ml", bytes[141..145]);
    try testing.expectEqualStrings("foo", bytes[145..148]);
    try testing.expectEqualStrings("fn", bytes[148..150]);

    const crc = std.mem.readInt(u32, bytes[24..28], .little);
    try testing.expectEqual(std.hash.Crc32.hash(bytes[32..]), crc);
}

test "many entries round-trip, keys and hashes intact" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "a/one.zig", .name = "alpha", .kind = "fn", .docstring_hash = hash32(1), .decl_hash = hash32(11), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "a/one.zig", .name = "beta", .kind = "fn", .docstring_hash = hash32(2), .decl_hash = hash32(12), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "a/two.zig", .name = "gamma", .kind = "type", .docstring_hash = hash32(3), .decl_hash = hash32(13), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "z.zig", .name = "omega", .kind = "fn", .docstring_hash = hash32(4), .decl_hash = hash32(14), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
    };
    const bytes = try encode(gpa, &entries);
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 4), view.count());
    for (entries, 0..) |want, i| {
        const r = view.record(@intCast(i));
        try testing.expectEqualStrings(want.path, view.path(r));
        try testing.expectEqualStrings(want.name, view.name(r));
        try testing.expectEqualStrings(want.kind, view.kind(r));
        try testing.expectEqualSlices(u8, &want.docstring_hash, &r.docstring_hash);
        try testing.expectEqualSlices(u8, &want.decl_hash, &r.decl_hash);
        try testing.expectEqual(want.docstring_start_line, r.docstring_start_line);
        try testing.expectEqual(want.docstring_end_line, r.docstring_end_line);
        try testing.expectEqual(want.decl_start_line, r.decl_start_line);
        try testing.expectEqual(want.decl_end_line, r.decl_end_line);
    }
}

test "find locates the exact (path, name, kind) triple, and a miss is a miss" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "a.zig", .name = "alpha", .kind = "fn", .docstring_hash = hash32(1), .decl_hash = hash32(11), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "a.zig", .name = "beta", .kind = "fn", .docstring_hash = hash32(2), .decl_hash = hash32(12), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "b.zig", .name = "alpha", .kind = "fn", .docstring_hash = hash32(3), .decl_hash = hash32(13), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
    };
    const bytes = try encode(gpa, &entries);
    defer gpa.free(bytes);
    const view = try parse(bytes);

    try testing.expectEqual(@as(?u32, 1), view.find("a.zig", "beta", "fn"));
    try testing.expectEqual(@as(?u32, 2), view.find("b.zig", "alpha", "fn"));
    try testing.expectEqual(@as(?u32, null), view.find("a.zig", "beta", "type")); // right name, wrong kind
    try testing.expectEqual(@as(?u32, null), view.find("c.zig", "alpha", "fn")); // no such path
}

test "pathRange is every entry for one file, contiguous, and empty for an untracked file" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "a.zig", .name = "alpha", .kind = "fn", .docstring_hash = hash32(1), .decl_hash = hash32(11), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "a.zig", .name = "beta", .kind = "fn", .docstring_hash = hash32(2), .decl_hash = hash32(12), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "b.zig", .name = "alpha", .kind = "fn", .docstring_hash = hash32(3), .decl_hash = hash32(13), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
    };
    const bytes = try encode(gpa, &entries);
    defer gpa.free(bytes);
    const view = try parse(bytes);

    const a_range = view.pathRange("a.zig");
    try testing.expectEqual(@as(u32, 0), a_range.start);
    try testing.expectEqual(@as(u32, 2), a_range.end);

    const b_range = view.pathRange("b.zig");
    try testing.expectEqual(@as(u32, 2), b_range.start);
    try testing.expectEqual(@as(u32, 3), b_range.end);

    const untracked = view.pathRange("c.zig");
    try testing.expectEqual(untracked.start, untracked.end);
}

test "unsorted input is rejected at encode time" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "b.zig", .name = "x", .kind = "fn", .docstring_hash = hash32(1), .decl_hash = hash32(1), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
        .{ .path = "a.zig", .name = "x", .kind = "fn", .docstring_hash = hash32(2), .decl_hash = hash32(2), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2 },
    };
    try testing.expectError(error.Unsorted, encode(gpa, &entries));
}

test "a flipped byte in the string region fails the checksum" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{
        .path = "a.zig",
        .name = "alpha",
        .kind = "fn",
        .docstring_hash = hash32(1),
        .decl_hash = hash32(2), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2,
    }});
    defer gpa.free(bytes);

    const corrupt = try gpa.dupe(u8, bytes);
    defer gpa.free(corrupt);
    corrupt[corrupt.len - 1] ^= 0xff;

    try testing.expectError(error.ChecksumMismatch, parse(corrupt));
}

test "a file truncated inside the record table is Truncated, not a bounds panic" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{
        .path = "a.zig",
        .name = "alpha",
        .kind = "fn",
        .docstring_hash = hash32(1),
        .decl_hash = hash32(2), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2,
    }});
    defer gpa.free(bytes);

    // Cut into the record table itself (which starts right after the
    // 32-byte header) -- caught by the table_end/bytes.len check, before
    // the checksum (which covers everything past the header, and would
    // also fail here, but table_end is the more specific diagnosis).
    try testing.expectError(error.Truncated, parse(bytes[0 .. Header.wire_size + 10]));
}

test "a file truncated inside the string region fails the checksum" {
    // The checksum covers the whole post-header region -- unlike the tags
    // cache, this format has no separate payload region excluded from it
    // -- so a truncation past the record table is always a checksum
    // failure, never a distinct Truncated/OffsetOutOfRange path.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{
        .path = "a.zig",
        .name = "alpha",
        .kind = "fn",
        .docstring_hash = hash32(1),
        .decl_hash = hash32(2), .docstring_start_line = 1, .docstring_end_line = 1, .decl_start_line = 2, .decl_end_line = 2,
    }});
    defer gpa.free(bytes);

    try testing.expectError(error.ChecksumMismatch, parse(bytes[0 .. bytes.len - 3]));
}

test "wrong magic is NotACache, not a version mismatch" {
    try testing.expectError(error.NotACache, parse(&(.{0} ** 40)));
}
