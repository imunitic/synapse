//! End-to-end test of the real pipeline (build-lists -> push-nodes ->
//! build-index -> build-project-index -> query): every bug this mechanism
//! has ever had was an interface mismatch between two real steps, invisible
//! until the whole chain runs through real subprocess boundaries -- no
//! in-process fixture call can substitute.

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

fn setUpTree(fx: *Fixture) !void {
    try fx.makeRepo(null);
    try fx.writeRepoFile("src/main/java/com/example/App.java", "class App {}\n");
    try fx.writeRepoFile("src/main/java/com/example/Util.java", "class Util {}\n");
    try fx.writeRepoFile("lib/core.ml", "let f x = x\n");
    try fx.writeRepoFile("docs/guide.md", "# Guide\n");
    try fx.writeRepoFile("docs/notes.md", "# Notes\n");
    try fx.writeRepoFile("assets/logo.png", "PNG\n");
    try fx.writeRepoFile("leftover.txt", "orphan\n");
    const add_res = try fx.git(&.{ "add", "-A" });
    add_res.deinit(fx.gpa);
    const commit_res = try fx.git(&.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "tree" });
    commit_res.deinit(fx.gpa);

    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);
    _ = try fx.setupSchemaContentRoot();
}

/// A file directly under the fixture's own scratch `work` dir, parent
/// directories included.
fn writeWorkFile(fx: *Fixture, sub_path: []const u8, data: []const u8) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.fs.path.dirname(sub_path)) |d| {
        const full_dir = try std.fmt.bufPrint(&path_buf, "work/{s}", .{d});
        try fx.dir.createDirPath(std.testing.io, full_dir);
    }
    const full = try std.fmt.allocPrint(fx.gpa, "work/{s}", .{sub_path});
    defer fx.gpa.free(full);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = full, .data = data });
}

/// Runs all four real steps in sequence, each a real subprocess spawn --
/// the index needs no copying into place, it's written straight to
/// `SYNAPSE_WORK_DIR`, where every reader already looks.
fn runPipeline(fx: *Fixture) !void {
    try writeWorkFile(fx, "manifest.tsv", "Java — the application\t^src/\t\nDocs — the documentation\t^docs/\t\nOCaml — the library\t^lib/\t\n");
    const r1 = try fx.runFake(&.{"build-lists"});
    defer r1.deinit(fx.gpa);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());

    // Each authored body carries its own one-line summary in frontmatter;
    // the driver strips it and it becomes the node's `summary` field, which
    // the index reads back.
    try writeWorkFile(fx, "b-001.md", "---\nsummary: The java application.\n---\n\n## Summary\nThe java application.\n\n## Links\n- uses [[Docs — the documentation]]\n");
    try writeWorkFile(fx, "b-002.md", "---\nsummary: The documentation.\n---\n\n## Summary\nThe documentation.\n");
    try writeWorkFile(fx, "b-003.md", "---\nsummary: The ocaml library.\n---\n\n## Summary\nThe ocaml library.\n");

    const r2 = try fx.runFake(&.{"push-nodes"});
    defer r2.deinit(fx.gpa);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());

    const r3 = try fx.runFake(&.{"build-index"});
    defer r3.deinit(fx.gpa);
    try testing.expectEqual(@as(?u8, 0), r3.exitCode());

    const r4 = try fx.runFake(&.{"build-project-index"});
    defer r4.deinit(fx.gpa);
    try testing.expectEqual(@as(?u8, 0), r4.exitCode());
}

fn fileExists(fx: *Fixture, sub_path: []const u8) bool {
    fx.dir.access(std.testing.io, sub_path, .{}) catch return false;
    return true;
}

fn readFile(fx: *Fixture, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return fx.dir.readFileAlloc(std.testing.io, sub_path, gpa, .limited(4 << 20));
}

test "the four steps produce a complete, self-consistent namespace" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);

    inline for (.{ "Java — the application.md", "Docs — the documentation.md", "OCaml — the library.md", "Index.md" }) |name| {
        const p = try std.fmt.allocPrint(fx.gpa, "{s}/{s}", .{ ns_dir, name });
        defer fx.gpa.free(p);
        try testing.expect(fileExists(&fx, p));
    }
    try testing.expect(fileExists(&fx, "work/_index.bin"));

    // Coverage: the binary file was dropped at enumeration, and the one
    // text file no node claimed is in unassigned.txt rather than lost.
    const all_txt = try readFile(&fx, testing.allocator, "work/all.txt");
    defer testing.allocator.free(all_txt);
    try testing.expect(std.mem.indexOf(u8, all_txt, "logo.png") == null);

    const unassigned_txt = try readFile(&fx, testing.allocator, "work/unassigned.txt");
    defer testing.allocator.free(unassigned_txt);
    var found_leftover = false;
    var lines = std.mem.splitScalar(u8, unassigned_txt, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, "leftover.txt")) {
        found_leftover = true;
    };
    try testing.expect(found_leftover);

    const index_bin = try std.fmt.allocPrint(fx.gpa, "{s}/work/_index.bin", .{fx.root});
    defer fx.gpa.free(index_bin);
    const r5 = try fx.runFake(&.{ "index", "unassigned", "--file", index_bin });
    defer r5.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, r5.stdout, "leftover.txt") != null);

    // Every node in the index points at a file that exists.
    const r6 = try fx.runFake(&.{ "index", "nodes", "--file", index_bin });
    defer r6.deinit(testing.allocator);
    var node_lines = std.mem.splitScalar(u8, r6.stdout, '\n');
    while (node_lines.next()) |node| {
        if (node.len == 0) continue;
        const p = try std.fmt.allocPrint(fx.gpa, "{s}/{s}", .{ ns_dir, node });
        defer fx.gpa.free(p);
        try testing.expect(fileExists(&fx, p));
    }
}

