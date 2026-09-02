//! `synapse index` -- the read and write surface for `_index.bin`.
//!
//!   index build --unassigned <file> [--out <file>]   pairs on stdin
//!   index build --lists <dir> --unassigned <file>    pairs from lists/NN.txt
//!   build-index                                      the whole step, work dir derived
//!   index unassigned [--file <file>]                 every unclaimed path
//!   index lookup <path> [--file <file>]              the nodes claiming it
//!   index nodes [--file <file>]                      every node that claims anything
//!   index paths [--file <file>]                      every claimed path
//!   index add-unassigned <path> [--file <file>]      queue one path for the sweep
//!
//! New because the storage changed: `synapse-build-index.sh` authored
//! `_index.json` with `jq` and PUT it to the vault; these forms replace
//! each `jq` block that read it back, one at a time, with no CLI contract
//! moving.
//!
//! The default path comes from `SYNAPSE_WORK_DIR` and nowhere else -- the
//! (still-bash) scripts already resolve the namespace and export the work
//! dir with it baked in; guessing it here again would be a second
//! implementation of the one thing that must not disagree. Unset, `--out`/
//! `--file` is required.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = core.index_map.Map;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    const form = args.next() orelse return usage();
    // Answered before anything resolves -- help must work outside a repo.
    if (std.mem.eql(u8, form, "-h") or std.mem.eql(u8, form, "--help")) {
        _ = usage();
        return 0;
    }

    var file: ?[]const u8 = null;
    var unassigned_file: ?[]const u8 = null;
    var lists_dir: ?[]const u8 = null;
    var positional: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--file")) {
            file = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--unassigned")) {
            unassigned_file = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = args.next() orelse return usage();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else if (positional == null) {
            positional = arg;
        } else return usage();
    }

    const path = file orelse (defaultPath(gpa, io, env) catch return noWorkDir()) orelse return noWorkDir();
    defer if (file == null) gpa.free(@constCast(path));

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = code: {
        if (std.mem.eql(u8, form, "build")) break :code try buildIndex(gpa, io, path, unassigned_file, lists_dir, &out.interface);
        if (std.mem.eql(u8, form, "unassigned")) break :code try listUnassigned(io, path, &out.interface);
        if (std.mem.eql(u8, form, "lookup")) break :code try lookup(io, path, positional orelse return usage(), &out.interface);
        if (std.mem.eql(u8, form, "nodes")) break :code try listNodes(io, path, &out.interface);
        if (std.mem.eql(u8, form, "paths")) break :code try listPaths(io, path, &out.interface);
        if (std.mem.eql(u8, form, "add-unassigned"))
            break :code try addUnassigned(gpa, io, path, positional orelse return usage());
        return usage();
    };
    try out.interface.flush();
    return code;
}

fn usage() u8 {
    std.debug.print(
        \\usage: synapse index build --unassigned <file> [--out <file>] [--lists <dir>]
        \\       (pairs on stdin unless --lists names the lists directory)
        \\       synapse index unassigned [--file <file>]
        \\       synapse index lookup <path> [--file <file>]
        \\       synapse index nodes [--file <file>]
        \\       synapse index paths [--file <file>]
        \\       synapse index add-unassigned <path> [--file <file>]
        \\
    , .{});
    return 1;
}

fn noWorkDir() u8 {
    std.debug.print("synapse-index: no SYNAPSE_WORK_DIR and no --out/--file\n", .{});
    return 1;
}

/// `$SYNAPSE_WORK_DIR/_index.bin`, or null when unset. The namespace is
/// already baked into that variable, so nothing here joins repo to branch.
fn defaultPath(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !?[]const u8 {
    const work = (try context.workDir(gpa, io, env, "synapse-index")) orelse return null;
    defer work.deinit(gpa);
    return try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work.path});
}

