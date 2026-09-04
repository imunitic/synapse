//! `synapse brief` -- one self-contained data file per node, bundling
//! everything a concurrent author needs except the prose itself.
//!
//!   brief --lists <dir> [--rank <dir>] [--links <file>] [--repo <path>] [--out <dir>]
//!
//! Reshapes stage 1 (`rank --lists`) and stage 2 (`build-refs` +
//! `link-graph`) output, per node, into `{out}/brief/NN.md`: sources list
//! path/count (not content), both ranked pools verbatim, this node's
//! `links.tsv` rows, and every node's title (for judging `part_of`, still a
//! judgement call, never computed here). Data, not instructions -- what an
//! author does with it lives in the `synapse-node-authoring` skill.
//!
//! Missing `--rank`/`--links` is advice-level: empty pool sections plus a
//! warning. A missing/empty `--lists` dir is fatal.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");
const cli_args = @import("cli_args.zig");
const repo_root = @import("repo_root.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-brief";

const usage_text =
    \\usage: synapse brief --lists <dir> [--rank <dir>] [--links <file>] [--repo <path>] [--out <dir>]
    \\
    \\  --lists  the NN.txt/NN.title path lists synapse build-lists wrote.
    \\  --rank   where synapse rank --lists wrote NN.summary.tsv/NN.crux.tsv.
    \\           Default $SYNAPSE_WORK_DIR/rank.
    \\  --links  synapse link-graph's output. Default $SYNAPSE_WORK_DIR/links.tsv.
    \\           A missing file warns and leaves every node's edges empty.
    \\  --out    where to write brief/NN.md. Default $SYNAPSE_WORK_DIR.
    \\
;

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var lists_dir: ?[]const u8 = null;
    var rank_dir: ?[]const u8 = null;
    var links_path: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = cli_args.takenValue(args.next()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--rank")) {
            rank_dir = cli_args.takenValue(args.next()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--links")) {
            links_path = cli_args.takenValue(args.next()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = cli_args.takenValue(args.next()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = cli_args.takenValue(args.next()) orelse return usage();
        } else return usage();
    }
    const lists = lists_dir orelse return usage();

    return build(gpa, io, env, .{
        .lists = lists,
        .rank_dir = rank_dir,
        .links_path = links_path,
        .repo = repo,
        .out_dir = out_dir,
    });
}

pub const Options = struct {
    lists: []const u8,
    rank_dir: ?[]const u8 = null,
    links_path: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
};

pub fn build(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    opts: Options,
) !u8 {
    const lists = opts.lists;
    var rank_dir = opts.rank_dir;
    var links_path = opts.links_path;
    var out_dir = opts.out_dir;
    const repo = opts.repo;

    const cwd = Io.Dir.cwd();
    cwd.access(io, lists, .{}) catch {
        std.debug.print("{s}: no such lists dir: {s}\n", .{ prog, lists });
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Explicit flags win, otherwise the namespace of --repo (or cwd). Kept
    // alive for the rest of the function -- out_dir/rank_dir/links_path borrow it.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (out_dir == null or rank_dir == null or links_path == null) {
        derived = try context.workDirFor(gpa, io, env, repo orelse ".", prog);
        if (derived == null) return 1;
    }
    if (out_dir == null) out_dir = derived.?.path;
    if (rank_dir == null) rank_dir = try std.fmt.allocPrint(arena, "{s}/rank", .{derived.?.path});
    if (links_path == null) links_path = try std.fmt.allocPrint(arena, "{s}/links.tsv", .{derived.?.path});

    // `gpa`, not `arena`: `process.run` drains a spawned child's stdout
    // inline while draining stderr concurrently on another thread, and
    // `ArenaAllocator` isn't safe for that concurrent use.
    const root = try repo_root.resolve(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("{s}: not inside a git repo: {s}\n", .{ prog, repo orelse "." });
        return 1;
    }

    const nodes = try readLists(arena, io, lists);
    if (nodes.len == 0) {
        std.debug.print("{s}: no NN.txt/NN.title pairs in {s}\n", .{ prog, lists });
        return 1;
    }

    // Mapped, not read whole -- `writeLinksFor` scans it once per node, so a
    // links.tsv past the old 1 GiB read cap no longer fails outright.
    var links_index: core.refs.Index = core.refs.Index.open(io, gpa, links_path.?) catch blk: {
        std.debug.print(
            "{s}: no link graph at {s} -- every brief's candidate links will be empty; run synapse build-refs and synapse link-graph first\n",
            .{ prog, links_path.? },
        );
        break :blk .{ .bytes = "" };
    };
    defer links_index.deinit(io, gpa);
    const links_text = links_index.bytes;

    const brief_dir = try std.fmt.allocPrint(arena, "{s}/brief", .{out_dir.?});
    cwd.createDirPath(io, brief_dir) catch {
        std.debug.print("{s}: cannot write {s}\n", .{ prog, brief_dir });
        return 1;
    };

    var rank_missing: usize = 0;
    for (nodes) |n| {
        const summary_path = try std.fmt.allocPrint(arena, "{s}/{d:0>3}.summary.tsv", .{ rank_dir.?, n.n });
        const crux_path = try std.fmt.allocPrint(arena, "{s}/{d:0>3}.crux.tsv", .{ rank_dir.?, n.n });
        const summary = cwd.readFileAlloc(io, summary_path, arena, .limited(16 << 20)) catch blk: {
            rank_missing += 1;
            break :blk "";
        };
        const crux = cwd.readFileAlloc(io, crux_path, arena, .limited(16 << 20)) catch "";

        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const w = &body.writer;

        try w.print("# {s}\n\n", .{n.title});
        try w.print("Repo root: {s}\n", .{root});
        try w.print("Sources list: {s} ({d} files, exhaustive -- do not re-enumerate; `write-node` reads this list directly)\n\n", .{ n.txt_path, n.count });

        try w.writeAll("## Summary pool (ranked, read the top few)\n");
        try writeTsvBlock(w, summary);

        try w.writeAll("\n## Crux pool (ranked, tests excluded)\n");
        try writeTsvBlock(w, crux);

        try w.writeAll("\n## Candidate links (from the link graph; weight = distinct rare shared symbols)\n");
        try writeLinksFor(w, links_text, n.title);

        try w.writeAll("\n## Every node in this namespace (for judging part_of)\n");
        for (nodes) |other| try w.print("- {s}\n", .{other.title});

        const out_path = try std.fmt.allocPrint(arena, "{s}/{d:0>3}.md", .{ brief_dir, n.n });
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = body.written() });
    }

    if (rank_missing != 0) {
        std.debug.print(
            "{s}: {d}/{d} nodes had no rank output at {s} -- their pool sections are empty; run synapse rank --lists first\n",
            .{ prog, rank_missing, nodes.len, rank_dir.? },
        );
    }
    std.debug.print("{s}: {d} briefs -> {s}\n", .{ prog, nodes.len, brief_dir });
    return 0;
}

