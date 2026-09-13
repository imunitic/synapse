//! A SearchFiltered that answers every query with no hits -- exists so a
//! `ComposeCtx` test fixture has a real value to put in
//! `inner_search_filtered` without needing a real `DiskStore`/vault on disk.

const std = @import("std");
const ports = @import("ports");

const SearchFiltered = ports.SearchFiltered;
const Store = ports.Store;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FakeSearchFiltered = struct {
    /// The wrapper idiom: `SearchFiltered.from` generates the `*anyopaque`
    /// cast from `FakeSearchFiltered` alone, so it can never disagree with
    /// `.ptr` the way a hand-written vtable literal could.
    pub fn searchFiltered_(self: *FakeSearchFiltered) SearchFiltered {
        return SearchFiltered.from(FakeSearchFiltered, self);
    }

    pub fn searchFiltered(
        self: *FakeSearchFiltered,
        gpa: Allocator,
        io: Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        _ = self;
        _ = gpa;
        _ = io;
        _ = query;
        _ = path_filter;
        return &.{};
    }
};

const testing = std.testing;

test "every query answers no hits, never an error" {
    var fake: FakeSearchFiltered = .{};
    const hits = try fake.searchFiltered_().searchFiltered(testing.allocator, undefined, "query", null);
    try testing.expectEqual(@as(usize, 0), hits.len);
}