/// Reads `path<TAB>node` pairs on stdin, groups them, replaces the index.
/// Prints one line of counts on success -- the script owns the wording,
/// this owns the numbers.
fn buildIndex(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    unassigned_file: ?[]const u8,
    lists_dir: ?[]const u8,
    result: *Io.Writer,
) !u8 {
    var pairs: std.ArrayListUnmanaged(core.index_map.Pair) = .empty;
    defer pairs.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty; // owns what --lists read; pairs slice into it
    defer {
        for (owned.items) |b| gpa.free(b);
        owned.deinit(gpa);
    }

    var text: []u8 = &.{};
    defer gpa.free(text);
    if (lists_dir) |dir| {
        if (try pairsFromLists(gpa, io, dir, &pairs, &owned) == 0) {
            std.debug.print("synapse-index: no (path, node) pairs\n", .{});
            return 1;
        }
    } else {
        var in_buf: [256 * 1024]u8 = undefined;
        var in = Io.File.stdin().reader(io, &in_buf);
        text = in.interface.allocRemaining(gpa, .limited(512 << 20)) catch {
            std.debug.print("synapse-index: unreadable stdin\n", .{});
            return 1;
        };

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            // Last tab, not first: a path may contain one, node filename follows it.
            const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
            if (tab == 0 or tab + 1 == line.len) continue;
            try pairs.append(gpa, .{ .path = line[0..tab], .node = line[tab + 1 ..] });
        }
    }

    // Absent is empty, not an error -- a namespace with every file claimed
    // has no unassigned list.
    var unassigned_text: []u8 = &.{};
    defer gpa.free(unassigned_text);
    if (unassigned_file) |uf| {
        unassigned_text = Io.Dir.cwd().readFileAlloc(io, uf, gpa, .limited(64 << 20)) catch {
            std.debug.print("synapse-index: cannot read --unassigned {s}\n", .{uf});
            return 1;
        };
    }

    var unassigned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unassigned.deinit(gpa);
    var un_lines = std.mem.splitScalar(u8, unassigned_text, '\n');
    while (un_lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        try unassigned.append(gpa, line);
    }

    const bytes = core.index_map.build(gpa, pairs.items, unassigned.items) catch |e| {
        std.debug.print("synapse-index: cannot build index ({t})\n", .{e});
        return 1;
    };
    defer gpa.free(bytes);

    core.index_map.writeFile(gpa, io, path, bytes) catch {
        std.debug.print("synapse-index: cannot write {s}\n", .{path});
        return 1;
    };

    var map = try Map.open(io, path); // reopen to report what a reader will actually find
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: wrote an index that will not read back ({t})\n", .{e});
        return 1;
    }

    try result.print("keys={d} unassigned={d} bytes={d}\n", .{
        map.count(),
        map.unassignedCount(),
        bytes.len,
    });
    return 0;
}

/// Every unclaimed path, one per line, in the order the index holds them.
/// Replaces `jq -r '._unassigned[]'` -- tens of megabytes must not reach a
/// context window.
fn listUnassigned(io: Io, path: []const u8, result: *Io.Writer) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var it = map.unassignedIter();
    while (it.next()) |p| try result.print("{s}\n", .{p});
    return 0;
}

/// Queue `newly` for the `_unassigned` sweep, if not already there. Exit 0
/// either way -- a hook's missing precondition is silence, and "already
/// queued" is the common case, not a fault. An unreadable index is exit 0
/// too: nothing to re-encode from.
fn addUnassigned(gpa: Allocator, io: Io, path: []const u8, newly: []const u8) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded != null) return 0;
    if (map.count() == 0 and map.unassignedCount() == 0 and map.map == null) return 0;

    const grown = core.index_map.withUnassigned(gpa, map.view, newly) catch |e| {
        std.debug.print("synapse-index: cannot re-encode index ({t})\n", .{e});
        return 1;
    } orelse return 0;
    defer gpa.free(grown);

    core.index_map.writeFile(gpa, io, path, grown) catch {
        std.debug.print("synapse-index: cannot write {s}\n", .{path});
        return 1;
    };
    return 0;
}

/// Every node that claims at least one path, one per line, ascending -- the
/// node table is already sorted by name.
fn listNodes(io: Io, path: []const u8, result: *Io.Writer) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var id: u32 = 0;
    while (id < map.nodeCount()) : (id += 1)
        try result.print("{s}\n", .{map.view.nodeName(id)});
    return 0;
}

