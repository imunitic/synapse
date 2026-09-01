//! `synapse build-lists` -- the work half of `claude/lib/synapse/synapse-build-lists.sh`.
//!
//!   build-lists [--reenumerate]   manifest.tsv into one path list per node
//!
//! Reads `$SYNAPSE_WORK_DIR/manifest.tsv` (`title <TAB> include-ERE <TAB>
//! exclude-ERE`), enumerates first, writes `lists/NN.txt`/`NN.title` per
//! line, then `covered.txt`/`all-sorted.txt`/`unassigned.txt` plus coverage counts.
//!
//! `include`/`exclude` stay real `grep -E` (one manifest here uses 233
//! alternations, 60 groups across 32 lines -- reimplementing an ERE engine
//! would silently change which files a node claims). Measured on
//! `syrius-querschnitt-basis` (32 nodes, 4,892 files): of the script's
//! 3166ms, the 64 greps were 329ms; the rest was enumeration and 69 `wc -l`
//! spawns this port removes.
//!
//! Sorting/comparing stays byte-order throughout -- the script needed
//! `LC_ALL=C` on both sorts and `comm`, since `comm` under a UTF-8 locale
//! silently reports every line unique once uppercase filenames appear.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var reenumerate = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = usage();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--reenumerate")) {
            reenumerate = true;
        } else return usage();
    }

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try build(gpa, io, env, ".", reenumerate, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture repo without depending on the test
/// process's own cwd. `identity_path` is `"."` for the real CLI (identity
/// resolves from wherever the process was invoked) or a fixture's real
/// repo root for a test, matching `enumerate_cmd.runEnumerate`'s own split.
pub fn build(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    identity_path: []const u8,
    reenumerate: bool,
    out: *Io.Writer,
) !u8 {
    const id = core.identity.resolve(gpa, io, identity_path) catch {
        std.debug.print("synapse-build-lists: not inside a git repo\n", .{});
        return 1;
    };
    defer id.deinit(gpa);

    const work = (try context.workDir(gpa, io, env, "synapse-build-lists")) orelse return 1;
    defer work.deinit(gpa);
    const work_dir = work.path;

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, work_dir) catch {};

    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.tsv", .{work_dir});
    defer gpa.free(manifest_path);

    // Checked before enumerating: a missing manifest shouldn't cost minutes
    // of work on a 125k-file repo before reporting it.
    const manifest = cwd.readFileAlloc(io, manifest_path, gpa, context.maxListingBytes(env, 16 << 20)) catch {
        std.debug.print("synapse-build-lists: no manifest.tsv in {s}\n", .{work_dir});
        return 1;
    };
    defer gpa.free(manifest);

    try enumerate_cmd.ensure(gpa, io, env, id.layout.repo_root, work_dir, reenumerate, out);

    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{work_dir});
    defer gpa.free(all_path);
    const all = try cwd.readFileAlloc(io, all_path, gpa, context.maxListingBytes(env, 256 << 20));
    defer gpa.free(all);

    const lists_dir = try std.fmt.allocPrint(gpa, "{s}/lists", .{work_dir});
    defer gpa.free(lists_dir);
    // Rebuilt from scratch so a removed manifest line leaves no stale list behind.
    cwd.deleteTree(io, lists_dir) catch {};
    try cwd.createDirPath(io, lists_dir);

    // `covered`'s entries are slices into the per-node grep output, so those
    // buffers must outlive the loop -- a per-iteration `defer` would free
    // them while `covered` still points in (caught in ReleaseSafe as an
    // overflow inside `std.sort.block`, not by design).
    var covered: std.ArrayListUnmanaged([]const u8) = .empty;
    defer covered.deinit(gpa);
    var matched_buffers: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (matched_buffers.items) |b| gpa.free(b);
        matched_buffers.deinit(gpa);
    }

    var node_index: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw| {
        const row = parseRow(raw) orelse continue;

        node_index += 1;
        // Every reader of `lists/` iterates exactly `1..=max_nodes` -- a
        // slug this loop would write past that point is never read back by
        // any of them, silently. Refuse here instead, where the manifest
        // that caused it is easy to see, rather than let it through and
        // have node_index's own cluster vanish from every brief/ranking.
        if (node_index > core.node.max_nodes) {
            std.debug.print(
                "synapse-build-lists: manifest has more than {d} nodes -- raise core.node.max_nodes\n",
                .{core.node.max_nodes},
            );
            return 1;
        }
        const slug = try std.fmt.allocPrint(gpa, "{d:0>3}", .{node_index});
        defer gpa.free(slug);

        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists_dir, slug });
        defer gpa.free(title_path);
        const title_body = try std.fmt.allocPrint(gpa, "{s}\n", .{row.title});
        defer gpa.free(title_body);
        try cwd.writeFile(io, .{ .sub_path = title_path, .data = title_body });

        const matched = try selectPaths(gpa, io, all, row.include, row.exclude);
        try matched_buffers.append(gpa, matched);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists_dir, slug });
        defer gpa.free(list_path);
        try cwd.writeFile(io, .{ .sub_path = list_path, .data = matched });

        var count: usize = 0;
        var it = std.mem.splitScalar(u8, matched, '\n');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            count += 1;
            try covered.append(gpa, p);
        }
        try out.print("{s}\t{d}\t{s}\n", .{ slug, count, row.title });
    }

    try out.writeAll("--- coverage\n");
    try writeCoverage(gpa, io, work_dir, all, covered.items, out);
    return 0;
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse build-lists [--reenumerate]
        \\
    , .{});
    return 2;
}

