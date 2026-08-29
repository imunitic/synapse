//! `synapse build-project-index` -- `claude/lib/synapse/synapse-build-project-index.sh`.
//!
//! Builds and uploads `synapse/{repo}@{branch}/Index.md`, the per-namespace node map
//! carrying the `remote` field the SessionStart hook verifies before injecting a
//! pointer. Step 4, and last, of a scripted `/synapse-init`.
//!
//! Built *from* the nodes on disk, not from anything the build kept: a
//! missing node or a missing `summary` field is a hard error with different
//! advice for each.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

const prog = "synapse-build-project-index";

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse build-project-index\n", .{});
            return 0;
        }
        std.debug.print("usage: synapse build-project-index\n", .{});
        return 2;
    }

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try write(gpa, io, env, &ctx, &out.interface);
    try out.interface.flush();
    return code;
}

/// The build itself, minus argument parsing and Context resolution --
/// separated so a test can drive it against a fixture vault without going
/// through the CLI. `result` receives the one success line, the same
/// shape `write_node_cmd.write` already uses.
pub fn write(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    result: *Io.Writer,
) !u8 {
    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{ctx.work_dir});
    defer gpa.free(lists);

    var names = try listTitles(gpa, io, lists);
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    if (names.items.len == 0) {
        std.debug.print("{s}: no lists/NN.title in {s}\n", .{ prog, ctx.work_dir });
        return 1;
    }

    var bullets: std.ArrayListUnmanaged(core.project_index.Bullet) = .empty;
    defer bullets.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |b| gpa.free(b);
        owned.deinit(gpa);
    }

    const cwd = Io.Dir.cwd();
    for (names.items) |nn| {
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists, nn });
        defer gpa.free(title_path);
        const raw_title = cwd.readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(raw_title);
        const link = try core.emit.fileTitle(gpa, std.mem.trimEnd(u8, raw_title, "\n"));
        try owned.append(gpa, link);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists, nn });
        defer gpa.free(list_path);
        const list = cwd.readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch "";
        defer if (list.len != 0) gpa.free(list);
        const files = std.mem.count(u8, list, "\n"); // `wc -l`: one path per line

        const node_text = try context.readNode(ctx, io, link);
        defer if (node_text) |t| gpa.free(t);
        if (node_text == null) {
            std.debug.print("{s}: node not in the vault: {s}.md\n", .{ prog, link });
            std.debug.print("  the index is built from the nodes, so write them first\n", .{});
            return 1;
        }
        // `scalar`, not `field`: unescaped, since the summary goes into prose.
        const clean = (try core.query.scalar(gpa, node_text.?, "summary")) orelse
            try gpa.dupe(u8, "");
        if (clean.len == 0) {
            gpa.free(clean);
            std.debug.print("{s}: no summary field on {s}.md\n", .{ prog, link });
            return 1;
        }
        for (clean) |*c| if (c.* == '\t') { // tabs squashed to spaces
            c.* = ' ';
        };
        try owned.append(gpa, clean);

        try bullets.append(gpa, .{ .link = link, .files = files, .summary = clean });
    }

    std.mem.sort(core.project_index.Bullet, bullets.items, {}, struct {
        fn less(_: void, a: core.project_index.Bullet, b: core.project_index.Bullet) bool {
            return std.mem.order(u8, a.link, b.link) == .lt;
        }
    }.less);

    const total_files = try totalFiles(gpa, io, ctx, lists);

    const built_at = try nowStamp(gpa, io);
    defer gpa.free(built_at);

    var index: Io.Writer.Allocating = .init(gpa);
    defer index.deinit();
    try core.project_index.write(&index.writer, .{
        .namespace = ctx.namespace,
        .project = ctx.namespace[0 .. std.mem.indexOfScalar(u8, ctx.namespace, '@') orelse ctx.namespace.len],
        .branch = ctx.branch,
        .remote = ctx.remote,
        .built_at = built_at,
        .total_files = total_files,
        .bullets = bullets.items,
    });

    var resolved = (try adapters.store_resolve.resolveStore(gpa, io, env, ctx.vault, ctx.dir, prog, "")) orelse return 1;
    defer resolved.deinit();
    var store = resolved.store();
    const put_result = store.write(io, "Index.md", index.written()) catch |err| {
        std.debug.print("{s}: write failed: {s}\n", .{ prog, @errorName(err) });
        return 1;
    };
    defer gpa.free(put_result.body);
    if (!put_result.accepted) {
        std.debug.print("{s}: write rejected ({d:0>3}): {s}\n", .{ prog, put_result.status, put_result.body });
        return 1;
    }

    try result.print("Index.md written: {d} nodes, {d} tracked files, remote={s}\n", .{
        bullets.items.len,
        total_files,
        ctx.remote,
    });
    return 0;
}

/// `find "$LISTS" -name '*.title' | LC_ALL=C sort`, yielding the `NN`.
fn listTitles(gpa: Allocator, io: Io, lists: []const u8) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, lists, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".title")) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".title".len]));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out;
}

