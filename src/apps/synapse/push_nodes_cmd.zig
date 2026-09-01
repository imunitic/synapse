//! `synapse push-nodes` -- `claude/lib/synapse/synapse-push-nodes.sh`.
//!
//!   push-nodes [NN ...]
//!
//! Writes one node per authored body, pairing `$SYNAPSE_WORK_DIR/b-NN.md` with
//! `lists/NN.txt` and `lists/NN.title`. With no arguments the target set is the
//! *union* of staged lists and authored bodies, so an un-authored node reports as a
//! SKIP rather than vanishing.
//!
//! One process per push, writing straight to disk through `write_node_cmd`'s
//! own `write()` -- no subprocess chain at all.
//!
//! Any failed node is exit 1. So is a run that pushed nothing at all --
//! otherwise a no-op would read as success.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const write_node_cmd = @import("write_node_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

const prog = "synapse-push-nodes";

const usage_text =
    \\usage: synapse push-nodes [NN ...]
    \\
    \\  NN   three-digit node numbers to push. Default: every b-NN.md and lists/NN.title.
    \\
;

pub fn run(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(gpa);
    var explicit = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (arg.len != 0 and arg[0] == '-') {
            std.debug.print("{s}", .{usage_text});
            return 2;
        }
        explicit = true;
        try targets.append(gpa, arg);
    }

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try push(Extractor, gpa, io, env, &ctx, targets.items, explicit, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture `Context` directly. `targets_in` is the
/// explicit `NN ...` list from argv (empty when `explicit` is false, in
/// which case the target set is discovered from what's on disk instead).
pub fn push(
    comptime Extractor: type,
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    ctx: *const Context,
    targets_in: []const []const u8,
    explicit: bool,
    out: *Io.Writer,
) !u8 {
    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{ctx.work_dir});
    defer gpa.free(lists);
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, lists, .{})) |_| {} else |_| {
        std.debug.print(
            "{s}: no lists/ in {s} -- run `synapse build-lists` first\n",
            .{ prog, ctx.work_dir },
        );
        return 1;
    }

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(gpa);
    try targets.appendSlice(gpa, targets_in);

    var discovered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (discovered.items) |d| gpa.free(d);
        discovered.deinit(gpa);
    }
    if (!explicit) {
        try discover(gpa, io, ctx, lists, &discovered);
        for (discovered.items) |d| try targets.append(gpa, d);
        if (targets.items.len == 0) {
            std.debug.print(
                "{s}: nothing to push (no lists/NN.title or b-NN.md in {s})\n",
                .{ prog, ctx.work_dir },
            );
            return 1;
        }
    }

    var pushed: usize = 0;
    var failed: usize = 0;

    for (targets.items) |nn| {
        const body_path = try std.fmt.allocPrint(gpa, "{s}/b-{s}.md", .{ ctx.work_dir, nn });
        defer gpa.free(body_path);
        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists, nn });
        defer gpa.free(list_path);
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists, nn });
        defer gpa.free(title_path);

        const body = cwd.readFileAlloc(io, body_path, gpa, .limited(64 << 20)) catch {
            try out.print("{s}\tSKIP (no body)\n", .{nn});
            continue;
        };
        defer gpa.free(body);

        const list = cwd.readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch "";
        defer if (list.len != 0) gpa.free(list);
        const title_text = cwd.readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch {
            try out.print("{s}\tSKIP (no list/title)\n", .{nn});
            continue;
        };
        defer gpa.free(title_text);
        // An empty list is a skip too -- a node claiming no files isn't one.
        if (list.len == 0) {
            try out.print("{s}\tSKIP (no list/title)\n", .{nn});
            continue;
        }

        const summary = core.query.field(body, "summary") orelse "";
        if (summary.len == 0) {
            // Failure, not skip: the body exists, so a missing summary is a
            // mistake in it, not unfinished work.
            try out.print(
                "{s}\tFAILED (no `summary:` frontmatter in b-{s}.md)\n",
                .{ nn, nn },
            );
            failed += 1;
            continue;
        }

        var line: Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        const code = write_node_cmd.write(Extractor, gpa, io, env, ctx, .{
            .title = std.mem.trimEnd(u8, title_text, "\n"),
            .summary = summary,
            .paths_text = list,
            .body_text = core.query.bodyAfterFrontmatter(body), // frontmatter stripped
        }, &line.writer) catch 1;

        if (code == 0) {
            try out.print("{s}\t{s}", .{ nn, line.written() });
            pushed += 1;
        } else {
            try out.print("{s}\tFAILED\n", .{nn});
            failed += 1;
        }
    }

    if (failed != 0) {
        std.debug.print("{s}: {d} node(s) failed\n", .{ prog, failed });
        return 1;
    }
    if (pushed == 0) {
        std.debug.print(
            "{s}: nothing to push (no node had both a list and a body)\n",
            .{prog},
        );
        return 1;
    }
    return 0;
}

