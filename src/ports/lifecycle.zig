//! Lifecycle: which node fields are maintained.
//!
//! **A value, not a vtable, and that is a deliberate departure from the other
//! three ports.** Lifecycle has no behaviour to dispatch: it answers whether a
//! product maintains a crux pointer, a `sources_digest`, `grounded_in` hashes.
//! The behaviour behind each answer is core's, and it is the same code in both
//! products — what differs is only whether it runs. Wrapping four booleans in
//! an opaque pointer and a function table would be ceremony that obscures
//! rather than substitutes.
//!
//! It stays in `ports` because it is still a seam: the thing a product picks
//! and core consults, sitting in the same place a reader looks for the others.

const std = @import("std");

pub const Lifecycle = struct {
    /// A pointer into a source file, sliced verbatim into the node.
    crux: bool,
    /// A digest over the node's sources, for tier-2 staleness verification.
    sources_digest: bool,
    /// Per-claim hashes over the exact lines a statement rests on.
    grounded_in: bool,

    /// Code: an opaque source file has to be compressed into something an LLM
    /// does not re-read and re-derive every time, and every one of these
    /// exists to make that compression checkable rather than trusted.
    pub const full: Lifecycle = .{
        .crux = true,
        .sources_digest = true,
        .grounded_in = true,
    };

    /// A bible: YAML frontmatter already *is* the compact record, so there is
    /// nothing to compress and nothing to verify a compression against. Not a
    /// reduced version of the code lifecycle — an absent one.
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
