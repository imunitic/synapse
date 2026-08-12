//! The node format, and the rules two scripts had to agree about by hand.
//!
//! `synapse-write-node.sh` produces a node and `synapse-query.sh` reads one, so
//! every rule below existed twice in bash with a comment asking the copies to
//! stay in step. Write-node's said it outright above its own `module_of`: *"Two
//! groupings for one concept is a divergence nobody notices for months, so this
//! must not drift from synapse-query.sh's --modules."* A shared implementation is
//! the only thing that retires a comment like that.
//!
//! ## What a node looks like
//!
//! ```
//! ---
//! title: "State machine"
//! node_type: synapse-node
//! project: fw-core
//! sources:
//!   - path: statemachine/src/main/java/.../StateMachine.java
//!     hash: f98dd5a829c27ab4161f252ee857ece38e294d35
//! sources_digest: "df91a067…4a7526"
//! stale: false
//! built_at: "2026-08-03 16:50"
//! ---
//!
//! # State machine
//! <!-- synapse:generated:start -->
//!
//! ## Summary
//! …prose…
//!
//! ## Crux
//! ```java
//! …lines sliced verbatim from a source file…
//! ```
//!
//! ## Links
//! - uses [[Service framework — ServiceContext, ServiceFactory and sessions]]
//!
//! ## Sources
//! - `statemachine` (19)
//! <!-- synapse:generated:end -->
//!
//! ## Notes
//! ```
//!
//! The fence is the contract with the human: everything between the markers is
//! regenerated on every write, and everything after `synapse:generated:end` --
//! `## Notes` in practice -- is carried through untouched. A writer that
//! regenerated the whole file would silently eat hand-written notes, and a
//! regeneration is not an event anyone reviews.

const std = @import("std");

/// The `## Sources` mirror's grouping, and `query sources --modules`'s.
///
/// Configured boilerplate chains carry no subsystem information -- `src/main/java`
/// says nothing about what a module is *for* -- so a path containing one is cut
/// at the segment before it. A flat `<pkg>/src/<subsystem>/…` layout has no such
/// chain, and there the segment right *after* `src/` is the subsystem, so one is
/// kept. Failing both, the first path component; failing that, `(repo root)`.
///
/// `chains` comes from `~/.claude/synapse-module-boilerplate.conf`, and an empty
/// list is not a failure: grouping still works, it just stops collapsing any
/// ecosystem's scaffolding.
pub fn moduleOf(path: []const u8, chains: []const []const u8) []const u8 {
    // First match wins, in the order the conf lists them -- the awk broke out of
    // its loop on the first hit, and a longer chain listed later must not
    // override a shorter one listed earlier.
    for (chains) |chain| {
        if (chain.len == 0) continue;
        // Searched as `/chain/`, so a chain never matches at position zero and a
        // partial segment never matches at all: `src/main` must not fire on
        // `mysrc/maintenance`.
        var buf: [256]u8 = undefined;
        const pattern = std.fmt.bufPrint(&buf, "/{s}/", .{chain}) catch continue;
        if (std.mem.indexOf(u8, path, pattern)) |at| return path[0..at];
    }

    if (std.mem.indexOf(u8, path, "/src/")) |at| {
        const base = path[0..at];
        const rest = path[at + 5 ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // `base/src/<subsystem>`, rebuilt by the caller: returning a slice
            // means the two halves have to be contiguous in the input, and they
            // are -- this is exactly `path` up to the end of that segment.
            return path[0 .. at + 5 + slash];
        }
        return base;
    }

    if (std.mem.indexOfScalar(u8, path, '/')) |at| return path[0..at];
    return repo_root_module;
}

pub const repo_root_module = "(repo root)";

/// One source a node claims, at the content hash it was last seen with.
pub const Source = struct {
    path: []const u8,
    /// 40 hex characters, as written in the node. Kept as text rather than
    /// parsed: this type's job is the file's contract, and the node stores hex.
    hash: []const u8,
};