/// `all.txt`'s line count, or the distinct union of the lists when absent --
/// the lists only cover what a node claimed, so the union is the honest
/// fallback rather than zero.
fn totalFiles(gpa: Allocator, io: Io, ctx: *const Context, lists: []const u8) !usize {
    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{ctx.work_dir});
    defer gpa.free(all_path);
    if (Io.Dir.cwd().readFileAlloc(io, all_path, gpa, .limited(256 << 20))) |all| {
        defer gpa.free(all);
        if (all.len != 0) return std.mem.count(u8, all, "\n");
    } else |_| {}

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, lists, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ lists, entry.name });
        defer gpa.free(p);
        const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 << 20)) catch continue;
        try texts.append(gpa, text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try seen.put(gpa, line, {});
        }
    }
    return seen.count();
}

/// `date '+%Y-%m-%d %H:%M'`, spawned -- see `write_node_cmd.nowStamp`.
fn nowStamp(gpa: Allocator, io: Io) ![]u8 {
    const res = try adapters.process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M" }, .{});
    defer res.deinit(gpa);
    if (!res.ok()) return error.NoDate;
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn stageList(fx: *fixture.Fixture, nn: []const u8, title: []const u8, paths: []const []const u8) !void {
    try fx.tmp.dir.createDirPath(testing.io, "work/lists");
    const title_path = try std.fmt.allocPrint(fx.gpa, "work/lists/{s}.title", .{nn});
    defer fx.gpa.free(title_path);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = title_path, .data = title });

    var body: Io.Writer.Allocating = .init(fx.gpa);
    defer body.deinit();
    for (paths) |p| try body.writer.print("{s}\n", .{p});
    const txt_path = try std.fmt.allocPrint(fx.gpa, "work/lists/{s}.txt", .{nn});
    defer fx.gpa.free(txt_path);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_path, .data = body.written() });
}

/// A node the builder reads its summary back from, matching the bats
/// fixture's own `stage_node` -- filename sanitized like the real writer,
/// summary escaped for a double-quoted YAML scalar.
fn stageNode(fx: *fixture.Fixture, title: []const u8, summary: []const u8) !void {
    const link = try core.emit.fileTitle(fx.gpa, title);
    defer fx.gpa.free(link);

    var out: Io.Writer.Allocating = .init(fx.gpa);
    defer out.deinit();
    try out.writer.writeAll("---\ntitle: \"");
    try out.writer.writeAll(title);
    try out.writer.writeAll("\"\nsummary: \"");
    for (summary) |c| switch (c) {
        '\\' => try out.writer.writeAll("\\\\"),
        '"' => try out.writer.writeAll("\\\""),
        else => try out.writer.writeByte(c),
    };
    try out.writer.print(
        "\"\nnode_type: synapse-node\nsources:\n  - path: x\n    hash: y\n" ++
            "sources_digest: deadbeef\nstale: false\nbuilt_at: \"2026-01-01 00:00\"\n---\n\n" ++
            "# {s}\n<!-- synapse:generated:start -->\nbody\n<!-- synapse:generated:end -->\n\n## Notes\n",
        .{title},
    );
    try fx.writeNodeFile(link, out.written());
}

fn runBuild(gpa: Allocator, fx: *fixture.Fixture) !struct { code: u8, out: []u8 } {
    var ctx = try fx.resolveContext();
    defer ctx.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try write(gpa, fx.io(), &fx.env, &ctx, &out.writer);
    return .{ .code = code, .out = try gpa.dupe(u8, out.written()) };
}

fn readIndex(gpa: Allocator, fx: *fixture.Fixture) ![]u8 {
    return fx.tmp.dir.readFileAlloc(testing.io, "vault/synapse/repo@main/Index.md", gpa, .limited(1 << 20));
}

test "build-project-index: writes the frontmatter the SessionStart hook expects" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.env.put("SYNAPSE_REMOTE", "ssh://git@example.com/x/proj.git");
    try stageList(&fx, "01", "Mod A", &.{ "mod-a/a.txt", "mod-a/b.txt" });
    try stageNode(&fx, "Mod A", "The first module.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    try testing.expect(std.mem.indexOf(u8, idx, "title: \"repo@main — Synapse index\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "node_type: synapse-index\n") != null);
    // project and branch are the two halves of the namespace key, recorded
    // separately: the combined form is already the title and the directory name.
    try testing.expect(std.mem.indexOf(u8, idx, "project: repo\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "branch: main\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "remote: \"ssh://git@example.com/x/proj.git\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "built_at: \"") != null);
}

test "build-project-index: each bullet carries the node's own summary and its file count" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{ "mod-a/a.txt", "mod-a/b.txt", "mod-a/c.txt" });
    try stageList(&fx, "02", "Docs", &.{"docs/d.md"});
    try stageNode(&fx, "Mod A", "The first module.");
    try stageNode(&fx, "Docs", "The documentation.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    try testing.expect(std.mem.indexOf(u8, idx, "- [[Mod A]] — The first module. (3 files)\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "- [[Docs]] — The documentation. (1 files)\n") != null);
}

