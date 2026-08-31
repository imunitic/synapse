//! `synapse link-graph` -- the node-to-node link graph, computed before any
//! prose is written. Rule in `core/links.zig`; this is
//! the file-in/file-out wrapper.
//!
//!   link-graph --refs <_refs.tsv> --lists <dir> [--deps <f>] [--namespaces <f>] [--top N] [--out <dir>]
//!
//! Distinct from `synapse query links "{Node}"`, which traverses a node's
//! already-written `## Links`; this computes candidates before any node
//! exists, from `_refs.tsv` and the cluster path lists alone. Needs no
//! vault or git: every input is a file `build-refs`/`build-lists` produced.
//!
//! `--deps`/`--namespaces` (`synapse build-deps`/`build-namespaces`'s own
//! output) enable `core.links.resolveAmbiguous` -- optional, and silently
//! skipped, not an error, when either file is missing: this is a strictly
//! additive enhancement over `compute`'s own always-on join, never a
//! requirement to get ordinary link candidates.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-link-graph";

const usage_text =
    \\usage: synapse link-graph --refs <_refs.tsv> --lists <dir> [--deps <f>] [--namespaces <f>]
    \\                          [--top N] [--out <dir>]
    \\
    \\  --refs        synapse build-refs's index. Default $SYNAPSE_WORK_DIR/_refs.tsv.
    \\  --lists       the NN.txt/NN.title path lists synapse build-lists wrote.
    \\  --deps        synapse build-deps's index. Default $SYNAPSE_WORK_DIR/_deps.tsv,
    \\                skipped silently if absent.
    \\  --namespaces  synapse build-namespaces's index. Default
    \\                $SYNAPSE_WORK_DIR/_namespaces.tsv, skipped silently if absent.
    \\  --top         edges kept per node, strongest first, default 8. 0 means no cap.
    \\  --out         where to write links.tsv. Default $SYNAPSE_WORK_DIR.
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
    var refs_path: ?[]const u8 = null;
    var lists_dir: ?[]const u8 = null;
    var deps_path: ?[]const u8 = null;
    var namespaces_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var top: usize = 8;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--refs")) {
            refs_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--lists")) {
            lists_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--deps")) {
            deps_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--namespaces")) {
            namespaces_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--top")) {
            const text = args.next() orelse return usage();
            top = std.fmt.parseInt(usize, text, 10) catch return usage();
        } else return usage();
    }
    const lists = lists_dir orelse return usage();
    return write(gpa, io, env, refs_path, lists, deps_path, namespaces_path, out_dir, top);
}

