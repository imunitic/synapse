//! The reverse index: which nodes claim a source path, and which paths no node
//! claims.
//!
//! **The storage is `index_map/format.zig`, not JSON.** That file carries why;
//! the short version is that `_index.json` was 26 MB for syrius3, every reader
//! of it was a `jq` invocation, and it sat in the vault behind an HTTP PUT
//! despite being derived, gitignored and never travelling anywhere. This layer
//! is the part that touches a file: mapping one to read, and grouping unordered
//! `(path, node)` pairs into one to write.
//!
//! The grouping is here rather than in the caller because it is the one piece
//! of real logic in the pipeline. `synapse-build-index.sh` emits a pair per
//! (list, path) in whatever order the lists happened to be walked, and the
//! format demands paths strictly ascending with each path's nodes strictly
//! ascending. Getting that wrong does not fail loudly -- it encodes fine and
//! makes every later binary search wrong -- so it belongs somewhere with tests
//! rather than in a shell pipeline's argument order.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const format = @import("index_map/format.zig");

pub const max_nodes_per_path = format.max_nodes_per_path;
pub const ParseError = format.ParseError;

/// One claim, as `synapse-build-index.sh` emits them: unordered, and repeated
/// per node for a path several nodes claim.
pub const Pair = struct {
    path: []const u8,
    node: []const u8,
};

pub const BuildError = format.EncodeError;

/// Group unordered pairs into the file's bytes. Duplicate `(path, node)` pairs
/// collapse; a path appearing under several nodes keeps all of them.
///
/// Owns nothing it is given and returns one allocation the caller frees.
pub fn build(
    gpa: Allocator,
    pairs: []const Pair,
    unassigned: []const []const u8,
) BuildError![]u8 {
    // Insertion-ordered so the grouping is deterministic before the sort, which
    // makes a failure reproducible rather than dependent on hash iteration.
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
        // Collapse duplicates in place: two identical pairs are one claim, and
        // `format.encode` refuses a repeated name rather than storing it twice.
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

/// The index's bytes again with `extra` added to the unassigned list, or null
/// when it is already there.
///
/// A whole re-encode, because every region's offsets move when one grows. That
/// is affordable precisely where it is used: the staleness hook reaches here
/// only for a file no node claims and that is not already listed, which is a
/// genuinely new path rather than something that happens per edit. What it
/// replaces is a 27 MB `jq` read-modify-write followed by a 27 MB HTTPS PUT, so
/// even the uncommon case gets cheaper.
///
/// Appends rather than inserting in order: the unassigned list has never been
/// sorted, and its reader iterates the whole thing.
pub fn withUnassigned(
    gpa: Allocator,
    view: format.View,
    extra: []const u8,
) BuildError!?[]u8 {
    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);

    var it = view.unassignedIter();
    while (it.next()) |p| {
        // Idempotent: the hook fires on every edit, and re-listing a path it
        // already queued would grow the file without bound.
        if (std.mem.eql(u8, p, extra)) return null;
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
    // `names` may have reallocated while it grew, so the slices above are fixed
    // up once it has stopped growing rather than trusted as they were taken.
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

/// Write `bytes` to `path` via a temporary file and a rename, so a concurrent
/// reader sees either the old index whole or the new one -- never half of
/// either. The staleness hook reads this file on every edit, so that window is
/// not theoretical.
pub fn writeFile(gpa: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();

    // `Io.Dir.path` rather than `std.fs.path`, which the purity gate forbids
    // core from naming. The functions are the same -- std aliases them there --
    // and they are pure string work with no system access.
    if (Io.Dir.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);

    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.rename(tmp, cwd, path, io);
}

/// An index file, mapped. Every slice a lookup returns points into the mapping,
/// so it is valid until `close`.
pub const Map = struct {
    /// Borrowed from the caller and outliving this struct is the caller's
    /// problem, as with every other path in core.
    path: []const u8,
    view: format.View,
    map: ?Io.File.MemoryMap = null,
    /// Why the file on disk was not used, when it was not. Null means it was
    /// read, or was simply absent. Nothing here prints; a caller that wants to
    /// say something about a discarded index reads this.
    discarded: ?format.ParseError = null,

    /// Never accessed for a zero-entry index -- every count is 0, so no record,
    /// path or id offset is ever computed from it.
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

    /// Absent, unreadable, damaged, or written by another version: all of them
    /// open as an empty index rather than an error, and `discarded` says which.
    ///
    /// The same "it is derived" argument the tags cache spends, for the same
    /// reason: everything here is recomputable from the work dir's lists, so a
    /// migration path would carry risk to save one rebuild. The cost is that a
    /// file which is not an index at all is replaced by the next build --
    /// including, on the first run after this change, an `_index.json` left at
    /// this path. That is the intended migration, not an accident.
    ///
    /// No allocator: the mapping is the storage and `format.parse` allocates
    /// nothing.
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
            // A lookup should fault in the pages it reads, not the file. The
            // staleness hook resolves one path per edit and has a budget
            // measured against a person waiting.
            .populate = false,
        }) catch return self;
        errdefer map.destroy(io);

        self.view = format.parse(map.memory) catch |e| {
            self.discarded = e;
            map.destroy(io);
            return self;
        };
        self.map = map;
        // The mapping keeps its own reference to the file, so the descriptor
        // opened here is only needed until `createMemoryMap` succeeds.
        close_file = false;
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

    /// The nodes claiming `path`, ascending, written into `out` -- which must
    /// hold `max_nodes_per_path`. Null means no node claims it, which is an
    /// ordinary answer: the path may be unassigned, or not enumerated at all.
    /// Those two are different, and `unassignedIter` is where the difference
    /// lives.
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
    // The input order is the one `synapse-build-index.sh` produces: a pair per
    // (list, path), so one path's claimants arrive far apart and no path order
    // is guaranteed at all.
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
    // Two identical pairs would reach `format.encode` as a duplicate name and
    // be refused. Collapsing them here is the difference between a build that
    // works and one that fails on a repo where two lists name the same file
    // under the same node.
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

/// An index under a temp directory, addressed by absolute path so the tests do
/// not depend on the process's cwd.
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
    // The migration case: for one release, every installed machine has JSON
    // sitting exactly here. It must open as an empty index with a reason, so
    // the next build replaces it.
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
