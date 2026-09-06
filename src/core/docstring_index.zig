//! The docstring index: which declarations' docstrings have been checked,
//! at what pair of content hashes, in a repo's `$SYNAPSE_WORK_DIR`.
//!
//! A `(path, name, kind)` triple is current when the index holds it at
//! exactly the requested docstring/declaration hash pair. `commit` merges
//! onto what's already there, so two callers covering different subsets of
//! a repo don't erase each other. A mismatch on *either* hash of the pair
//! is the trigger for a fresh look -- code changed under an unchanged
//! docstring, or the docstring changed over unchanged code, both mean
//! "this pair needs a look." A brand-new triple is a mismatch against an
//! absent baseline, verified the first time it's written.
//!
//! Structured directly on `core/tags_cache.zig`'s own shape -- open/get/
//! commit, mmap-backed, single-writer and undefended for the same reasons
//! documented there -- with two differences this format's own doc comment
//! (`docstring_index/format.zig`) explains: the key is a triple, not a
//! path, and there is no separate payload region to stream.

const std = @import("std");
const format = @import("docstring_index/format.zig");
const conf = @import("conf.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Opt-in, not on by default: enabled via a `synapse.conf` entry
/// (`SYNAPSE_DOCSTRING_STALENESS_DETECTION`), shipped absent -- the same
/// shape `SYNAPSE_GRAMMARS_QUERY_PATH`/`SYNAPSE_AUTHOR_POOL` already use,
/// not a disable-flag defaulting to on. A real environment variable of the
/// same name still overrides whatever `synapse.conf` sets, since
/// `conf.resolve` already checks the environment first -- the standard
/// resolution order every `synapse.conf`-backed setting follows, no new
/// precedence mechanism needed. Any non-empty value enables it; there is
/// no boolean parsing (`"false"` still enables it, matching
/// `SYNAPSE_DISABLE_PROMPT_INJECTION`'s own "any value" convention, just
/// with the polarity this design deliberately flipped).
pub fn enabled(gpa: Allocator, io: Io, vars: conf.Vars) !bool {
    const value = try conf.resolve(gpa, io, vars, "SYNAPSE_DOCSTRING_STALENESS_DETECTION");
    if (value) |v| {
        gpa.free(v);
        return true;
    }
    return false;
}

/// What the index knows about one `(path, name, kind)` triple. No key
/// fields: you found it by one.
pub const Entry = struct {
    docstring_hash: [32]u8,
    decl_hash: [32]u8,
    /// 1-based, inclusive -- `core.verify.slice`'s own convention -- as of
    /// the last time this pair was derived. Only ever written by Tier 2
    /// (the only thing that calls `docstring_pairs.findPairs`); Tier 1
    /// uses it to re-hash the current content at this range without
    /// re-parsing (see the format's own doc comment). Defaulted to 0 so a
    /// call site that only cares about hash comparison doesn't need to
    /// spell out a range irrelevant to what it's testing.
    docstring_start_line: u32 = 0,
    docstring_end_line: u32 = 0,
    decl_start_line: u32 = 0,
    decl_end_line: u32 = 0,
};

/// The triple that identifies one tracked docstring: which file, which
/// declaration, and its kind (the same free-form vocabulary `Tag.kind`
/// already uses) -- name and kind together survive an edit elsewhere in
/// the file without falsely re-baselining an untouched docstring; a
/// genuine rename looks like a brand-new triple instead, the accepted
/// trade-off this index's design note states directly.
pub const Key = struct {
    path: []const u8,
    name: []const u8,
    kind: []const u8,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.path);
        h.update(&.{0});
        h.update(k.name);
        h.update(&.{0});
        h.update(k.kind);
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return std.mem.eql(u8, a.path, b.path) and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.kind, b.kind);
    }
};

const Map = std.HashMapUnmanaged(Key, Entry, KeyContext, std.hash_map.default_max_load_percentage);

pub const Update = struct {
    key: Key,
    entry: Entry,
};

/// Every reason `Cache.open` didn't use the file it found: either
/// `format.parse` rejected its content, or the mapping itself failed.
pub const OpenIssue = format.ParseError || error{
    /// The file exists and has a nonzero size, but `createMemoryMap`
    /// failed. Unlike every other `OpenIssue`, this says nothing about
    /// whether the content is good -- see `Cache.open`'s doc comment.
    MapFailed,
};