/// One `manifest.tsv` row: `title <TAB> include-ERE <TAB> exclude-ERE`.
pub const Row = struct {
    title: []const u8,
    include: []const u8,
    exclude: []const u8,
};

/// A blank line has an empty title, treated as blank rather than a row; a
/// row missing its `include` field is skipped the same way -- the same
/// "truncated line, not fatal" contract `core/refs.zig`'s and
/// `core/deps.zig`'s own `parseRow` use for their tab-separated formats.
/// Missing `exclude` means "exclude nothing" (`selectPaths` below), not a
/// truncation -- a two-column row is a normal, complete one.
pub fn parseRow(raw: []const u8) ?Row {
    const line = std.mem.trimEnd(u8, raw, "\r");
    var cols = std.mem.splitScalar(u8, line, '\t');
    const title = cols.next() orelse return null;
    if (title.len == 0) return null;
    const include = cols.next() orelse return null;
    const exclude = cols.next() orelse "";
    return .{ .title = title, .include = include, .exclude = exclude };
}

/// `grep -E "$include" all.txt | grep -vE "${exclude:-^$}"`. Empty exclude
/// means "exclude nothing", spelled `^$` (a pattern matching no path) rather
/// than special-cased, since `^$` is also valid manifest content.
pub fn selectPaths(
    gpa: Allocator,
    io: Io,
    all: []const u8,
    include: []const u8,
    exclude: []const u8,
) ![]u8 {
    const included = try adapters.process.run(io, gpa, &.{ "grep", "-E", include }, .{
        .stdin = all,
    });
    defer gpa.free(included.stderr);
    errdefer gpa.free(included.stdout);
    if (included.exitCode() == null or included.exitCode().? > 1) {
        gpa.free(included.stdout);
        return error.GrepFailed;
    }
    if (included.stdout.len == 0) return included.stdout;

    const pattern = if (exclude.len == 0) "^$" else exclude;
    defer gpa.free(included.stdout);
    const kept = try adapters.process.run(io, gpa, &.{ "grep", "-vE", pattern }, .{
        .stdin = included.stdout,
    });
    defer gpa.free(kept.stderr);
    if (kept.exitCode() == null or kept.exitCode().? > 1) {
        gpa.free(kept.stdout);
        return error.GrepFailed;
    }
    return kept.stdout;
}

