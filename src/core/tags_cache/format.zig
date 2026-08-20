//! The on-disk tags cache: bytes in, bytes out. No files, no paths, no `Io`.
//!
//! Replaces `_tags_cache.json` (one JSON object of `path -> {hash, tags,
//! unsupported}`): answering "which of these 4,000 files changed?" meant
//! `jq` parsing every tag line of every entry, 5.0s over syrius3's 828 MB
//! cache. Here tag text lives out of line, so that question touches only
//! the record table (~5 MB, not 828 MB), and payload is read only for a
//! specific file's tags.
//!
//! ## Layout
//!
//! ```
//! 0                     header, 40 bytes
//! 40                    record table, entry_count * 43 bytes, sorted by path
//! paths_off             path region: every path's bytes, concatenated
//! blob_off              payload region: every entry's tag text, concatenated
//! ```
//!
//! Records are fixed-width and sorted by path bytes, so lookup is a binary
//! search over a region small enough to stay in cache.
//!
//! ## Architecture independence
//!
//! Every multi-byte field is read/written one at a time with an explicit
//! `.little` -- no `@bitCast`, `packed struct`, or struct-typed `@ptrCast`.
//! The 43-byte record is deliberately odd-width, so nothing in it is
//! naturally aligned and a cast shortcut can't accidentally work on x86.
//! Held to by the byte-exact encoder test below and a committed fixture
//! that must keep decoding.
//!
//! ## Opening is meant to be cheap, and the checksum nearly was not
//!
//! Reading must cost the record table, not the payload. Everything `parse`
//! does is bounded by `blob_off` for that reason, checksum included -- see `crc32`.
//!
//! ## Versioning
//!
//! A header that doesn't match is discarded and rebuilt -- a cache, so
//! nothing in it can't be recomputed. `NotACache` and `VersionMismatch`
//! are separate errors because the former usually means something else is
//! sitting at that path.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Eight bytes including the trailing NUL, so the header's first field
/// aligns and `head -c 8` shows the name intact.
pub const magic: [8]u8 = "SYNTAGS\x00".*;

pub const version: u32 = 1;

pub const Header = struct {
    version: u32,
    entry_count: u32,
    paths_off: u64,
    blob_off: u64,
    /// Over `bytes[wire_size..blob_off]` -- record table and path region
    /// only. Covering the payload too made `open` take 8.0s over syrius3's
    /// 801 MB cache, worse than the 5.0s `jq` parse this format replaces;
    /// excluding it costs only that a bit-flip inside a tag string goes
    /// undetected (same damage class as a stale cache, fixed by a rebuild),
    /// while a bit-flip in an offset is still caught.
    crc32: u32,

    /// 40, not the 36 the fields add to: four reserved bytes, written zero
    /// and unread, keep the record table 8-byte aligned.
    pub const wire_size = 40;

    fn write(self: Header, out: *[wire_size]u8) void {
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.version, .little);
        std.mem.writeInt(u32, out[12..16], self.entry_count, .little);
        std.mem.writeInt(u64, out[16..24], self.paths_off, .little);
        std.mem.writeInt(u64, out[24..32], self.blob_off, .little);
        std.mem.writeInt(u32, out[32..36], self.crc32, .little);
        std.mem.writeInt(u32, out[36..40], 0, .little);
    }

    fn read(in: *const [wire_size]u8) Header {
        return .{
            .version = std.mem.readInt(u32, in[8..12], .little),
            .entry_count = std.mem.readInt(u32, in[12..16], .little),
            .paths_off = std.mem.readInt(u64, in[16..24], .little),
            .blob_off = std.mem.readInt(u64, in[24..32], .little),
            .crc32 = std.mem.readInt(u32, in[32..36], .little),
        };
    }
};

