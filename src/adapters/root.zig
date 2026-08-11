//! Adapters: the concrete implementations behind the domain ports, plus the
//! small helpers they share. Everything that touches a C library, a network,
//! or another process lives at or below this level, and never in `core`.
//!
//! Per-app dependency sets are what make a second product cheap: an executable
//! imports only the adapters it wires, so a build that never lists the
//! tree-sitter adapter links no libtree-sitter and needs no C compiler.

const std = @import("std");

pub const process = @import("process.zig");
pub const fakes = @import("fakes/root.zig");
pub const treesitter = @import("treesitter/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = process;
    _ = fakes;
    _ = treesitter;
}