/// The rule itself, minus argument parsing -- separated so a test can drive
/// it against real files without going through the CLI. `refs_path`/
/// `out_dir` still resolve against `$SYNAPSE_WORK_DIR` when null, same as
/// `run()`'s own default, so a test can exercise that path too by setting
/// the env var directly instead of passing `--refs`/`--out`. `deps_path`/
/// `namespaces_path` resolve the same way, but a missing file at the
/// resolved path is not an error -- `resolveAmbiguous` is simply skipped.
pub fn write(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    refs_path_in: ?[]const u8,
    lists: []const u8,
    deps_path_in: ?[]const u8,
    namespaces_path_in: ?[]const u8,
    out_dir_in: ?[]const u8,
    top: usize,
) !u8 {
    var refs_path = refs_path_in;
    var deps_path = deps_path_in;
    var namespaces_path = namespaces_path_in;
    var out_dir = out_dir_in;

    const cwd = Io.Dir.cwd();
    cwd.access(io, lists, .{}) catch {
        std.debug.print("{s}: no such lists dir: {s}\n", .{ prog, lists });
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Work dir supplies whichever of --refs/--out is missing (as build-refs
    // does for --cache/--out); resolved only if needed -- required, so a
    // failure to resolve is an error. Kept alive for the rest of the
    // function since the resolved paths borrow its `path`.
    var derived: ?context.WorkDir = null;
    defer if (derived) |d| d.deinit(gpa);
    if (refs_path == null or out_dir == null) {
        derived = (try context.workDir(gpa, io, env, prog)) orelse return 1;
        if (refs_path == null) {
            refs_path = try std.fmt.allocPrint(arena, "{s}/_refs.tsv", .{derived.?.path});
        }
        if (out_dir == null) out_dir = derived.?.path;
    }
    // --deps/--namespaces default from the *same* work dir, but only when
    // one was already resolved above -- optional, so a caller who passed
    // explicit --refs/--out (no work dir needed at all) never pays for a
    // git-identity resolution, or its stderr noise, just to learn these two
    // files don't exist. Left null here, `resolveAmbiguous` is skipped.
    if (derived) |d| {
        if (deps_path == null) {
            deps_path = try std.fmt.allocPrint(arena, "{s}/_deps.tsv", .{d.path});
        }
        if (namespaces_path == null) {
            namespaces_path = try std.fmt.allocPrint(arena, "{s}/_namespaces.tsv", .{d.path});
        }
    }

    // Killed the 1 GiB read cap: the refs index is mapped, not read whole —
    // `compute`/`resolveAmbiguous` both take it as a `[]const u8`, so they
    // don't care whether it came from a mapping or an allocation. `refs_index`
    // must outlive `edges`, whose `symbols` borrow its bytes.
    var refs_index = core.refs.Index.open(io, gpa, refs_path.?) catch {
        std.debug.print(
            "{s}: no reference index at {s} -- run `synapse build-refs`\n",
            .{ prog, refs_path.? },
        );
        return 1;
    };
    defer refs_index.deinit(io, gpa);
    const refs_table = refs_index.bytes;

    var path_to_nodes: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    const node_count = try readLists(arena, io, lists, &path_to_nodes);
    if (node_count == 0) {
        std.debug.print("{s}: no NN.txt/NN.title pairs in {s}\n", .{ prog, lists });
        return 1;
    }

    var edges = try core.links.compute(gpa, refs_table, &path_to_nodes, node_count, .{ .top = top });
    defer core.links.free(gpa, &edges);

    var resolved_ambiguous: usize = 0;
    resolve_ambiguous: {
        const dp = deps_path orelse break :resolve_ambiguous;
        const nsp = namespaces_path orelse break :resolve_ambiguous;
        var deps_index = core.refs.Index.open(io, gpa, dp) catch break :resolve_ambiguous;
        defer deps_index.deinit(io, gpa);
        var namespaces_index = core.refs.Index.open(io, gpa, nsp) catch break :resolve_ambiguous;
        defer namespaces_index.deinit(io, gpa);

        var path_to_deps = try readPathSets(arena, deps_index.bytes);
        var path_to_namespace = try readPathSets(arena, namespaces_index.bytes);
        var extra = try core.links.resolveAmbiguous(gpa, refs_table, &path_to_nodes, &path_to_namespace, &path_to_deps, .{ .top = top });
        resolved_ambiguous = extra.items.len;
        try core.links.mergeEdges(gpa, &edges, &extra, top);
    }

    cwd.createDirPath(io, out_dir.?) catch {
        std.debug.print("{s}: cannot write {s}\n", .{ prog, out_dir.? });
        return 1;
    };
    const out_path = try std.fmt.allocPrint(gpa, "{s}/links.tsv", .{out_dir.?});
    defer gpa.free(out_path);
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (edges.items) |e| try core.links.writeEdge(&body.writer, e);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = body.written() });

    var nodes_covered: std.StringHashMapUnmanaged(void) = .empty;
    for (edges.items) |e| try nodes_covered.put(arena, e.from, {});

    std.debug.print(
        "{s}: {d} nodes, {d} edges ({d} via import-edge resolution), {d} nodes with at least one -> {s}\n",
        .{ prog, node_count, edges.items.len, resolved_ambiguous, nodes_covered.count(), out_path },
    );
    return 0;
}

/// `path <TAB> library` rows (`core.deps.Row`'s own shape) folded into
/// `path -> {library, ...}`, the set `resolveAmbiguous` checks a
/// referencing file's dependencies against.
/// `path <TAB> value` rows folded into `path -> {value, ...}` -- the shape
/// both `_deps.tsv` (a file's own declared dependencies) and
/// `_namespaces.tsv` (a file's own declared identities, more than one when
/// its rule has aliases) share, so one reader serves both.
fn readPathSets(arena: Allocator, table: []const u8) !std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) {
    var out: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const path = it.next() orelse continue;
        const value = it.next() orelse continue;
        const gop = try out.getOrPut(arena, path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.put(arena, value, {});
    }
    return out;
}

