//! The on-disk reverse index: bytes in, bytes out. No files, no paths, no `Io`.
//!
//! Replaces `_index.json`, the map from every enumerated source path to the
//! node filenames that claim it, plus the `_unassigned` list. Two things are
//! being fixed at once, and only one of them is the encoding.
//!
//! The encoding: the JSON is 26 MB for syrius3's 124,837 paths, and every
//! reader of it is a `jq` invocation -- `synapse-build-index.sh` to validate
//! and count, `synapse-query.sh` to resolve a path, the staleness hook on
//! every `Write`/`Edit`. `jq` was the last heavy runtime dependency once the
//! `tree-sitter` CLI left, and this file is what retires it.
//!
//! The location: `_index.json` lived in the vault and was PUT over the
//! Obsidian REST API at 26 MB, despite being derived, machine-only and
//! gitignored (`.gitignore:5` in the vault, on the grounds that the graph's
//! churn dominated the history while adding nothing a rebuild cannot
//! restore -- zero commits have ever touched the path). Nothing that never
//! travels needs an HTTP round trip, so this moves beside the tags cache in
//! `$SYNAPSE_WORK_DIR/{repo}@{branch}/`, which is already keyed the same way.
//!
//! ## What a path maps to
//!
//! A list of nodes, not one node. `synapse-build-index.sh` groups pairs by
//! path and keeps `[.[].node] | sort`, because a source file can legitimately
//! be cited by more than one subsystem. A format that stored a single owner
//! would encode fine and silently drop the second claimant, so the record
//! holds a count and the node names are interned: ~100 nodes name themselves
//! once each, and 124,837 records point at them by index.
//!
//! ## Layout
//!
//! ```
//! 0                  header, 64 bytes
//! 64                 record table, entry_count * 15 bytes, sorted by path
//! paths_off          path region: every path's bytes, concatenated
//! ids_off            node-id region: one u32 per (path, node) pair
//! nodes_off          node table, node_count * 6 bytes, sorted by name,
//!                    followed by the name bytes it points into
//! unassigned_off     unassigned region: every path, each '\n'-terminated
//! ```
//!
//! Records are fixed-width and sorted by path bytes, which is what makes
//! lookup a binary search over a region small enough to stay in cache. The
//! node table is sorted by name for the same reason, and because sorting it
//! makes the output a function of the input set rather than of the order the
//! encoder happened to meet things in.
//!
//! ## Explicit field reads, and what they are for
//!
//! Every multi-byte field is read and written a field at a time with an
//! explicit `.little`, and there is not a single `@bitCast`, `packed struct`
//! or `@ptrCast` to a struct type here. The node-id region is the same
//! restraint in the other direction: it is a run of u32 that would be tempting
//! to hand out as `[]const u32`, so it is read one id at a time and never
//! sliced as a typed array.
//!
//! **This is not for portability, and no claim of it is made.** This file and
//! `_tags_cache.bin` live in `$SYNAPSE_WORK_DIR`, are gitignored, never
//! travel, and are rebuilt from the work dir's lists on any mismatch. Carrying
//! one to another architecture is not a case that occurs, so it is not a case
//! this format spends anything on. `ci/build-targets.sh` covers the two
//! release targets, both little-endian; nothing here is verified on a
//! big-endian machine and nothing here needs to be.
//!
//! What the restraint does buy, on this machine:
//!
//! - **Layout stability across compiler versions.** A cast over a struct makes
//!   the on-disk layout a function of whatever Zig decides `@sizeOf` and the
//!   field offsets are. A toolchain upgrade could then shift the layout with
//!   no version bump to notice it, and an existing file would be misread
//!   rather than rejected. Written out a field at a time, the layout is the
//!   doc comment above and nothing else.
//! - **No alignment assumption on the mapping.** `parse` takes whatever bytes
//!   it is handed, and a struct cast at an arbitrary offset into a mapping is
//!   undefined behaviour that happens to work on x86 and does not everywhere
//!   this is compiled. The 15-byte record keeps that honest: an odd width
//!   leaves nothing in the table naturally aligned, so a cast shortcut is
//!   visibly wrong rather than accidentally fine.
//!
//! Both of those are same-machine concerns, which is why the technique stays
//! even though the portability goal is gone. What holds it: the byte-exact
//! encoder test below, written against this comment rather than against the
//! encoder's output, and a committed fixture that must keep decoding.
//!
//! ## The checksum covers everything, unlike the tags cache
//!
//! `tags_cache/format.zig` deliberately stops its checksum before the payload,
//! because covering syrius3's 828 MB of tag text made `open` take 8.0s and the
//! format exists to beat a 5.0s `jq` parse. Nothing here is that big: the same
//! namespace is ~1.9 MB of records, ~7.5 MB of paths and a few kilobytes of
//! node names, so a full CRC costs single-digit milliseconds and there is no
//! reason to leave a region unprotected. Same reasoning, opposite answer,
//! because the measurement is different.
//!
//! ## Versioning
//!
//! A header that does not match is discarded and rebuilt. It is derived data:
//! there is nothing in it that cannot be recomputed from the work dir's lists,
//! so migration code would be carrying risk in exchange for saving one
//! rebuild. `NotAnIndex` and `VersionMismatch` are separate errors only
//! because the first says something else is sitting at that path -- most
//! likely the `_index.json` this replaces -- which is worth seeing in a log.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The trailing NULs are part of it: eight bytes, so the header's first field
/// is aligned and a `file` / `head -c 8` shows the name intact.
pub const magic: [8]u8 = "SYNIDX\x00\x00".*;

