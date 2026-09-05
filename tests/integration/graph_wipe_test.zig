//! A real multi-subcommand composition proving graph-wipe and a fresh
//! rebuild actually work together end to end -- the one thing native
//! coverage can't reach. Arg parsing and the wipe logic itself have native
//! coverage (`graph_cmd.zig`'s own tests, via `wipe()`).

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

fn exists(fx: *Fixture, sub_path: []const u8) bool {
    fx.dir.access(std.testing.io, sub_path, .{}) catch return false;
    return true;
}

/// A minimal two-node namespace: one node with hand-written `## Notes`
/// content (at risk), one with the section present but empty (not at
/// risk) -- the exact shape `write-node` produces, not a simplified
/// stand-in, since the extraction logic depends on the literal
/// generated-fence markers.
fn makeNamespace(fx: *Fixture) !void {
    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const project = try fx.nsRepo();
    defer fx.gpa.free(project);
    const branch = try fx.nsBranch();
    defer fx.gpa.free(branch);
    const remote = try fx.repoRemoteOrPath();
    defer fx.gpa.free(remote);

    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);
    try fx.dir.createDirPath(std.testing.io, ns_dir);

    const index_path = try std.fmt.allocPrint(fx.gpa, "{s}/Index.md", .{ns_dir});
    defer fx.gpa.free(index_path);
    const index_body = try std.fmt.allocPrint(fx.gpa,
        \\---
        \\title: "{s} — Synapse index"
        \\node_type: synapse-index
        \\project: {s}
        \\branch: {s}
        \\remote: "{s}"
        \\built_at: "test"
        \\---
        \\- [[Node A]]
        \\- [[Node B]]
        \\
    , .{ ns, project, branch, remote });
    defer fx.gpa.free(index_body);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = index_path, .data = index_body });

    const node_a_path = try std.fmt.allocPrint(fx.gpa, "{s}/Node A.md", .{ns_dir});
    defer fx.gpa.free(node_a_path);
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = node_a_path,
        .data =
        \\---
        \\title: "Node A"
        \\summary: "Node A in one line."
        \\node_type: synapse-node
        \\---
        \\
        \\# Node A
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Generated stuff about Node A.
        \\
        \\## Sources
        \\- `src` (1)
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\Hand-written finding worth keeping: the retry logic here is load-bearing for the batch job, do not simplify it away.
        ,
    });

    const node_b_path = try std.fmt.allocPrint(fx.gpa, "{s}/Node B.md", .{ns_dir});
    defer fx.gpa.free(node_b_path);
    try fx.dir.writeFile(std.testing.io, .{
        .sub_path = node_b_path,
        .data =
        \\---
        \\title: "Node B"
        \\summary: "Node B in one line."
        \\node_type: synapse-node
        \\---
        \\
        \\# Node B
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Generated stuff about Node B.
        \\
        \\## Sources
        \\- `src` (1)
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        ,
    });

    const manifest_path = try std.fmt.allocPrint(fx.gpa, "{s}/_manifest.tsv", .{ns_dir});
    defer fx.gpa.free(manifest_path);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "Node A\t^a\t\nNode B\t^b\t\n" });
}

test "wipe then rebuild: a fresh /synapse-init-style build over the wiped repo is drift-clean, and the preserved-notes staging note survives" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    _ = try fx.setupSchemaContentRoot();
    try fx.makeRepo(null);
    try fx.writeRepoFile("src/a.aa", "let x = 1\n");
    try fx.writeRepoFile("src/b.aa", "let y = 2\n");
    const add_res = try fx.git(&.{ "add", "-A" });
    add_res.deinit(fx.gpa);
    const commit_res = try fx.git(&.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "more" });
    commit_res.deinit(fx.gpa);

    try makeNamespace(&fx);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);
    const staging_note = try std.fmt.allocPrint(fx.gpa, "vault/scratchpad/{s} — preserved notes before full rebuild.md", .{ns});
    defer fx.gpa.free(staging_note);

    const r1 = try fx.runFake(&.{"graph-wipe"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());

    try testing.expect(!exists(&fx, ns_dir));
    try testing.expect(exists(&fx, staging_note));

    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);
    const manifest_data = "Src — the source module\t^src/\t\n";
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/manifest.tsv", .data = manifest_data });
    const rb1 = try fx.runFake(&.{"build-lists"});
    rb1.deinit(testing.allocator);

    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/b-001.md", .data = "---\nsummary: Src in one line.\n---\n\n## Summary\nProse for src.\n" });
    const rb2 = try fx.runFake(&.{"push-nodes"});
    rb2.deinit(testing.allocator);
    const rb3 = try fx.runFake(&.{"build-index"});
    rb3.deinit(testing.allocator);
    const rb4 = try fx.runFake(&.{"build-project-index"});
    rb4.deinit(testing.allocator);

    const r2 = try fx.runFake(&.{ "query", "drift" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    try testing.expectEqualStrings("", r2.stdout);

    // The rebuild does not touch scratchpad -- that staging note is the
    // merge step's input, and only the merge step (not this mechanical
    // rebuild) may consume or delete it.
    try testing.expect(exists(&fx, staging_note));
}