/// One cached path. Fixed width so the table is indexable, sorted by path
/// bytes so it is searchable.
pub const Record = struct {
    /// Into the path region, not the file.
    path_off: u64,
    path_len: u16,
    /// Raw 20-byte SHA-1, not hex: halves the table, comparison is a memcmp.
    hash: [20]u8,
    /// Into the payload region, not the file.
    tags_off: u64,
    tags_len: u32,
    flags: u8,

    pub const wire_size = 8 + 2 + 20 + 8 + 4 + 1;

    /// No usable grammar. Distinct from `tags_len == 0` (parsed, declared
    /// nothing) -- conflating them re-tags a readable file forever.
    pub const flag_unsupported: u8 = 1 << 0;

    pub fn unsupported(self: Record) bool {
        return self.flags & flag_unsupported != 0;
    }

    fn write(self: Record, out: *[wire_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.path_off, .little);
        std.mem.writeInt(u16, out[8..10], self.path_len, .little);
        @memcpy(out[10..30], &self.hash);
        std.mem.writeInt(u64, out[30..38], self.tags_off, .little);
        std.mem.writeInt(u32, out[38..42], self.tags_len, .little);
        out[42] = self.flags;
    }

    fn read(in: *const [wire_size]u8) Record {
        return .{
            .path_off = std.mem.readInt(u64, in[0..8], .little),
            .path_len = std.mem.readInt(u16, in[8..10], .little),
            .hash = in[10..30].*,
            .tags_off = std.mem.readInt(u64, in[30..38], .little),
            .tags_len = std.mem.readInt(u32, in[38..42], .little),
            .flags = in[42],
        };
    }
};

/// What `encode` takes: a whole entry, path included. The reader's equivalent
/// has no path, because you found it by one.
pub const Entry = struct {
    path: []const u8,
    hash: [20]u8,
    tags: []const u8,
    unsupported: bool = false,
};

pub const EncodeError = error{
    /// Unsorted input would encode fine and make every binary search wrong.
    Unsorted,
    PathTooLong,
    TagsTooLong,
    TooManyEntries,
} || Allocator.Error;

pub const ParseError = error{
    /// Magic doesn't match -- something else is at this path.
    NotACache,
    /// Ours, but a version this build doesn't read. Discard and rebuild.
    VersionMismatch,
    Truncated,
    ChecksumMismatch,
    /// A header or record offset points outside its region.
    OffsetOutOfRange,
};

/// The whole file as one buffer -- a convenience over `encodeTo` for tests
/// and small caches; anything repository-sized should stream instead.
pub fn encode(gpa: Allocator, entries: []const Entry) EncodeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    encodeTo(gpa, &out.writer, entries) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return out.toOwnedSlice();
}

/// Everything up to `blob_off` (header, record table, path region) is built
/// in memory -- record offsets are only known once every path length is,
/// and the checksum covers exactly that span. Tag payloads then stream
/// straight through: the buffered prefix is ~11 MB at 125k files, versus a
/// second in-memory copy of every tag if the whole file were built first.
pub fn encodeTo(
    gpa: Allocator,
    w: *std.Io.Writer,
    entries: []const Entry,
) (EncodeError || std.Io.Writer.Error)!void {
    if (entries.len > std.math.maxInt(u32)) return error.TooManyEntries;

    var paths_len: u64 = 0;
    for (entries, 0..) |e, i| {
        if (e.path.len > std.math.maxInt(u16)) return error.PathTooLong;
        if (e.tags.len > std.math.maxInt(u32)) return error.TagsTooLong;
        if (i > 0 and std.mem.order(u8, entries[i - 1].path, e.path) != .lt) return error.Unsorted;
        paths_len += e.path.len;
    }

    const table_len: u64 = @as(u64, entries.len) * Record.wire_size;
    const paths_off: u64 = Header.wire_size + table_len;
    const blob_off: u64 = paths_off + paths_len;

    const prefix = try gpa.alloc(u8, @intCast(blob_off));
    defer gpa.free(prefix);

    var path_at: u64 = 0;
    var tags_at: u64 = 0;
    for (entries, 0..) |e, i| {
        const rec: Record = .{
            .path_off = path_at,
            .path_len = @intCast(e.path.len),
            .hash = e.hash,
            .tags_off = tags_at,
            .tags_len = @intCast(e.tags.len),
            .flags = if (e.unsupported) Record.flag_unsupported else 0,
        };
        const at = Header.wire_size + i * Record.wire_size;
        rec.write(prefix[at..][0..Record.wire_size]);

        @memcpy(prefix[@intCast(paths_off + path_at)..][0..e.path.len], e.path);
        path_at += e.path.len;
        tags_at += e.tags.len;
    }

    const header: Header = .{
        .version = version,
        .entry_count = @intCast(entries.len),
        .paths_off = paths_off,
        .blob_off = blob_off,
        .crc32 = std.hash.Crc32.hash(prefix[Header.wire_size..]),
    };
    header.write(prefix[0..Header.wire_size]);

    try w.writeAll(prefix);
    for (entries) |e| try w.writeAll(e.tags);
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
        const at: usize = @intCast(self.header.paths_off + r.path_off);
        return self.bytes[at..][0..r.path_len];
    }

    pub fn tags(self: View, r: Record) []const u8 {
        const at: usize = @intCast(self.header.blob_off + r.tags_off);
        return self.bytes[at..][0..r.tags_len];
    }

    /// Index of `wanted`, or null. Lives here since the sort invariant it
    /// depends on is this format's own promise.
    pub fn find(self: View, wanted: []const u8) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.path(self.record(mid)), wanted)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
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
    // Checked before the checksum: a corrupt blob_off would otherwise slice
    // out of bounds computing the checksum's own range.
    if (header.blob_off > bytes.len) return error.OffsetOutOfRange;
    if (header.blob_off < Header.wire_size) return error.OffsetOutOfRange;

    if (std.hash.Crc32.hash(bytes[Header.wire_size..@intCast(header.blob_off)]) != header.crc32)
        return error.ChecksumMismatch;
    if (header.paths_off < table_end) return error.OffsetOutOfRange; // `>=`, not `==`: a gap is fine

    if (header.blob_off < header.paths_off) return error.OffsetOutOfRange;

    const view: View = .{ .bytes = bytes, .header = header };
    var prev: ?[]const u8 = null;
    var i: u32 = 0;
    while (i < header.entry_count) : (i += 1) {
        const r = view.record(i);
        if (r.path_off + r.path_len > header.blob_off - header.paths_off)
            return error.OffsetOutOfRange;
        if (header.blob_off + r.tags_off + r.tags_len > bytes.len)
            return error.OffsetOutOfRange;
        const p = view.path(r); // find() rests on this order
        if (prev) |q| if (std.mem.order(u8, q, p) != .lt) return error.OffsetOutOfRange;
        prev = p;
    }
    return view;
}

