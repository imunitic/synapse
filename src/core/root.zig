//! The graph itself: the def/ref model, the source-path-to-owning-node index
//! and its reverse, tokenizer, vocabulary, ranking, query and traversal,
//! staleness bookkeeping, and the tags cache. All of it operates on defs and
//! refs, never on how they were extracted or where they are stored -- which is
//! what lets a second product reuse this without a fork.
//!
//! Purity, in the specific sense that applies here: core reaches the system
//! only through an injected `std.Io` and the ports, and spawns nothing itself.
//! It does not name `std.fs`, `std.process`, `std.time` or `std.http`. Taking
//! an `Io` parameter and doing I/O through it is the design; naming those
//! namespaces directly is what `just check`'s purity gate forbids, because the
//! build graph can enforce "imports no adapter" but cannot enforce this.

const std = @import("std");

pub const ports = @import("ports");
pub const model = @import("model");
pub const tag_line = @import("tag_line.zig");

/// A namespace rather than a `tags_cache.zig` that only re-exports one thing.
/// The cache itself -- open, needsTagging, get, commit -- lands here next, at
/// which point this becomes an import of that file.
pub const tags_cache = struct {
    pub const format = @import("tags_cache/format.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = model;
    _ = tag_line;
    _ = tags_cache.format;
}