pub const version: u32 = 1;

/// A path claimed by more nodes than this is refused rather than truncated.
/// The cap exists so `ids_len` fits a byte and the record table stays an odd
/// width; a path cited by 255 subsystems is a clustering that went wrong, not
/// a case to support.
pub const max_nodes_per_path = std.math.maxInt(u8);

pub const Header = struct {
    version: u32,
    /// Paths with at least one owning node. `_unassigned` is counted
    /// separately and is not in the record table.
    entry_count: u32,
    node_count: u32,
    unassigned_count: u32,
    /// Absolute file offset of the path region.
    paths_off: u64,
    /// Absolute file offset of the node-id region.
    ids_off: u64,
    /// Absolute file offset of the node table. The name bytes follow it, at
    /// `nodes_off + node_count * Node.wire_size`.
    nodes_off: u64,
    /// Absolute file offset of the unassigned region.
    unassigned_off: u64,
    /// Over `bytes[wire_size..]` -- everything after the header, including the
    /// unassigned region. See the note at the top on why this differs from the
    /// tags cache.
    crc32: u32,

    /// 64, not the 60 the fields add up to: four reserved bytes keep the
    /// record table starting on an 8-byte boundary and the number round. They
    /// are written as zero and not read, and using them for anything is a
    /// version bump like any other field would be.
    pub const wire_size = 64;

    fn write(self: Header, out: *[wire_size]u8) void {
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.version, .little);
        std.mem.writeInt(u32, out[12..16], self.entry_count, .little);
        std.mem.writeInt(u32, out[16..20], self.node_count, .little);
        std.mem.writeInt(u32, out[20..24], self.unassigned_count, .little);
        std.mem.writeInt(u64, out[24..32], self.paths_off, .little);
        std.mem.writeInt(u64, out[32..40], self.ids_off, .little);
        std.mem.writeInt(u64, out[40..48], self.nodes_off, .little);
        std.mem.writeInt(u64, out[48..56], self.unassigned_off, .little);
        std.mem.writeInt(u32, out[56..60], self.crc32, .little);
        std.mem.writeInt(u32, out[60..64], 0, .little);
    }

    fn read(in: *const [wire_size]u8) Header {
        return .{
            .version = std.mem.readInt(u32, in[8..12], .little),
            .entry_count = std.mem.readInt(u32, in[12..16], .little),
            .node_count = std.mem.readInt(u32, in[16..20], .little),
            .unassigned_count = std.mem.readInt(u32, in[20..24], .little),
            .paths_off = std.mem.readInt(u64, in[24..32], .little),
            .ids_off = std.mem.readInt(u64, in[32..40], .little),
            .nodes_off = std.mem.readInt(u64, in[40..48], .little),
            .unassigned_off = std.mem.readInt(u64, in[48..56], .little),
            .crc32 = std.mem.readInt(u32, in[56..60], .little),
        };
    }
};

/// One indexed path. Fixed width so the table is indexable, sorted by path
/// bytes so it is searchable.
pub const Record = struct {
    /// Into the path region, not the file.
    path_off: u64,
    path_len: u16,
    /// Into the node-id region, counted in u32 slots rather than bytes.
    ids_at: u32,
    /// How many node ids belong to this path. Never zero: a path with no owner
    /// is in the unassigned region instead, and the two are not the same claim.
    ids_len: u8,

    pub const wire_size = 8 + 2 + 4 + 1;

    fn write(self: Record, out: *[wire_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.path_off, .little);
        std.mem.writeInt(u16, out[8..10], self.path_len, .little);
        std.mem.writeInt(u32, out[10..14], self.ids_at, .little);
        out[14] = self.ids_len;
    }

    fn read(in: *const [wire_size]u8) Record {
        return .{
            .path_off = std.mem.readInt(u64, in[0..8], .little),
            .path_len = std.mem.readInt(u16, in[8..10], .little),
            .ids_at = std.mem.readInt(u32, in[10..14], .little),
            .ids_len = in[14],
        };
    }
};