/// Union of `lists/NN.title` and `b-NN.md`, byte-sorted and deduplicated --
/// either side alone would let a mismatched node vanish silently.
fn discover(
    gpa: Allocator,
    io: Io,
    ctx: *const Context,
    lists: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    try collect(gpa, io, lists, "", ".title", out);
    try collect(gpa, io, ctx.work_dir, "b-", ".md", out);
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var n: usize = 0;
    for (out.items) |item| {
        if (n != 0 and std.mem.eql(u8, out.items[n - 1], item)) {
            gpa.free(item);
            continue;
        }
        out.items[n] = item;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
}

/// Entries matching `<prefix>NNN<suffix>`, yielding the `NNN`. Three digits
/// exactly -- `b-1.md`/`b-1000.md` aren't node files. Tied to
/// `core.node.max_nodes`'s own 3-digit slug width: raising that constant
/// past 999 means this exact-length check needs to widen too.
fn collect(
    gpa: Allocator,
    io: Io,
    dir_path: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len != prefix.len + 3 + suffix.len) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (!std.mem.endsWith(u8, name, suffix)) continue;
        const nnn = name[prefix.len .. prefix.len + 3];
        if (!std.ascii.isDigit(nnn[0]) or !std.ascii.isDigit(nnn[1]) or !std.ascii.isDigit(nnn[2])) continue;
        try out.append(gpa, try gpa.dupe(u8, nnn));
    }
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");
const fake_grammar = @import("fake_grammar.zig");

/// No real git needed -- `write_node_cmd.write` hashes source files
/// directly off disk, the same reason its own native tests get away with
/// just `fx.writeRepoFile` and the env-var identity bypass (`fx.resolveContext()`).
const PushNodesFixture = struct {
    fx: fixture.Fixture,
    ctx: Context,

    fn init(gpa: Allocator) !PushNodesFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        const ctx = try fx.resolveContext();
        return .{ .fx = fx, .ctx = ctx };
    }

    fn deinit(self: *PushNodesFixture) void {
        self.ctx.deinit();
        self.fx.deinit();
    }

    /// Stages node `nn` with a title, a one-path list and a body whose
    /// frontmatter's `summary` is `"Node {nn} in one line."`.
    fn stageNode(self: *PushNodesFixture, nn: []const u8, title: []const u8, path: []const u8) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "work/lists");
        const title_path = try std.fmt.allocPrint(self.fx.gpa, "work/lists/{s}.title", .{nn});
        defer self.fx.gpa.free(title_path);
        const title_body = try std.fmt.allocPrint(self.fx.gpa, "{s}\n", .{title});
        defer self.fx.gpa.free(title_body);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = title_path, .data = title_body });

        const list_path = try std.fmt.allocPrint(self.fx.gpa, "work/lists/{s}.txt", .{nn});
        defer self.fx.gpa.free(list_path);
        const list_body = try std.fmt.allocPrint(self.fx.gpa, "{s}\n", .{path});
        defer self.fx.gpa.free(list_body);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = list_path, .data = list_body });

        const body_path = try std.fmt.allocPrint(self.fx.gpa, "work/b-{s}.md", .{nn});
        defer self.fx.gpa.free(body_path);
        const body = try std.fmt.allocPrint(
            self.fx.gpa,
            "---\nsummary: Node {s} in one line.\n---\n\n## Summary\nNode {s}.\n",
            .{ nn, nn },
        );
        defer self.fx.gpa.free(body);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = body_path, .data = body });
    }

    fn run(self: *PushNodesFixture, targets: []const []const u8, explicit: bool, out: *Io.Writer) !u8 {
        return push(fake_grammar.FakeExtractor, self.fx.gpa, self.fx.io(), &self.fx.env, &self.ctx, targets, explicit, out);
    }
};