const testing = std.testing;

fn h(comptime hex: *const [40]u8) [20]u8 {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "one entry encodes to exactly the bytes this file documents" {
    // Written against the layout comment at the top, field by field --
    // not by printing what the encoder produced, which could only ever
    // agree with itself.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{
        .path = "a.ml",
        .hash = h("0123456789abcdef0123456789abcdef01234567"),
        .tags = "T",
    }});
    defer gpa.free(bytes);

    // 40 header + 43 record + 4 path + 1 payload
    try testing.expectEqual(@as(usize, 88), bytes.len);

    try testing.expectEqualSlices(u8, "SYNTAGS\x00", bytes[0..8]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[8..12]); // version 1
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[12..16]); // entry_count 1
    try testing.expectEqualSlices(u8, &.{ 83, 0, 0, 0, 0, 0, 0, 0 }, bytes[16..24]); // paths_off 40+43
    try testing.expectEqualSlices(u8, &.{ 87, 0, 0, 0, 0, 0, 0, 0 }, bytes[24..32]); // blob_off 83+4
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[36..40]); // reserved

    const rec = bytes[40..83];
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, rec[0..8]); // path_off
    try testing.expectEqualSlices(u8, &.{ 4, 0 }, rec[8..10]); // path_len
    try testing.expectEqualSlices(u8, &h("0123456789abcdef0123456789abcdef01234567"), rec[10..30]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, rec[30..38]); // tags_off
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, rec[38..42]); // tags_len
    try testing.expectEqual(@as(u8, 0), rec[42]); // flags

    try testing.expectEqualStrings("a.ml", bytes[83..87]);
    try testing.expectEqualStrings("T", bytes[87..88]);

    const crc = std.mem.readInt(u32, bytes[32..36], .little); // covers record table + paths, not payload

    try testing.expectEqual(std.hash.Crc32.hash(bytes[40..87]), crc);
    try testing.expect(crc != std.hash.Crc32.hash(bytes[40..]));
}

test "many entries round-trip, payload and flags intact" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "a/one.java", .hash = h("11" ** 20), .tags = "Alpha\nBeta\n" },
        .{ .path = "a/two.bin", .hash = h("22" ** 20), .tags = "", .unsupported = true },
        .{ .path = "b/three.py", .hash = h("33" ** 20), .tags = "" },
        .{ .path = "z.kt", .hash = h("44" ** 20), .tags = "Zed\n" },
    };
    const bytes = try encode(gpa, &entries);
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 4), view.count());
    for (entries, 0..) |want, i| {
        const r = view.record(@intCast(i));
        try testing.expectEqualStrings(want.path, view.path(r));
        try testing.expectEqualSlices(u8, &want.hash, &r.hash);
        try testing.expectEqualStrings(want.tags, view.tags(r));
        try testing.expectEqual(want.unsupported, r.unsupported());
    }
}