/// `path<TAB>node.md` for every (list, path) pair, from `lists/NN.txt`.
/// Skips a list with no `NN.title` -- an unfinished build, not a node
/// claiming nothing. The `.md` extension is part of the value: the
/// staleness hook uses it directly as a vault path. Returns the pair count.
/// Ordering isn't this function's problem -- `index_map.build` groups and sorts.
fn pairsFromLists(
    gpa: Allocator,
    io: Io,
    lists_dir: []const u8,
    pairs: *std.ArrayListUnmanaged(core.index_map.Pair),
    owned: *std.ArrayListUnmanaged([]u8),
) !usize {
    var dir = Io.Dir.cwd().openDir(io, lists_dir, .{ .iterate = true }) catch {
        std.debug.print("synapse-index: cannot read --lists {s}\n", .{lists_dir});
        return 0;
    };
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - 4]));
    }
    // Sorted so a rebuild of the same lists produces the same bytes.
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var count: usize = 0;
    for (names.items) |nn| {
        const title_path = try std.fmt.allocPrint(gpa, "{s}/{s}.title", .{ lists_dir, nn });
        defer gpa.free(title_path);
        const title = Io.Dir.cwd().readFileAlloc(io, title_path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(title);

        // Same sanitisation the writer applies before using a title as a filename.
        const sanitised = try core.emit.fileTitle(gpa, std.mem.trimEnd(u8, title, "\n"));
        defer gpa.free(sanitised);
        const node = try std.fmt.allocPrint(gpa, "{s}.md", .{sanitised});
        try owned.append(gpa, node);

        const list_path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ lists_dir, nn });
        defer gpa.free(list_path);
        const list = Io.Dir.cwd().readFileAlloc(io, list_path, gpa, .limited(256 << 20)) catch continue;
        try owned.append(gpa, list);

        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r"); // a blank line is not a path
            if (line.len == 0) continue;
            try pairs.append(gpa, .{ .path = line, .node = node });
            count += 1;
        }
    }
    return count;
}

/// Every claimed path, one per line, in `LC_ALL=C` byte order -- the record
/// table is already in that order. Unlike the old `jq -r 'keys[]'`, this
/// never includes the literal `_unassigned` string as a claimed path.
fn listPaths(io: Io, path: []const u8, result: *Io.Writer) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var i: u32 = 0;
    while (i < map.count()) : (i += 1)
        try result.print("{s}\n", .{map.view.path(map.view.record(i))});
    return 0;
}

/// The nodes claiming `wanted`, one per line, ascending. Exit 1 with no
/// output when no node claims it -- covers both unassigned and never-enumerated.
fn lookup(io: Io, path: []const u8, wanted: []const u8, result: *Io.Writer) !u8 {
    var map = try Map.open(io, path);
    defer map.close(io);
    if (map.discarded) |e| {
        std.debug.print("synapse-index: unreadable index ({t}): {s}\n", .{ e, path });
        return 1;
    }

    var names: [core.index_map.max_nodes_per_path][]const u8 = undefined;
    const nodes = map.nodesFor(wanted, &names) orelse return 1;

    for (nodes) |n| try result.print("{s}\n", .{n});
    return 0;
}


/// `synapse build-index` -- `index build --lists` with every path derived
/// from the work dir. Its own subcommand rather than flags a caller
/// remembers, since the only caller (`/synapse-init` step 3) has no choices.
pub fn runBuildIndex(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse build-index\n", .{});
            return 0;
        }
        std.debug.print("usage: synapse build-index\n", .{});
        return 2;
    }

    var ctx = (try context.resolve(gpa, io, env, "synapse-build-index")) orelse return 1;
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    const code = try buildIndexAt(gpa, io, ctx.work_dir, &out.interface);
    try out.interface.flush();
    return code;
}

/// `index build --lists` with every path derived from `work_dir` -- split
/// out of `runBuildIndex` so a test can drive it against a real work dir
/// without a full `Context` resolution.
pub fn buildIndexAt(gpa: Allocator, io: Io, work_dir: []const u8, result: *Io.Writer) !u8 {
    const lists = try std.fmt.allocPrint(gpa, "{s}/lists", .{work_dir});
    defer gpa.free(lists);
    const unassigned = try std.fmt.allocPrint(gpa, "{s}/unassigned.txt", .{work_dir});
    defer gpa.free(unassigned);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/_index.bin", .{work_dir});
    defer gpa.free(out_path);

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, lists, .{})) |_| {} else |_| {
        std.debug.print("synapse-build-index: no lists/ in {s}\n", .{work_dir});
        return 1;
    }
    if (cwd.statFile(io, unassigned, .{})) |_| {} else |_| {
        std.debug.print("synapse-build-index: no unassigned.txt in {s}\n", .{work_dir});
        return 1;
    }

    try result.writeAll("_index.bin written: ");
    return buildIndex(gpa, io, out_path, unassigned, lists, result);
}