test "pushes every node that has both a list and a body" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.fx.writeRepoFile("docs/d.md", "d\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");
    try pf.stageNode("002", "Docs", "docs/d.md");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    try testing.expect(try pf.fx.nodeExists("Mod A"));
    try testing.expect(try pf.fx.nodeExists("Docs"));
    // Each line reports the node number alongside the writer's own output.
    try testing.expect(std.mem.indexOf(u8, out.written(), "001\tMod A.md") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "002\tDocs.md") != null);
}

test "explicit node numbers restrict the push" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.fx.writeRepoFile("docs/d.md", "d\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");
    try pf.stageNode("002", "Docs", "docs/d.md");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{"002"}, true, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    try testing.expect(try pf.fx.nodeExists("Docs"));
    try testing.expect(!try pf.fx.nodeExists("Mod A"));
}

test "a list with no authored body is skipped, not written empty" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.fx.writeRepoFile("docs/d.md", "d\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");
    try pf.fx.tmp.dir.createDirPath(testing.io, "work/lists");
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/002.title", .data = "Docs\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/002.txt", .data = "docs/d.md\n" });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "002\tSKIP (no body)\n") != null);
    try testing.expect(!try pf.fx.nodeExists("Docs"));
}

test "a body with no list is skipped rather than pushed with empty sources" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");
    try pf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "work/b-007.md",
        .data = "---\nsummary: Orphan.\n---\n\n## Summary\nOrphan.\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "007\tSKIP (no list/title)\n") != null);
}

test "one failing node is reported and the rest still push" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.fx.writeRepoFile("docs/d.md", "d\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");
    // A list naming a path that no longer exists makes the writer refuse.
    try pf.fx.tmp.dir.createDirPath(testing.io, "work/lists");
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/002.title", .data = "Broken\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/002.txt", .data = "docs/gone.md\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "work/b-002.md",
        .data = "---\nsummary: Broken.\n---\n\n## Summary\nBroken.\n",
    });
    try pf.stageNode("003", "Docs", "docs/d.md");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "002\tFAILED\n") != null);
    // The failure must not abort the run: 03 comes after 02 and must still exist.
    try testing.expect(try pf.fx.nodeExists("Docs"));
    try testing.expect(try pf.fx.nodeExists("Mod A"));
}

test "no bodies at all exits 1 instead of reporting a silent success" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.tmp.dir.createDirPath(testing.io, "work/lists");
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/001.title", .data = "Mod A\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/001.txt", .data = "mod-a/a.txt\n" });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "the summary comes from the body's frontmatter and is stripped from the prose" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.stageNode("001", "Mod A", "mod-a/a.txt");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    // Everything authored about a node lives in one b-NN.md: its headline
    // becomes the node's `summary` field...
    const written = (try pf.fx.readNode(gpa, "Mod A")).?;
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "summary: \"Node 001 in one line.\"\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "summary:"));
    // ...and must not be repeated inside the prose.
    try testing.expect(std.mem.indexOf(u8, written, "## Summary\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Node 001.\n") != null);
}

test "a body with no summary frontmatter fails rather than writing a node without one" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    try pf.fx.writeRepoFile("mod-a/a.txt", "a\n");
    try pf.fx.tmp.dir.createDirPath(testing.io, "work/lists");
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/001.title", .data = "Mod A\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/lists/001.txt", .data = "mod-a/a.txt\n" });
    try pf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "work/b-001.md",
        .data = "## Summary\nNo frontmatter here.\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    // The index is built from node summaries, so a node without one would
    // break it later; better to fail at the point the author can fix it.
    try testing.expect(std.mem.indexOf(u8, out.written(), "001\tFAILED (no `summary:` frontmatter in b-001.md)\n") != null);
    try testing.expect(!try pf.fx.nodeExists("Mod A"));
}

test "a missing lists directory points at the step that produces it" {
    const gpa = testing.allocator;
    var pf = try PushNodesFixture.init(gpa);
    defer pf.deinit();
    // `work/lists` is never created -- Fixture.init only pre-creates `work`.
    try pf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "work/b-001.md",
        .data = "---\nsummary: x.\n---\n\n## Summary\nx\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try pf.run(&.{}, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}
