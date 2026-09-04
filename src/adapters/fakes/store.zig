//! A Store held entirely in memory, and the reason the REST adapter needs no
//! network in tests.

const std = @import("std");
const ports = @import("ports");

const Store = ports.Store;

pub const FakeStore = struct {
    gpa: std.mem.Allocator,
    nodes: std.StringHashMapUnmanaged([]const u8) = .empty,
    writes: usize = 0,
    reads: usize = 0,
    lists: usize = 0,
    /// Set to make the next call fail -- tests that a hook stays quiet when
    /// the vault is unreachable.
    fail_next: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator) FakeStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeStore) void {
        var it = self.nodes.iterator();
        while (it.next()) |e| self.gpa.free(e.value_ptr.*);
        self.nodes.deinit(self.gpa);
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque`
    /// cast from `FakeStore` alone, so it can never disagree with `.ptr`
    /// the way a hand-written vtable literal could.
    pub fn port(self: *FakeStore) Store {
        return Store.from(FakeStore, self);
    }

    fn take(self: *FakeStore) ?anyerror {
        defer self.fail_next = null;
        return self.fail_next;
    }

    pub fn read(self: *FakeStore, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror!?[]u8 {
        _ = io;
        self.reads += 1;
        if (self.take()) |e| return e;
        const body = self.nodes.get(node) orelse return null;
        return try gpa.dupe(u8, body);
    }

    pub fn write(self: *FakeStore, io: std.Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        _ = io;
        if (self.take()) |e| return e;
        const copy = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(copy);
        const gop = try self.nodes.getOrPut(self.gpa, node);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
        self.writes += 1;
        return .{ .accepted = true };
    }

    pub fn list(self: *FakeStore, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        _ = io;
        self.lists += 1;
        if (self.take()) |e| return e;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        var it = self.nodes.keyIterator();
        // Duped, not borrowed from the map -- `ports.Store.list`'s contract
        // is caller-frees-every-name for every implementation, since a
        // directory-backed one has no persistent copy to lend.
        while (it.next()) |k| try out.append(gpa, try gpa.dupe(u8, k.*));
        return out.toOwnedSlice(gpa);
    }

    /// Substring matching, no more -- a fake that ranked results would
    /// assert an answer real adapters don't have to agree on.
    pub fn search(self: *FakeStore, gpa: std.mem.Allocator, io: std.Io, query: []const u8) anyerror![]const Store.Hit {
        _ = io;
        if (self.take()) |e| return e;
        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer {
            for (out.items) |h| {
                gpa.free(h.node);
                gpa.free(h.context);
            }
            out.deinit(gpa);
        }
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            if (std.mem.indexOf(u8, e.value_ptr.*, query) != null) {
                // Duped, not borrowed from this map's own storage -- every
                // real `Store.search` implementation dupes per-hit, and a
                // caller that frees a `Hit` the way that real contract
                // requires must not free memory this fake never owned.
                try out.append(gpa, .{
                    .node = try gpa.dupe(u8, e.key_ptr.*),
                    .score = 1.0,
                    .context = try gpa.dupe(u8, e.value_ptr.*),
                });
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "write then read round-trips through the port" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    const store = fake.port();

    _ = try store.write(undefined, "Foo Node.md", "body text");
    const body = (try store.read(testing.allocator, undefined, "Foo Node.md")).?;
    defer testing.allocator.free(body);

    try testing.expectEqualStrings("body text", body);
    try testing.expectEqual(@as(usize, 1), fake.writes);
}

test "a missing node reads as null, not as an error" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    try testing.expectEqual(@as(?[]u8, null), try fake.port().read(testing.allocator, undefined, "absent.md"));
}

test "a scripted failure surfaces, so unreachable-vault paths are testable" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    fake.fail_next = error.ConnectionRefused;
    try testing.expectError(error.ConnectionRefused, fake.port().read(testing.allocator, undefined, "Foo Node.md"));
    // One failure, not a broken store: the next call works again.
    try testing.expectEqual(@as(?[]u8, null), try fake.port().read(testing.allocator, undefined, "Foo Node.md"));
}

test "rewriting a node replaces it rather than accumulating" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    const store = fake.port();

    _ = try store.write(undefined, "n.md", "first");
    _ = try store.write(undefined, "n.md", "second");

    const body = (try store.read(testing.allocator, undefined, "n.md")).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("second", body);

    const names = try store.list(testing.allocator, undefined);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
}

test "search finds by content" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    const store = fake.port();

    _ = try store.write(undefined, "a.md", "mentions tree-sitter");
    _ = try store.write(undefined, "b.md", "mentions nothing");

    const hits = try store.search(testing.allocator, undefined, "tree-sitter");
    defer {
        for (hits) |h| {
            testing.allocator.free(h.node);
            testing.allocator.free(h.context);
        }
        testing.allocator.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}
