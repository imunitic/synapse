//! Port definitions: vtables and the types crossing them. No implementations
//! live here, and this module imports nothing but `std` -- that is what lets
//! `core` and every adapter depend on it without a cycle.
//!
//! Four domain ports carry what differs between products (Extractor, Store,
//! Clusterer, Lifecycle). One system port carries what `std.Io` does not
//! already provide, which is process spawning (Exec). Filesystem, clock,
//! network and file mapping are `std.Io`'s job and get no port of ours.
//!
//! Each port arrives together with a fake in `src/adapters/fakes/`. A port
//! with a single implementation is not a seam, and the fakes are also what
//! replaces the PATH-shimmed `tests/fixtures/fake-bin` executables.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
