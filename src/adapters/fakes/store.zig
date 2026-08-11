//! A Store held entirely in memory, and the reason the REST adapter needs no
//! network in tests.

const std = @import("std");
const ports = @import("ports");

const Store = ports.Store;

pub const FakeStore = struct {
    gpa: std.mem.Allocator,
    nodes: std.StringHashMapUnmanaged([]const u8) = .empty,
    writes: usize = 0,
    /// Set to make the next call fail. A store that can only succeed cannot
    /// test the thing that matters most about this one -- that a hook stays
    /// quiet when the vault is unreachable.
    fail_next: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator) FakeStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeStore) void {
        var it = self.nodes.iterator();
        while (it.next()) |e| self.gpa.free(e.value_ptr.*);
        self.nodes.deinit(self.gpa);
    }

    pub fn port(self: *FakeStore) Store {
        return .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .list = list,
            .search = search,
        } };
    }

    fn take(self: *FakeStore) ?anyerror {
        defer self.fail_next = null;
        return self.fail_next;
    }

    fn read(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror!?[]u8 {
        _ = io;
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        if (self.take()) |e| return e;
        const body = self.nodes.get(node) orelse return null;
        return try gpa.dupe(u8, body);
    }

    fn write(ptr: *anyopaque, io: std.Io, node: []const u8, body: []const u8) anyerror!void {
        _ = io;
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        if (self.take()) |e| return e;
        const copy = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(copy);
        const gop = try self.nodes.getOrPut(self.gpa, node);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
        self.writes += 1;
    }

    fn list(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        _ = io;
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        if (self.take()) |e| return e;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(gpa);
        var it = self.nodes.keyIterator();
        while (it.next()) |k| try out.append(gpa, k.*);
        return out.toOwnedSlice(gpa);
    }

    /// Substring matching, and no more than that. A fake that ranked results
    /// would be asserting an answer the real adapters do not have to agree on.
    fn search(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, query: []const u8) anyerror![]const Store.Hit {
        _ = io;
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        if (self.take()) |e| return e;
        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer out.deinit(gpa);
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            if (std.mem.indexOf(u8, e.value_ptr.*, query) != null) {
                try out.append(gpa, .{ .node = e.key_ptr.*, .score = 1.0, .context = e.value_ptr.* });
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

    try store.write(undefined, "Foo Node.md", "body text");
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

    try store.write(undefined, "n.md", "first");
    try store.write(undefined, "n.md", "second");

    const body = (try store.read(testing.allocator, undefined, "n.md")).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("second", body);

    const names = try store.list(testing.allocator, undefined);
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
}

test "search finds by content" {
    var fake: FakeStore = .init(testing.allocator);
    defer fake.deinit();
    const store = fake.port();

    try store.write(undefined, "a.md", "mentions tree-sitter");
    try store.write(undefined, "b.md", "mentions nothing");

    const hits = try store.search(testing.allocator, undefined, "tree-sitter");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.md", hits[0].node);
}