fn writeTsvBlock(w: *Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("(none)\n");
        return;
    }
    try w.writeAll("```\n");
    try w.writeAll(trimmed);
    try w.writeAll("\n```\n");
}

/// Rows of `links.tsv` whose `from` is this node -- already strongest-first
/// per node, so filtered order is preserved, not re-sorted.
fn writeLinksFor(w: *Io.Writer, links_text: []const u8, title: []const u8) !void {
    var any = false;
    var lines = std.mem.splitScalar(u8, links_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[0..tab], title)) continue;
        if (!any) try w.writeAll("```\n");
        try w.writeAll(line);
        try w.writeAll("\n");
        any = true;
    }
    if (any) {
        try w.writeAll("```\n");
    } else {
        try w.writeAll("(none)\n");
    }
}

const NodeInfo = struct {
    n: usize,
    title: []const u8,
    txt_path: []const u8,
    count: usize,
};

/// Every `NN.txt`/`NN.title` pair in `dir`, ascending. A node missing either
/// half is skipped.
fn readLists(arena: Allocator, io: Io, dir: []const u8) ![]NodeInfo {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayListUnmanaged(NodeInfo) = .empty;
    var n: usize = 1;
    while (n <= core.node.max_nodes) : (n += 1) {
        const title_path = try std.fmt.allocPrint(arena, "{s}/{d:0>3}.title", .{ dir, n });
        const title_raw = cwd.readFileAlloc(io, title_path, arena, .limited(64 << 10)) catch continue;
        const title = std.mem.trim(u8, firstLine(title_raw), " \t\r");
        if (title.len == 0) continue;

        const txt_path = try std.fmt.allocPrint(arena, "{s}/{d:0>3}.txt", .{ dir, n });
        const body = cwd.readFileAlloc(io, txt_path, arena, .limited(64 << 20)) catch continue;

        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            if (std.mem.trim(u8, raw, " \t\r").len != 0) count += 1;
        }

        try out.append(arena, .{
            .n = n,
            .title = title,
            .txt_path = txt_path,
            .count = count,
        });
    }
    return out.items;
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