test "every wikilink resolves, and every node is listed in Index.md" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);

    var dir = try fx.dir.openDir(std.testing.io, ns_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (targets.items) |t| testing.allocator.free(t);
        targets.deinit(testing.allocator);
    }
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }

    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
        const p = try std.fmt.allocPrint(fx.gpa, "{s}/{s}", .{ ns_dir, entry.name });
        defer fx.gpa.free(p);
        const body = try readFile(&fx, testing.allocator, p);
        defer testing.allocator.free(body);

        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, pos, "[[")) |start| {
            const end = std.mem.indexOfPos(u8, body, start, "]]") orelse break;
            try targets.append(testing.allocator, try testing.allocator.dupe(u8, body[start + 2 .. end]));
            pos = end + 2;
        }
    }

    // A broken wikilink is a valid link to a not-yet-existing note, so it
    // fails silently in any vault viewer -- the only way to catch it is
    // exactly this check.
    for (targets.items) |target| {
        const p = try std.fmt.allocPrint(fx.gpa, "{s}/{s}.md", .{ ns_dir, target });
        defer fx.gpa.free(p);
        try testing.expect(fileExists(&fx, p));
    }

    // And the reverse: a node missing from the index is invisible to a reader.
    const index_path = try std.fmt.allocPrint(fx.gpa, "{s}/Index.md", .{ns_dir});
    defer fx.gpa.free(index_path);
    const index_body = try readFile(&fx, testing.allocator, index_path);
    defer testing.allocator.free(index_body);
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "Index.md")) continue;
        const title = name[0 .. name.len - 3];
        const wikilink = try std.fmt.allocPrint(testing.allocator, "[[{s}]]", .{title});
        defer testing.allocator.free(wikilink);
        try testing.expect(std.mem.indexOf(u8, index_body, wikilink) != null);
    }
}

test "synapse-query.sh reads back what the pipeline wrote" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    // body prints the prose only -- no frontmatter, no ## Notes.
    const r1 = try fx.runFake(&.{ "query", "body", "Java — the application" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "The java application.") != null);
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "sources_digest") == null);
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "## Notes") == null);

    // Asserted against the list the node was built from, so the two cannot
    // drift: the ^src/ pattern also picks up the helper's src/foo.aa.
    const r2 = try fx.runFake(&.{ "query", "sources", "Java — the application", "--count" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    const lists_001 = try readFile(&fx, testing.allocator, "work/lists/001.txt");
    defer testing.allocator.free(lists_001);
    const expected_count = std.mem.count(u8, lists_001, "\n");
    const got_count = try std.fmt.parseInt(usize, std.mem.trim(u8, r2.stdout, " \t\r\n"), 10);
    try testing.expectEqual(expected_count, got_count);
    try testing.expectEqual(@as(usize, 3), got_count);

    const r3 = try fx.runFake(&.{ "query", "sources", "Docs — the documentation", "--modules" });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r3.exitCode());
    try testing.expect(std.mem.indexOf(u8, r3.stdout, "docs") != null);

    const r4 = try fx.runFake(&.{ "query", "field", "OCaml — the library", "project" });
    defer r4.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r4.exitCode());
    const ns_repo = try fx.nsRepo();
    defer fx.gpa.free(ns_repo);
    try testing.expectEqualStrings(ns_repo, std.mem.trim(u8, r4.stdout, " \t\r\n"));
}

test "a freshly built namespace verifies clean, and detects a real edit" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    // Silence means clean: the digests the writer computed must satisfy the
    // verifier's independent recomputation of the same definition.
    const r1 = try fx.runFake(&.{ "query", "stale" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    try testing.expectEqualStrings("", std.mem.trim(u8, r1.stdout, " \t\r\n"));

    try fx.writeRepoFile("src/main/java/com/example/App.java", "class App { int x; }\n");
    const r2 = try fx.runFake(&.{ "query", "stale" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "Java — the application\tcontent changed") != null);
    // Only the node covering that file may be flagged.
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "OCaml") == null);
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "Docs") == null);
}

test "a deleted source is reported by name rather than crashing the verifier" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    const del_path = try std.fmt.allocPrint(fx.gpa, "repo/lib/core.ml", .{});
    defer fx.gpa.free(del_path);
    try fx.dir.deleteFile(std.testing.io, del_path);

    const r = try fx.runFake(&.{ "query", "stale" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "OCaml — the library\tsource files gone: lib/core.ml") != null);
}

test "re-running the pipeline is idempotent" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try setUpTree(&fx);
    try runPipeline(&fx);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const java_node = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}/Java — the application.md", .{ns});
    defer fx.gpa.free(java_node);

    const first = try readFile(&fx, testing.allocator, java_node);
    defer testing.allocator.free(first);
    const first_digest = digestLine(first);

    try runPipeline(&fx);

    const second = try readFile(&fx, testing.allocator, java_node);
    defer testing.allocator.free(second);
    const second_digest = digestLine(second);
    try testing.expectEqualStrings(first_digest, second_digest);

    // Node count must not drift, and the namespace must still verify.
    const ns_dir = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}", .{ns});
    defer fx.gpa.free(ns_dir);
    var dir = try fx.dir.openDir(std.testing.io, ns_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md") and !std.mem.eql(u8, entry.name, "Index.md")) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);

    const r = try fx.runFake(&.{ "query", "stale" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expectEqualStrings("", std.mem.trim(u8, r.stdout, " \t\r\n"));
}

fn digestLine(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "sources_digest: ")) return line;
    }
    return "";
}
