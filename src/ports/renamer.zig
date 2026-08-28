//! Renamer: renames a note -- its filename and every referring
//! `[[wikilink]]` -- as one capability, keeping title and filename identity
//! in sync per the vault's own convention. A separate capability from
//! `Store`, same shape as `LinkGraph`: not every `Store` has a wikilink
//! graph to rewrite through (Bard's stores have no wikilink-rewrite concept
//! either), so this is composed in, never a fifth `Store` method.

const std = @import("std");

pub const Renamer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        rename: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, old_path: []const u8, new_path: []const u8) anyerror!void,
    };

    /// `old_path`/`new_path` are full vault-relative paths, the same
    /// addressing `Store`/`LinkGraph` already use for a namespace-less
    /// (vault-wide) node.
    pub fn rename(self: Renamer, gpa: std.mem.Allocator, io: std.Io, old_path: []const u8, new_path: []const u8) anyerror!void {
        return self.vtable.rename(self.ptr, gpa, io, old_path, new_path);
    }

    /// The wrapper idiom, identical to `Store.from`/`LinkGraph.from`: builds
    /// a `Renamer` from any concrete `T` exposing `rename` with this same
    /// shape, self-first.
    pub fn from(comptime T: type, self: *T) Renamer {
        const Impl = struct {
            fn rename(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, old_path: []const u8, new_path: []const u8) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.rename(gpa, io, old_path, new_path);
            }
        };
        return .{ .ptr = self, .vtable = &.{ .rename = Impl.rename } };
    }
};
