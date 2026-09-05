//! The real rebuild/diff pipeline against a repo with real history and real
//! drift -- every failure this mechanism has ever had was an interface
//! mismatch between two real steps, invisible until the whole chain runs
//! through real subprocess boundaries.

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;
const gpa = testing.allocator;

fn commitAll(fx: *Fixture, message: []const u8) !void {
    const r1 = try fx.git(&.{ "add", "-A" });
    r1.deinit(fx.gpa);
    const r2 = try fx.git(&.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", message });
    r2.deinit(fx.gpa);
}

/// Four modules of 20 files each, so a two-file change is 10% of a node and
/// a whole-module change is not.
fn makeProject(fx: *Fixture) !void {
    try fx.makeRepo(null);
    inline for (.{ "alpha", "beta", "gamma" }) |m| {
        var i: usize = 1;
        while (i <= 20) : (i += 1) {
            const path = try std.fmt.allocPrint(fx.gpa, "mod-{s}/src/main/java/{s}{d:0>2}.java", .{ m, m, i });
            defer fx.gpa.free(path);
            const data = try std.fmt.allocPrint(fx.gpa, "class {s}{d:0>2} {{ int v = {d}; }}\n", .{ m, i, i });
            defer fx.gpa.free(data);
            try fx.writeRepoFile(path, data);
        }
    }
    inline for (.{ 1, 2, 3 }) |i| {
        const path = try std.fmt.allocPrint(fx.gpa, "docs/d{d}.md", .{i});
        defer fx.gpa.free(path);
        const data = try std.fmt.allocPrint(fx.gpa, "# doc {d}\n", .{i});
        defer fx.gpa.free(data);
        try fx.writeRepoFile(path, data);
    }
    try commitAll(fx, "project");

    const manifest =
        "Alpha — the first module\t^mod-alpha/\t\n" ++
        "Beta — the second module\t^mod-beta/\t\n" ++
        "Gamma — the third module\t^mod-gamma/\t\n" ++
        "Docs — the documentation\t^docs/\t\n";
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/manifest.tsv", .data = manifest });
}

/// Runs the full four-step build, as `/synapse-init` would.
fn buildNamespace(fx: *Fixture) !void {
    const r1 = try fx.runFake(&.{"build-lists"});
    r1.deinit(fx.gpa);

    inline for (.{ "001", "002", "003", "004" }) |nn| {
        const title_path = try std.fmt.allocPrint(fx.gpa, "work/lists/{s}.title", .{nn});
        defer fx.gpa.free(title_path);
        const title = try fx.dir.readFileAlloc(std.testing.io, title_path, fx.gpa, .limited(4096));
        defer fx.gpa.free(title);
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        const body = try std.fmt.allocPrint(fx.gpa,
            "---\nsummary: {s} in one line.\n---\n\n## Summary\nProse for {s}.\n\n## Crux\n```java\nclass alpha1 {{ int v = 1; }}\n```\n",
            .{ trimmed, trimmed },
        );
        defer fx.gpa.free(body);
        const b_path = try std.fmt.allocPrint(fx.gpa, "work/b-{s}.md", .{nn});
        defer fx.gpa.free(b_path);
        try fx.dir.writeFile(std.testing.io, .{ .sub_path = b_path, .data = body });
    }
    const r2 = try fx.runFake(&.{"push-nodes"});
    r2.deinit(fx.gpa);
    const r3 = try fx.runFake(&.{"build-index"});
    r3.deinit(fx.gpa);
    const r4 = try fx.runFake(&.{"build-project-index"});
    r4.deinit(fx.gpa);
}

fn setUp(fx: *Fixture) !void {
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);
    _ = try fx.setupSchemaContentRoot();
}

/// `body` with `## Sources` and everything after it stripped. Caller frees.
fn stripSourcesOnward(g: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(g);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "## Sources")) break;
        try out.appendSlice(g, line);
        try out.append(g, '\n');
    }
    return out.toOwnedSlice(g);
}

test "a freshly built namespace has no drift" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    const r1 = try fx.runFake(&.{ "query", "drift" });
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    try testing.expectEqualStrings("", r1.stdout);

    const r2 = try fx.runFake(&.{ "query", "stale" });
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    try testing.expectEqualStrings("", r2.stdout);
}