/// `sha256` over `LC_ALL=C`-sorted `path:hash` lines, joined by newlines with no
/// trailing one.
///
/// Pinned in three places in the bash -- `/synapse-init`'s procedure,
/// `synapse-write-node.sh` and `synapse-query.sh stale` -- and all three had to
/// agree or every node reports a false mismatch forever. The sort is byte order,
/// which is what `LC_ALL=C sort` meant and what Zig does anyway.
///
/// Returns the digest as 64 lowercase hex characters, the form the node stores.
pub fn sourcesDigest(gpa: std.mem.Allocator, sources: []const Source) ![64]u8 {
    var lines = try gpa.alloc([]u8, sources.len);
    defer {
        for (lines) |l| gpa.free(l);
        gpa.free(lines);
    }
    for (sources, 0..) |s, i| lines[i] = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ s.path, s.hash });
    std.mem.sort([]u8, lines, {}, lessByBytes);

    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (lines, 0..) |l, i| {
        if (i > 0) sha.update("\n");
        sha.update(l);
    }
    var raw: [32]u8 = undefined;
    sha.final(&raw);

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&raw}) catch unreachable;
    return hex;
}

fn lessByBytes(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const generated_start = "<!-- synapse:generated:start -->";
pub const generated_end = "<!-- synapse:generated:end -->";

/// A node split into the part a writer owns and the part a human does.
pub const Split = struct {
    /// Everything before and including the `# Title` line and the start marker.
    head: []const u8,
    /// Everything from the end marker onward -- `## Notes` and whatever follows.
    /// Empty when the node has no end marker, which is a node written before the
    /// fence existed.
    tail: []const u8,
    /// True when both markers were found. A node missing them is not an error:
    /// the writer replaces the whole body, which is what it did before the fence
    /// was introduced.
    fenced: bool,
};

/// Where the generated region begins and ends, so a rewrite can replace it and
/// keep everything else byte-for-byte.
pub fn split(body: []const u8) Split {
    const start = std.mem.indexOf(u8, body, generated_start) orelse
        return .{ .head = body, .tail = "", .fenced = false };
    const after_start = start + generated_start.len;
    const end = std.mem.indexOfPos(u8, body, after_start, generated_end) orelse
        return .{ .head = body, .tail = "", .fenced = false };
    return .{
        .head = body[0..after_start],
        .tail = body[end..],
        .fenced = true,
    };
}

const testing = std.testing;

/// A copy of `claude/synapse-module-boilerplate.conf.template`'s chains, so the
/// tests below exercise realistic input rather than invented input.
///
/// Deliberately *not* claimed to be kept in sync automatically -- there is no
/// check, and pretending otherwise would be worse than the copy. It is safe to
/// drift because `moduleOf` takes its chains as a parameter: a stale constant
/// here weakens these tests and cannot change what a caller computes. The
/// production list is whatever the installed conf says, which is the point of
/// its being configured at all.
const default_chains = [_][]const u8{
    "src/main/java", "src/test/java", "src/main/resources",
};

test "a boilerplate chain cuts at the segment before it" {
    const p = "statemachine/src/main/java/com/adcubum/State.java";
    try testing.expectEqualStrings("statemachine", moduleOf(p, &default_chains));

    const nested = "core/sub/src/test/java/com/x/FooTest.java";
    try testing.expectEqualStrings("core/sub", moduleOf(nested, &default_chains));
}

test "a flat src layout keeps one segment after src" {
    // No boilerplate chain here, so `/src/` is the fallback and the segment
    // *after* it is the subsystem -- the opposite of the chain case, and the
    // distinction the comment in both scripts was protecting.
    const p = "qst-basis/src/berechtigung/Rights.java";
    try testing.expectEqualStrings("qst-basis/src/berechtigung", moduleOf(p, &default_chains));
}

test "a src directory with nothing after it falls back to the base" {
    try testing.expectEqualStrings("pkg", moduleOf("pkg/src/", &default_chains));
    try testing.expectEqualStrings("pkg", moduleOf("pkg/src/Foo.java", &default_chains));
}

test "no chain and no src falls to the first component, then the root" {
    try testing.expectEqualStrings("docs", moduleOf("docs/guide.md", &default_chains));
    try testing.expectEqualStrings("a", moduleOf("a/b/c/d.txt", &default_chains));
    try testing.expectEqualStrings(repo_root_module, moduleOf("README.md", &default_chains));
}

test "a chain matches only on whole segments" {
    // `/src/main/java/` searched with its slashes, so neither of these is a hit
    // and both fall through to the later rules.
    try testing.expectEqualStrings("mysrc", moduleOf("mysrc/maintenance/x.java", &default_chains));
    try testing.expectEqualStrings("a", moduleOf("a/notsrc/main/java/x.java", &default_chains));
}

test "an empty chain list still groups, just without collapsing" {
    try testing.expectEqualStrings(
        "statemachine/src/main",
        moduleOf("statemachine/src/main/java/com/x/State.java", &.{}),
    );
    try testing.expectEqualStrings("docs", moduleOf("docs/guide.md", &.{}));
}

test "the first listed chain wins" {
    // The awk broke out on its first hit, so order in the conf decides. A path
    // containing two chains resolves by the earlier one.
    const chains = [_][]const u8{ "src", "src/main/java" };
    try testing.expectEqualStrings("pkg", moduleOf("pkg/src/main/java/X.java", &chains));
}

test "sources_digest is sha256 over sorted path:hash lines" {
    const gpa = testing.allocator;
    // Deliberately out of order on input: the digest sorts, so two nodes with the
    // same sources in a different order must agree.
    const a = try sourcesDigest(gpa, &.{
        .{ .path = "b.java", .hash = "2222222222222222222222222222222222222222" },
        .{ .path = "a.java", .hash = "1111111111111111111111111111111111111111" },
    });
    const b = try sourcesDigest(gpa, &.{
        .{ .path = "a.java", .hash = "1111111111111111111111111111111111111111" },
        .{ .path = "b.java", .hash = "2222222222222222222222222222222222222222" },
    });
    try testing.expectEqualStrings(&a, &b);
    try testing.expectEqual(@as(usize, 64), a.len);

    // A changed hash changes the digest -- the whole point of the field.
    const c = try sourcesDigest(gpa, &.{
        .{ .path = "a.java", .hash = "1111111111111111111111111111111111111111" },
        .{ .path = "b.java", .hash = "3333333333333333333333333333333333333333" },
    });
    try testing.expect(!std.mem.eql(u8, &b, &c));
}

test "an empty source list digests to sha256 of nothing" {
    const gpa = testing.allocator;
    const d = try sourcesDigest(gpa, &.{});
    // sha256("") -- a node claiming no files still has a well-defined digest
    // rather than an empty field that reads as "not computed".
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &d,
    );
}

test "split isolates the generated region and keeps the tail byte for byte" {
    const body =
        "# Title\n" ++ generated_start ++ "\n\n## Summary\nprose\n" ++
        generated_end ++ "\n\n## Notes\nhand written\n";
    const s = split(body);
    try testing.expect(s.fenced);
    try testing.expectEqualStrings("# Title\n" ++ generated_start, s.head);
    try testing.expectEqualStrings(generated_end ++ "\n\n## Notes\nhand written\n", s.tail);
}

test "a node with no fence is not an error, it is a whole-body rewrite" {
    const s = split("# Title\n\n## Summary\nold style\n");
    try testing.expect(!s.fenced);
    try testing.expectEqualStrings("", s.tail);
}

test "a start marker with no end marker is treated as unfenced" {
    // Half a fence cannot say where the generated region stops, and guessing
    // would put a writer's output on top of whatever followed.
    const s = split("# T\n" ++ generated_start ++ "\n## Summary\nx\n");
    try testing.expect(!s.fenced);
}
