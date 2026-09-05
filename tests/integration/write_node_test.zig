//! The two `write-node` warning pairs that only ever reach real stderr via
//! `std.debug.print`, which no in-process fixture captures. Node-assembly
//! logic, the real-git baseline-commit/dirty-sources fields, and the
//! tags-cache wiring all have native `zig build test` coverage already
//! (`write_node_cmd.zig`'s own tests, calling `write()` directly).

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

const body_text = "## Summary\nA node.\n\n## Links\n- part_of [[Other]]\n";

/// A file directly under the fixture's own scratch root, parent dirs
/// included.
fn writeRootFile(fx: *Fixture, sub_path: []const u8, data: []const u8) !void {
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

/// `write-node --title <t> --summary <s> --paths <paths> --body <body>`,
/// run from inside `fx.repo` -- the script resolves the repo from cwd.
fn runWrite(fx: *Fixture, extra: []const []const u8) !adapters.process.Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(fx.gpa);
    try argv.append(fx.gpa, "write-node");
    try argv.appendSlice(fx.gpa, extra);
    return fx.runFake(argv.items);
}

/// A repo with files at three shapes the `## Sources` module rule treats
/// differently: under a module's src/, under a top-level dir, and at the
/// root.
fn makeLayeredRepo(fx: *Fixture) !void {
    try fx.makeRepo(null);
    try fx.writeRepoFile("mod-a/src/main/java/com/example/A.java", "class A {}\n");
    try fx.writeRepoFile("mod-a/src/main/java/com/example/B.java", "class B {}\n");
    try fx.writeRepoFile("mod-b/src/main/java/C.java", "class C {}\n");
    try fx.writeRepoFile("docs/guide.md", "# doc\n");
    try fx.writeRepoFile("rootfile.txt", "root\n");
    const add_res = try fx.git(&.{ "add", "-A" });
    add_res.deinit(fx.gpa);
    const commit_res = try fx.git(&.{ "-c", "user.email=test@test", "-c", "user.name=test", "commit", "-q", "-m", "layered" });
    commit_res.deinit(fx.gpa);
}

test "uncommitted changes in this node's own sources are called out" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try makeLayeredRepo(&fx);
    try writeRootFile(&fx, "body.md", body_text);
    try writeRootFile(&fx, "paths.txt", "mod-a/src/main/java/com/example/A.java\n");
    try fx.writeRepoFile("mod-a/src/main/java/com/example/A.java", "class A { int changed; }\n");

    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const body = try std.fmt.allocPrint(fx.gpa, "{s}/body.md", .{fx.root});
    defer fx.gpa.free(body);

    const r = try runWrite(&fx, &.{ "--title", "Dirty", "--summary", "A one-line summary.", "--paths", paths, "--body", body });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    // git hash-object fingerprints the worktree, so the recorded commit is
    // "what was checked out" rather than a faithful baseline -- worth
    // saying, since a later diff would otherwise compare against content
    // that was never committed.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "uncommitted changes in this node's sources") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "A.java") != null);
}

test "a dirty file outside the node's sources stays quiet" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try makeLayeredRepo(&fx);
    try writeRootFile(&fx, "body.md", body_text);
    try writeRootFile(&fx, "paths.txt", "docs/guide.md\n");
    try fx.writeRepoFile("mod-a/src/main/java/com/example/A.java", "class A { int changed; }\n");

    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const body = try std.fmt.allocPrint(fx.gpa, "{s}/body.md", .{fx.root});
    defer fx.gpa.free(body);

    const r = try runWrite(&fx, &.{ "--title", "Quiet", "--summary", "A one-line summary.", "--paths", paths, "--body", body });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    // Narrow on purpose: a developer mid-work elsewhere in the repo should
    // not be warned on every node write.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "uncommitted changes") == null);
}

test "a title needing sanitizing warns that inbound wikilinks will not resolve" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try fx.makeRepo(null);
    try writeRootFile(&fx, "body.md", body_text);
    try writeRootFile(&fx, "paths.txt", "src/foo.aa\n");

    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const body = try std.fmt.allocPrint(fx.gpa, "{s}/body.md", .{fx.root});
    defer fx.gpa.free(body);

    const r = try runWrite(&fx, &.{ "--title", "Bad — import/export", "--summary", "A one-line summary.", "--paths", paths, "--body", body });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stderr, "WARNING") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "will not resolve") != null);
}

test "a clean title writes silently" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try fx.makeRepo(null);
    try writeRootFile(&fx, "body.md", body_text);
    try writeRootFile(&fx, "paths.txt", "src/foo.aa\n");

    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const body = try std.fmt.allocPrint(fx.gpa, "{s}/body.md", .{fx.root});
    defer fx.gpa.free(body);

    const r = try runWrite(&fx, &.{ "--title", "Bad — import and export", "--summary", "A one-line summary.", "--paths", paths, "--body", body });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stderr, "WARNING") == null);
}
