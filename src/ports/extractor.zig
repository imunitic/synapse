//! Extractor: source files in, defs and refs out.
//!
//! Tree-sitter for code; a frontmatter parser for a bible, where a def is the
//! entity's own identity and a ref is each relationship field.
//!
//! **Batch-shaped on purpose**, not per-file: CLI startup and grammar load
//! dominate the per-file cost (measured: 0.076s for 200 files in one
//! invocation vs. 2.543s for 200 invocations). The port takes a slice of
//! paths; each implementation batches as it sees fit.

const std = @import("std");
const model = @import("model");

pub const Extractor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// A file that parsed to nothing differs from one with no grammar --
    /// the tags cache needs to know which, so a re-attempt isn't repeated
    /// on every call.
    pub const Outcome = union(enum) {
        tags: []const model.Tag,
        unsupported,
    };

    pub const VTable = struct {
        /// One outcome per requested path, same order. `root` is the
        /// directory paths are relative to. Returned data is caller-owned.
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