test "mixed drift is classified per node, and the ratios are measurable" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    // Alpha: 2 of 20 files edited -> 10%, the patch case.
    try fx.writeRepoFile("mod-alpha/src/main/java/alpha01.java", "class alpha01 { int v = 99; }\n");
    try fx.writeRepoFile("mod-alpha/src/main/java/alpha02.java", "class alpha02 { int v = 99; }\n");
    // Beta: every file moved, content untouched -> the reseat case.
    const mv_res = try fx.git(&.{ "mv", "mod-beta/src/main/java", "mod-beta/src/main/kotlin" });
    mv_res.deinit(fx.gpa);
    // Gamma: one deletion plus three additions under the existing pattern.
    const rm_res = try fx.git(&.{ "rm", "-q", "mod-gamma/src/main/java/gamma01.java" });
    rm_res.deinit(fx.gpa);
    inline for (.{ 21, 22, 23 }) |i| {
        const path = std.fmt.comptimePrint("mod-gamma/src/main/java/gamma{d}.java", .{i});
        const data = std.fmt.comptimePrint("class gamma{d} {{}}\n", .{i});
        try fx.writeRepoFile(path, data);
    }
    // A whole new subsystem no manifest pattern covers.
    try fx.writeRepoFile("mod-delta/src/main/java/delta1.java", "class delta1 {}\n");
    try commitAll(&fx, "drift");

    const r = try fx.runFake(&.{ "query", "drift" });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    try testing.expect(std.mem.indexOf(u8, r.stdout, "Alpha — the first module\tcontent changed in 2 of its files") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Beta — the second module\t20 of its files were renamed") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Gamma — the third module\t1 of its files are gone") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "3 new paths already match a manifest pattern") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "1 new paths match no manifest pattern") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "mod-delta/src/main/java/delta1.java") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Docs — the documentation\tcontent changed") == null);

    const r2 = try fx.runFake(&.{ "query", "sources", "Alpha — the first module", "--count" });
    defer r2.deinit(gpa);
    try testing.expectEqual(@as(usize, 20), try std.fmt.parseInt(usize, std.mem.trim(u8, r2.stdout, " \t\r\n"), 10));
}

test "reseat: a rename-only node is rebuilt from its own body, with no re-reading" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    const r0 = try fx.runFake(&.{ "query", "body", "Beta — the second module" });
    defer r0.deinit(gpa);
    const before = try stripSourcesOnward(gpa, r0.stdout);
    defer gpa.free(before);

    const mv_res = try fx.git(&.{ "mv", "mod-beta/src/main/java", "mod-beta/src/main/kotlin" });
    mv_res.deinit(fx.gpa);
    try commitAll(&fx, "rename-beta");

    const r1 = try fx.runFake(&.{ "query", "drift" });
    defer r1.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "Beta — the second module\t20 of its files were renamed") != null);

    const r2 = try fx.runFake(&.{ "build-lists", "--reenumerate" });
    r2.deinit(gpa);

    const r3 = try fx.runFake(&.{ "query", "body", "Beta — the second module" });
    defer r3.deinit(gpa);
    const reseat_body = try stripSourcesOnward(gpa, r3.stdout);
    defer gpa.free(reseat_body);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/reseat.md", .data = reseat_body });
    fx.dir.deleteFile(std.testing.io, "work/b-002.md") catch {};

    const reseat_path = try std.fmt.allocPrint(fx.gpa, "{s}/reseat.md", .{fx.work});
    defer fx.gpa.free(reseat_path);
    const paths_path = try std.fmt.allocPrint(fx.gpa, "{s}/lists/002.txt", .{fx.work});
    defer fx.gpa.free(paths_path);
    const r4 = try fx.runFake(&.{ "write-node", "--title", "Beta — the second module", "--summary", "Beta — the second module in one line.", "--paths", paths_path, "--body", reseat_path });
    defer r4.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r4.exitCode());

    const r5 = try fx.runFake(&.{ "query", "body", "Beta — the second module" });
    defer r5.deinit(gpa);
    const after = try stripSourcesOnward(gpa, r5.stdout);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);

    const r6 = try fx.runFake(&.{"build-index"});
    r6.deinit(gpa);
    const r7 = try fx.runFake(&.{ "query", "drift" });
    defer r7.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r7.stdout, "Beta — the second module") == null);
}