/// One interned node name. The offset is into the name bytes that follow the
/// table, not into the file.
pub const Node = struct {
    name_off: u32,
    name_len: u16,

    pub const wire_size = 4 + 2;

    fn write(self: Node, out: *[wire_size]u8) void {
        std.mem.writeInt(u32, out[0..4], self.name_off, .little);
        std.mem.writeInt(u16, out[4..6], self.name_len, .little);
    }

    fn read(in: *const [wire_size]u8) Node {
        return .{
            .name_off = std.mem.readInt(u32, in[0..4], .little),
            .name_len = std.mem.readInt(u16, in[4..6], .little),
        };
    }
};

/// What `encode` takes. `nodes` must be strictly ascending, matching the
/// `sort` the bash writer applies to each path's claimants.
pub const Entry = struct {
    path: []const u8,
    nodes: []const []const u8,
};

pub const EncodeError = error{
    /// Paths must be strictly ascending by bytes. Unsorted input would encode
    /// fine and then make every binary search wrong, which is the kind of bug
    /// that shows up as "this file belongs to no node" months later.
    Unsorted,
    /// A single path's node list must be strictly ascending too. The bash
    /// writer sorts it, and callers of `nodes` are entitled to that order.
    UnsortedNodes,
    /// A record with no owner. Say it in the unassigned list instead: the
    /// distinction between "claimed by nobody" and "not enumerated at all" is
    /// the one thing this index exists to keep straight.
    NoNodes,
    PathTooLong,
    NodeNameTooLong,
    /// An unassigned path containing a newline cannot be stored in the
    /// '\n'-terminated region, and the bash `unassigned.txt` it comes from
    /// could not represent one either. Refused rather than silently split.
    PathContainsNewline,
    TooManyEntries,
    TooManyNodes,
    TooManyNodesForPath,
} || Allocator.Error;

pub const ParseError = error{
    /// The magic does not match. Something else is at this path -- most often
    /// the `_index.json` this format replaces.
    NotAnIndex,
    /// Ours, but a version this build does not read. Discard and rebuild.
    VersionMismatch,
    Truncated,
    ChecksumMismatch,
    /// A header or record offset points outside its region, a node id names no
    /// node, or the unassigned region does not hold the count it claims.
    OffsetOutOfRange,
};

/// The whole file, in one allocation, from entries already sorted by path.
///
/// `unassigned` is stored in the order given, deliberately: it is a list, not
/// an index, its only reader iterates it whole, and the bash `unassigned.txt`
/// it comes from is not sorted either. Imposing an order here would be this
/// format inventing a contract its predecessor did not have.
pub fn encode(
    gpa: Allocator,
    entries: []const Entry,
    unassigned: []const []const u8,
) EncodeError![]u8 {
    if (entries.len > std.math.maxInt(u32)) return error.TooManyEntries;
    if (unassigned.len > std.math.maxInt(u32)) return error.TooManyEntries;

    // Pass one: validate, and intern the node names. The set is small -- a
    // namespace has tens of nodes against tens of thousands of paths -- so the
    // map is over names and the sort at the end is over nothing much.
    var interned: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer interned.deinit(gpa);

    var paths_len: u64 = 0;
    var ids_count: u64 = 0;
    for (entries, 0..) |e, i| {
        if (e.path.len > std.math.maxInt(u16)) return error.PathTooLong;
        if (i > 0 and std.mem.order(u8, entries[i - 1].path, e.path) != .lt) return error.Unsorted;
        if (e.nodes.len == 0) return error.NoNodes;
        if (e.nodes.len > max_nodes_per_path) return error.TooManyNodesForPath;
        for (e.nodes, 0..) |n, k| {
            if (n.len > std.math.maxInt(u16)) return error.NodeNameTooLong;
            if (k > 0 and std.mem.order(u8, e.nodes[k - 1], n) != .lt) return error.UnsortedNodes;
            try interned.put(gpa, n, {});
        }
        paths_len += e.path.len;
        ids_count += e.nodes.len;
    }
    if (interned.count() > std.math.maxInt(u32)) return error.TooManyNodes;

    var unassigned_len: u64 = 0;
    for (unassigned) |p| {
        if (std.mem.indexOfScalar(u8, p, '\n') != null) return error.PathContainsNewline;
        unassigned_len += p.len + 1;
    }

    // Sorted, so the bytes are a function of the input set and not of the
    // order the loop above happened to meet the names in.
    const names = interned.keys();
    std.mem.sort([]const u8, names, {}, lessByBytes);

    var names_len: u64 = 0;
    for (names) |n| names_len += n.len;

    const table_len: u64 = @as(u64, entries.len) * Record.wire_size;
    const paths_off: u64 = Header.wire_size + table_len;
    const ids_off: u64 = paths_off + paths_len;
    const nodes_off: u64 = ids_off + ids_count * 4;
    const names_off: u64 = nodes_off + @as(u64, names.len) * Node.wire_size;
    const unassigned_off: u64 = names_off + names_len;
    const total: u64 = unassigned_off + unassigned_len;

    const bytes = try gpa.alloc(u8, @intCast(total));
    errdefer gpa.free(bytes);

    // The node table and its names, written from the sorted order so an id is
    // an index into it.
    var name_at: u64 = 0;
    for (names, 0..) |n, i| {
        const node: Node = .{ .name_off = @intCast(name_at), .name_len = @intCast(n.len) };
        node.write(bytes[@intCast(nodes_off + i * Node.wire_size)..][0..Node.wire_size]);
        @memcpy(bytes[@intCast(names_off + name_at)..][0..n.len], n);
        name_at += n.len;
    }

    var path_at: u64 = 0;
    var ids_at: u64 = 0;
    for (entries, 0..) |e, i| {
        const rec: Record = .{
            .path_off = path_at,
            .path_len = @intCast(e.path.len),
            .ids_at = @intCast(ids_at),
            .ids_len = @intCast(e.nodes.len),
        };
        rec.write(bytes[Header.wire_size + i * Record.wire_size ..][0..Record.wire_size]);

        @memcpy(bytes[@intCast(paths_off + path_at)..][0..e.path.len], e.path);
        path_at += e.path.len;

        for (e.nodes) |n| {
            // Ascending names against an ascending table give ascending ids,
            // so `nodes` hands back what the caller passed in, in order.
            const id = findName(names, n).?;
            std.mem.writeInt(u32, bytes[@intCast(ids_off + ids_at * 4)..][0..4], id, .little);
            ids_at += 1;
        }
    }

    var un_at: u64 = 0;
    for (unassigned) |p| {
        @memcpy(bytes[@intCast(unassigned_off + un_at)..][0..p.len], p);
        bytes[@intCast(unassigned_off + un_at + p.len)] = '\n';
        un_at += p.len + 1;
    }

    const header: Header = .{
        .version = version,
        .entry_count = @intCast(entries.len),
        .node_count = @intCast(names.len),
        .unassigned_count = @intCast(unassigned.len),
        .paths_off = paths_off,
        .ids_off = ids_off,
        .nodes_off = nodes_off,
        .unassigned_off = unassigned_off,
        .crc32 = std.hash.Crc32.hash(bytes[Header.wire_size..]),
    };
    header.write(bytes[0..Header.wire_size]);
    return bytes;
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn findName(names: []const []const u8, wanted: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = names.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, names[mid], wanted)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return null;
}

