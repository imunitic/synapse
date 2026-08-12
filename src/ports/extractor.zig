//! Extractor: source files in, defs and refs out.
//!
//! Tree-sitter for code; a frontmatter parser for a bible, where a def is the
//! entity's own identity and a ref is each relationship field.
//!
//! **Batch-shaped on purpose.** The obvious signature is one file in, tags
//! out, and it is wrong here: CLI startup and grammar load are nearly all of
//! the per-file cost, measured at 0.076s for 200 files in one invocation
//! against 2.543s for 200 invocations across 12 workers. A per-file port would
//! make that batching impossible to express, so the port takes a slice of
//! paths and the implementation batches as it sees fit -- one CLI call per
//! chunk for tree-sitter, a plain loop for a frontmatter parser that has no
//! startup cost to amortise.

const std = @import("std");
const model = @import("model");

pub const Extractor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// A file that parsed and yielded nothing is not the same as a file the
    /// extractor has no grammar for. Callers must report the second as such
    /// and never as a plain non-match, and the tags cache records it so an
    /// unparseable file is not re-attempted on every call -- which is why the
    /// distinction lives in the type rather than in an empty slice.
    pub const Outcome = union(enum) {
        tags: []const model.Tag,
        unsupported,
    };

    pub const VTable = struct {
        /// One outcome per requested path, in the same order. `root` is the
        /// directory the paths are relative to. The returned slices, and
        /// everything they point at, are owned by the caller.
        extract: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            io: std.Io,
            root: []const u8,
            paths: []const []const u8,
        ) anyerror![]Outcome,
    };

    pub fn extract(
        self: Extractor,
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        paths: []const []const u8,
    ) anyerror![]Outcome {
        return self.vtable.extract(self.ptr, gpa, io, root, paths);
    }
};