/// Same `NN.txt`/`NN.title` reading as `vocab_cmd.zig`'s `mapFromLists`,
/// minus the `counts.tsv` side table. Returns 0 if the dir was empty or
/// malformed -- the caller treats that as an error.
fn readLists(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    out: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) !usize {
    const cwd = Io.Dir.cwd();
    var titles: std.StringHashMapUnmanaged(void) = .empty;
    var n: usize = 1;
    while (n <= 99) : (n += 1) {
        const txt_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.txt", .{ dir, n });
        const title_path = try std.fmt.allocPrint(arena, "{s}/{d:0>2}.title", .{ dir, n });
        const title_raw = cwd.readFileAlloc(io, title_path, arena, .limited(64 << 10)) catch continue;
        const title = std.mem.trim(u8, firstLine(title_raw), " \t\r");
        if (title.len == 0) continue;
        const body = cwd.readFileAlloc(io, txt_path, arena, .limited(64 << 20)) catch continue;

        try titles.put(arena, title, {});
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const p = std.mem.trimEnd(u8, raw, "\r");
            if (p.len == 0) continue;
            const gop = try out.getOrPut(arena, p);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, title);
        }
    }
    return titles.count();
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

const testing = std.testing;

/// A real `_refs.tsv` and `lists/` dir in a real temp dir -- `write()`
/// reads both by path, same shape `synapse build-refs`/`build-lists`
/// produce.
const Fixture = struct {
    tmp: testing.TmpDir,
    refs: Io.Writer.Allocating,
    gpa: Allocator,

    fn init(gpa: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "lists");
        try tmp.dir.createDirPath(testing.io, "out");
        return .{ .tmp = tmp, .refs = .init(gpa), .gpa = gpa };
    }

    fn deinit(self: *Fixture) void {
        self.refs.deinit();
        self.tmp.cleanup();
    }

    /// One `_refs.tsv` row: `name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expr`.
    fn refline(
        self: *Fixture,
        name: []const u8,
        role: []const u8,
        kind: []const u8,
        path: []const u8,
        line: u32,
        expr: []const u8,
    ) !void {
        try self.refs.writer.print("{s}\t{s}\t{s}\t{s}:{d}\t{s}\n", .{ name, role, kind, path, line, expr });
    }

    /// A `synapse build-lists`-shaped `lists/` entry: `NN.txt` (one path per
    /// line) and `NN.title`.
    fn writeList(self: *Fixture, nn: []const u8, title: []const u8, paths: []const []const u8) !void {
        const title_path = try std.fmt.allocPrint(self.gpa, "lists/{s}.title", .{nn});
        defer self.gpa.free(title_path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = title_path, .data = title });

        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        for (paths) |p| try body.writer.print("{s}\n", .{p});
        const txt_path = try std.fmt.allocPrint(self.gpa, "lists/{s}.txt", .{nn});
        defer self.gpa.free(txt_path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = txt_path, .data = body.written() });
    }

    fn absPath(self: *Fixture, rel: []const u8) ![]const u8 {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ root, rel });
    }

    /// Writes `_refs.tsv` (everything accumulated via `refline` so far) and
    /// calls `write()` with `--refs`/`--lists`/`--out` all explicit --
    /// `context.workDir` is never reached. Caller frees `.out`.
    fn run(self: *Fixture, top: usize) !struct { code: u8, out: []const u8 } {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "_refs.tsv", .data = self.refs.written() });
        const refs_path = try self.absPath("_refs.tsv");
        defer self.gpa.free(refs_path);
        const lists_path = try self.absPath("lists");
        defer self.gpa.free(lists_path);
        const out_path = try self.absPath("out");
        defer self.gpa.free(out_path);

        var env = std.process.Environ.Map.init(self.gpa);
        defer env.deinit();
        const code = try write(self.gpa, testing.io, &env, refs_path, lists_path, null, null, out_path, top);

        const links_path = try std.fmt.allocPrint(self.gpa, "out/links.tsv", .{});
        defer self.gpa.free(links_path);
        const out = self.tmp.dir.readFileAlloc(testing.io, links_path, self.gpa, .limited(1 << 20)) catch "";
        return .{ .code = code, .out = out };
    }
};

test "a ref in one node to a def in another is an edge, weighted and evidenced" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{"a/Widget.java"});
    try fx.writeList("02", "B", &.{"b/Gadget.java"});
    try fx.refline("Helper", "def", "class", "b/Gadget.java", 1, "class Helper {");
    try fx.refline("Helper", "ref", "call", "a/Widget.java", 5, "Helper.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("A\tB\t1\tHelper\n", r.out);
}