/// A validated file. Borrows the bytes -- they are expected to be a mapping,
/// so nothing here copies and nothing here owns.
pub const View = struct {
    bytes: []const u8,
    header: Header,

    pub fn count(self: View) u32 {
        return self.header.entry_count;
    }

    pub fn nodeCount(self: View) u32 {
        return self.header.node_count;
    }

    pub fn unassignedCount(self: View) u32 {
        return self.header.unassigned_count;
    }

    pub fn record(self: View, i: u32) Record {
        const at = Header.wire_size + @as(usize, i) * Record.wire_size;
        return .read(self.bytes[at..][0..Record.wire_size]);
    }

    pub fn path(self: View, r: Record) []const u8 {
        const at: usize = @intCast(self.header.paths_off + r.path_off);
        return self.bytes[at..][0..r.path_len];
    }

    /// The `k`th node id of `r`. One at a time rather than a `[]const u32`:
    /// see the architecture-independence note at the top.
    pub fn nodeId(self: View, r: Record, k: u8) u32 {
        const at: usize = @intCast(self.header.ids_off + (@as(u64, r.ids_at) + k) * 4);
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }

    pub fn nodeName(self: View, id: u32) []const u8 {
        const at: usize = @intCast(self.header.nodes_off + @as(u64, id) * Node.wire_size);
        const n: Node = .read(self.bytes[at..][0..Node.wire_size]);
        const names_off = self.header.nodes_off + @as(u64, self.header.node_count) * Node.wire_size;
        return self.bytes[@intCast(names_off + n.name_off)..][0..n.name_len];
    }

    /// `r`'s node names, in ascending order, written into `out` and returned as
    /// the prefix that was filled. `out` must hold `r.ids_len`; a
    /// `[max_nodes_per_path][]const u8` on the stack always does, which is why
    /// this takes a buffer rather than an allocator.
    pub fn nodes(self: View, r: Record, out: [][]const u8) [][]const u8 {
        var k: u8 = 0;
        while (k < r.ids_len) : (k += 1) out[k] = self.nodeName(self.nodeId(r, k));
        return out[0..r.ids_len];
    }

    /// The index of `wanted`, or null. Lives here rather than in the layer
    /// above because the sort invariant this depends on is the format's
    /// promise, and a search written anywhere else could outlive it.
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

    /// The id of `name`, or null. The node table is sorted by name, so this is
    /// the same binary search as `find` over a much smaller region.
    pub fn findNode(self: View, name: []const u8) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = self.nodeCount();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.nodeName(mid), name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// The unassigned region verbatim: every path, each '\n'-terminated, in
    /// the order the writer was given. `unassignedIter` walks it.
    pub fn unassignedBytes(self: View) []const u8 {
        return self.bytes[@intCast(self.header.unassigned_off)..];
    }

    pub fn unassignedIter(self: View) Iterator {
        return .{ .rest = self.unassignedBytes() };
    }

    pub const Iterator = struct {
        rest: []const u8,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.rest.len == 0) return null;
            // `parse` established that the region is '\n'-terminated, so the
            // scan cannot run off the end and there is no trailing partial.
            const at = std.mem.indexOfScalar(u8, self.rest, '\n').?;
            const out = self.rest[0..at];
            self.rest = self.rest[at + 1 ..];
            return out;
        }
    };
};

