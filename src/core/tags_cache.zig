//! The tags cache: which files have been tagged, at what content hash, with
//! what result. The port of `claude/lib/synapse/synapse-tags-cache.sh`, minus
//! the part that actually tags -- deciding *what* needs tagging, holding the
//! answers, and projecting them into `_refs.tsv` all live here; running the
//! extractor over the shortfall is an app's job, because core spawns nothing.
//!
//! The behaviour is the script's, deliberately. A path is current when the
//! cache holds it at exactly the requested hash. A commit merges onto what is
//! already there rather than replacing it, so two callers covering different
//! subsets of a repo do not erase each other's work. A file with no usable
//! grammar is recorded as `unsupported` with no tags rather than left out, or
//! it would be re-attempted on every call forever.
//!
//! Two things are new.
//!
//! **Eviction.** Nothing in the shell version ever removed a row, which is why
//! `_refs.tsv` can name a caller in a file that was deleted months ago: the
//! projection faithfully reproduces whatever the cache still holds. `commit`
//! takes removals, and they are the only way a row leaves.
//!
//! **The storage is `tags_cache/format.zig`, not JSON.** That is what makes
//! `needsTagging` cheap: it compares hashes in the record table and never
//! touches the payload region, so answering "which of these 4,000 files
//! changed?" reads a few megabytes rather than parsing every tag line of every
//! entry -- 5.0s of `jq` over syrius3's 828 MB cache, measured.