/// An index file, mapped. Every slice a lookup returns points into the
/// mapping, valid until `close` or the next `commit`.
pub const Cache = struct {
    /// Borrowed; outliving this struct is the caller's problem.
    path: []const u8,
    view: format.View,
    map: ?Io.File.MemoryMap = null,
    /// Why the file on disk wasn't used. Null means it was read or absent;
    /// nothing here prints, a caller reads this to say why.
    discarded: ?OpenIssue = null,

    /// Never accessed for a zero-entry index.
    const no_entries: format.View = .{
        .bytes = &.{},
        .header = .{
            .version = format.version,
            .entry_count = 0,
            .strings_off = 0,
            .crc32 = 0,
        },
    };

    /// Absent, damaged, or from another version: all open as an empty
    /// index rather than an error -- recomputable by re-checking, so no
    /// migration path. A failed *mapping* is distinct (`error.MapFailed`),
    /// same reasoning as `tags_cache.zig`'s own `open`: the file may hold
    /// good entries this run simply couldn't map, so `commit` must refuse
    /// to treat that as "nothing was there."
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
            .populate = false,
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

    pub fn get(self: *const Cache, key: Key) ?Entry {
        const i = self.view.find(key.path, key.name, key.kind) orelse return null;
        return entryOf(self.view.record(i));
    }

    fn entryOf(r: format.Record) Entry {
        return .{
            .docstring_hash = r.docstring_hash,
            .decl_hash = r.decl_hash,
            .docstring_start_line = r.docstring_start_line,
            .docstring_end_line = r.docstring_end_line,
            .decl_start_line = r.decl_start_line,
            .decl_end_line = r.decl_end_line,
        };
    }

    pub fn count(self: *const Cache) u32 {
        return self.view.count();
    }

    /// Every tracked triple for one file, `(name, kind, Entry)` triples in
    /// on-disk order -- what Tier 2's per-file read-time check scans, and
    /// what a sweep uses to find a triple no longer present in a fresh
    /// extraction (evict it; the declaration or its docstring is gone).
    pub const FileEntry = struct { name: []const u8, kind: []const u8, entry: Entry };

    pub fn entriesForPath(self: *const Cache, gpa: Allocator, path: []const u8) ![]FileEntry {
        const range = self.view.pathRange(path);
        var out = try gpa.alloc(FileEntry, range.end - range.start);
        var i = range.start;
        while (i < range.end) : (i += 1) {
            const r = self.view.record(i);
            out[i - range.start] = .{
                .name = self.view.name(r),
                .kind = self.view.kind(r),
                .entry = entryOf(r),
            };
        }
        return out;
    }

    /// Requested triples not already held at exactly that hash pair, in
    /// order, deduplicated by key (first occurrence wins). Touches the
    /// record table only.
    pub fn needsCheck(
        self: *const Cache,
        gpa: Allocator,
        requested: []const Update,
    ) ![]Update {
        var out: std.ArrayListUnmanaged(Update) = .empty;
        errdefer out.deinit(gpa);

        var seen: std.HashMapUnmanaged(Key, void, KeyContext, std.hash_map.default_max_load_percentage) = .empty;
        defer seen.deinit(gpa);

        for (requested) |want| {
            if ((try seen.fetchPut(gpa, want.key, {})) != null) continue;
            if (self.get(want.key)) |have| {
                if (std.mem.eql(u8, &have.docstring_hash, &want.entry.docstring_hash) and
                    std.mem.eql(u8, &have.decl_hash, &want.entry.decl_hash)) continue;
            }
            try out.append(gpa, want);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Apply `updates`, drop `removals`, write and rename over the
    /// original. Single-writer, not locked -- same tolerance for a lost
    /// concurrent update as `tags_cache.zig`'s own `commit`: a re-derivable
    /// index entry, not data loss.
    ///
    /// Refuses outright when `open` couldn't map the existing file
    /// (`error.MapFailed`), for the same reason `tags_cache.zig` does:
    /// merging onto this cache's empty view and writing that over the
    /// original would discard whatever real data the file still holds.
    pub fn commit(
        self: *Cache,
        gpa: Allocator,
        io: Io,
        updates: []const Update,
        removals: []const Key,
    ) !usize {
        if (self.discarded) |d| {
            if (d == error.MapFailed) return error.MapFailed;
        }

        var merged: Map = .empty;
        defer merged.deinit(gpa);

        var i: u32 = 0;
        while (i < self.view.count()) : (i += 1) {
            const r = self.view.record(i);
            try merged.put(gpa, .{
                .path = self.view.path(r),
                .name = self.view.name(r),
                .kind = self.view.kind(r),
            }, entryOf(r));
        }

        // Updates before removals, so removing a triple also being
        // updated wins.
        for (updates) |u| try merged.put(gpa, u.key, u.entry);

        var removed: usize = 0;
        for (removals) |k| {
            if (merged.remove(k)) removed += 1;
        }

        var entries = try gpa.alloc(format.Entry, merged.count());
        defer gpa.free(entries);
        var n: usize = 0;
        var it = merged.iterator();
        while (it.next()) |e| : (n += 1) {
            entries[n] = .{
                .path = e.key_ptr.path,
                .name = e.key_ptr.name,
                .kind = e.key_ptr.kind,
                .docstring_hash = e.value_ptr.docstring_hash,
                .decl_hash = e.value_ptr.decl_hash,
                .docstring_start_line = e.value_ptr.docstring_start_line,
                .docstring_end_line = e.value_ptr.docstring_end_line,
                .decl_start_line = e.value_ptr.decl_start_line,
                .decl_end_line = e.value_ptr.decl_end_line,
            };
        }
        std.mem.sort(format.Entry, entries, {}, lessByKey);

        try self.replaceFile(gpa, io, entries);
        return removed;
    }

    fn lessByKey(_: void, a: format.Entry, b: format.Entry) bool {
        const path_order = std.mem.order(u8, a.path, b.path);
        if (path_order != .eq) return path_order == .lt;
        const name_order = std.mem.order(u8, a.name, b.name);
        if (name_order != .eq) return name_order == .lt;
        return std.mem.order(u8, a.kind, b.kind) == .lt;
    }

    /// Write to a temp file and rename over the original, then re-map --
    /// renaming keeps a concurrent reader from seeing a half-written index.
    fn replaceFile(self: *Cache, gpa: Allocator, io: Io, entries: []const format.Entry) !void {
        const cwd = Io.Dir.cwd();

        if (Io.Dir.path.dirname(self.path)) |dir| cwd.createDirPath(io, dir) catch {};

        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{self.path});
        defer gpa.free(tmp);

        const bytes = try format.encode(gpa, entries);
        defer gpa.free(bytes);

        {
            const file = try cwd.createFile(io, tmp, .{});
            defer file.close(io);
            errdefer cwd.deleteFile(io, tmp) catch {};
            var buf: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buf);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
        }
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, self.path, io);

        self.close(io);
        self.* = try open(io, self.path);
    }
};