/// A real git repo (`brief` needs `git rev-parse --show-toplevel` to
/// resolve `--repo`'s root) plus real `lists`/`rank`/`links.tsv` inputs --
/// no vault, no tagging, so most of `cmd_test_support.Fixture` goes unused,
/// but its real-git support (`gitCommit()`) is the one thing this file
/// genuinely needs.
///
/// `commit()` is a separate step from `init()`, called once by every test
/// right after construction, never inside `init()` itself, because a hang
/// follows otherwise: `gitCommit()` spawns real subprocesses,
/// which binds the fixture's `Io.Threaded` worker threads to `init()`'s own
/// *local* copy of the struct; `init()` then returns that struct by value,
/// moving it to the caller's stack slot, and the already-spawned worker
/// keeps servicing the old (now-orphaned) address forever while every
/// later call operates on the moved one -- the real subprocess exits fine
/// (reaped as a zombie), but its async stderr-drain future is never again
/// signalled, and the caller hangs waiting on it. Every other fixture
/// wrapper in this codebase already avoids this by construction, never
/// spawning a subprocess before its own `init()` returns.
const BriefFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !BriefFixture {
        var fx = try fixture.Fixture.init(gpa);
        errdefer fx.deinit();
        try fx.tmp.dir.createDirPath(testing.io, "lists");
        try fx.tmp.dir.createDirPath(testing.io, "rank");
        try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "links.tsv", .data = "" });
        try fx.writeRepoFile(".gitkeep", "");
        return .{ .fx = fx };
    }

    fn deinit(self: *BriefFixture) void {
        self.fx.deinit();
    }

    /// Commits the repo for real. Call once, after every `writeList`/
    /// `writePool`/`appendLink` call for a test, and always before `run()`.
    fn commit(self: *BriefFixture) !void {
        try self.fx.gitCommit("init");
    }

    fn writeList(self: *BriefFixture, nn: []const u8, title: []const u8, paths: []const []const u8) !void {
        const title_sub = try std.fmt.allocPrint(self.fx.gpa, "lists/{s}.title", .{nn});
        defer self.fx.gpa.free(title_sub);
        const title_line = try std.fmt.allocPrint(self.fx.gpa, "{s}\n", .{title});
        defer self.fx.gpa.free(title_line);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = title_sub, .data = title_line });

        var body: Io.Writer.Allocating = .init(self.fx.gpa);
        defer body.deinit();
        for (paths) |p| try body.writer.print("{s}\n", .{p});
        const txt_sub = try std.fmt.allocPrint(self.fx.gpa, "lists/{s}.txt", .{nn});
        defer self.fx.gpa.free(txt_sub);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_sub, .data = body.written() });
    }

    fn writePool(self: *BriefFixture, nn: []const u8, pool: []const u8, tier: []const u8, score: []const u8, paths: []const []const u8) !void {
        var body: Io.Writer.Allocating = .init(self.fx.gpa);
        defer body.deinit();
        for (paths) |p| try body.writer.print("{s}\t{s}\t{s}\n", .{ tier, score, p });
        const sub = try std.fmt.allocPrint(self.fx.gpa, "rank/{s}.{s}.tsv", .{ nn, pool });
        defer self.fx.gpa.free(sub);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = body.written() });
    }

    fn appendLink(self: *BriefFixture, from: []const u8, to: []const u8, weight: []const u8, symbols: []const u8) !void {
        const existing = self.fx.tmp.dir.readFileAlloc(testing.io, "links.tsv", self.fx.gpa, .limited(1 << 20)) catch "";
        defer if (existing.len != 0) self.fx.gpa.free(existing);
        const line = try std.fmt.allocPrint(self.fx.gpa, "{s}\t{s}\t{s}\t{s}\n", .{ from, to, weight, symbols });
        defer self.fx.gpa.free(line);
        const combined = try std.fmt.allocPrint(self.fx.gpa, "{s}{s}", .{ existing, line });
        defer self.fx.gpa.free(combined);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "links.tsv", .data = combined });
    }

    fn listsDir(self: *BriefFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/lists", .{self.fx.root});
    }

    fn rankDir(self: *BriefFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/rank", .{self.fx.root});
    }

    fn linksPath(self: *BriefFixture) ![]const u8 {
        return std.fmt.allocPrint(self.fx.gpa, "{s}/links.tsv", .{self.fx.root});
    }

    /// Runs `build` with `--lists`/`--rank`/`--links`/`--repo`/`--out` all
    /// resolved to the fixture's own real paths, unless overridden. Call
    /// `commit()` first.
    fn run(self: *BriefFixture, over: struct {
        lists: ?[]const u8 = null,
        rank_dir: ?[]const u8 = null,
        links_path: ?[]const u8 = null,
        repo: ?[]const u8 = null,
        out_dir: ?[]const u8 = null,
    }) !u8 {
        const gpa = self.fx.gpa;
        const lists = over.lists orelse try self.listsDir();
        defer if (over.lists == null) gpa.free(lists);
        const rank_dir = over.rank_dir orelse try self.rankDir();
        defer if (over.rank_dir == null) gpa.free(rank_dir);
        const links_path = over.links_path orelse try self.linksPath();
        defer if (over.links_path == null) gpa.free(links_path);
        const repo = over.repo orelse self.fx.repo;
        const out_dir = over.out_dir orelse self.fx.work;

        return build(gpa, self.fx.io(), &self.fx.env, .{
            .lists = lists,
            .rank_dir = rank_dir,
            .links_path = links_path,
            .repo = repo,
            .out_dir = out_dir,
        });
    }

    fn readBrief(self: *BriefFixture, gpa: Allocator, nn: []const u8) !?[]u8 {
        const sub = try std.fmt.allocPrint(gpa, "work/brief/{s}.md", .{nn});
        defer gpa.free(sub);
        return self.fx.tmp.dir.readFileAlloc(testing.io, sub, gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }
};

