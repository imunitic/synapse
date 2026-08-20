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

    /// Builds an `Extractor` from any concrete `T` exposing `extract` with
    /// this same shape, self-first -- the wrapper idiom (sb-024), same
    /// reasoning as `Store.from`: the compiler generates the one
    /// `*anyopaque` -> `*T` cast, from `T` alone, so it can never disagree
    /// with `.ptr` the way a hand-written `.port()` literal could.
    pub fn from(comptime T: type, self: *T) Extractor {
        const Impl = struct {
            fn extract(
                ptr: *anyopaque,
                gpa: std.mem.Allocator,
                io: std.Io,
                root: []const u8,
                paths: []const []const u8,
            ) anyerror![]Outcome {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.extract(gpa, io, root, paths);
            }
        };
        return .{ .ptr = self, .vtable = &.{ .extract = Impl.extract } };
    }
};
