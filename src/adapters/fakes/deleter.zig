//! A Deleter that does nothing and records nothing -- exists so a
//! `ComposeCtx` test fixture has a real value to put in `inner_deleter`
//! without needing a real `DiskStore`/vault on disk.

const std = @import("std");
const ports = @import("ports");

const Deleter = ports.Deleter;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FakeDeleter = struct {
    /// The wrapper idiom: `Deleter.from` generates the `*anyopaque` cast
    /// from `FakeDeleter` alone, so it can never disagree with `.ptr` the
    /// way a hand-written vtable literal could.
    pub fn deleter(self: *FakeDeleter) Deleter {
        return Deleter.from(FakeDeleter, self);
    }

    pub fn delete(self: *FakeDeleter, gpa: Allocator, io: Io, path: []const u8) anyerror!void {
        _ = self;
        _ = gpa;
        _ = io;
        _ = path;
    }
};

const testing = std.testing;

test "delete is a no-op, never an error" {
    var fake: FakeDeleter = .{};
    try fake.deleter().delete(testing.allocator, undefined, "note.md");
}
