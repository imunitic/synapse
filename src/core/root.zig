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

pub const tags_cache = @import("tags_cache.zig");
pub const index_map = @import("index_map.zig");
pub const enumerate = @import("enumerate.zig");

test {
    std.testing.refAllDecls(@This());
    _ = model;
    _ = tag_line;
    _ = tags_cache;
    _ = index_map;
    _ = enumerate;
    _ = @import("tags_cache/format.zig");
    _ = @import("index_map/format.zig");
}
