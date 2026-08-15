//! Lifecycle: which node fields are maintained.
//!
//! A value, not a vtable -- the only port without behaviour to dispatch.
//! Core's code is identical either way; only whether it runs differs, so
//! three booleans need no opaque pointer and function table.

const std = @import("std");

pub const Lifecycle = struct {
    /// A pointer into a source file, sliced verbatim into the node.
    crux: bool,
    /// A digest over the node's sources, for tier-2 staleness verification.
    sources_digest: bool,
    /// Per-claim hashes over the exact lines a statement rests on.
    grounded_in: bool,

    /// Code: makes the LLM's compression of a source file checkable, not trusted.
    pub const full: Lifecycle = .{
        .crux = true,
        .sources_digest = true,
        .grounded_in = true,
    };

    /// A bible: frontmatter already *is* the compact record -- nothing to
    /// compress, nothing to verify. Absent, not reduced.
    pub const none: Lifecycle = .{
        .crux = false,
        .sources_digest = false,
        .grounded_in = false,
    };

    pub fn maintainsAnything(self: Lifecycle) bool {
        return self.crux or self.sources_digest or self.grounded_in;
    }
};

test "the two shipped policies are what their names claim" {
    try std.testing.expect(Lifecycle.full.maintainsAnything());
    try std.testing.expect(!Lifecycle.none.maintainsAnything());
}
