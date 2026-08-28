//! Test doubles, one per vtable port -- a build-graph module rather than
//! test-file scaffolding, since each is the second implementation that makes
//! its port a real seam. The Extractor fake also replaces `tree-sitter`,
//! which is linked rather than spawned (`git`/`obsidian` still get
//! intercepted on PATH via `tests/fixtures/fake-bin`).
//!
//! Deliberately dumb: a fake that grows logic starts passing tests the real
//! adapter would fail. Each returns what it's told and records what it saw.

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