test "re-enumeration claims new files under existing patterns, without touching prose" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    inline for (.{ 21, 22, 23 }) |i| {
        const path = std.fmt.comptimePrint("mod-gamma/src/main/java/gamma{d}.java", .{i});
        const data = std.fmt.comptimePrint("class gamma{d} {{}}\n", .{i});
        try fx.writeRepoFile(path, data);
    }
    try commitAll(&fx, "adds");

    const r1 = try fx.runFake(&.{ "query", "drift" });
    defer r1.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "3 new paths already match a manifest pattern") != null);

    const r2 = try fx.runFake(&.{ "build-lists", "--reenumerate" });
    r2.deinit(gpa);
    const list_txt = try fx.dir.readFileAlloc(std.testing.io, "work/lists/003.txt", gpa, .limited(1 << 20));
    defer gpa.free(list_txt);
    try testing.expectEqual(@as(usize, 23), std.mem.count(u8, list_txt, "\n"));

    const r3 = try fx.runFake(&.{ "query", "body", "Gamma — the third module" });
    defer r3.deinit(gpa);
    const stripped = try stripSourcesOnward(gpa, r3.stdout);
    defer gpa.free(stripped);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "work/g.md", .data = stripped });

    const g_path = try std.fmt.allocPrint(fx.gpa, "{s}/g.md", .{fx.work});
    defer fx.gpa.free(g_path);
    const paths_path = try std.fmt.allocPrint(fx.gpa, "{s}/lists/003.txt", .{fx.work});
    defer fx.gpa.free(paths_path);
    const r4 = try fx.runFake(&.{ "write-node", "--title", "Gamma — the third module", "--summary", "Gamma — the third module in one line.", "--paths", paths_path, "--body", g_path });
    defer r4.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r4.exitCode());

    const r5 = try fx.runFake(&.{ "query", "sources", "Gamma — the third module", "--count" });
    defer r5.deinit(gpa);
    try testing.expectEqual(@as(usize, 23), try std.fmt.parseInt(usize, std.mem.trim(u8, r5.stdout, " \t\r\n"), 10));
}

test "a diverged line that removes a module leaves an empty list, and nothing is written" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    const fork = try fx.gitOutput(&.{ "rev-parse", "HEAD" });
    defer fx.gpa.free(fork);

    try fx.writeRepoFile("mod-alpha/src/main/java/alpha01.java", "class alpha01 { int v = 2; }\n");
    try commitAll(&fx, "mainline");
    try buildNamespace(&fx);

    const reset_res = try fx.git(&.{ "reset", "--hard", "-q", fork });
    reset_res.deinit(fx.gpa);
    const rm_res = try fx.git(&.{ "rm", "-rq", "mod-gamma" });
    rm_res.deinit(fx.gpa);
    try commitAll(&fx, "line-drops-gamma");

    const r1 = try fx.runFake(&.{ "query", "drift" });
    defer r1.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "is not an ancestor of HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "Gamma — the third module\t20 of its files are gone") != null);

    const r2 = try fx.runFake(&.{ "build-lists", "--reenumerate" });
    r2.deinit(gpa);
    const list_stat = fx.dir.statFile(std.testing.io, "work/lists/003.txt", .{}) catch null;
    try testing.expect(list_stat == null or list_stat.?.size == 0);

    const b_path = try std.fmt.allocPrint(fx.gpa, "{s}/b-003.md", .{fx.work});
    defer fx.gpa.free(b_path);
    const paths_path = try std.fmt.allocPrint(fx.gpa, "{s}/lists/003.txt", .{fx.work});
    defer fx.gpa.free(paths_path);
    const r3 = try fx.runFake(&.{ "write-node", "--title", "Gamma — the third module", "--summary", "x", "--paths", paths_path, "--body", b_path });
    defer r3.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r3.exitCode());
    try testing.expect(std.mem.indexOf(u8, r3.stderr, "empty path list") != null or std.mem.indexOf(u8, r3.stdout, "empty path list") != null);

    const ns = try fx.repoName();
    defer fx.gpa.free(ns);
    const node_path = try std.fmt.allocPrint(fx.gpa, "vault/synapse/{s}/Gamma — the third module.md", .{ns});
    defer fx.gpa.free(node_path);
    const node_body = try fx.dir.readFileAlloc(std.testing.io, node_path, gpa, .limited(1 << 20));
    defer gpa.free(node_body);
    try testing.expect(std.mem.indexOf(u8, node_body, "## Notes") != null);

    const r4 = try fx.runFake(&.{ "push-nodes", "003" });
    defer r4.deinit(gpa);
    try testing.expectEqual(@as(?u8, 1), r4.exitCode());
    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ r4.stdout, r4.stderr });
    defer gpa.free(combined);
    try testing.expect(std.mem.indexOf(u8, combined, "003\tSKIP (no list/title)") != null or std.mem.indexOf(u8, combined, "003\tFAILED") != null);
}

