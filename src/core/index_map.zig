//! The reverse index: which nodes claim a source path, and which paths no
//! node claims.
//!
//! Storage is `index_map/format.zig`, not JSON -- `_index.json` grew to
//! 26 MB on a real large repo, read by `jq`, and sat in the vault behind
//! an HTTP PUT despite being derived and gitignored. This layer maps the
//! file to read, and groups unordered `(path, node)` pairs into one to
//! write: the format
//! demands strictly-ascending paths and node lists, which the emitting
//! shell pipeline does not guarantee, so grouping belongs here, with tests.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const format = @import("index_map/format.zig");

pub const max_nodes_per_path = format.max_nodes_per_path;
pub const ParseError = format.ParseError;

/// One claim, unordered, repeated per node for a path several nodes claim.
pub const Pair = struct {
    path: []const u8,
    node: []const u8,
};

pub const BuildError = format.EncodeError;

/// Group unordered pairs into the file's bytes. Duplicate `(path, node)`
/// pairs collapse; a path under several nodes keeps all of them. Owns
/// nothing it is given; returns one allocation the caller frees.
pub fn build(
    gpa: Allocator,
    pairs: []const Pair,
    unassigned: []const []const u8,
) BuildError![]u8 {
    // Insertion-ordered, so grouping is deterministic before the sort.
    var byPath: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        for (byPath.values()) |*v| v.deinit(gpa);
        byPath.deinit(gpa);
    }

    for (pairs) |p| {
        const gop = try byPath.getOrPut(gpa, p.path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, p.node);
    }

    var entries = try gpa.alloc(format.Entry, byPath.count());
    defer gpa.free(entries);

    for (byPath.keys(), byPath.values(), 0..) |path, *nodes, i| {
        std.mem.sort([]const u8, nodes.items, {}, lessByBytes);
        // Collapse duplicates in place: format.encode refuses a repeated name.
        var n: usize = 0;
        for (nodes.items, 0..) |name, k| {
            if (k > 0 and std.mem.eql(u8, nodes.items[k - 1], name)) continue;
            nodes.items[n] = name;
            n += 1;
        }
        entries[i] = .{ .path = path, .nodes = nodes.items[0..n] };
    }

    std.mem.sort(format.Entry, entries, {}, lessEntryByPath);
    return format.encode(gpa, entries, unassigned);
}