const testing = std.testing;

/// A real `work/lists/` + `work/unassigned.txt` in a real temp dir --
/// `buildIndexAt` reads both by path, same shape `synapse enumerate`/
/// `build-lists` produce.
const Fixture = struct {
    tmp: testing.TmpDir,
    gpa: Allocator,

    fn init(gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "work/lists");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/unassigned.txt", .data = "" });
        return .{ .tmp = tmp, .gpa = gpa };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn stageList(self: *Fixture, nn: []const u8, title: []const u8, paths: []const []const u8) !void {
        const title_path = try std.fmt.allocPrint(self.gpa, "work/lists/{s}.title", .{nn});
        defer self.gpa.free(title_path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = title_path, .data = title });

        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        for (paths) |p| try body.writer.print("{s}\n", .{p});
        const txt_path = try std.fmt.allocPrint(self.gpa, "work/lists/{s}.txt", .{nn});
        defer self.gpa.free(txt_path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_path, .data = body.written() });
    }

    fn writeRaw(self: *Fixture, sub: []const u8, data: []const u8) !void {
        const full = try std.fmt.allocPrint(self.gpa, "work/{s}", .{sub});
        defer self.gpa.free(full);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = full, .data = data });
    }

    fn workPath(self: *Fixture) ![]const u8 {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        return std.fmt.allocPrint(self.gpa, "{s}/work", .{root});
    }

    fn indexPath(self: *Fixture) ![]const u8 {
        const work = try self.workPath();
        defer self.gpa.free(work);
        return std.fmt.allocPrint(self.gpa, "{s}/_index.bin", .{work});
    }

    /// Runs `buildIndexAt` and returns its own output. Caller frees.
    fn build(self: *Fixture) !struct { code: u8, out: []u8 } {
        const work = try self.workPath();
        defer self.gpa.free(work);
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const code = try buildIndexAt(self.gpa, testing.io, work, &out.writer);
        return .{ .code = code, .out = try self.gpa.dupe(u8, out.written()) };
    }

    /// The nodes claiming one path, comma-joined -- `lookup`'s own output,
    /// read straight from `_index.bin`, not through the CLI.
    fn claimants(self: *Fixture, path: []const u8) ![]u8 {
        const index_path = try self.indexPath();
        defer self.gpa.free(index_path);
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        _ = lookup(testing.io, index_path, path, &out.writer) catch {};
        const joined = try self.gpa.dupe(u8, std.mem.trimEnd(u8, out.written(), "\n"));
        for (joined) |*c| if (c.* == '\n') {
            c.* = ',';
        };
        return joined;
    }

    fn unassignedPaths(self: *Fixture) ![]u8 {
        const index_path = try self.indexPath();
        defer self.gpa.free(index_path);
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        _ = try listUnassigned(testing.io, index_path, &out.writer);
        return self.gpa.dupe(u8, out.written());
    }

    fn lookupStatus(self: *Fixture, path: []const u8) !u8 {
        const index_path = try self.indexPath();
        defer self.gpa.free(index_path);
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        return lookup(testing.io, index_path, path, &out.writer);
    }
};

test "build-index: maps each path to its owning node, with the .md extension" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{ "mod-a/a.txt", "mod-a/b.txt" });
    try fx.stageList("02", "Docs", &.{"docs/d.md"});

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    // The hook and the read-time procedure use this value directly as a
    // vault path with no extension handling of their own.
    const a = try fx.claimants("mod-a/a.txt");
    defer gpa.free(a);
    try testing.expectEqualStrings("Mod A.md", a);
    const b = try fx.claimants("mod-a/b.txt");
    defer gpa.free(b);
    try testing.expectEqualStrings("Mod A.md", b);
    const d = try fx.claimants("docs/d.md");
    defer gpa.free(d);
    try testing.expectEqualStrings("Docs.md", d);
}

test "build-index: a file load-bearing for two concepts lists both nodes, sorted" {
    // Many-to-many is intentional in the design, not an oversight.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Zeta", &.{"shared/thing.java"});
    try fx.stageList("02", "Alpha", &.{"shared/thing.java"});

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    const claimed = try fx.claimants("shared/thing.java");
    defer gpa.free(claimed);
    try testing.expectEqualStrings("Alpha.md,Zeta.md", claimed);
}