test "the loop closes: after rebuilding every flagged node, drift goes silent" {
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try setUp(&fx);
    try makeProject(&fx);
    try buildNamespace(&fx);

    try fx.writeRepoFile("mod-alpha/src/main/java/alpha01.java", "class alpha01 { int v = 99; }\n");
    const mv_res = try fx.git(&.{ "mv", "mod-beta/src/main/java", "mod-beta/src/main/kotlin" });
    mv_res.deinit(fx.gpa);
    try fx.writeRepoFile("mod-gamma/src/main/java/gamma21.java", "class gamma21 {}\n");
    try commitAll(&fx, "mixed");

    const r1 = try fx.runFake(&.{ "query", "drift" });
    defer r1.deinit(gpa);
    try testing.expect(r1.stdout.len != 0);

    const r2 = try fx.runFake(&.{ "build-lists", "--reenumerate" });
    r2.deinit(gpa);

    inline for (.{ "001", "002", "003" }) |nn| {
        const title_path = std.fmt.comptimePrint("work/lists/{s}.title", .{nn});
        const title = try fx.dir.readFileAlloc(std.testing.io, title_path, fx.gpa, .limited(4096));
        defer fx.gpa.free(title);
        const trimmed = std.mem.trim(u8, title, " \t\r\n");

        const rb = try fx.runFake(&.{ "query", "body", trimmed });
        const stripped = try stripSourcesOnward(fx.gpa, rb.stdout);
        rb.deinit(fx.gpa);
        defer fx.gpa.free(stripped);
        const r_path = std.fmt.comptimePrint("work/r-{s}.md", .{nn});
        try fx.dir.writeFile(std.testing.io, .{ .sub_path = r_path, .data = stripped });

        const summary = try std.fmt.allocPrint(fx.gpa, "{s} in one line.", .{trimmed});
        defer fx.gpa.free(summary);
        const abs_r_path = try std.fmt.allocPrint(fx.gpa, "{s}/r-{s}.md", .{ fx.work, nn });
        defer fx.gpa.free(abs_r_path);
        const abs_paths_path = try std.fmt.allocPrint(fx.gpa, "{s}/lists/{s}.txt", .{ fx.work, nn });
        defer fx.gpa.free(abs_paths_path);
        const rw = try fx.runFake(&.{ "write-node", "--title", trimmed, "--summary", summary, "--paths", abs_paths_path, "--body", abs_r_path });
        rw.deinit(fx.gpa);
    }
    const r3 = try fx.runFake(&.{"build-index"});
    r3.deinit(gpa);
    const r4 = try fx.runFake(&.{"build-project-index"});
    r4.deinit(gpa);

    const r5 = try fx.runFake(&.{ "query", "drift" });
    defer r5.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r5.exitCode());
    try testing.expectEqualStrings("", r5.stdout);

    const r6 = try fx.runFake(&.{ "query", "stale" });
    defer r6.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r6.exitCode());
    try testing.expectEqualStrings("", r6.stdout);
}
