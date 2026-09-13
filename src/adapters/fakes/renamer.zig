//! A Renamer that does nothing and records nothing -- exists so a
//! `ComposeCtx` test fixture has a real value to put in `inner_renamer`
//! without needing a real `DiskStore`/vault on disk.

const std = @import("std");
const ports = @import("ports");

const Renamer = ports.Renamer;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FakeRenamer = struct {
    /// The wrapper idiom: `Renamer.from` generates the `*anyopaque` cast
    /// from `FakeRenamer` alone, so it can never disagree with `.ptr` the
    /// way a hand-written vtable literal could.
    pub fn renamer(self: *FakeRenamer) Renamer {
        return Renamer.from(FakeRenamer, self);
    }

    pub fn rename(self: *FakeRenamer, gpa: Allocator, io: Io, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = gpa;
        _ = io;
        _ = old_path;
        _ = new_path;
    }
};

const testing = std.testing;

test "rename is a no-op, never an error" {
    var fake: FakeRenamer = .{};
    try fake.renamer().rename(testing.allocator, undefined, "old.md", "new.md");
}
