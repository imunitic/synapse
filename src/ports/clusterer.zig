//! Clusterer: source paths in, proposed nodes out.
//!
//! A port rather than a core function because how expensive "what are the
//! nodes" is varies by product: for code it's *inferred* (vocabulary and
//! directory weight, see `synapse-orientation`); for a bible it's simply
//! *read* from the repo's own folder taxonomy. Core doesn't need to know which.

const std = @import("std");

pub const Clusterer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Cluster = struct {
        /// Proposed node name -- from the folder, or derived by inference.
        name: []const u8,
        /// Repo-relative source paths, owned by the caller.
        paths: []const []const u8,
    };

    pub const VTable = struct {
        cluster: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            root: []const u8,
            paths: []const []const u8,
        ) anyerror![]const Cluster,
    };

    pub fn cluster(
        self: Clusterer,
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]const Cluster {
        return self.vtable.cluster(self.ptr, gpa, io, root, paths);
    }
};