/// Validate `bytes` and return a view over them. Every offset a `View`
/// accessor will use is checked here, so the accessors themselves need no
/// bounds checks and cannot read outside the file.
pub fn parse(bytes: []const u8) ParseError!View {
    if (bytes.len < Header.wire_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.NotAnIndex;

    const header: Header = .read(bytes[0..Header.wire_size]);
    if (header.version != version) return error.VersionMismatch;

    if (std.hash.Crc32.hash(bytes[Header.wire_size..]) != header.crc32)
        return error.ChecksumMismatch;

    const table_end: u64 = Header.wire_size + @as(u64, header.entry_count) * Record.wire_size;
    if (table_end > bytes.len) return error.Truncated;

    // The regions are in this order and each must fit. `>=` rather than `==`
    // throughout: a writer is free to leave a gap, and rejecting one would
    // make the format harder to extend than the version field makes it easy.
    if (header.paths_off < table_end) return error.OffsetOutOfRange;
    if (header.ids_off < header.paths_off) return error.OffsetOutOfRange;
    if (header.nodes_off < header.ids_off) return error.OffsetOutOfRange;
    if (header.unassigned_off < header.nodes_off) return error.OffsetOutOfRange;
    if (header.unassigned_off > bytes.len) return error.OffsetOutOfRange;

    // The id region has to hold every id the records will ask for, and the
    // node table plus its names has to fit between `nodes_off` and the
    // unassigned region.
    const ids_capacity: u64 = (header.nodes_off - header.ids_off) / 4;
    const names_off: u64 = header.nodes_off + @as(u64, header.node_count) * Node.wire_size;
    if (names_off > header.unassigned_off) return error.OffsetOutOfRange;

    const view: View = .{ .bytes = bytes, .header = header };

    // Node names first: the record pass resolves ids through them.
    const names_len: u64 = header.unassigned_off - names_off;
    var prev_name: ?[]const u8 = null;
    var id: u32 = 0;
    while (id < header.node_count) : (id += 1) {
        const at: usize = @intCast(header.nodes_off + @as(u64, id) * Node.wire_size);
        const n: Node = .read(bytes[at..][0..Node.wire_size]);
        if (@as(u64, n.name_off) + n.name_len > names_len) return error.OffsetOutOfRange;
        // `findNode` rests on this order, and a corrupt file that broke it
        // would return wrong answers rather than fail.
        const name = view.nodeName(id);
        if (prev_name) |q| if (std.mem.order(u8, q, name) != .lt) return error.OffsetOutOfRange;
        prev_name = name;
    }

    const paths_len: u64 = header.ids_off - header.paths_off;
    var prev_path: ?[]const u8 = null;
    var i: u32 = 0;
    while (i < header.entry_count) : (i += 1) {
        const r = view.record(i);
        if (r.ids_len == 0) return error.OffsetOutOfRange;
        if (r.path_off + r.path_len > paths_len) return error.OffsetOutOfRange;
        if (@as(u64, r.ids_at) + r.ids_len > ids_capacity) return error.OffsetOutOfRange;
        var k: u8 = 0;
        while (k < r.ids_len) : (k += 1) {
            if (view.nodeId(r, k) >= header.node_count) return error.OffsetOutOfRange;
        }
        // Same argument as the node order above, for `find`.
        const p = view.path(r);
        if (prev_path) |q| if (std.mem.order(u8, q, p) != .lt) return error.OffsetOutOfRange;
        prev_path = p;
    }

    // The unassigned region must hold exactly the count it claims, each entry
    // '\n'-terminated. `Iterator.next` unwraps its scan on the strength of
    // this, and a region ending mid-path would make it read past the end.
    const un = bytes[@intCast(header.unassigned_off)..];
    if (un.len != 0 and un[un.len - 1] != '\n') return error.OffsetOutOfRange;
    if (std.mem.count(u8, un, "\n") != header.unassigned_count) return error.OffsetOutOfRange;

    return view;
}

const testing = std.testing;

test "one entry encodes to exactly the bytes this file documents" {
    // Written against the layout comment at the top, field by field, rather
    // than by printing what the encoder produced. That direction is the whole
    // value: a test built from the output can only ever agree with it, and
    // would keep passing through a switch to struct casts or a padding change
    // -- the two ways the layout could stop being what the doc says it is.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .nodes = &.{"N.md"} }}, &.{"u.ml"});
    defer gpa.free(bytes);

    // 64 header + 15 record + 4 path + 4 ids + 6 node table + 4 name + 5 unassigned
    try testing.expectEqual(@as(usize, 102), bytes.len);

    try testing.expectEqualSlices(u8, "SYNIDX\x00\x00", bytes[0..8]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[8..12]); // version 1
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[12..16]); // entry_count 1
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[16..20]); // node_count 1
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[20..24]); // unassigned_count 1
    try testing.expectEqualSlices(u8, &.{ 79, 0, 0, 0, 0, 0, 0, 0 }, bytes[24..32]); // paths_off 64+15
    try testing.expectEqualSlices(u8, &.{ 83, 0, 0, 0, 0, 0, 0, 0 }, bytes[32..40]); // ids_off 79+4
    try testing.expectEqualSlices(u8, &.{ 87, 0, 0, 0, 0, 0, 0, 0 }, bytes[40..48]); // nodes_off 83+4
    try testing.expectEqualSlices(u8, &.{ 97, 0, 0, 0, 0, 0, 0, 0 }, bytes[48..56]); // unassigned_off 87+6+4
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[60..64]); // reserved

    const rec = bytes[64..79];
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, rec[0..8]); // path_off
    try testing.expectEqualSlices(u8, &.{ 4, 0 }, rec[8..10]); // path_len
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, rec[10..14]); // ids_at
    try testing.expectEqual(@as(u8, 1), rec[14]); // ids_len

    try testing.expectEqualStrings("a.ml", bytes[79..83]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[83..87]); // node id 0
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[87..91]); // name_off 0
    try testing.expectEqualSlices(u8, &.{ 4, 0 }, bytes[91..93]); // name_len 4
    try testing.expectEqualStrings("N.md", bytes[93..97]);
    try testing.expectEqualStrings("u.ml\n", bytes[97..102]);

    // The checksum covers everything after the header, unassigned region
    // included -- the opposite choice from the tags cache, for the reason in
    // the header comment.
    const crc = std.mem.readInt(u32, bytes[56..60], .little);
    try testing.expectEqual(std.hash.Crc32.hash(bytes[64..]), crc);
}

