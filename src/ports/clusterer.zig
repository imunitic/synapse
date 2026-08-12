//! Clusterer: source paths in, proposed nodes out.
//!
//! The two products differ more here than anywhere else. For code the
//! clustering is *inferred* — vocabulary and directory weight, the process
//! `synapse-orientation` describes, which is genuine work with a cost. For a
//! bible it is simply *read*: the repo's own folder taxonomy already is the
//! cluster hierarchy, every non-underscore folder a cluster, and there is no
//! inference step at all.
//!
//! That asymmetry is the reason this is a port rather than a core function.
//! Core wants "what are the nodes"; how expensive that question is, and
//! whether answering it involves reading a directory listing or ranking a
//! symbol vocabulary, is not core's business.

const std = @import("std");

pub const Clusterer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Cluster = struct {
        /// Proposed node name. A clusterer that reads a taxonomy takes this
        /// from the folder; one that infers has to derive it.
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