test "build-project-index: editing a node's summary changes the index, with no second copy to update" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Mod A", "First wording.");

    const first = try runBuild(gpa, &fx);
    gpa.free(first.out);
    const idx1 = try readIndex(gpa, &fx);
    defer gpa.free(idx1);
    try testing.expect(std.mem.indexOf(u8, idx1, "First wording.") != null);

    // The whole point of keeping the summary on the node: rewriting it
    // cannot leave the index describing the node as it used to be.
    try stageNode(&fx, "Mod A", "Second wording.");
    const second = try runBuild(gpa, &fx);
    gpa.free(second.out);
    const idx2 = try readIndex(gpa, &fx);
    defer gpa.free(idx2);
    try testing.expect(std.mem.indexOf(u8, idx2, "Second wording.") != null);
    try testing.expect(std.mem.indexOf(u8, idx2, "First wording.") == null);
}

test "build-project-index: quotes and backslashes in a summary survive the round trip" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Mod A", "Handles \"quoted\" input and a C:\\path.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    try testing.expect(std.mem.indexOf(u8, idx, "Handles \"quoted\" input and a C:\\path.") != null);
}

test "build-project-index: bullets link by filename, so a sanitized title still resolves" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Bad — import/export", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Bad — import/export", "Small modules.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    // The wikilink must match the file the writer produced, not the raw title.
    try testing.expect(std.mem.indexOf(u8, idx, "- [[Bad — import_export]] — Small modules. (1 files)\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "[[Bad — import/export]]") == null);
}

test "build-project-index: bullets are sorted by title, not by list number" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Zeta module", &.{"z/z.txt"});
    try stageList(&fx, "02", "Alpha module", &.{"a/a.txt"});
    try stageNode(&fx, "Zeta module", "Last alphabetically.");
    try stageNode(&fx, "Alpha module", "First alphabetically.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    // An index of dozens of entries is scanned for a name, so alphabetical
    // is the only order a reader can predict.
    const first = std.mem.indexOf(u8, idx, "[[Alpha module]]").?;
    const second = std.mem.indexOf(u8, idx, "[[Zeta module]]").?;
    try testing.expect(first < second);
}

test "build-project-index: the index carries no repo-specific prose at all" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Mod A", "Only node.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);

    // A whitelist, not a blacklist of suspicious words: every prose line
    // (the body, between the two `---` fences) must be one of the generic
    // sentences the writer emits, so ANY repo-specific text would fail
    // regardless of how it is worded.
    const fm_end = std.mem.indexOf(u8, idx, "---\n").?;
    const body_start = fm_end + 4 + (std.mem.indexOf(u8, idx[fm_end + 4 ..], "---\n").? + 4);
    const body = idx[body_start..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "- [[")) continue;
        if (std.mem.startsWith(u8, line, "# ")) continue;
        const generic = std.mem.indexOf(u8, line, "tracked files,") != null and std.mem.indexOf(u8, line, "nodes.") != null;
        const reading_guidance = std.mem.startsWith(u8, line, "Reading a node:");
        try testing.expect(generic or reading_guidance);
    }
    try testing.expect(std.mem.indexOf(u8, idx, "synapse query body") != null);
}

test "build-project-index: the file count comes from all.txt when present" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Mod A", "Only node.");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/all.txt", .data = "a\nb\nc\nd\n" });

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const idx = try readIndex(gpa, &fx);
    defer gpa.free(idx);
    try testing.expect(std.mem.indexOf(u8, idx, "4 tracked files, 1 nodes.") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "4 tracked files") != null);
}

test "build-project-index: a node that is not in the vault yet exits 1 rather than emitting a dead link" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageList(&fx, "02", "Never written", &.{"x/x.txt"});
    try stageNode(&fx, "Mod A", "Only node.");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "build-project-index: a node with no summary field exits 1" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try fx.writeNodeFile("Mod A", "---\ntitle: \"Mod A\"\nnode_type: synapse-node\n---\n\n# Mod A\n");

    const r = try runBuild(gpa, &fx);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "build-project-index: missing lists and a disk write failure each exit 1" {
    // "write failed" goes to real stderr via std.debug.print, not the result
    // writer -- the same split index_cmd's own equivalent test already
    // ran into. Only the exit code is asserted here; the wording is bats'.
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.forceWriteFailure("synapse/repo@main/Index.md");
    try stageList(&fx, "01", "Mod A", &.{"mod-a/a.txt"});
    try stageNode(&fx, "Mod A", "Only node.");

    const rejected = try runBuild(gpa, &fx);
    defer gpa.free(rejected.out);
    try testing.expectEqual(@as(u8, 1), rejected.code);

    try fx.tmp.dir.deleteTree(testing.io, "work/lists");
    const no_lists = try runBuild(gpa, &fx);
    defer gpa.free(no_lists.out);
    try testing.expectEqual(@as(u8, 1), no_lists.code);
}