test "many entries round-trip, multi-node paths and node order intact" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .path = "a/one.java", .nodes = &.{ "Alpha.md", "Zeta.md" } },
        .{ .path = "a/two.java", .nodes = &.{"Zeta.md"} },
        .{ .path = "b/three.py", .nodes = &.{ "Alpha.md", "Beta.md", "Zeta.md" } },
        .{ .path = "z.kt", .nodes = &.{"Beta.md"} },
    };
    const bytes = try encode(gpa, &entries, &.{});
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 4), view.count());
    // Three distinct names across nine claims: the interning is the point.
    try testing.expectEqual(@as(u32, 3), view.nodeCount());
    try testing.expectEqual(@as(u32, 0), view.unassignedCount());

    var buf: [max_nodes_per_path][]const u8 = undefined;
    for (entries, 0..) |want, i| {
        const r = view.record(@intCast(i));
        try testing.expectEqualStrings(want.path, view.path(r));
        const got = view.nodes(r, &buf);
        try testing.expectEqual(want.nodes.len, got.len);
        for (want.nodes, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "a path claimed by several nodes keeps every claimant" {
    // The failure this guards: a format storing one owner per path encodes
    // without complaint and silently drops the rest, which surfaces much later
    // as a node that never goes stale when its own source changes.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{
        .{ .path = "shared.java", .nodes = &.{ "A.md", "B.md", "C.md" } },
    }, &.{});
    defer gpa.free(bytes);

    const view = try parse(bytes);
    var buf: [max_nodes_per_path][]const u8 = undefined;
    const got = view.nodes(view.record(0), &buf);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("A.md", got[0]);
    try testing.expectEqualStrings("B.md", got[1]);
    try testing.expectEqualStrings("C.md", got[2]);
}

test "unassigned is a separate list, iterated in the order given" {
    // Not sorted, on purpose: the bash `unassigned.txt` is not, its only
    // reader iterates the whole thing, and inventing an order here would be
    // this format claiming a contract its predecessor did not have.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a", .nodes = &.{"N.md"} }}, &.{
        "z/last.java",
        "a/first.java",
        "m/middle.java",
    });
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 3), view.unassignedCount());
    var it = view.unassignedIter();
    try testing.expectEqualStrings("z/last.java", it.next().?);
    try testing.expectEqualStrings("a/first.java", it.next().?);
    try testing.expectEqualStrings("m/middle.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());

    // An unassigned path is not in the record table, and must not be findable
    // there: "claimed by nobody" and "not enumerated" are different answers.
    try testing.expectEqual(@as(?u32, null), view.find("a/first.java"));
}

