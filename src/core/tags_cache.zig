//! The tags cache: which files have been tagged, at what content hash, with
//! what result. Port of `synapse-tags-cache.sh` minus the actual tagging --
//! deciding what needs tagging, holding answers, projecting into
//! `_refs.tsv` live here; running the extractor is an app's job.
//!
//! A path is current when the cache holds it at exactly the requested hash.
//! `commit` merges onto what's already there, so two callers covering
//! different subsets of a repo don't erase each other. A file with no
//! usable grammar is recorded `unsupported` rather than omitted, or it'd be
//! re-attempted forever.
//!
//! Two things new versus the shell version: **eviction** (`commit` takes
//! removals -- the shell version never removed a row, so `_refs.tsv` could
//! name a deleted file's caller), and **storage in `tags_cache/format.zig`,
//! not JSON** -- `needsTagging` compares hashes in the record table without
//! touching the payload, versus 5.0s of `jq` over syrius3's 828 MB cache.

const std = @import("std");
const format = @import("tags_cache/format.zig");
/// Public: `tags_cache_cmd.zig`/`vocab_cmd.zig` encode a `Tag` list directly
/// when writing an entry, and `rank_cmd.zig`/`core/symbol.zig` decode one
/// when reading -- `Cache` itself only needs `payload.iterate` for
/// `writeRefs`, but the codec is the whole point of this module's Entry.tags
/// contract, not an implementation detail to hide from its own callers.
pub const payload = @import("tags_cache/payload.zig");
const tag_line = @import("tag_line.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What the cache knows about one path. No `path` field: you found it by one.
pub const Entry = struct {
    hash: [20]u8,
    /// `tags_cache/payload.zig`'s encoding of every tag found -- structured
    /// data, not a rendered display line; decode with `payload.iterate`.
    /// Empty means parsed and declared nothing -- not the same as
    /// `unsupported`.
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

/// Every reason `Cache.open` didn't use the file it found: either
/// `format.parse` rejected its content, or the mapping itself failed.
pub const OpenIssue = format.ParseError || error{
    /// The file exists and has a nonzero size, but `createMemoryMap` failed.
    /// Unlike every other `OpenIssue`, this says nothing about whether the
    /// content is good -- see `Cache.open`'s doc comment.
    MapFailed,
};

/// A cache file, mapped. Every slice a lookup returns points into the
/// mapping, valid until `close` or the next `commit`.
pub const Cache = struct {
    /// Borrowed; outliving this struct is the caller's problem.
    path: []const u8,
    view: format.View,
    map: ?Io.File.MemoryMap = null,
    /// Why the file on disk wasn't used. Null means it was read or absent;
    /// nothing here prints, a caller reads this to say why.
    discarded: ?OpenIssue = null,

    /// Never accessed for a zero-entry cache.
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

    /// Absent, damaged, or from another version: all open as an empty cache
    /// rather than an error. Recomputable by re-tagging, so no migration
    /// path -- a non-cache file (including the shell version's leftover
    /// JSON) is just overwritten by the next commit. A failed *mapping* is
    /// not the same as those: the file may hold hundreds of MB of good,
    /// parseable entries that simply couldn't be mapped this run (an
    /// address-space or `mmap` limit, a filesystem that refuses it) --
    /// `discarded` records `error.MapFailed` distinctly so `commit` can
    /// refuse to treat "couldn't map it" as "nothing was there" and
    /// silently replace real data with an empty merge.
    ///
    /// No allocator: the mapping is the storage, `format.parse` allocates nothing.
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
            .populate = false, // avoid prefaulting an 800 MB mapping
        }) catch {
            self.discarded = error.MapFailed;
            return self;
        };
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

    /// Requested pairs not already held at that hash, in order,
    /// deduplicated by path (first occurrence wins) -- the answer feeds an
    /// extractor, so a duplicate would otherwise be tagged twice. Touches
    /// the record table only; the payload region is never read.
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

    /// Apply `updates`, drop `removals`, write and rename over the original.
    /// Returns rows actually removed -- a removal naming a path the cache
    /// never held is not an error, and not counted. Every previously
    /// returned slice is invalidated once the mapping is replaced.
    ///
    /// Refuses outright when `open` couldn't map the existing file
    /// (`error.MapFailed`): merging `updates` onto this cache's empty view
    /// and writing that over the original would discard however much real
    /// data the file on disk still holds, for a failure that has nothing to
    /// do with that data's validity. Absent, empty, damaged, or
    /// wrong-version caches carry no such risk and commit normally -- there
    /// was nothing recoverable to lose in those cases.
    ///
    /// Single-writer, not locked: two `commit`s racing against the same
    /// cache file both read `self.view` before either writes, so the loser's
    /// rename silently discards whatever the winner just added. Deliberately
    /// undefended -- a lost update here is a handful of re-derivable tag
    /// entries, picked back up whole the next time anything reads a stale
    /// hash for that path, not data loss or a wrong answer that persists.
    /// Two `synapse tags-cache`/`vocab` invocations against the same work
    /// dir at once is the only way to hit this, and adding a lock-acquire
    /// to a path this hot for a self-healing race nothing has actually hit
    /// costs more than it buys.
    pub fn commit(
        self: *Cache,
        gpa: Allocator,
        io: Io,
        updates: []const Update,
        removals: []const []const u8,
    ) !usize {
        if (self.discarded) |d| {
            if (d == error.MapFailed) return error.MapFailed;
        }

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

        // Updates before removals, so removing a path also being updated wins.
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

        try self.replaceFile(gpa, io, entries);
        return removed;
    }

    /// Write to a temp file and rename over the original, then re-map --
    /// renaming keeps a concurrent reader from seeing a half-written cache.
    /// Streamed rather than buffered whole: at repo scale the cache is
    /// hundreds of MB, and `format.encodeTo` holds only the record table and
    /// paths (~11 MB at 125k files), passing tag payloads straight through.
    fn replaceFile(self: *Cache, gpa: Allocator, io: Io, entries: []const format.Entry) !void {
        const cwd = Io.Dir.cwd();

        // `Io.Dir.path`, not `std.fs.path` -- the purity gate forbids core
        // naming the latter, though they're pure string work either way.
        if (Io.Dir.path.dirname(self.path)) |dir| cwd.createDirPath(io, dir) catch {};

        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{self.path});
        defer gpa.free(tmp);

        {
            const file = try cwd.createFile(io, tmp, .{});
            defer file.close(io);
            errdefer cwd.deleteFile(io, tmp) catch {};

            var buf: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buf);
            try format.encodeTo(gpa, &writer.interface, entries);
            try writer.interface.flush();
        }
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, self.path, io);

        self.close(io);
        self.* = try open(io, self.path);
    }

    /// Every cached tag as an `_refs.tsv` row, in path order. Streams the
    /// payload one record at a time -- 828 MB on syrius3, too big to
    /// materialise. An `unsupported` or evicted entry contributes nothing.
    /// Path order, not `_refs.tsv`'s own sort order: the writer sorts these
    /// rows, this just emits them.
    ///
    /// The one place `look`-compatible rendering happens: `writeRefsRow`'s
    /// tab-separated columns are `_refs.tsv`'s actual on-disk contract, read
    /// straight from each entry's stored `Tag`s -- no intermediate text to
    /// re-parse.
    pub fn writeRefs(self: *const Cache, w: *std.Io.Writer) !usize {
        var rows: usize = 0;
        var i: u32 = 0;
        while (i < self.view.count()) : (i += 1) {
            const r = self.view.record(i);
            const path = self.view.path(r);
            var it = payload.iterate(self.view.tags(r));
            while (it.next()) |tag| {
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

/// A cache under a temp directory, addressed by absolute path so tests
/// don't depend on the process's cwd.
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

test "commit refuses when the file couldn't be mapped, leaving real on-disk data untouched" {
    // Simulates what `open` leaves behind after a real mmap failure on an
    // existing, non-empty file -- `discarded = error.MapFailed` with the
    // empty `no_entries` view, exactly `open`'s own catch branch produces.
    // Before `commit` checked `discarded`, this sequence would merge
    // `updates` onto nothing and silently replace the real cache below with
    // just those two rows.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    var real = try Cache.open(io, path);
    _ = try real.commit(gpa, io, &.{
        .{ .path = "src/A.java", .entry = .{ .hash = h("11" ** 20), .tags = "Alpha\tdef\n" } },
        .{ .path = "src/B.java", .entry = .{ .hash = h("22" ** 20), .tags = "Beta\tdef\n" } },
    }, &.{});
    real.close(io);

    var unmapped: Cache = .{ .path = path, .view = Cache.no_entries, .discarded = error.MapFailed };
    try testing.expectError(error.MapFailed, unmapped.commit(gpa, io, &.{
        .{ .path = "src/C.java", .entry = .{ .hash = h("33" ** 20), .tags = "Gamma\tdef\n" } },
    }, &.{}));

    var reopened = try Cache.open(io, path);
    defer reopened.close(io);
    try testing.expectEqual(@as(u32, 2), reopened.count());
    try testing.expect(reopened.get("src/A.java") != null);
    try testing.expect(reopened.get("src/B.java") != null);
    try testing.expectEqual(@as(?Entry, null), reopened.get("src/C.java"));
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

    // Neither is re-tagged at the same hash.
    const need = try cache.needsTagging(gpa, &.{
        .{ .path = "empty.java", .hash = h("11" ** 20) },
        .{ .path = "nogrammar.bin", .hash = h("22" ** 20) },
    });
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 0), need.len);
}

test "commit merges onto what is there rather than replacing it" {
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
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.cachePath(gpa, io);
    defer gpa.free(path);

    const alpha = try payload.encode(gpa, &.{
        .{ .name = "Alpha", .role = .def, .kind = "class", .line = 14, .expression = "public class Alpha {" },
    });
    defer gpa.free(alpha);
    const gone = try payload.encode(gpa, &.{
        .{ .name = "Gone", .role = .def, .kind = "class", .line = 2, .expression = "public class Gone {" },
    });
    defer gpa.free(gone);

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

    var reopened = try Cache.open(io, path); // stays gone across a reopen
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

    const zed = try payload.encode(gpa, &.{
        .{ .name = "Zed", .role = .def, .kind = "class", .line = 1, .expression = "public class Zed {" },
    });
    defer gpa.free(zed);
    const ay = try payload.encode(gpa, &.{
        .{ .name = "Ay", .role = .def, .kind = "class", .line = 0, .expression = "public class Ay {" },
        .{ .name = "call", .role = .ref, .kind = "call", .line = 3, .expression = "call();" },
    });
    defer gpa.free(ay);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .path = "z.java", .entry = .{ .hash = h("11" ** 20), .tags = zed } },
        .{ .path = "a.java", .entry = .{ .hash = h("22" ** 20), .tags = ay } },
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
    // Checked structurally: the sibling temp file must not survive.
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
