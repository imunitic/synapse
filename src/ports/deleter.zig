//! Deleter: removes a note and unlinks every referring `[[wikilink]]` to
//! plain text, as one capability -- keeping the vault internally consistent
//! the same way `Renamer` does for a move. A separate capability from
//! `Store`: `Store` stays at exactly four methods, none of them delete (see
//! `disk/store.zig`'s own `deleteVaultFile`), and not every `Store` has a
//! delete concept either (Bard's stores have no rename concept for the same
//! reason, and compose no `Renamer`).

const std = @import("std");

pub const Deleter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        delete: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void,
    };

    /// `path` is a full vault-relative path, the same addressing
    /// `Store`/`LinkGraph`/`Renamer` already use for a namespace-less
    /// (vault-wide) node. `error.NodeNotFound` when there's nothing there to
    /// delete.
    pub fn delete(self: Deleter, gpa: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void {
        return self.vtable.delete(self.ptr, gpa, io, path);
    }

    /// The wrapper idiom, identical to `Renamer.from`/`Store.from`: builds a
    /// `Deleter` from any concrete `T` exposing `delete` with this same
    /// shape, self-first.
    pub fn from(comptime T: type, self: *T) Deleter {
        const Impl = struct {
            fn delete(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.delete(gpa, io, path);
            }
        };
        return .{ .ptr = self, .vtable = &.{ .delete = Impl.delete } };
    }
};