/// `covered.txt`, `all-sorted.txt` and `unassigned.txt`, plus the two
/// counts. `unassigned.txt` is `synapse-build-index.sh`'s input.
fn writeCoverage(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    all: []const u8,
    covered_paths: []const []const u8,
    out: *Io.Writer,
) !void {
    const covered = try gpa.dupe([]const u8, covered_paths);
    defer gpa.free(covered);
    std.mem.sort([]const u8, covered, {}, lessByBytes);
    const covered_unique = dedupe(covered);

    var all_sorted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_sorted.deinit(gpa);
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |p| {
        if (p.len != 0) try all_sorted.append(gpa, p);
    }
    std.mem.sort([]const u8, all_sorted.items, {}, lessByBytes);

    try writeLines(gpa, io, work_dir, "covered.txt", covered_unique);
    try writeLines(gpa, io, work_dir, "all-sorted.txt", all_sorted.items);

    // `comm -23`: in all-sorted, not in covered. One merge pass over byte-sorted sides.
    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < all_sorted.items.len) {
        const a = all_sorted.items[i];
        if (j >= covered_unique.len) {
            try unassigned.append(gpa, a);
            i += 1;
            continue;
        }
        switch (std.mem.order(u8, a, covered_unique[j])) {
            .lt => {
                try unassigned.append(gpa, a);
                i += 1;
            },
            .eq => i += 1,
            .gt => j += 1,
        }
    }

    try writeLines(gpa, io, work_dir, "unassigned.txt", unassigned.items);
    try out.print("covered:    {d}\nunassigned: {d}\n", .{ covered_unique.len, unassigned.items.len });
}

fn lessByBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// In place, on an already-sorted slice: `sort -u`'s second half.
fn dedupe(sorted: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (sorted, 0..) |s, k| {
        if (k > 0 and std.mem.eql(u8, sorted[k - 1], s)) continue;
        sorted[n] = s;
        n += 1;
    }
    return sorted[0..n];
}

fn writeLines(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    name: []const u8,
    lines: []const []const u8,
) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_dir, name });
    defer gpa.free(path);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (lines) |l| try body.writer.print("{s}\n", .{l});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

/// Enumeration itself (binary/noise extensions, `$SYNAPSE_EXTRA_EXCLUDE_RE`,
/// `synapse-ignore-files.conf`, submodule gitlinks, the size cap) is covered
/// by `enumerate_cmd.zig`'s own native tests, driven through the same
/// `ensure()` this file also calls -- nothing here re-proves it. This file's
/// own tests cover what only `build()` does: manifest parsing, `grep -E`/
/// `grep -vE` selection per node, the coverage arithmetic, and rebuilding
/// `lists/` from scratch.
const BuildListsFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !BuildListsFixture {
        const fx = try fixture.Fixture.init(gpa);
        return .{ .fx = fx };
    }

    fn deinit(self: *BuildListsFixture) void {
        self.fx.deinit();
    }

    /// A separate step from `init()`, called by every test right after
    /// construction: `gitCommit()` spawns a real subprocess, and doing that
    /// on `init()`'s own local copy before it returns the fixture by value
    /// binds `Io.Threaded`'s worker thread to a stale, soon-to-be-orphaned
    /// address -- see [[sb — Io.Threaded fixture-wrapper hang]] (found
    /// building `BriefFixture` in `brief_cmd.zig`).
    fn commit(self: *BuildListsFixture, message: []const u8) !void {
        try self.fx.gitCommit(message);
    }

    fn writeManifest(self: *BuildListsFixture, content: []const u8) !void {
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/manifest.tsv", .data = content });
    }

    fn run(self: *BuildListsFixture, reenumerate: bool, out: *Io.Writer) !u8 {
        return build(self.fx.gpa, self.fx.io(), &self.fx.env, self.fx.repo, reenumerate, out);
    }
};