test "a ref and its def in the same node produce no edge" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{ "a/One.java", "a/Two.java" });
    try fx.refline("Local", "def", "class", "a/One.java", 1, "class Local {");
    try fx.refline("Local", "ref", "call", "a/Two.java", 2, "Local.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "a symbol referenced from too many nodes is filtered out, not just down-weighted" {
    // rare_max = max(2, 4/20) = 2. Three referencing nodes exceeds it.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "D", &.{"d/Def.java"});
    try fx.writeList("02", "A", &.{"a/A.java"});
    try fx.writeList("03", "B", &.{"b/B.java"});
    try fx.writeList("04", "C", &.{"c/C.java"});
    try fx.refline("Common", "def", "class", "d/Def.java", 1, "class Common {");
    try fx.refline("Common", "ref", "call", "a/A.java", 1, "Common.run();");
    try fx.refline("Common", "ref", "call", "b/B.java", 1, "Common.run();");
    try fx.refline("Common", "ref", "call", "c/C.java", 1, "Common.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "weight is distinct rare symbols, so two calls to the same one still weigh one" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "B", &.{"b/B.java"});
    try fx.writeList("02", "A", &.{"a/A.java"});
    try fx.refline("Widget", "def", "class", "b/B.java", 1, "class Widget {");
    try fx.refline("Widget", "ref", "call", "a/A.java", 3, "Widget.run();");
    try fx.refline("Widget", "ref", "call", "a/A.java", 9, "Widget.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expect(std.mem.indexOf(u8, r.out, "\t1\t") != null);
}

test "--top caps edges kept per node, strongest first" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{"a/A.java"});
    try fx.writeList("02", "B", &.{"b/B.java"});
    try fx.writeList("03", "C", &.{"c/C.java"});
    try fx.writeList("04", "D", &.{"d/D.java"});
    try fx.refline("X", "def", "class", "b/B.java", 1, "class X {");
    try fx.refline("X", "ref", "call", "a/A.java", 1, "X.run();");
    try fx.refline("Y", "def", "class", "c/C.java", 1, "class Y {");
    try fx.refline("Y", "ref", "call", "a/A.java", 2, "Y.run();");
    try fx.refline("Z", "def", "class", "d/D.java", 1, "class Z {");
    try fx.refline("Z", "ref", "call", "a/A.java", 3, "Z.run();");

    const capped = try fx.run(2);
    defer gpa.free(capped.out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, capped.out, "\n"));

    const uncapped = try fx.run(0);
    defer gpa.free(uncapped.out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, uncapped.out, "\n"));
}

test "a path claimed by two nodes fans out an edge from each" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "B", &.{"b/B.java"});
    try fx.writeList("02", "A", &.{"a/A.java"});
    try fx.writeList("03", "C", &.{"a/A.java"});
    try fx.refline("Alpha", "def", "class", "b/B.java", 1, "class Alpha {");
    try fx.refline("Alpha", "ref", "call", "a/A.java", 1, "Alpha.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "A\t"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.out, "C\t"));
}

test "a missing --lists dir is an error, not a silent empty result" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const code = try write(gpa, testing.io, &env, "/nonexistent/_refs.tsv", "/nonexistent/lists", null, null, "/nonexistent/out", 8);
    try testing.expectEqual(@as(u8, 1), code);
}

test "an empty --lists dir is an error, pointing at what to run" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    // lists/ exists (created by Fixture.init) but is empty.

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
}

test "a missing _refs.tsv points at build-refs rather than failing opaquely" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{"a/A.java"});
    const lists_path = try fx.absPath("lists");
    defer gpa.free(lists_path);
    const out_path = try fx.absPath("out");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try write(gpa, testing.io, &env, "/nonexistent/nope.tsv", lists_path, null, null, out_path, 8);
    try testing.expectEqual(@as(u8, 1), code);
}

test "an empty refs table and a real lists dir produce an empty, present links.tsv" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{"a/A.java"});
    try fx.writeList("02", "B", &.{"b/B.java"});

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}

test "defaults to SYNAPSE_WORK_DIR when --refs/--out are omitted" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeList("01", "A", &.{"a/A.java"});
    try fx.writeList("02", "B", &.{"b/B.java"});
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "_refs.tsv", .data = fx.refs.written() });

    const work_path = try fx.absPath(".");
    defer gpa.free(work_path);
    const lists_path = try fx.absPath("lists");
    defer gpa.free(lists_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("SYNAPSE_WORK_DIR", work_path);

    const code = try write(gpa, testing.io, &env, null, lists_path, null, null, null, 8);
    try testing.expectEqual(@as(u8, 0), code);
    const links = try fx.tmp.dir.readFileAlloc(testing.io, "links.tsv", gpa, .limited(1 << 20));
    defer gpa.free(links);
}

