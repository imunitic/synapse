//! Three `query` concerns that genuinely need a real spawn: `dispatch.zig`'s
//! own tests only prove the dispatch table returns null for an unknown
//! subcommand name in-process, not that the outer CLI glue turns that into
//! exit 2 with the right usage text; a real branch switch needs
//! `context.resolve`'s git-identity walk to read an actual `.git/HEAD`,
//! which no native fixture's env-var bypass can stand in for; and an
//! implicit resolve's real-remote-mismatch case needs that same walk to
//! compare against a real git remote, not an env-var stand-in.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

test "unknown subcommand and no subcommand both exit 2" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);

    const r1 = try fx.runFake(&.{ "query", "bogus" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try fx.runFake(&.{"query"});
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());
}

// A namespace describes one branch, so another branch has none. Exit 1 is
// "could not run", never "clean" -- reporting clean here would read as a
// graph that matches, the exact conflation the per-branch keying exists to
// remove. A real branch switch is required: `context.resolve`'s
// git-identity walk reads the actual `.git/HEAD`, which no native fixture's
// env-var bypass can stand in for.
test "drift: a branch switch landing on a namespace that doesn't describe it exits 1, not clean" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);

    try fx.writeRepoFile("mod-a/a.bb", "class A {}\n");
    try fx.writeRepoFile("mod-a/b.bb", "class B {}\n");
    try fx.writeRepoFile("docs/guide.md", "# guide\n");
    try fx.gitCommit("two-areas");

    const ns = try fx.repoName();
    defer gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);

    const base = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer gpa.free(base);
    const hash = try fx.gitOutput(&.{ "hash-object", "mod-a/a.bb" });
    defer gpa.free(hash);

    const node_dir = try std.fmt.allocPrint(gpa, "vault/synapse/{s}", .{ns});
    defer gpa.free(node_dir);
    try fx.dir.createDirPath(std.testing.io, node_dir);
    const node_path = try std.fmt.allocPrint(gpa, "{s}/Mod A.md", .{node_dir});
    defer gpa.free(node_path);
    const node_body = try std.fmt.allocPrint(gpa,
        \\---
        \\title: "Mod A"
        \\summary: "One line."
        \\node_type: synapse-node
        \\project: {s}
        \\sources:
        \\  - path: mod-a/a.bb
        \\    hash: {s}
        \\sources_digest: notchecked
        \\stale: false
        \\built_at: "2026-01-01 00:00"
        \\commit: {s}
        \\---
        \\
        \\# Mod A
        \\<!-- synapse:generated:start -->
        \\body
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
    , .{ ns, hash, base });
    defer gpa.free(node_body);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = node_path, .data = node_body });
    try fx.writeIndexBin(fx.work, &.{.{ .path = "mod-a/a.bb", .node = "Mod A.md" }});

    const clean = try fx.runSynapse(&.{ "query", "drift" });
    defer clean.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), clean.exitCode());

    (try fx.git(&.{ "checkout", "-q", "-b", "some-other-branch" })).deinit(gpa);

    const r = try fx.runSynapse(&.{ "query", "drift" });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "is not an ancestor of HEAD") == null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "is not an ancestor of HEAD") == null);
}

test "stale (implicit resolve): a namespace belonging to a different remote exits 1 and reports nothing" {
    // An implicit resolve, unlike `--namespace`, compares the namespace's
    // recorded remote against the real remote of the checkout it's run
    // from -- this needs a real git remote and a real process cwd to mean
    // anything at all.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRepoFile("src/foo.aa", "let x = 1\n");
    (try fx.git(&.{ "remote", "add", "origin", "ssh://git@example.com/mine.git" })).deinit(gpa);
    try fx.gitCommit("init");

    const ns = try fx.repoName();
    defer gpa.free(ns);
    try fx.writeSynapseIndex(ns, "ssh://git@example.com/SOMEONE-ELSE.git");
    try fx.writeIndexBin(fx.work, &.{.{ .path = "src/foo.aa", .node = "Foo Node.md" }});
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);

    const r = try fx.runSynapse(&.{ "query", "stale" });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r.exitCode());
    try testing.expectEqualStrings("", r.stdout);
}