const std = @import("std");
const format = @import("tags_cache/format.zig");
const tag_line = @import("tag_line.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What the cache knows about one path. No `path` field: you found it by one.
pub const Entry = struct {
    hash: [20]u8,
    /// The extractor's output for this file, newline-separated, unindented.
    /// Empty for a file that parsed and declared nothing -- which is not the
    /// same as `unsupported`, and the cache is the place that has to keep them
    /// apart.
    tags: []const u8,
    unsupported: bool = false,
};

/// A path and the content hash the caller currently sees for it.
pub const PathHash = struct {
    path: []const u8,
    hash: [20]u8,
};

pub const Update = struct {
    path: []const u8,
    entry: Entry,
};

/// A cache file, mapped. Every slice a lookup returns points into the mapping,
/// so it is valid until `close` or the next `commit`.
pub const Cache = struct {
    /// Borrowed from the caller and outliving this struct is the caller's
    /// problem, as with every other path in core.
    path: []const u8,
    view: format.View,
    map: ?Io.File.MemoryMap = null,
    /// Why the file on disk was not used, when it was not. Null means it was
    /// read, or was simply absent. A caller that wants to say something about
    /// a discarded cache reads this; nothing here prints.
    discarded: ?format.ParseError = null,

    /// Never accessed for a zero-entry cache -- `count` is 0, so no record,
    /// path or payload offset is ever computed from it.
    const no_entries: format.View = .{
        .bytes = &.{},
        .header = .{
            .version = format.version,
            .entry_count = 0,
            .paths_off = 0,
            .blob_off = 0,
            .crc32 = 0,
        },
    };

    /// Absent, unreadable, damaged, or written by another version: all of them
    /// open as an empty cache rather than an error.
    ///
    /// This is the one place the "it is a cache" argument gets spent, so it is
    /// worth being explicit about what it buys and costs. Everything in here
    /// can be recomputed by re-tagging, so a migration path would carry risk
    /// to save one rebuild. The cost is that a file which is not a cache at
    /// all gets overwritten by the next commit -- including, on the first run
    /// after this change, the JSON cache the shell version left behind. That
    /// is the intended migration and not an accident: the JSON is obsolete the
    /// moment this code runs.
    ///
    /// No allocator: the mapping is the storage and `format.parse` allocates
    /// nothing, so the plan's `open(gpa, io, path)` had one it never used.
    pub fn open(io: Io, path: []const u8) !Cache {
        var self: Cache = .{ .path = path, .view = no_entries };

        const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return self;
        var close_file = true;
        defer if (close_file) file.close(io);

        const size = (file.stat(io) catch return self).size;
        if (size == 0) return self;

        var map = file.createMemoryMap(io, .{
            .len = @intCast(size),
            .protection = .{ .read = true, .write = false },
            // Prefaulting an 800 MB mapping is the exact cost this format
            // exists to avoid; a reader that wants one file's tags should
            // fault in one file's pages. Ignored outside Linux, so it changes
            // nothing measured here -- it is set so it does not start costing
            // something the day the hooks run there.
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

    pub fn close(self: *Cache, io: Io) void {
        if (self.map) |*m| {
            m.file.close(io);
            m.destroy(io);
        }
        self.map = null;
        self.view = no_entries;
    }

    pub fn get(self: *const Cache, path: []const u8) ?Entry {
        const i = self.view.find(path) orelse return null;
        const r = self.view.record(i);
        return .{
            .hash = r.hash,
            .tags = self.view.tags(r),
            .unsupported = r.unsupported(),
        };
    }

    pub fn count(self: *const Cache) u32 {
        return self.view.count();
    }

    /// The requested pairs this cache does not already hold at that hash, in
    /// the order given, deduplicated by path.
    ///
    /// Touches the record table only. The payload region -- which is all but a
    /// few megabytes of the file -- is never read, and that is the whole
    /// reason for the format.
    ///
    /// Deduplication matters because the answer feeds an extractor: a path
    /// listed twice would otherwise be tagged twice, which the shell version
    /// avoided by `sort -u`ing its input. First occurrence wins.
    pub fn needsTagging(
        self: *const Cache,
        gpa: Allocator,
        requested: []const PathHash,
    ) ![]PathHash {
        var out: std.ArrayListUnmanaged(PathHash) = .empty;
        errdefer out.deinit(gpa);

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);

        for (requested) |want| {
            if ((try seen.fetchPut(gpa, want.path, {})) != null) continue;
            if (self.view.find(want.path)) |i| {
                if (std.mem.eql(u8, &self.view.record(i).hash, &want.hash)) continue;
            }
            try out.append(gpa, want);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Apply `updates`, drop `removals`, write the result and rename it over
    /// the original. Returns the number of rows actually removed -- a removal
    /// naming a path the cache never held is not an error, and not counted.
    ///
    /// The mapping is replaced by one over the new file, so the cache stays
    /// usable and every previously returned slice is invalidated.
    pub fn commit(
        self: *Cache,
        gpa: Allocator,
        io: Io,
        updates: []const Update,
        removals: []const []const u8,
    ) !usize {
        var merged: std.StringHashMapUnmanaged(Entry) = .empty;
        defer merged.deinit(gpa);

        var i: u32 = 0;
        while (i < self.view.count()) : (i += 1) {
            const r = self.view.record(i);
            try merged.put(gpa, self.view.path(r), .{
                .hash = r.hash,
                .tags = self.view.tags(r),
                .unsupported = r.unsupported(),
            });
        }

        // Updates before removals, so removing a path that is also being
        // updated removes it. The alternative ordering makes the outcome
        // depend on argument order, which is worse than either answer.
        for (updates) |u| try merged.put(gpa, u.path, u.entry);

        var removed: usize = 0;
        for (removals) |p| {
            if (merged.remove(p)) removed += 1;
        }

        var entries = try gpa.alloc(format.Entry, merged.count());
        defer gpa.free(entries);
        var n: usize = 0;
        var it = merged.iterator();
        while (it.next()) |e| : (n += 1) {
            entries[n] = .{
                .path = e.key_ptr.*,
                .hash = e.value_ptr.hash,
                .tags = e.value_ptr.tags,
                .unsupported = e.value_ptr.unsupported,
            };
        }
        std.mem.sort(format.Entry, entries, {}, lessByPath);

        const bytes = try format.encode(gpa, entries);
        defer gpa.free(bytes);

        try self.replaceFile(gpa, io, bytes);
        return removed;
    }

    /// Write and rename, then re-map. Renaming rather than writing in place is
    /// what keeps a concurrent reader from seeing a half-written cache: on a
    /// POSIX filesystem it either sees the old file whole or the new one.
    fn replaceFile(self: *Cache, gpa: Allocator, io: Io, bytes: []const u8) !void {
        const cwd = Io.Dir.cwd();

        // `Io.Dir.path` rather than `std.fs.path`, which the purity gate
        // forbids core from naming. The functions are the same -- std aliases
        // them there -- and they are pure string work with no system access,
        // which is what the gate is actually about.
        if (Io.Dir.path.dirname(self.path)) |dir| cwd.createDirPath(io, dir) catch {};

        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{self.path});
        defer gpa.free(tmp);

        try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, self.path, io);

        self.close(io);
        self.* = try open(io, self.path);
    }

    /// Every cached tag as an `_refs.tsv` row, in path order.
    ///
    /// Streams the payload region once and holds one line at a time, because
    /// this runs over a whole repository's tags -- 828 MB on syrius3 -- and
    /// materialising that would defeat the point of keeping it out of line.
    ///
    /// An `unsupported` entry contributes nothing, having no tags. So does an
    /// evicted one, which is the point: the projection can only report what
    /// the cache still holds, which is why eviction had to exist before a
    /// deleted file could stop appearing here.
    ///
    /// Path order is not the order `_refs.tsv` is stored in. That file is
    /// `LC_ALL=C sort`ed by name and binary-searched with `look`, so whoever
    /// writes it sorts these rows first -- this emits them, it does not order
    /// them for the search.
    pub fn writeRefs(self: *const Cache, w: *std.Io.Writer) !usize {
        var rows: usize = 0;
        var i: u32 = 0;
        while (i < self.view.count()) : (i += 1) {
            const r = self.view.record(i);
            const path = self.view.path(r);
            var lines = std.mem.splitScalar(u8, self.view.tags(r), '\n');
            while (lines.next()) |line| {
                const tag = tag_line.parse(line) orelse continue;
                try tag_line.writeRefsRow(w, path, tag);
                rows += 1;
            }
        }
        return rows;
    }
};

fn lessByPath(_: void, a: format.Entry, b: format.Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const testing = std.testing;

fn h(comptime hex: *const [40]u8) [20]u8 {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// A cache under a temp directory, addressed by absolute path so the tests do
/// not depend on the process's cwd.
const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [Io.Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = &.{},

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn cachePath(f: *Fixture, gpa: Allocator, io: Io) ![]u8 {
        const dir = f.buf[0..try f.tmp.dir.realPath(io, &f.buf)];
        return std.fmt.allocPrint(gpa, "{s}/_tags_cache.bin", .{dir});
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }
};

test "an absent cache opens empty and needs everything" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    try testing.expectEqual(@as(u32, 0), cache.count());
    try testing.expectEqual(@as(?format.ParseError, null), cache.discarded);

    const need = try cache.needsTagging(gpa, &.{
        .{ .path = "a.java", .hash = h("11" ** 20) },
        .{ .path = "b.java", .hash = h("22" ** 20) },
    });
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 2), need.len);
}

test "commit then reopen: what went in comes back out" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .path = "src/A.java", .entry = .{ .hash = h("11" ** 20), .tags = "Alpha\tdef\n" } },
        .{ .path = "src/b.bin", .entry = .{ .hash = h("22" ** 20), .tags = "", .unsupported = true } },
    }, &.{});

    var reopened = try Cache.open(io, path);
    defer reopened.close(io);

    try testing.expectEqual(@as(u32, 2), reopened.count());
    const a = reopened.get("src/A.java").?;
    try testing.expectEqualStrings("Alpha\tdef\n", a.tags);
    try testing.expect(!a.unsupported);
    try testing.expect(reopened.get("src/b.bin").?.unsupported);
    try testing.expectEqual(@as(?Entry, null), reopened.get("src/Missing.java"));
}

