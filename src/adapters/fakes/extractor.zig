//! An Extractor that returns scripted outcomes and records what it was asked.

const std = @import("std");
const model = @import("model");
const ports = @import("ports");

const Extractor = ports.Extractor;

pub const FakeExtractor = struct {
    gpa: std.mem.Allocator,
    /// Consulted by path. A path with no entry gets `default`.
    scripted: std.StringHashMapUnmanaged(Extractor.Outcome) = .empty,
    default: Extractor.Outcome = .{ .tags = &.{} },
    /// Every path the extractor was asked about, in call order, so a test can
    /// assert that batching happened rather than trusting it.
    seen: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Number of `extract` calls. Two hundred paths in one call is the point
    /// of the batch-shaped port; this is how a test proves it.
    calls: usize = 0,

    pub fn init(gpa: std.mem.Allocator) FakeExtractor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeExtractor) void {
        self.scripted.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    pub fn script(self: *FakeExtractor, path: []const u8, outcome: Extractor.Outcome) !void {
        try self.scripted.put(self.gpa, path, outcome);
    }

    pub fn port(self: *FakeExtractor) Extractor {
        return .{ .ptr = self, .vtable = &.{ .extract = extract } };
    }

    fn extract(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]Extractor.Outcome {
        _ = io;
        _ = root;
        const self: *FakeExtractor = @ptrCast(@alignCast(ptr));
        self.calls += 1;

        const out = try gpa.alloc(Extractor.Outcome, paths.len);
        errdefer gpa.free(out);
        for (paths, 0..) |p, i| {
            try self.seen.append(self.gpa, p);
            out[i] = self.scripted.get(p) orelse self.default;
        }
        return out;
    }
};

const testing = std.testing;

test "outcomes come back one per path, in order" {
    var fake: FakeExtractor = .init(testing.allocator);
    defer fake.deinit();

    const tags = [_]model.Tag{.{
        .name = "Token",
        .role = .def,
        .kind = "class",
        .line = 15,
        .expression = "public class Token {",
    }};
    try fake.script("a.java", .{ .tags = &tags });
    try fake.script("b.bin", .unsupported);

    const out = try fake.port().extract(testing.allocator, undefined, ".", &.{ "a.java", "b.bin", "c.java" });
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("Token", out[0].tags[0].name);
    try testing.expectEqual(Extractor.Outcome.unsupported, out[1]);
    try testing.expectEqual(@as(usize, 0), out[2].tags.len);
}

test "unsupported is distinguishable from parsed-but-empty" {
    var fake: FakeExtractor = .init(testing.allocator);
    defer fake.deinit();
    try fake.script("nogrammar.bin", .unsupported);

    const out = try fake.port().extract(testing.allocator, undefined, ".", &.{ "nogrammar.bin", "empty.java" });
    defer testing.allocator.free(out);

    // The whole reason the port returns a union: an empty tag slice would
    // conflate these, and the cache has to record them differently.
    try testing.expect(out[0] == .unsupported);
    try testing.expect(out[1] == .tags);
}

test "one call for many paths, which is what the batch shape is for" {
    var fake: FakeExtractor = .init(testing.allocator);
    defer fake.deinit();

    var paths: [200][]const u8 = undefined;
    for (&paths) |*p| p.* = "x.java";

    const out = try fake.port().extract(testing.allocator, undefined, ".", &paths);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqual(@as(usize, 200), fake.seen.items.len);
}