const testing = std.testing;

const TestVars = struct {
    pairs: []const [2][]const u8,

    fn vars(self: *const TestVars) conf.Vars {
        return .{ .ctx = @constCast(@ptrCast(self)), .getFn = lookup };
    }

    fn lookup(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "enabled: absent from both environment and synapse.conf is disabled" {
    const tv: TestVars = .{ .pairs = &.{} };
    try testing.expect(!try enabled(testing.allocator, testing.io, tv.vars()));
}

test "enabled: any non-empty environment value enables it, no boolean parsing" {
    const tv: TestVars = .{ .pairs = &.{.{ "SYNAPSE_DOCSTRING_STALENESS_DETECTION", "false" }} };
    try testing.expect(try enabled(testing.allocator, testing.io, tv.vars()));
}

test "enabled: an empty environment value is the same as absent" {
    const tv: TestVars = .{ .pairs = &.{.{ "SYNAPSE_DOCSTRING_STALENESS_DETECTION", "" }} };
    try testing.expect(!try enabled(testing.allocator, testing.io, tv.vars()));
}

fn hash32(byte: u8) [32]u8 {
    return .{byte} ** 32;
}

/// An index under a temp directory, addressed by absolute path so tests
/// don't depend on the process's cwd -- same shape as `tags_cache.zig`'s
/// own `Fixture`.
const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [Io.Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = &.{},

    fn init() !Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn indexPath(f: *Fixture, gpa: Allocator, io: Io) ![]u8 {
        const dir = f.buf[0..try f.tmp.dir.realPath(io, &f.buf)];
        return std.fmt.allocPrint(gpa, "{s}/_docstring_index.bin", .{dir});
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }
};

test "an absent index opens empty and needs everything" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    try testing.expectEqual(@as(u32, 0), cache.count());
    try testing.expectEqual(@as(?OpenIssue, null), cache.discarded);

    const need = try cache.needsCheck(gpa, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
    });
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 1), need.len);
}