test "needsTagging: only what is missing or has moved on" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "same.java", .entry = .{ .hash = h("11" ** 20), .tags = "" } },
        .{ .path = "changed.java", .entry = .{ .hash = h("22" ** 20), .tags = "" } },
    }, &.{});

    const need = try cache.needsTagging(gpa, &.{
        .{ .path = "same.java", .hash = h("11" ** 20) },
        .{ .path = "changed.java", .hash = h("99" ** 20) },
        .{ .path = "new.java", .hash = h("33" ** 20) },
    });
    defer gpa.free(need);

    try testing.expectEqual(@as(usize, 2), need.len);
    try testing.expectEqualStrings("changed.java", need[0].path);
    try testing.expectEqualStrings("new.java", need[1].path);
}

test "needsTagging deduplicates, so nothing is tagged twice" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    const need = try cache.needsTagging(gpa, &.{
        .{ .path = "a.java", .hash = h("11" ** 20) },
        .{ .path = "a.java", .hash = h("11" ** 20) },
        .{ .path = "b.java", .hash = h("22" ** 20) },
    });
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 2), need.len);
}

test "a file that parsed to nothing is current, and is not unsupported" {
    // The distinction the whole Outcome union exists for, asserted where it
    // finally matters: both entries hold zero bytes of tags, and only one of
    // them means "do not bother trying again".
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "empty.java", .entry = .{ .hash = h("11" ** 20), .tags = "" } },
        .{ .path = "nogrammar.bin", .entry = .{ .hash = h("22" ** 20), .tags = "", .unsupported = true } },
    }, &.{});

    try testing.expect(!cache.get("empty.java").?.unsupported);
    try testing.expect(cache.get("nogrammar.bin").?.unsupported);

    // Neither is re-tagged at the same hash. An unsupported file being
    // re-attempted on every call is the bug this recording prevents.
    const need = try cache.needsTagging(gpa, &.{
        .{ .path = "empty.java", .hash = h("11" ** 20) },
        .{ .path = "nogrammar.bin", .hash = h("22" ** 20) },
    });
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 0), need.len);
}