test "brief: writes one brief per node, with title, source count, both pools and this node's own edges" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{ "a/One.java", "a/Two.java" });
    try bf.writeList("002", "B", &.{"b/Three.java"});
    try bf.writePool("001", "summary", "code", "3.5", &.{"a/One.java"});
    try bf.writePool("001", "crux", "code", "3.5", &.{"a/One.java"});
    try bf.writePool("002", "summary", "code", "1.0", &.{"b/Three.java"});
    try bf.writePool("002", "crux", "code", "1.0", &.{"b/Three.java"});
    try bf.appendLink("A", "B", "2", "Widget Gadget");
    try bf.appendLink("B", "A", "1", "Helper");
    try bf.commit();

    try testing.expectEqual(@as(u8, 0), try bf.run(.{}));

    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
    try testing.expect(std.mem.startsWith(u8, a, "# A"));
    try testing.expect(std.mem.indexOf(u8, a, "(2 files, exhaustive") != null);
    try testing.expect(std.mem.indexOf(u8, a, "a/One.java") != null);
    try testing.expect(std.mem.indexOf(u8, a, "A\tB\t2\tWidget Gadget") != null);
    try testing.expect(std.mem.indexOf(u8, a, "B\tA\t1\tHelper") == null);

    const b = (try bf.readBrief(gpa, "002")).?;
    defer gpa.free(b);
    try testing.expect(std.mem.startsWith(u8, b, "# B"));
    try testing.expect(std.mem.indexOf(u8, b, "B\tA\t1\tHelper") != null);
    try testing.expect(std.mem.indexOf(u8, b, "Widget Gadget") == null);
}

