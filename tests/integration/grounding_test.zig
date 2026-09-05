//! `query grounding`'s one genuinely process-level concern: a real
//! write-node -> query round trip proving `grounded_in` provenance survives
//! a realistic edit-regenerate-rewrite cycle. The verification logic itself
//! has native coverage (`query_cmd.zig`'s own tests, calling `cmdGrounding`
//! directly).

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

/// Everything up to (not including) the first `## Sources` line: what a
/// regeneration actually has in hand, the prose with no directives in it.
fn stripSourcesOnward(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "## Sources")) break;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// A node grounded in a two-line doc comment at the top of calc.aa.
fn buildGroundedNode(fx: *Fixture) !void {
    try fx.makeRepo(null);
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(fx.gpa);
    try body.appendSlice(fx.gpa, "(* Computes the premium for a contract.\n   Rounds half-up at two decimals. *)\n");
    var i: usize = 3;
    while (i <= 12) : (i += 1) {
        const line = try std.fmt.allocPrint(fx.gpa, "let line{d:0>2} = {d}\n", .{ i, i });
        defer fx.gpa.free(line);
        try body.appendSlice(fx.gpa, line);
    }
    try fx.writeRepoFile("lib/calc.aa", body.items);

    const add_res = try fx.git(&.{ "add", "lib/calc.aa" });
    add_res.deinit(fx.gpa);
    const commit_res = try fx.git(&.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "calc" });
    commit_res.deinit(fx.gpa);

    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "paths.txt", .data = "src/foo.aa\nlib/calc.aa\n" });
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = "body.md",
        .data = "## Summary\nRounds half-up at two decimals.\n<!-- grounded_in: lib/calc.aa 1-2 -->\n",
    });

    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const write_body = try std.fmt.allocPrint(fx.gpa, "{s}/body.md", .{fx.root});
    defer fx.gpa.free(write_body);
    const r = try fx.runFake(&.{ "write-node", "--title", "Premium", "--summary", "Premium calc.", "--paths", paths, "--body", write_body });
    defer r.deinit(fx.gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const remote = try fx.repoRemoteOrPath();
    defer fx.gpa.free(remote);
    try fx.writeSynapseIndex(ns, remote);

    const work_dir = try fx.defaultWorkDir();
    defer fx.gpa.free(work_dir);
    try fx.writeIndexBin(work_dir, &.{
        .{ .path = "lib/calc.aa", .node = "Premium.md" },
        .{ .path = "src/foo.aa", .node = "Premium.md" },
    });
}

test "round trip: --list plus re-emit preserves groundings; omitting them loses all" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try buildGroundedNode(&fx);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const node_path = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}/Premium.md", .{ns});
    defer fx.gpa.free(node_path);

    const r1 = try fx.runFake(&.{ "query", "body", "Premium" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    const recovered = try stripSourcesOnward(testing.allocator, r1.stdout);
    defer testing.allocator.free(recovered);
    try testing.expect(std.mem.indexOf(u8, recovered, "grounded_in") == null);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "recovered.md", .data = recovered });

    // (a) writing the recovered body back as-is drops the provenance, silently.
    const paths = try std.fmt.allocPrint(fx.gpa, "{s}/paths.txt", .{fx.root});
    defer fx.gpa.free(paths);
    const recovered_path = try std.fmt.allocPrint(fx.gpa, "{s}/recovered.md", .{fx.root});
    defer fx.gpa.free(recovered_path);
    const r2 = try fx.runFake(&.{ "write-node", "--title", "Premium", "--summary", "Premium calc.", "--paths", paths, "--body", recovered_path });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());

    const after_a = try fx.dir.readFileAlloc(std.testing.io, node_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(after_a);
    try testing.expect(!lineStartsWith(after_a, "grounded_in:"));

    // (b) re-emitting from --list restores it exactly -- which is why --list exists.
    var reemit: std.ArrayListUnmanaged(u8) = .empty;
    defer reemit.deinit(testing.allocator);
    try reemit.appendSlice(testing.allocator, recovered);
    try reemit.appendSlice(testing.allocator, "<!-- grounded_in: lib/calc.aa 1-2 -->\n");
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "reemit.md", .data = reemit.items });

    const reemit_path = try std.fmt.allocPrint(fx.gpa, "{s}/reemit.md", .{fx.root});
    defer fx.gpa.free(reemit_path);
    const r3 = try fx.runFake(&.{ "write-node", "--title", "Premium", "--summary", "Premium calc.", "--paths", paths, "--body", reemit_path });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r3.exitCode());

    const after_b = try fx.dir.readFileAlloc(std.testing.io, node_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(after_b);
    try testing.expect(std.mem.indexOf(u8, after_b, "  - path: lib/calc.aa\n") != null);
    try testing.expect(std.mem.indexOf(u8, after_b, "    lines: \"1-2\"\n") != null);

    const r4 = try fx.runFake(&.{ "query", "grounding" });
    defer r4.deinit(testing.allocator);
    try testing.expectEqualStrings("", r4.stdout);
}

fn lineStartsWith(body: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}