test "commit merges onto what is there rather than replacing it" {
    // Two callers covering different subsets of a repo -- a node write and a
    // query backfill -- must not erase each other.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "first.java", .entry = .{ .hash = h("11" ** 20), .tags = "One\n" } },
    }, &.{});
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "second.java", .entry = .{ .hash = h("22" ** 20), .tags = "Two\n" } },
    }, &.{});

    try testing.expectEqual(@as(u32, 2), cache.count());
    try testing.expectEqualStrings("One\n", cache.get("first.java").?.tags);
    try testing.expectEqualStrings("Two\n", cache.get("second.java").?.tags);
}

test "a re-commit of the same path replaces its entry, not adds one" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "a.java", .entry = .{ .hash = h("11" ** 20), .tags = "Old\n" } },
    }, &.{});
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "a.java", .entry = .{ .hash = h("22" ** 20), .tags = "New\n" } },
    }, &.{});

    try testing.expectEqual(@as(u32, 1), cache.count());
    try testing.expectEqualStrings("New\n", cache.get("a.java").?.tags);
    try testing.expectEqualSlices(u8, &h("22" ** 20), &cache.get("a.java").?.hash);
}

test "eviction: a removed path leaves the cache and the refs projection" {
    // The gap the shell version left. Nothing there ever removed a row, so
    // _refs.tsv kept naming callers in files that had been deleted -- the
    // projection was faithful, the cache was not.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    const alpha = "Alpha     \t | class   \tdef (14, 13) - (14, 18) `public class Alpha {`";
    const gone = "Gone      \t | class   \tdef (2, 13) - (2, 17) `public class Gone {`";

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "src/Alpha.java", .entry = .{ .hash = h("11" ** 20), .tags = alpha } },
        .{ .path = "src/Gone.java", .entry = .{ .hash = h("22" ** 20), .tags = gone } },
    }, &.{});

    var before: std.Io.Writer.Allocating = .init(gpa);
    defer before.deinit();
    try testing.expectEqual(@as(usize, 2), try cache.writeRefs(&before.writer));
    try testing.expect(std.mem.indexOf(u8, before.written(), "src/Gone.java") != null);

    const removed = try cache.commit(gpa, io, &.{}, &.{"src/Gone.java"});
    try testing.expectEqual(@as(usize, 1), removed);

    try testing.expectEqual(@as(u32, 1), cache.count());
    try testing.expectEqual(@as(?Entry, null), cache.get("src/Gone.java"));

    var after: std.Io.Writer.Allocating = .init(gpa);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 1), try cache.writeRefs(&after.writer));
    try testing.expect(std.mem.indexOf(u8, after.written(), "src/Gone.java") == null);
    try testing.expect(std.mem.indexOf(u8, after.written(), "src/Alpha.java") != null);

    // It stays gone across a reopen -- the removal is in the file, not just in
    // this process's view of it.
    var reopened = try Cache.open(io, path);
    defer reopened.close(io);
    try testing.expectEqual(@as(u32, 1), reopened.count());
}

