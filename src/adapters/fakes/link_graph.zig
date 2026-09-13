//! A LinkGraph with no real graph behind it -- every query answers empty.
//! Exists so a `ComposeCtx` test fixture has a real value to put in
//! `inner_link_graph` without needing a real `DiskStore`/vault on disk.

const std = @import("std");
const ports = @import("ports");

const LinkGraph = ports.LinkGraph;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FakeLinkGraph = struct {
    /// The wrapper idiom: `LinkGraph.from` generates the `*anyopaque` cast
    /// from `FakeLinkGraph` alone, so it can never disagree with `.ptr` the
    /// way a hand-written vtable literal could.
    pub fn linkGraph(self: *FakeLinkGraph) LinkGraph {
        return LinkGraph.from(FakeLinkGraph, self);
    }

    pub fn backlinks(self: *FakeLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const LinkGraph.Backlink {
        _ = self;
        _ = gpa;
        _ = io;
        _ = node;
        return &.{};
    }

    pub fn links(self: *FakeLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const []const u8 {
        _ = self;
        _ = gpa;
        _ = io;
        _ = node;
        return &.{};
    }

    pub fn unresolved(self: *FakeLinkGraph, gpa: Allocator, io: Io) anyerror![]const LinkGraph.Unresolved {
        _ = self;
        _ = gpa;
        _ = io;
        return &.{};
    }

    pub fn orphans(self: *FakeLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        _ = self;
        _ = gpa;
        _ = io;
        return &.{};
    }

    pub fn deadends(self: *FakeLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        _ = self;
        _ = gpa;
        _ = io;
        return &.{};
    }

    pub fn ambiguous(self: *FakeLinkGraph, gpa: Allocator, io: Io) anyerror![]const LinkGraph.Ambiguous {
        _ = self;
        _ = gpa;
        _ = io;
        return &.{};
    }
};

const testing = std.testing;

test "every query answers empty, never an error" {
    var fake: FakeLinkGraph = .{};
    const lg = fake.linkGraph();
    try testing.expectEqual(@as(usize, 0), (try lg.backlinks(testing.allocator, undefined, "n.md")).len);
    try testing.expectEqual(@as(usize, 0), (try lg.links(testing.allocator, undefined, "n.md")).len);
    try testing.expectEqual(@as(usize, 0), (try lg.unresolved(testing.allocator, undefined)).len);
    try testing.expectEqual(@as(usize, 0), (try lg.orphans(testing.allocator, undefined)).len);
    try testing.expectEqual(@as(usize, 0), (try lg.deadends(testing.allocator, undefined)).len);
    try testing.expectEqual(@as(usize, 0), (try lg.ambiguous(testing.allocator, undefined)).len);
}