test "expands each manifest line into a numbered list plus its title, with per-node counts printed" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.fx.writeRepoFile("mod-a/src/main/java/B.java", "class B {}\n");
    try bf.fx.writeRepoFile("docs/guide.md", "# guide\n");
    try bf.commit("mixed");
    try bf.writeManifest("Code — the java\t^mod-a/\t\nDocs — the docs\t^docs/\t\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const title1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/001.title", gpa, .limited(1 << 10));
    defer gpa.free(title1);
    try testing.expectEqualStrings("Code — the java\n", title1);
    const title2 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/002.title", gpa, .limited(1 << 10));
    defer gpa.free(title2);
    try testing.expectEqualStrings("Docs — the docs\n", title2);

    const list1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/001.txt", gpa, .limited(1 << 10));
    defer gpa.free(list1);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, list1, "\n"));
    const list2 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/002.txt", gpa, .limited(1 << 10));
    defer gpa.free(list2);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, list2, "\n"));

    // Echoed per node, so a bad regex is visible immediately.
    try testing.expect(std.mem.indexOf(u8, out.written(), "001\t2\tCode — the java\n") != null);
}

test "a manifest with more nodes than max_nodes is refused, not silently truncated" {
    // Before this refusal existed, node core.node.max_nodes + 1 would still
    // get written (build-lists' own slug isn't capped), just under a slug
    // wider than every reader's own 1..=max_nodes loop ever visits -- gone
    // from every brief/ranking with nothing to say why.
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.commit("mixed");

    var manifest: std.Io.Writer.Allocating = .init(gpa);
    defer manifest.deinit();
    var i: usize = 0;
    while (i <= core.node.max_nodes) : (i += 1) {
        try manifest.writer.print("Node {d}\t^config$\t\n", .{i});
    }
    try bf.writeManifest(manifest.written());

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "the exclude column removes paths the include column matched" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.fx.writeRepoFile("mod-a/src/main/java/B.java", "class B {}\n");
    try bf.commit("mixed");
    try bf.writeManifest("Java except B\t^mod-a/\tB\\.java$\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const list1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/001.txt", gpa, .limited(1 << 10));
    defer gpa.free(list1);
    try testing.expect(std.mem.indexOf(u8, list1, "A.java") != null);
    try testing.expect(std.mem.indexOf(u8, list1, "B.java") == null);
}

test "an empty exclude column excludes nothing" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.fx.writeRepoFile("mod-a/src/main/java/B.java", "class B {}\n");
    try bf.commit("mixed");
    // Third column absent entirely -- must not fall back to a pattern that
    // silently matches everything.
    try bf.writeManifest("Java\t^mod-a/\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const list1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/001.txt", gpa, .limited(1 << 10));
    defer gpa.free(list1);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, list1, "\n"));
}

test "coverage reports the arithmetic and records what nothing claimed" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("src/foo.ml", "let x = 1\n");
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.fx.writeRepoFile("mod-a/src/main/java/B.java", "class B {}\n");
    try bf.fx.writeRepoFile("docs/guide.md", "# guide\n");
    try bf.fx.writeRepoFile("stray.txt", "stray\n");
    try bf.fx.writeRepoFile(".gitignore", "secret.txt\n");
    try bf.commit("mixed");
    try bf.writeManifest("Java\t^mod-a/\t\nDocs\t^docs/\t\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "covered:    3\n") != null);

    // src/foo.ml, stray.txt and .gitignore are claimed by nothing.
    const unassigned = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/unassigned.txt", gpa, .limited(1 << 10));
    defer gpa.free(unassigned);
    try testing.expect(std.mem.indexOf(u8, unassigned, "src/foo.ml\n") != null);
    try testing.expect(std.mem.indexOf(u8, unassigned, "stray.txt\n") != null);
    try testing.expect(std.mem.indexOf(u8, unassigned, ".gitignore\n") != null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, unassigned, "\n"));
}

