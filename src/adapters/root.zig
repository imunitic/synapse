//! Adapters: concrete implementations behind the domain ports, plus shared
//! helpers. Anything touching a C library, network, or another process
//! lives here or below, never in `core`.
//!
//! The tree-sitter Extractor is deliberately not re-exported here despite
//! living under `src/adapters/` -- it's its own build module, so an
//! executable that never lists it links no libtree-sitter, no C compiler.

const std = @import("std");

pub const process = @import("process.zig");
pub const fakes = @import("fakes/root.zig");

/// The Obsidian Local REST API behind the Store port. Spawns `curl` and
/// links nothing, so wanting a vault doesn't imply wanting a C compiler.
pub const obsidian = @import("obsidian/store.zig");

test {
    std.testing.refAllDecls(@This());
    _ = process;
    _ = fakes;
    _ = obsidian;
    // Not `pub`: a conformance check on the port, compiled for tests only.
    _ = @import("frontmatter_conformance.zig");
}