/// The index's bytes again with `extra` added to the unassigned list, or
/// null when already there. A whole re-encode, since every region's offsets
/// move when one grows -- affordable since this only fires for a genuinely
/// new unclaimed path, not per edit, and replaces what was a 27 MB `jq`
/// read-modify-write plus HTTPS PUT. Appended, not inserted in order: the
/// unassigned list was never sorted and its reader iterates all of it.
pub fn withUnassigned(
    gpa: Allocator,
    view: format.View,
    extra: []const u8,
) BuildError!?[]u8 {
    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);

    var it = view.unassignedIter();
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, extra)) return null; // idempotent: don't grow unbounded
        try unassigned.append(gpa, p);
    }
    try unassigned.append(gpa, extra);

    var entries = try gpa.alloc(format.Entry, view.count());
    defer gpa.free(entries);
    // One flat allocation for every node-name slice, indexed by the running
    // offset each entry records -- a slice per entry would be `view.count()`
    // small allocations for no gain.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(gpa);

    var i: u32 = 0;
    while (i < view.count()) : (i += 1) {
        const r = view.record(i);
        const at = names.items.len;
        var k: u8 = 0;
        while (k < r.ids_len) : (k += 1)
            try names.append(gpa, view.nodeName(view.nodeId(r, k)));
        entries[i] = .{ .path = view.path(r), .nodes = names.items[at..][0..r.ids_len] };
    }
    // `names` may have reallocated while growing, so slices are fixed up now.
    var off: usize = 0;
    i = 0;
    while (i < view.count()) : (i += 1) {
        const n = view.record(i).ids_len;
        entries[i].nodes = names.items[off..][0..n];
        off += n;
    }

    return try format.encode(gpa, entries, unassigned.items);
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessEntryByPath(_: void, a: format.Entry, b: format.Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Write `bytes` to `path` via a temp file and a rename, so a concurrent
/// reader (the staleness hook, on every edit) sees the old index whole or
/// the new one, never half of either.
pub fn writeFile(gpa: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();

    // `Io.Dir.path`, not `std.fs.path` -- the purity gate forbids core
    // naming the latter, though they're pure string work either way.
    if (Io.Dir.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);

    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.rename(tmp, cwd, path, io);
}

/// An index file, mapped. Every slice a lookup returns points into the
/// mapping, valid until `close`.
pub const Map = struct {
    /// Borrowed; outliving this struct is the caller's problem.
    path: []const u8,
    view: format.View,
    map: ?Io.File.MemoryMap = null,
    /// Why the file on disk was not used. Null means it was read, or was
    /// simply absent; nothing here prints, a caller reads this to say why.
    discarded: ?format.ParseError = null,

    /// Every count is 0, so nothing is ever computed from this for a
    /// zero-entry index.
    const no_entries: format.View = .{
        .bytes = &.{},
        .header = .{
            .version = format.version,
            .entry_count = 0,
            .node_count = 0,
            .unassigned_count = 0,
            .paths_off = 0,
            .ids_off = 0,
            .nodes_off = 0,
            .unassigned_off = 0,
            .crc32 = 0,
        },
    };

    /// Absent, unreadable, damaged, or from another version: all open as an
    /// empty index rather than an error, `discarded` says which. Recomputable
    /// from the work dir's lists, so no migration path -- the next build just
    /// replaces whatever was there, including a leftover `_index.json`.
    ///
    /// No allocator: the mapping is the storage, `format.parse` allocates nothing.
    pub fn open(io: Io, path: []const u8) !Map {
        var self: Map = .{ .path = path, .view = no_entries };

        const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return self;
        var close_file = true;
        defer if (close_file) file.close(io);

        const size = (file.stat(io) catch return self).size;
        if (size == 0) return self;

        var map = file.createMemoryMap(io, .{
            .len = @intCast(size),
            .protection = .{ .read = true, .write = false },
            .populate = false, // fault in only the pages a lookup reads
        }) catch return self;
        errdefer map.destroy(io);

        self.view = format.parse(map.memory) catch |e| {
            self.discarded = e;
            map.destroy(io);
            return self;
        };
        self.map = map;
        close_file = false; // the mapping keeps its own reference now
        return self;
    }

    pub fn close(self: *Map, io: Io) void {
        if (self.map) |*m| {
            m.file.close(io);
            m.destroy(io);
        }
        self.map = null;
        self.view = no_entries;
    }

    /// Nodes claiming `path`, ascending, into `out` (must hold
    /// `max_nodes_per_path`). Null is ordinary: unassigned, or not
    /// enumerated -- `unassignedIter` is where that distinction lives.
    pub fn nodesFor(self: *const Map, path: []const u8, out: [][]const u8) ?[][]const u8 {
        const i = self.view.find(path) orelse return null;
        return self.view.nodes(self.view.record(i), out);
    }

    pub fn count(self: *const Map) u32 {
        return self.view.count();
    }

    pub fn nodeCount(self: *const Map) u32 {
        return self.view.nodeCount();
    }

    pub fn unassignedCount(self: *const Map) u32 {
        return self.view.unassignedCount();
    }

    pub fn unassignedIter(self: *const Map) format.View.Iterator {
        return self.view.unassignedIter();
    }
};

const testing = std.testing;

test "pairs in any order group into a valid index" {
    const gpa = testing.allocator;
    const bytes = try build(gpa, &.{
        .{ .path = "z.java", .node = "Zeta.md" },
        .{ .path = "a.java", .node = "Zeta.md" },
        .{ .path = "m.java", .node = "Alpha.md" },
        .{ .path = "a.java", .node = "Alpha.md" },
    }, &.{});
    defer gpa.free(bytes);

    const view = try format.parse(bytes);
    try testing.expectEqual(@as(u32, 3), view.count());
    try testing.expectEqual(@as(u32, 2), view.nodeCount());

    var buf: [max_nodes_per_path][]const u8 = undefined;
    // a.java came in under Zeta then Alpha; it comes out ascending.
    try testing.expectEqualStrings("a.java", view.path(view.record(0)));
    const both = view.nodes(view.record(0), &buf);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualStrings("Alpha.md", both[0]);
    try testing.expectEqualStrings("Zeta.md", both[1]);

    try testing.expectEqualStrings("m.java", view.path(view.record(1)));
    try testing.expectEqualStrings("z.java", view.path(view.record(2)));
}

test "a repeated pair is one claim, not two" {
    const gpa = testing.allocator;
    const bytes = try build(gpa, &.{
        .{ .path = "a.java", .node = "N.md" },
        .{ .path = "a.java", .node = "N.md" },
    }, &.{});
    defer gpa.free(bytes);

    const view = try format.parse(bytes);
    var buf: [max_nodes_per_path][]const u8 = undefined;
    const got = view.nodes(view.record(0), &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("N.md", got[0]);
}

test "an index with no pairs at all is buildable" {
    const gpa = testing.allocator;
    const bytes = try build(gpa, &.{}, &.{ "a.java", "b.java" });
    defer gpa.free(bytes);

    const view = try format.parse(bytes);
    try testing.expectEqual(@as(u32, 0), view.count());
    try testing.expectEqual(@as(u32, 2), view.unassignedCount());
}

test "an absent file opens as an empty index, not an error" {
    var map = try Map.open(testing.io, "definitely/not/here/_index.bin");
    defer map.close(testing.io);
    try testing.expectEqual(@as(u32, 0), map.count());
    try testing.expectEqual(@as(?format.ParseError, null), map.discarded);
    var buf: [max_nodes_per_path][]const u8 = undefined;
    try testing.expectEqual(@as(?[][]const u8, null), map.nodesFor("anything", &buf));
}

/// An index under a temp directory, addressed by absolute path so tests
/// don't depend on the process's cwd.
const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [Io.Dir.max_path_bytes]u8 = undefined,

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn indexPath(f: *Fixture, gpa: Allocator, io: Io) ![]u8 {
        const dir = f.buf[0..try f.tmp.dir.realPath(io, &f.buf)];
        return std.fmt.allocPrint(gpa, "{s}/_index.bin", .{dir});
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }
};

test "written and mapped back, a path resolves to its nodes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    const bytes = try build(gpa, &.{
        .{ .path = "src/Shared.java", .node = "Beta.md" },
        .{ .path = "src/Alpha.java", .node = "Alpha.md" },
        .{ .path = "src/Shared.java", .node = "Alpha.md" },
    }, &.{"src/Orphan.java"});
    defer gpa.free(bytes);
    try writeFile(gpa, io, path, bytes);

    var map = try Map.open(io, path);
    defer map.close(io);
    try testing.expectEqual(@as(?format.ParseError, null), map.discarded);
    try testing.expectEqual(@as(u32, 2), map.count());
    try testing.expectEqual(@as(u32, 1), map.unassignedCount());

    var buf: [max_nodes_per_path][]const u8 = undefined;
    const one = map.nodesFor("src/Alpha.java", &buf).?;
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("Alpha.md", one[0]);

    const both = map.nodesFor("src/Shared.java", &buf).?;
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualStrings("Alpha.md", both[0]);
    try testing.expectEqualStrings("Beta.md", both[1]);

    // Unassigned is reachable, and deliberately not findable as a record.
    try testing.expectEqual(@as(?[][]const u8, null), map.nodesFor("src/Orphan.java", &buf));
    var it = map.unassignedIter();
    try testing.expectEqualStrings("src/Orphan.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "adding an unassigned path preserves every claim, and is idempotent" {
    const gpa = testing.allocator;
    const bytes = try build(gpa, &.{
        .{ .path = "src/Alpha.java", .node = "Alpha.md" },
        .{ .path = "src/Shared.java", .node = "Beta.md" },
        .{ .path = "src/Shared.java", .node = "Alpha.md" },
    }, &.{"old.java"});
    defer gpa.free(bytes);

    const grown = (try withUnassigned(gpa, try format.parse(bytes), "new.java")).?;
    defer gpa.free(grown);

    const view = try format.parse(grown);
    try testing.expectEqual(@as(u32, 2), view.count());
    try testing.expectEqual(@as(u32, 2), view.nodeCount());
    try testing.expectEqual(@as(u32, 2), view.unassignedCount());

    // The multi-claimant record is the one a careless re-encode would flatten.
    var buf: [max_nodes_per_path][]const u8 = undefined;
    const both = view.nodes(view.record(1), &buf);
    try testing.expectEqualStrings("src/Shared.java", view.path(view.record(1)));
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualStrings("Alpha.md", both[0]);
    try testing.expectEqualStrings("Beta.md", both[1]);

    var it = view.unassignedIter();
    try testing.expectEqualStrings("old.java", it.next().?);
    try testing.expectEqualStrings("new.java", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());

    // Already listed: null rather than a file that grows on every edit.
    try testing.expectEqual(
        @as(?[]u8, null),
        try withUnassigned(gpa, view, "new.java"),
    );
}

test "an _index.json left at the path is discarded, not misread" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data =
        \\{"src/A.java": ["Alpha.md"], "src/B.java": ["Beta.md"], "_unassigned": ["src/C.java"]}
        ,
    });

    var map = try Map.open(io, path);
    defer map.close(io);
    try testing.expectEqual(@as(u32, 0), map.count());
    try testing.expectEqual(@as(?format.ParseError, error.NotAnIndex), map.discarded);
}
