//! SearchFiltered: full-text search scoped to a candidate path set. A
//! separate capability from `Store`, same shape as `LinkGraph`/`Renamer`:
//! not every `Store` needs a path-filtered search (Bard's stores never call
//! one), so this is composed in, never a fifth `Store` method.

const std = @import("std");
const store = @import("store.zig");

const Store = store.Store;

pub const SearchFiltered = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        searchFiltered: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            query: []const u8,
            path_filter: ?std.json.Value,
        ) anyerror![]const Store.Hit,
    };

    pub fn searchFiltered(
        self: SearchFiltered,
        gpa: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        return self.vtable.searchFiltered(self.ptr, gpa, io, query, path_filter);
    }

    /// The wrapper idiom, identical to `Store.from`/`LinkGraph.from`/
    /// `Renamer.from`: builds a `SearchFiltered` from any concrete `T`
    /// exposing `searchFiltered` with this same shape, self-first.
    pub fn from(comptime T: type, self: *T) SearchFiltered {
        const Impl = struct {
            fn searchFiltered(
                ptr: *anyopaque,
                gpa: std.mem.Allocator,
                io: std.Io,
                query: []const u8,
                path_filter: ?std.json.Value,
            ) anyerror![]const Store.Hit {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.searchFiltered(gpa, io, query, path_filter);
            }
        };
        return .{ .ptr = self, .vtable = &.{ .searchFiltered = Impl.searchFiltered } };
    }
};
