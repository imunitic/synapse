//! Store: where nodes and indexes are read, written, listed and searched.
//!
//! `DiskStore`'s own ranked full-text index for a vault; plain files under
//! `_bard/graph/` for a bible. Search belongs here rather than in core,
//! since "full-text over prose" vs. "exact symbol lookup" is an
//! adapter-specific question.

const std = @import("std");

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Hit = struct {
        node: []const u8,
        score: f32,
        context: []const u8,
    };

    /// What a backend said about a `write` beyond plain success -- an
    /// anticipated rejection, not the same thing as the `anyerror` a
    /// transport failure (a disk error, an unreachable network endpoint)
    /// still throws.
    /// `status`/`body` are HTTP-shaped because that's the one real case
    /// with something to say beyond accepted/not: a file-backed store
    /// (`BardGraphStore`, `FakeStore`) always returns `.{ .accepted = true }`
    /// on its own non-error path, since a plain file write has no "the
    /// backend answered but said no" case the way HTTP does.
    pub const WriteResult = struct {
        accepted: bool,
        /// The HTTP status, or 0 when the backend has no such concept.
        status: u16 = 0,
        /// The response body, or empty when there's none to show.
        /// Caller-owned when non-empty.
        body: []const u8 = "",
    };

    pub const VTable = struct {
        /// Null when the node doesn't exist -- an ordinary answer, not an
        /// error (a first build asks for nodes that aren't there yet).
        read: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            node: []const u8,
        ) anyerror!?[]u8,

        write: *const fn (
            ptr: *anyopaque,
            io: std.Io,
            node: []const u8,
            body: []const u8,
        ) anyerror!WriteResult,

        /// Caller-owned: free the outer slice and every name in it. A
        /// directory-backed implementation can only hand back names that
        /// outlive its own iterator by copying them -- the contract has to
        /// hold for every implementation, not just the ones for which it'd
        /// be free.
        list: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
        ) anyerror![]const []const u8,

        search: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            query: []const u8,
        ) anyerror![]const Hit,
    };

    pub fn read(self: Store, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror!?[]u8 {
        return self.vtable.read(self.ptr, gpa, io, node);
    }

    pub fn write(self: Store, io: std.Io, node: []const u8, body: []const u8) anyerror!WriteResult {
        return self.vtable.write(self.ptr, io, node, body);
    }

    pub fn list(self: Store, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
        return self.vtable.list(self.ptr, gpa, io);
    }

    pub fn search(self: Store, gpa: std.mem.Allocator, io: std.Io, query: []const u8) anyerror![]const Hit {
        return self.vtable.search(self.ptr, gpa, io, query);
    }

    /// Builds a `Store` from any concrete `T` exposing `read`/`write`/`list`/
    /// `search` with this same shape, self-first (otherwise identical to
    /// `VTable`'s own signatures) -- the wrapper idiom: the
    /// compiler generates the one `*anyopaque` -> `*T` cast, from `T` alone,
    /// so `.ptr` and the vtable's function pointers can never be built from
    /// two different concrete types the way a hand-written `.store()`
    /// literal could. Every real implementation (`DiskStore`,
    /// `BardGraphStore`, `BardVaultStore`, `FakeStore`) gets its own
    /// `.store()` for free by calling this once with its own type -- no
    /// hand-written vtable anywhere.
    pub fn from(comptime T: type, self: *T) Store {
        const Impl = struct {
            fn read(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, node: []const u8) anyerror!?[]u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.read(gpa, io, node);
            }
            fn write(ptr: *anyopaque, io: std.Io, node: []const u8, body: []const u8) anyerror!WriteResult {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.write(io, node, body);
            }
            fn list(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.list(gpa, io);
            }
            fn search(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, query: []const u8) anyerror![]const Hit {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.search(gpa, io, query);
            }
        };
        return .{ .ptr = self, .vtable = &.{
            .read = Impl.read,
            .write = Impl.write,
            .list = Impl.list,
            .search = Impl.search,
        } };
    }
};
