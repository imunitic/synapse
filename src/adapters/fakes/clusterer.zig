//! A Clusterer that returns whatever grouping a test hands it.

const std = @import("std");
const ports = @import("ports");

const Clusterer = ports.Clusterer;

pub const FakeClusterer = struct {
    /// Returned verbatim. Borrowed, not owned: the test owns the storage.
    clusters: []const Clusterer.Cluster = &.{},
    calls: usize = 0,

    pub fn port(self: *FakeClusterer) Clusterer {
        return .{ .ptr = self, .vtable = &.{ .cluster = cluster } };
    }

    fn cluster(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]const Clusterer.Cluster {
        _ = io;
        _ = root;
        _ = paths;
        const self: *FakeClusterer = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return gpa.dupe(Clusterer.Cluster, self.clusters);
    }
};

const testing = std.testing;

test "the scripted grouping comes back through the port" {
    const paths = [_][]const u8{ "src/a.zig", "src/b.zig" };
    var fake: FakeClusterer = .{ .clusters = &.{.{ .name = "Core", .paths = &paths }} };

    const got = try fake.port().cluster(testing.allocator, undefined, ".", &.{});
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("Core", got[0].name);
    try testing.expectEqual(@as(usize, 2), got[0].paths.len);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "no clusters is an ordinary answer" {
    var fake: FakeClusterer = .{};
    const got = try fake.port().cluster(testing.allocator, undefined, ".", &.{"x"});
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}
