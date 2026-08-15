//! Port definitions: vtables and the types crossing them. No implementations
//! live here; imports only `model`, which lets `core` and every adapter
//! depend on it without a cycle.
//!
//! Extractor, Store and Clusterer are vtables; Lifecycle is a plain value
//! (see its own file). No system-side port: `std.Io` is already that
//! boundary. Each vtable port has a fake in `src/adapters/fakes/`.

const std = @import("std");

pub const Extractor = @import("extractor.zig").Extractor;
pub const Store = @import("store.zig").Store;
pub const Clusterer = @import("clusterer.zig").Clusterer;
pub const Lifecycle = @import("lifecycle.zig").Lifecycle;

test {
    std.testing.refAllDecls(@This());
    _ = @import("lifecycle.zig");
}
