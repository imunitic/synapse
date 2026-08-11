//! Port definitions: vtables and the types crossing them. No implementations
//! live here, and this module imports only `model` -- that is what lets `core`
//! and every adapter depend on it without a cycle.
//!
//! Three of the four domain ports are vtables: Extractor, Store, Clusterer.
//! Lifecycle is a plain value, because it has no behaviour to dispatch -- see
//! its own file for why that is not an inconsistency.
//!
//! The system side has no port at all. `std.Io` is already that boundary,
//! process spawning included, and re-deriving it here would be ours to
//! maintain against a moving standard library for nothing.
//!
//! Each vtable port arrives together with a fake in `src/adapters/fakes/`. A
//! port with a single implementation is not a seam.

const std = @import("std");

pub const Extractor = @import("extractor.zig").Extractor;
pub const Store = @import("store.zig").Store;
pub const Clusterer = @import("clusterer.zig").Clusterer;
pub const Lifecycle = @import("lifecycle.zig").Lifecycle;

test {
    std.testing.refAllDecls(@This());
    _ = @import("lifecycle.zig");
}