test "unsupported and parsed-to-nothing stay distinguishable" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{
        .{ .path = "empty.java", .hash = h("00" ** 20), .tags = "" },
        .{ .path = "nogrammar.bin", .hash = h("00" ** 20), .tags = "", .unsupported = true },
    });
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expect(!view.record(0).unsupported());
    try testing.expect(view.record(1).unsupported());
}

test "lookup is a binary search, and a miss is a miss" {
    const gpa = testing.allocator;
    var entries: [500]Entry = undefined;
    var names: [500][8]u8 = undefined;
    for (&entries, &names, 0..) |*e, *n, i| {
        _ = std.fmt.bufPrint(n, "p{d:0>5}.j", .{i}) catch unreachable;
        e.* = .{ .path = n, .hash = h("00" ** 20), .tags = "" };
    }
    const bytes = try encode(gpa, &entries);
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(?u32, 0), view.find("p00000.j"));
    try testing.expectEqual(@as(?u32, 250), view.find("p00250.j"));
    try testing.expectEqual(@as(?u32, 499), view.find("p00499.j"));
    try testing.expectEqual(@as(?u32, null), view.find("p00500.j"));
    try testing.expectEqual(@as(?u32, null), view.find(""));
}

test "an empty cache is a valid cache, not a special case" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{});
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 0), view.count());
    try testing.expectEqual(@as(?u32, null), view.find("anything"));
}

test "unsorted input is refused rather than encoded into a broken search" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unsorted, encode(gpa, &.{
        .{ .path = "b", .hash = h("00" ** 20), .tags = "" },
        .{ .path = "a", .hash = h("00" ** 20), .tags = "" },
    }));
    try testing.expectError(error.Unsorted, encode(gpa, &.{ // a duplicate path is unsorted too
        .{ .path = "a", .hash = h("00" ** 20), .tags = "" },
        .{ .path = "a", .hash = h("11" ** 20), .tags = "" },
    }));
}

test "a bumped version rebuilds rather than misreads" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .hash = h("00" ** 20), .tags = "x" }});
    defer gpa.free(bytes);

    std.mem.writeInt(u32, bytes[8..12], version + 1, .little);
    try testing.expectError(error.VersionMismatch, parse(bytes));

    std.mem.writeInt(u32, bytes[8..12], version, .little);
    _ = try parse(bytes);
}

test "a file that is not ours, or is corrupt, or is short, is refused" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .hash = h("00" ** 20), .tags = "xyz" }});
    defer gpa.free(bytes);

    try testing.expectError(error.Truncated, parse(bytes[0 .. Header.wire_size - 1]));

    // Long enough to clear the header, exercising the magic check, not the
    // length check.
    const json = "{\"a.ml\": {\"hash\": \"0123456789abcdef\", \"unsupported\": false, \"tags\": \"\"}}";
    try testing.expect(json.len > Header.wire_size);
    try testing.expectError(error.NotACache, parse(json));

    // A flipped byte in the path region -- inside the checksum's covered
    // range, so only the checksum can catch it.
    const paths_off = std.mem.readInt(u64, bytes[16..24], .little);
    bytes[@intCast(paths_off)] ^= 0xff;
    try testing.expectError(error.ChecksumMismatch, parse(bytes));
}

test "a record pointing outside its region is refused, not followed" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .hash = h("00" ** 20), .tags = "xyz" }});
    defer gpa.free(bytes);

    // tags_len past the end of the file -- unchecked, an out-of-bounds read.
    std.mem.writeInt(u32, bytes[40 + 38 ..][0..4], 9999, .little);
    const blob_off = std.mem.readInt(u64, bytes[24..32], .little);
    std.mem.writeInt(u32, bytes[32..36], std.hash.Crc32.hash(bytes[40..@intCast(blob_off)]), .little);
    try testing.expectError(error.OffsetOutOfRange, parse(bytes));
}