test "lookup is a binary search, and a miss is a miss" {
    const gpa = testing.allocator;
    var entries: [500]Entry = undefined;
    var names: [500][8]u8 = undefined;
    for (&entries, &names, 0..) |*e, *n, i| {
        _ = std.fmt.bufPrint(n, "p{d:0>5}.j", .{i}) catch unreachable;
        e.* = .{ .path = n, .nodes = &.{"N.md"} };
    }
    const bytes = try encode(gpa, &entries, &.{});
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(?u32, 0), view.find("p00000.j"));
    try testing.expectEqual(@as(?u32, 250), view.find("p00250.j"));
    try testing.expectEqual(@as(?u32, 499), view.find("p00499.j"));
    try testing.expectEqual(@as(?u32, null), view.find("p00500.j"));
    try testing.expectEqual(@as(?u32, null), view.find(""));

    // One interned name for 500 paths.
    try testing.expectEqual(@as(u32, 1), view.nodeCount());
    try testing.expectEqual(@as(?u32, 0), view.findNode("N.md"));
    try testing.expectEqual(@as(?u32, null), view.findNode("Missing.md"));
}

test "an empty index is a valid index, not a special case" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{}, &.{});
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 0), view.count());
    try testing.expectEqual(@as(u32, 0), view.nodeCount());
    try testing.expectEqual(@as(u32, 0), view.unassignedCount());
    try testing.expectEqual(@as(?u32, null), view.find("anything"));
    var it = view.unassignedIter();
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "an index with only unassigned paths is valid too" {
    // What a first `/synapse-init` produces before any node exists: every
    // enumerated file is unassigned and the record table is empty.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{}, &.{ "a.java", "b.java" });
    defer gpa.free(bytes);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 0), view.count());
    try testing.expectEqual(@as(u32, 2), view.unassignedCount());
    var it = view.unassignedIter();
    try testing.expectEqualStrings("a.java", it.next().?);
    try testing.expectEqualStrings("b.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "unsorted input is refused rather than encoded into a broken search" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unsorted, encode(gpa, &.{
        .{ .path = "b", .nodes = &.{"N.md"} },
        .{ .path = "a", .nodes = &.{"N.md"} },
    }, &.{}));
    // A duplicate is unsorted too: two records for one path make `find`'s
    // answer depend on where the search happened to land.
    try testing.expectError(error.Unsorted, encode(gpa, &.{
        .{ .path = "a", .nodes = &.{"N.md"} },
        .{ .path = "a", .nodes = &.{"M.md"} },
    }, &.{}));
    // Same argument one level down: callers of `nodes` are promised order.
    try testing.expectError(error.UnsortedNodes, encode(gpa, &.{
        .{ .path = "a", .nodes = &.{ "Z.md", "A.md" } },
    }, &.{}));
    try testing.expectError(error.UnsortedNodes, encode(gpa, &.{
        .{ .path = "a", .nodes = &.{ "A.md", "A.md" } },
    }, &.{}));
}

test "a record with no owner is refused, because unassigned says it better" {
    const gpa = testing.allocator;
    try testing.expectError(error.NoNodes, encode(gpa, &.{
        .{ .path = "orphan.java", .nodes = &.{} },
    }, &.{}));
}

test "an unassigned path with a newline in it is refused, not split" {
    const gpa = testing.allocator;
    try testing.expectError(error.PathContainsNewline, encode(gpa, &.{}, &.{"two\nlines.java"}));
}

test "a bumped version rebuilds rather than misreads" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .nodes = &.{"N.md"} }}, &.{});
    defer gpa.free(bytes);

    // A different version is the case that matters: the bytes are ours, they
    // are intact, and reading them with this build's field offsets would
    // produce plausible nonsense rather than an error.
    std.mem.writeInt(u32, bytes[8..12], version + 1, .little);
    try testing.expectError(error.VersionMismatch, parse(bytes));

    std.mem.writeInt(u32, bytes[8..12], version, .little);
    _ = try parse(bytes);
}

test "the JSON this replaces is recognised as not ours, not misparsed" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .nodes = &.{"N.md"} }}, &.{});
    defer gpa.free(bytes);

    try testing.expectError(error.Truncated, parse(bytes[0 .. Header.wire_size - 1]));

    // Long enough to clear the header, so this exercises the magic check and
    // not the length check -- `_index.json` is far bigger than 64 bytes, and
    // finding one at this path is the case that has to be recognised, because
    // for one release every installed machine will have one.
    const json =
        \\{"src/A.java": ["Alpha.md"], "src/B.java": ["Beta.md"], "_unassigned": ["src/C.java"]}
    ;
    try testing.expect(json.len > Header.wire_size);
    try testing.expectError(error.NotAnIndex, parse(json));

    // A flipped byte in the path region. The structure is unchanged, so only
    // the checksum can catch it.
    const paths_off = std.mem.readInt(u64, bytes[24..32], .little);
    bytes[@intCast(paths_off)] ^= 0xff;
    try testing.expectError(error.ChecksumMismatch, parse(bytes));
}