test "evicting a path the cache never held is not an error, and not counted" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "kept.java", .entry = .{ .hash = h("11" ** 20), .tags = "" } },
    }, &.{});

    const removed = try cache.commit(gpa, io, &.{}, &.{ "never.java", "kept.java" });
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(u32, 0), cache.count());
}

test "removing a path that is also being updated removes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    const removed = try cache.commit(
        gpa,
        io,
        &.{.{ .path = "a.java", .entry = .{ .hash = h("11" ** 20), .tags = "X\n" } }},
        &.{"a.java"},
    );
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(u32, 0), cache.count());
}

test "the refs projection is the tag-line codec's rows, in path order" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "z.java", .entry = .{
            .hash = h("11" ** 20),
            .tags = "Zed       \t | class   \tdef (1, 13) - (1, 16) `public class Zed {`",
        } },
        .{ .path = "a.java", .entry = .{
            .hash = h("22" ** 20),
            .tags = "Ay        \t | class   \tdef (0, 13) - (0, 15) `public class Ay {`\n" ++
                "call      \t | call    \tref (3, 4) - (3, 8) `call();`",
        } },
        .{ .path = "none.bin", .entry = .{ .hash = h("33" ** 20), .tags = "", .unsupported = true } },
    }, &.{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 3), try cache.writeRefs(&out.writer));

    try testing.expectEqualStrings(
        "Ay\tdef\tclass\ta.java:0\tpublic class Ay {\n" ++
            "call\tref\tcall\ta.java:3\tcall();\n" ++
            "Zed\tdef\tclass\tz.java:1\tpublic class Zed {\n",
        out.written(),
    );
}

test "a cache written by another version is discarded, not misread" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    const bytes = try format.encode(gpa, &.{
        .{ .path = "a.java", .hash = h("11" ** 20), .tags = "X\n" },
    });
    defer gpa.free(bytes);
    std.mem.writeInt(u32, bytes[8..12], format.version + 1, .little);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    try testing.expectEqual(@as(u32, 0), cache.count());
    try testing.expectEqual(@as(?format.ParseError, error.VersionMismatch), cache.discarded);

    // And it rebuilds over the top rather than refusing forever.
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "a.java", .entry = .{ .hash = h("11" ** 20), .tags = "X\n" } },
    }, &.{});
    try testing.expectEqual(@as(u32, 1), cache.count());
}

test "the JSON cache the shell version left behind is discarded the same way" {
    // Named as its own case because it is the actual migration path, not a
    // hypothetical: every machine running the old code has one of these.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data =
        \\{"src/A.java": {"hash": "1111111111111111111111111111111111111111",
        \\ "tags": "Alpha\tdef", "unsupported": false}}
        ,
    });

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    try testing.expectEqual(@as(u32, 0), cache.count());
    try testing.expectEqual(@as(?format.ParseError, error.NotACache), cache.discarded);
}

test "a commit is atomic: no partial file is ever visible at the cache path" {
    // Asserted structurally rather than by racing: the write goes to a
    // sibling and is renamed, so a reader sees the old file whole or the new
    // one whole. What is checkable here is that the sibling does not survive.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "a.java", .entry = .{ .hash = h("11" ** 20), .tags = "" } },
    }, &.{});

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, tmp, .{}));
}