test "brief: every node's title is listed for judging part_of, not just the current one" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.writeList("002", "B", &.{"b/Two.java"});
    try bf.writeList("003", "C", &.{"c/Three.java"});
    try bf.commit();

    try testing.expectEqual(@as(u8, 0), try bf.run(.{}));
    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "- A") != null);
    try testing.expect(std.mem.indexOf(u8, a, "- B") != null);
    try testing.expect(std.mem.indexOf(u8, a, "- C") != null);
}

test "brief: a node with no candidate links gets (none), not an empty section" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.writeList("002", "B", &.{"b/Two.java"});
    try bf.commit();

    try testing.expectEqual(@as(u8, 0), try bf.run(.{}));
    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "Candidate links") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\n(none)") != null);
}

test "brief: missing rank output is advice, not fatal: empty pools, still succeeds" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.commit();

    try testing.expectEqual(@as(u8, 0), try bf.run(.{}));
    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "Summary pool") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\n(none)") != null);
}

test "brief: missing links.tsv is advice, not fatal: every node's links are (none)" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.writeList("002", "B", &.{"b/Two.java"});
    try bf.commit();
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.tsv", .{bf.fx.root});
    defer gpa.free(missing);

    try testing.expectEqual(@as(u8, 0), try bf.run(.{ .links_path = missing }));
    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "(none)") != null);
}

test "brief: a missing --lists dir is an error, not a silent empty result" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.commit();
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope", .{bf.fx.root});
    defer gpa.free(missing);

    try testing.expectEqual(@as(u8, 1), try bf.run(.{ .lists = missing }));
}

test "brief: an empty --lists dir is an error, pointing at what to run" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.commit();
    try bf.fx.tmp.dir.createDirPath(testing.io, "empty-lists");
    const empty = try std.fmt.allocPrint(gpa, "{s}/empty-lists", .{bf.fx.root});
    defer gpa.free(empty);

    try testing.expectEqual(@as(u8, 1), try bf.run(.{ .lists = empty }));
}

test "brief: a --repo that is not a git repo is an error, not an empty root in a plausible-looking brief" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.commit();
    // Not a subdirectory of the fixture's own tmp root: that root sits
    // inside this very project's real git repo, so `git rev-parse
    // --show-toplevel` would walk up and resolve to it instead of failing.
    // `/tmp` itself is reliably outside any git repo.
    try testing.expectEqual(@as(u8, 1), try bf.run(.{ .repo = "/tmp" }));
    try testing.expect((try bf.readBrief(gpa, "001")) == null);
}

test "brief: defaults to SYNAPSE_WORK_DIR for --rank/--links/--out when omitted" {
    const gpa = testing.allocator;
    var bf = try BriefFixture.init(gpa);
    defer bf.deinit();
    try bf.writeList("001", "A", &.{"a/One.java"});
    try bf.commit();

    const lists = try bf.listsDir();
    defer gpa.free(lists);
    const code = try build(gpa, bf.fx.io(), &bf.fx.env, .{
        .lists = lists,
        .repo = bf.fx.repo,
    });
    try testing.expectEqual(@as(u8, 0), code);
    const a = (try bf.readBrief(gpa, "001")).?;
    defer gpa.free(a);
}