test "a record pointing outside its region is refused, not followed" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .nodes = &.{"N.md"} }}, &.{});
    defer gpa.free(bytes);

    // ids_at past the end of the id region. Left unchecked this is an
    // out-of-bounds read on a mapping, from a file any process can write to.
    std.mem.writeInt(u32, bytes[64 + 10 ..][0..4], 9999, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[64..]), .little);
    try testing.expectError(error.OffsetOutOfRange, parse(bytes));
}

test "a node id naming no node is refused" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{.{ .path = "a.ml", .nodes = &.{"N.md"} }}, &.{});
    defer gpa.free(bytes);

    // The id region holds one id, 0. Point it at a node that does not exist:
    // unchecked, `nodeName` would read a Node struct out of the name bytes.
    const ids_off = std.mem.readInt(u64, bytes[32..40], .little);
    std.mem.writeInt(u32, bytes[@intCast(ids_off)..][0..4], 7, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[64..]), .little);
    try testing.expectError(error.OffsetOutOfRange, parse(bytes));
}

test "an unassigned region that disagrees with its count is refused" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &.{}, &.{ "a.java", "b.java" });
    defer gpa.free(bytes);

    // Claim three where two are stored. `Iterator.next` unwraps its scan on
    // the strength of the region being well-formed, so this has to fail at
    // parse rather than at iteration.
    std.mem.writeInt(u32, bytes[20..24], 3, .little);
    try testing.expectError(error.OffsetOutOfRange, parse(bytes));
}

/// The entries `testdata/v1.bin` holds, in its order. Two nodes claim
/// `src/Shared.java`, and `src/Orphan.java` is enumerated but claimed by
/// nobody -- the three cases a reader has to tell apart.
const fixture_entries = [_]Entry{
    .{ .path = "src/Alpha.java", .nodes = &.{"Alpha subsystem.md"} },
    .{ .path = "src/Beta.java", .nodes = &.{"Beta subsystem.md"} },
    .{ .path = "src/Shared.java", .nodes = &.{ "Alpha subsystem.md", "Beta subsystem.md" } },
};

const fixture_unassigned = [_][]const u8{ "src/Orphan.java", "docs/notes.md" };

test "encode reproduces the committed fixture byte for byte" {
    // `testdata/v1.bin` was generated from this file's layout comment by a
    // separate implementation, not by `encode`. So this comparison is the doc
    // checked against the code: if they ever disagree, one of them is wrong
    // and this says so, which neither an encode-then-parse round-trip nor a
    // fixture produced by the encoder itself could.
    const gpa = testing.allocator;
    const bytes = try encode(gpa, &fixture_entries, &fixture_unassigned);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, @embedFile("testdata/v1.bin"), bytes);
}

test "the committed v1 fixture still decodes" {
    // Frozen bytes, not bytes this build produced. Every other test here
    // encodes and then reads back, so all of them would keep passing through a
    // change that altered the format in both directions at once. This one
    // fails the moment a v1 file stops being readable -- which is the thing an
    // installed machine's index actually is.
    const view = try parse(@embedFile("testdata/v1.bin"));
    try testing.expectEqual(@as(u32, 3), view.count());
    try testing.expectEqual(@as(u32, 2), view.nodeCount());
    try testing.expectEqual(@as(u32, 2), view.unassignedCount());

    var buf: [max_nodes_per_path][]const u8 = undefined;

    try testing.expectEqualStrings("src/Alpha.java", view.path(view.record(0)));
    const one = view.nodes(view.record(0), &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("Alpha subsystem.md", one[0]);

    // The multi-claimant case, which is the whole reason a record carries a
    // count rather than a single node.
    try testing.expectEqualStrings("src/Shared.java", view.path(view.record(2)));
    const both = view.nodes(view.record(2), &buf);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualStrings("Alpha subsystem.md", both[0]);
    try testing.expectEqualStrings("Beta subsystem.md", both[1]);

    try testing.expectEqual(@as(?u32, 1), view.find("src/Beta.java"));
    try testing.expectEqual(@as(?u32, null), view.find("src/Missing.java"));

    // Enumerated but unowned: absent from the record table, present in the
    // unassigned list, and the order it was given in preserved.
    try testing.expectEqual(@as(?u32, null), view.find("src/Orphan.java"));
    var it = view.unassignedIter();
    try testing.expectEqualStrings("src/Orphan.java", it.next().?);
    try testing.expectEqualStrings("docs/notes.md", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}