test "commit then reopen: what went in comes back out" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "src/a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
        .{ .key = .{ .path = "src/a.zig", .name = "bar", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(3), .decl_hash = hash32(4) } },
    }, &.{});

    var reopened = try Cache.open(io, path);
    defer reopened.close(io);

    try testing.expectEqual(@as(u32, 2), reopened.count());
    const foo = reopened.get(.{ .path = "src/a.zig", .name = "foo", .kind = "fn" }).?;
    try testing.expectEqualSlices(u8, &hash32(1), &foo.docstring_hash);
    try testing.expectEqualSlices(u8, &hash32(2), &foo.decl_hash);
    try testing.expectEqual(
        @as(?Entry, null),
        reopened.get(.{ .path = "src/a.zig", .name = "missing", .kind = "fn" }),
    );
}

test "line ranges round-trip through commit and reopen, for Tier 1's re-hash-without-reparsing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{
            .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" },
            .entry = .{
                .docstring_hash = hash32(1),
                .decl_hash = hash32(2),
                .docstring_start_line = 3,
                .docstring_end_line = 4,
                .decl_start_line = 5,
                .decl_end_line = 9,
            },
        },
    }, &.{});

    var reopened = try Cache.open(io, path);
    defer reopened.close(io);
    const got = reopened.get(.{ .path = "a.zig", .name = "foo", .kind = "fn" }).?;
    try testing.expectEqual(@as(u32, 3), got.docstring_start_line);
    try testing.expectEqual(@as(u32, 4), got.docstring_end_line);
    try testing.expectEqual(@as(u32, 5), got.decl_start_line);
    try testing.expectEqual(@as(u32, 9), got.decl_end_line);
}

test "needsCheck: unchanged is silent, either hash moving is a hit, and a new triple is a hit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
        .{ .key = .{ .path = "a.zig", .name = "bar", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(3), .decl_hash = hash32(4) } },
    }, &.{});

    const need = try cache.needsCheck(gpa, &.{
        // Unchanged -- not a hit.
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
        // Declaration body changed, docstring didn't -- a hit.
        .{ .key = .{ .path = "a.zig", .name = "bar", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(3), .decl_hash = hash32(99) } },
        // Never seen before -- a hit.
        .{ .key = .{ .path = "a.zig", .name = "baz", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(5), .decl_hash = hash32(6) } },
    });
    defer gpa.free(need);

    try testing.expectEqual(@as(usize, 2), need.len);
    try testing.expectEqualStrings("bar", need[0].key.name);
    try testing.expectEqualStrings("baz", need[1].key.name);
}

test "entriesForPath scopes to one file, in on-disk order" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "alpha", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(11) } },
        .{ .key = .{ .path = "a.zig", .name = "beta", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(2), .decl_hash = hash32(12) } },
        .{ .key = .{ .path = "b.zig", .name = "gamma", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(3), .decl_hash = hash32(13) } },
    }, &.{});

    const a_entries = try cache.entriesForPath(gpa, "a.zig");
    defer gpa.free(a_entries);
    try testing.expectEqual(@as(usize, 2), a_entries.len);
    try testing.expectEqualStrings("alpha", a_entries[0].name);
    try testing.expectEqualStrings("beta", a_entries[1].name);

    const c_entries = try cache.entriesForPath(gpa, "c.zig");
    defer gpa.free(c_entries);
    try testing.expectEqual(@as(usize, 0), c_entries.len);
}

test "eviction: a removed triple leaves the index, and evicting an absent one is not an error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
    }, &.{});

    const removed = try cache.commit(gpa, io, &.{}, &.{
        .{ .path = "a.zig", .name = "foo", .kind = "fn" },
        .{ .path = "a.zig", .name = "never-existed", .kind = "fn" },
    });

    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(u32, 0), cache.count());
}

test "re-committing the same triple replaces it, not adds a second row" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);

    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
    }, &.{});
    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(9), .decl_hash = hash32(9) } },
    }, &.{});

    try testing.expectEqual(@as(u32, 1), cache.count());
    const got = cache.get(.{ .path = "a.zig", .name = "foo", .kind = "fn" }).?;
    try testing.expectEqualSlices(u8, &hash32(9), &got.docstring_hash);
}

test "a commit is atomic: no partial file is ever visible at the index path" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init();
    defer fx.deinit();
    const path = try fx.indexPath(gpa, io);
    defer gpa.free(path);

    var cache = try Cache.open(io, path);
    defer cache.close(io);
    _ = try cache.commit(gpa, io, &.{
        .{ .key = .{ .path = "a.zig", .name = "foo", .kind = "fn" }, .entry = .{ .docstring_hash = hash32(1), .decl_hash = hash32(2) } },
    }, &.{});

    var dir = try Io.Dir.cwd().openDir(io, Io.Dir.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}
