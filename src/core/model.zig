//! The types the graph is made of. Deliberately small and free of any notion
//! of where a def or a ref came from or where it is stored -- that is what
//! lets a second product reuse the graph without a fork.

const std = @import("std");

/// What tree-sitter calls the tag. Kept separate from `kind` because they
/// answer different questions: a `ref` is not necessarily a call, since an
/// `implements Foo` clause is `ref` with kind `implementation`, so a callers
/// query filtering on `ref` alone over-reports.
pub const Role = enum {
    def,
    ref,

    pub fn parse(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "def")) return .def;
        if (std.mem.eql(u8, s, "ref")) return .ref;
        return null;
    }

    pub fn text(self: Role) []const u8 {
        return @tagName(self);
    }
};

/// One tagged symbol occurrence.
pub const Tag = struct {
    /// Trimmed. tree-sitter space-pads this column (`execute   `), and an
    /// exact-match lookup against the raw text silently finds nothing -- the
    /// failure returns success with no rows, which is indistinguishable from
    /// "this name is never called". Trimming is therefore part of the type's
    /// contract, not a convenience of whoever parses it.
    name: []const u8,
    role: Role,
    /// Syntactic category: class, method, call, implementation, ...
    kind: []const u8,
    /// tree-sitter's own row number for the occurrence, carried through
    /// unchanged. Whether it is 0- or 1-based is tree-sitter's business; the
    /// bash pipeline never adjusted it and neither does this, because
    /// `_refs.tsv` rows and every `path:line` a query prints must not move.
    line: u32,
    /// The source line the occurrence sits on, as tree-sitter echoed it.
    expression: []const u8,
};

/// A source file a node claims, at the content hash it was last seen with.
pub const SourceRef = struct {
    path: []const u8,
    /// Raw 20-byte SHA-1, not 40 hex characters: it halves the tags cache's
    /// record table and turns comparison into a memcmp.
    hash: [20]u8,

    pub fn hashFromHex(hex: []const u8) error{InvalidHash}![20]u8 {
        if (hex.len != 40) return error.InvalidHash;
        var out: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
        return out;
    }

    pub fn hashToHex(hash: [20]u8) [40]u8 {
        var out: [40]u8 = undefined;
        const hex = "0123456789abcdef";
        for (hash, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0x0f];
        }
        return out;
    }
};

/// A graph node: a cluster of sources with prose about them.
///
/// Only the fields the graph itself reasons about are here. The node's
/// LLM-authored parts (crux, summary, `grounded_in`) are Lifecycle's concern
/// and are absent for a product whose lifecycle policy maintains none of them.
pub const Node = struct {
    name: []const u8,
    sources: []const SourceRef,
    stale: bool,
};

test "hash hex round-trips" {
    const hex = "45bc6ae64517e43785674ddad8b92e89b4a8fb4a";
    const raw = try SourceRef.hashFromHex(hex);
    try std.testing.expectEqualStrings(hex, &SourceRef.hashToHex(raw));
}

test "a short or malformed hash is rejected rather than padded" {
    try std.testing.expectError(error.InvalidHash, SourceRef.hashFromHex("45bc6ae6"));
    try std.testing.expectError(error.InvalidHash, SourceRef.hashFromHex("z" ** 40));
}

test "role text is the wire spelling" {
    try std.testing.expectEqualStrings("def", Role.def.text());
    try std.testing.expectEqualStrings("ref", Role.ref.text());
    try std.testing.expectEqual(Role.ref, Role.parse("ref").?);
    try std.testing.expectEqual(@as(?Role, null), Role.parse("defs"));
}