test "build-index: the unassigned list carries what no node claimed, in the order given" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{"mod-a/a.txt"});
    try fx.writeRaw("unassigned.txt", "stray.txt\n.claude/settings.json\n");

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "unassigned=2") != null);

    const unassigned = try fx.unassignedPaths();
    defer gpa.free(unassigned);
    try testing.expectEqualStrings("stray.txt\n.claude/settings.json\n", unassigned);
}

test "build-index: an unassigned path is not also a claimed one" {
    // "Claimed by nobody" and "never enumerated" are different answers, and
    // the index has to keep them apart: the first is in the unassigned
    // list, the second is in neither place. `lookup` says nothing for both.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{"mod-a/a.txt"});
    try fx.writeRaw("unassigned.txt", "stray.txt\n");

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);

    try testing.expectEqual(@as(u8, 1), try fx.lookupStatus("stray.txt"));
    try testing.expectEqual(@as(u8, 1), try fx.lookupStatus("never/enumerated.txt"));
}

test "build-index: an empty unassigned.txt yields no entries, not one blank one" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{"mod-a/a.txt"});

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "unassigned=0") != null);
    const unassigned = try fx.unassignedPaths();
    defer gpa.free(unassigned);
    try testing.expectEqual(@as(usize, 0), unassigned.len);
}

test "build-index: node values are sanitized to the filenames that actually exist on disk" {
    // The value has to match the file the writer produced, which is the
    // sanitized title -- an unsanitized value would point the hook at a
    // nonexistent note.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Bad — import/export", &.{"mod-a/a.txt"});

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    const claimed = try fx.claimants("mod-a/a.txt");
    defer gpa.free(claimed);
    try testing.expectEqualStrings("Bad — import_export.md", claimed);
}

test "build-index: blank lines in a list do not become empty keys" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeRaw("lists/01.title", "Mod A\n");
    try fx.writeRaw("lists/01.txt", "mod-a/a.txt\n\nmod-a/b.txt\n\n");

    const r = try fx.build();
    defer gpa.free(r.out);
    // Two paths, and `keys` now counts only paths. The JSON index reported 3
    // here, because `_unassigned` was a sibling key of every path in the
    // same object and `jq 'keys | length'` counted it. It is a separate
    // region now, counted separately, so the honest number for two paths is 2.
    try testing.expect(std.mem.indexOf(u8, r.out, "keys=2") != null);
    try testing.expect(try fx.lookupStatus("") != 0);
}

test "build-index: a list with no matching .title file is skipped rather than keyed to '.md'" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{"mod-a/a.txt"});
    try fx.writeRaw("lists/99.txt", "orphan/path.txt\n");

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(u8, 1), try fx.lookupStatus("orphan/path.txt"));
}

test "build-index: reports key count and byte size so a truncated index is visible" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.stageList("01", "Mod A", &.{ "mod-a/a.txt", "mod-a/b.txt" });

    const r = try fx.build();
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "keys=2") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "bytes=") != null);
}

test "build-index: missing lists, missing unassigned.txt and an empty lists dir each exit 1" {
    // The three distinct error messages ("no (path, node) pairs", "no
    // unassigned.txt", "no lists/") all go to real stderr via
    // `std.debug.print`, not through `result` -- deliberately, the same
    // split every other command in this codebase draws between error
    // output and success output. Not capturable here, so only the exit
    // code is asserted; the message text stays bats' job if ever revisited.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    const empty = try fx.build();
    defer gpa.free(empty.out);
    try testing.expectEqual(@as(u8, 1), empty.code);

    try fx.stageList("01", "Mod A", &.{"mod-a/a.txt"});
    try fx.tmp.dir.deleteFile(testing.io, "work/unassigned.txt");
    const no_unassigned = try fx.build();
    defer gpa.free(no_unassigned.out);
    try testing.expectEqual(@as(u8, 1), no_unassigned.code);

    try fx.writeRaw("unassigned.txt", "");
    try fx.tmp.dir.deleteTree(testing.io, "work/lists");
    const no_lists = try fx.build();
    defer gpa.free(no_lists.out);
    try testing.expectEqual(@as(u8, 1), no_lists.code);
}
