//! Whether a `Store` node name is safe to address a file with -- shared by
//! every `Store` implementation that turns `node` into a real path (a
//! filesystem join today, potentially something else for a future backend),
//! so every implementation rejects the same inputs rather than each rolling
//! its own check.

const std = @import("std");

/// False for an absolute path, or a `node` containing a `..` path segment
/// anywhere in it (not just leading) -- either would let a caller escape
/// whatever root the concrete `Store` addresses `node` relative to. A plain
/// join (filesystem or URL) has no opinion on either: the OS, or a REST
/// server on the other end, resolves a literal `..` exactly as it would
/// anywhere else.
pub fn isSafe(node: []const u8) bool {
    if (node.len != 0 and node[0] == '/') return false;
    var it = std.mem.splitScalar(u8, node, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

const testing = std.testing;

test "a bare title or a namespaced relative path is safe" {
    try testing.expect(isSafe("Foo.md"));
    try testing.expect(isSafe("designs/synapse/sb-001.md"));
}

test "a leading .. segment is rejected" {
    try testing.expect(!isSafe("../../../../etc/passwd"));
}

test "a .. segment buried mid-path is rejected too, not just a leading one" {
    try testing.expect(!isSafe("a/../../b.md"));
}

test "an absolute path is rejected" {
    try testing.expect(!isSafe("/etc/passwd"));
}

test "a single dot segment is not a traversal and stays safe" {
    // Not the attack this guards against -- `.` doesn't change directory,
    // and a node named e.g. ".config.md" is an ordinary filename.
    try testing.expect(isSafe("./Foo.md"));
}