test "a pattern that matches nothing yields an empty list rather than failing" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.commit("mixed");
    // Looks like "the config directory" but matches only a literal `config`.
    try bf.writeManifest("Nothing\t^config$\t\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const list1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "work/lists/001.txt", gpa, .limited(1 << 10));
    defer gpa.free(list1);
    try testing.expectEqualStrings("", list1);
    try testing.expect(std.mem.indexOf(u8, out.written(), "001\t0\tNothing\n") != null);
}

test "lists are rebuilt from scratch, so a removed manifest line leaves no stale list" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.fx.writeRepoFile("docs/guide.md", "# guide\n");
    try bf.commit("mixed");
    try bf.writeManifest("Java\t^mod-a/\t\nDocs\t^docs/\t\n");

    var out1: Io.Writer.Allocating = .init(gpa);
    defer out1.deinit();
    try testing.expectEqual(@as(u8, 0), try bf.run(false, &out1.writer));
    try bf.fx.tmp.dir.access(testing.io, "work/lists/002.txt", .{});

    try bf.writeManifest("Java\t^mod-a/\t\n");
    var out2: Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try testing.expectEqual(@as(u8, 0), try bf.run(false, &out2.writer));
    try testing.expectEqual(error.FileNotFound, bf.fx.tmp.dir.access(testing.io, "work/lists/002.txt", .{}));
}

test "a missing manifest.tsv is an error, not a silent empty result" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.commit("mixed");
    // No manifest written.

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try bf.run(false, &out.writer));
}

test "a --repo that is not a git repo is an error" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.writeManifest("Java\t^mod-a/\t\n");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // `/tmp` itself, not a subdirectory of the fixture's own tmp root: that
    // root sits inside this project's real git repo, so identity resolution
    // would walk up and find it instead of failing.
    const code = try build(gpa, bf.fx.io(), &bf.fx.env, "/tmp", false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "with $SYNAPSE_WORK_DIR unset, output lands in the default work dir and never in the repo" {
    const gpa = testing.allocator;
    var bf = try BuildListsFixture.init(gpa);
    defer bf.deinit();
    try bf.fx.writeRepoFile("mod-a/src/main/java/A.java", "class A {}\n");
    try bf.commit("mixed");
    _ = bf.fx.env.swapRemove("SYNAPSE_WORK_DIR");

    // `context.workDirFor` derives the default from `SYNAPSE_NAMESPACE`
    // (the fixture's own env-var identity bypass) without needing real
    // git for this call -- `$HOME/.cache/synapse/work/repo@main`, created
    // on demand by `build()`'s own `createDirPath`.
    try bf.fx.tmp.dir.createDirPath(testing.io, "home/.cache/synapse/work/repo@main");
    try bf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.cache/synapse/work/repo@main/manifest.tsv",
        .data = "Java\t^mod-a/\t\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try bf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const list1 = try bf.fx.tmp.dir.readFileAlloc(testing.io, "home/.cache/synapse/work/repo@main/lists/001.txt", gpa, .limited(1 << 10));
    defer gpa.free(list1);
    try testing.expect(std.mem.indexOf(u8, list1, "A.java") != null);

    try testing.expectEqual(error.FileNotFound, bf.fx.tmp.dir.access(testing.io, "repo/lists", .{}));
    try testing.expectEqual(error.FileNotFound, bf.fx.tmp.dir.access(testing.io, "repo/all.txt", .{}));
    try testing.expectEqual(error.FileNotFound, bf.fx.tmp.dir.access(testing.io, "repo/unassigned.txt", .{}));
    try testing.expectEqual(error.FileNotFound, bf.fx.tmp.dir.access(testing.io, "repo/covered.txt", .{}));
}
