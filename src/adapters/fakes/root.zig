//! Test doubles, one per vtable port.
//!
//! These are a module in the build graph rather than scaffolding inside test
//! files, because they are the second implementation that makes each port a
//! seam rather than an indirection with one caller. They are also what
//! replaces the part of `tests/fixtures/fake-bin` that the port actually
//! deletes: `git` and `curl` keep being intercepted on PATH, since a compiled
//! binary still spawns them, but `tree-sitter` is linked rather than spawned
//! and the Extractor fake is what stands in for it.
//!
//! Deliberately dumb. A fake that grows logic starts passing tests the real
//! adapter would fail; each of these returns what it was told to return and
//! records what it was asked.

const std = @import("std");

pub const Extractor = @import("extractor.zig").FakeExtractor;
pub const Store = @import("store.zig").FakeStore;
pub const Clusterer = @import("clusterer.zig").FakeClusterer;

test {
    std.testing.refAllDecls(@This());
    _ = @import("extractor.zig");
    _ = @import("store.zig");
    _ = @import("clusterer.zig");
}
