//! Adapters: the concrete implementations behind the domain ports, plus the
//! small helpers they share. Everything that touches a C library, a network,
//! or another process lives at or below this level, and never in `core`.
//!
//! Per-app dependency sets are what make a second product cheap: an executable
//! imports only the adapters it wires, so a build that never lists the
//! tree-sitter adapter links no libtree-sitter and needs no C compiler.
//!
//! Which is why the tree-sitter Extractor is deliberately *not* re-exported
//! here despite living under `src/adapters/`. It is its own build module. This
//! one is the dependency-free half, and bard imports it.

const std = @import("std");

pub const process = @import("process.zig");
pub const fakes = @import("fakes/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = process;
    _ = fakes;
    // Referenced from the test block only, and deliberately not `pub`: Zig
    // analyses lazily, so the frontmatter Extractor is compiled when the tests
    // are and never reaches a release build. It is a conformance check on the
    // port, not a second product's adapter -- see its own header.
    _ = @import("frontmatter_conformance.zig");
}