test "--deps/--namespaces recover an edge compute() alone would have dropped" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    // `Shared` is defined in both B and C -- ambiguous, compute() drops it
    // entirely. A's own file declares a dependency on B's library only.
    try fx.writeList("01", "A", &.{"a/A.ext"});
    try fx.writeList("02", "B", &.{"b/B.ext"});
    try fx.writeList("03", "C", &.{"c/C.ext"});
    try fx.refline("Shared", "def", "class", "b/B.ext", 1, "class Shared {");
    try fx.refline("Shared", "def", "class", "c/C.ext", 1, "class Shared {");
    try fx.refline("Shared", "ref", "call", "a/A.ext", 5, "Shared.run();");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "_refs.tsv", .data = fx.refs.written() });
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "_deps.tsv",
        .data = "a/A.ext\tlib_b\n",
    });
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "_namespaces.tsv",
        .data = "b/B.ext\tlib_b\nc/C.ext\tlib_c\n",
    });

    const refs_path = try fx.absPath("_refs.tsv");
    defer gpa.free(refs_path);
    const lists_path = try fx.absPath("lists");
    defer gpa.free(lists_path);
    const deps_path = try fx.absPath("_deps.tsv");
    defer gpa.free(deps_path);
    const namespaces_path = try fx.absPath("_namespaces.tsv");
    defer gpa.free(namespaces_path);
    const out_path = try fx.absPath("out");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try write(gpa, testing.io, &env, refs_path, lists_path, deps_path, namespaces_path, out_path, 8);
    try testing.expectEqual(@as(u8, 0), code);

    const links = try fx.tmp.dir.readFileAlloc(testing.io, "out/links.tsv", gpa, .limited(1 << 20));
    defer gpa.free(links);
    try testing.expectEqualStrings("A\tB\t1\tShared\n", links);
}

test "--deps/--namespaces: a second identity row for the same file (an alias) still resolves" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    // B's file is known under two identities in _namespaces.tsv (its rule's
    // primary value plus one alias) -- A's declared dependency matches only
    // the alias.
    try fx.writeList("01", "A", &.{"a/A.ext"});
    try fx.writeList("02", "B", &.{"b/B.ext"});
    try fx.writeList("03", "C", &.{"c/C.ext"});
    try fx.refline("Shared", "def", "class", "b/B.ext", 1, "class Shared {");
    try fx.refline("Shared", "def", "class", "c/C.ext", 1, "class Shared {");
    try fx.refline("Shared", "ref", "call", "a/A.ext", 5, "Shared.run();");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "_refs.tsv", .data = fx.refs.written() });
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "_deps.tsv",
        .data = "a/A.ext\tlib_b_pub\n",
    });
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "_namespaces.tsv",
        .data = "b/B.ext\tlib_b\nb/B.ext\tlib_b_pub\nc/C.ext\tlib_c\n",
    });

    const refs_path = try fx.absPath("_refs.tsv");
    defer gpa.free(refs_path);
    const lists_path = try fx.absPath("lists");
    defer gpa.free(lists_path);
    const deps_path = try fx.absPath("_deps.tsv");
    defer gpa.free(deps_path);
    const namespaces_path = try fx.absPath("_namespaces.tsv");
    defer gpa.free(namespaces_path);
    const out_path = try fx.absPath("out");
    defer gpa.free(out_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const code = try write(gpa, testing.io, &env, refs_path, lists_path, deps_path, namespaces_path, out_path, 8);
    try testing.expectEqual(@as(u8, 0), code);

    const links = try fx.tmp.dir.readFileAlloc(testing.io, "out/links.tsv", gpa, .limited(1 << 20));
    defer gpa.free(links);
    try testing.expectEqualStrings("A\tB\t1\tShared\n", links);
}

test "--deps/--namespaces absent leaves compute()'s own ambiguous-name drop unchanged" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    try fx.writeList("01", "A", &.{"a/A.ext"});
    try fx.writeList("02", "B", &.{"b/B.ext"});
    try fx.writeList("03", "C", &.{"c/C.ext"});
    try fx.refline("Shared", "def", "class", "b/B.ext", 1, "class Shared {");
    try fx.refline("Shared", "def", "class", "c/C.ext", 1, "class Shared {");
    try fx.refline("Shared", "ref", "call", "a/A.ext", 5, "Shared.run();");

    const r = try fx.run(8);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(usize, 0), r.out.len);
}