/// The three entries `testdata/v1.bin` holds.
const fixture_entries = [_]Entry{
    .{
        .path = "src/Alpha.java",
        .hash = h("45bc6ae64517e43785674ddad8b92e89b4a8fb4a"),
        .tags = "Alpha     \t | class   \tdef (0, 13) - (0, 18) `public class Alpha {`\n",
    },
    .{ .path = "src/Empty.java", .hash = h("aa" ** 20), .tags = "" },
    .{ .path = "src/logo.bin", .hash = h("bb" ** 20), .tags = "", .unsupported = true },
};

test "encode reproduces the committed fixture byte for byte" {
    // `testdata/v1.bin` was generated from the layout comment by a separate
    // implementation, not by `encode` -- checks the doc against the code.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &fixture_entries);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, @embedFile("testdata/v1.bin"), bytes);
}

test "the committed v1 fixture still decodes" {
    // Frozen bytes, not bytes this build produced -- every other test here
    // encodes and reads back, so all would keep passing through a change
    // that altered the format both ways at once.
    const view = try parse(@embedFile("testdata/v1.bin"));
    try testing.expectEqual(@as(u32, 3), view.count());

    try testing.expectEqualStrings("src/Alpha.java", view.path(view.record(0)));
    try testing.expectEqualStrings(
        "Alpha     \t | class   \tdef (0, 13) - (0, 18) `public class Alpha {`\n",
        view.tags(view.record(0)),
    );
    try testing.expectEqualSlices(
        u8,
        &h("45bc6ae64517e43785674ddad8b92e89b4a8fb4a"),
        &view.record(0).hash,
    );

    // A file that parsed and declared nothing.
    try testing.expectEqualStrings("src/Empty.java", view.path(view.record(1)));
    try testing.expectEqualStrings("", view.tags(view.record(1)));
    try testing.expect(!view.record(1).unsupported());

    // A file with no grammar at all.
    try testing.expectEqualStrings("src/logo.bin", view.path(view.record(2)));
    try testing.expect(view.record(2).unsupported());

    try testing.expectEqual(@as(?u32, 1), view.find("src/Empty.java"));
    try testing.expectEqual(@as(?u32, null), view.find("src/Missing.java"));
}

test "encode/parse round trip: any valid sorted []Entry survives byte-for-byte" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) anyerror!void {
            const max_entries = 6;
            const n: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 1, max_entries, 0));

            var path_bufs: [max_entries][32]u8 = undefined;
            var tags_bufs: [max_entries][24]u8 = undefined;
            var entries: [max_entries]Entry = undefined;

            for (0..n) |i| {
                // A zero-padded numeric prefix guarantees strictly
                // increasing path order regardless of the fuzzed suffix
                // that follows it -- the property under test is the
                // codec's byte-fidelity, not this test's own sorting.
                const suffix_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 20, @intCast(i * 4 + 1)));
                var suffix_buf: [20]u8 = undefined;
                for (suffix_buf[0..suffix_len], 0..) |*c, j| {
                    // Printable, non-slash, so the path stays one clean
                    // segment -- content diversity is the point, not
                    // exercising path-segment parsing (this format has none).
                    c.* = smith.valueRangeAtMostWithHash(u8, '!', '~', @intCast(i * 40 + j + 2));
                }
                entries[i].path = std.fmt.bufPrint(&path_bufs[i], "{d:0>3}-{s}", .{ i, suffix_buf[0..suffix_len] }) catch unreachable;

                smith.bytesWithHash(&entries[i].hash, @intCast(i * 4 + 2));

                const tags_len: usize = @intCast(smith.valueRangeAtMostWithHash(u32, 0, 24, @intCast(i * 4 + 3)));
                smith.bytesWithHash(tags_bufs[i][0..tags_len], @intCast(i * 4 + 3));
                entries[i].tags = tags_bufs[i][0..tags_len];

                entries[i].unsupported = smith.valueWithHash(bool, @intCast(i * 4 + 4));
            }

            const gpa = testing.allocator;
            const bytes = try encode(gpa, entries[0..n]);
            defer gpa.free(bytes);

            const view = try parse(bytes);
            try testing.expectEqual(@as(u32, @intCast(n)), view.count());
            for (0..n) |i| {
                const r = view.record(@intCast(i));
                try testing.expectEqualStrings(entries[i].path, view.path(r));
                try testing.expectEqualSlices(u8, &entries[i].hash, &r.hash);
                try testing.expectEqualStrings(entries[i].tags, view.tags(r));
                try testing.expectEqual(entries[i].unsupported, r.unsupported());
            }
        }
    }.testOne, .{});
}
