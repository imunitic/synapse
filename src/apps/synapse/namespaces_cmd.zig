//! `synapse build-namespaces` -- writes `_namespaces.tsv`, one row per
//! tracked file mapped to its own declared namespace, from
//! `synapse-namespace-rules.conf`. More than one row per file when its
//! rule has aliases (`core.namespace.Rule.aliases`): some ecosystems give
//! one file more than one valid self-reference, and a dependent's own
//! declared dependency might use either.
//!
//!   build-namespaces [--repo <path>] [--out <path>]
//!
//! Distinct from `synapse vocab`'s own `namespaces.tsv`: that table
//! aggregates this same per-file fact to one row per *group* (the most
//! common declared namespace, how many agreed), a clustering signal. This
//! is the per-file fact itself, undigested -- `core/links.zig`'s
//! import-edge resolution needs to know which library a specific candidate
//! definition's file actually belongs to, not a group-level summary.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const adapters = @import("adapters");
const enumerate_cmd = @import("enumerate_cmd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-build-namespaces";

const usage_text =
    \\usage: synapse build-namespaces [--repo <path>] [--out <path>]
    \\
    \\  --repo   the checkout to scan. Default: the one containing $PWD.
    \\  --out    where to write the index. Default $SYNAPSE_WORK_DIR/_namespaces.tsv.
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var repo: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        const dest: *?[]const u8 =
            if (std.mem.eql(u8, arg, "--repo")) &repo
            else if (std.mem.eql(u8, arg, "--out")) &out_path
            else {
                std.debug.print("{s}", .{usage_text});
                return 2;
            };
        dest.* = args.next() orelse {
            std.debug.print("{s}", .{usage_text});
            return 2;
        };
    }

    const root = try repoRoot(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("{s}: not inside a git repo\n", .{prog});
        return 1;
    }

    return buildNamespaces(gpa, io, env, root, out_path);
}

/// The projection itself, minus argument parsing and root resolution --
/// separated so a test can drive it directly against a real fixture repo,
/// the same split `refs_cmd.zig`'s `runBuild`/`buildRefs` already uses.
pub fn buildNamespaces(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    root: []const u8,
    out_path_in: ?[]const u8,
) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const home = env.get("HOME") orelse return 1;
    const registry_path = if (env.get("SYNAPSE_NAMESPACE_RULES_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-namespace-rules.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-namespace-rules.conf", .{home});
    defer gpa.free(registry_path);
    var registry = core.namespace.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("{s}: cannot read the namespace-rules registry\n", .{prog});
        return 1;
    };
    defer registry.deinit();

    var out_path = out_path_in;
    var owned_out: ?[]u8 = null;
    defer if (owned_out) |p| gpa.free(p);
    if (out_path == null) {
        const resolved = (try context.workDirFor(gpa, io, env, root, prog)) orelse return 1;
        defer resolved.deinit(gpa);
        owned_out = try std.fmt.allocPrint(gpa, "{s}/_namespaces.tsv", .{resolved.path});
        out_path = owned_out.?;
    }

    const listed = try adapters.process.run(io, gpa, &.{ "git", "ls-files" }, .{
        .cwd = .{ .path = root },
    });
    defer listed.deinit(gpa);
    if (!listed.ok()) {
        std.debug.print("{s}: git ls-files failed in {s}\n", .{ prog, root });
        return 1;
    }
    const kept_text = try enumerate_cmd.applyUserPatterns(gpa, io, env, listed.stdout);
    defer if (kept_text.ptr != listed.stdout.ptr) gpa.free(kept_text);

    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, kept_text, '\n');
    while (lines.next()) |p| {
        if (p.len != 0) try kept.append(arena, p);
    }

    var rows = try core.namespace.computePerFile(gpa, arena, io, root, kept.items, registry);
    defer rows.deinit(gpa);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (rows.items) |r| try body.writer.print("{s}\t{s}\n", .{ r.path, r.namespace });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path.?, .data = body.written() });

    std.debug.print("{s}: {d} row(s) -> {s}\n", .{ prog, rows.items.len, out_path.? });
    return 0;
}

fn repoRoot(gpa: Allocator, io: Io, repo: ?[]const u8) ![]u8 {
    const res = adapters.process.run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" }, .{
        .cwd = if (repo) |r| .{ .path = r } else .inherit,
    }) catch return gpa.dupe(u8, "");
    defer res.deinit(gpa);
    if (!res.ok()) return gpa.dupe(u8, "");
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn writeNamespaceRules(fx: *fixture.Fixture, json: []const u8) !void {
    try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/synapse-namespace-rules.conf",
        .data = json,
    });
}

test "build-namespaces: a build-file rule maps every file under it to the nearest ancestor's declared name" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    try fx.writeRepoFile("widget/src/build.deps", "name widget\n");
    try fx.writeRepoFile("widget/src/main.xx", "run\n");
    try fx.gitCommit("init");

    try writeNamespaceRules(&fx,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "name "}}
    );

    const out = try std.fmt.allocPrint(gpa, "{s}/_namespaces.tsv", .{fx.work});
    defer gpa.free(out);
    const rc = try buildNamespaces(gpa, fx.io(), &fx.env, fx.repo, out);
    try testing.expectEqual(@as(u8, 0), rc);

    const content = try Io.Dir.cwd().readFileAlloc(fx.io(), out, gpa, .limited(1 << 20));
    defer gpa.free(content);
    try testing.expectEqualStrings("widget/src/main.xx\twidget\n", content);
}

test "build-namespaces: an empty registry writes an empty file, not an error" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    try fx.writeRepoFile("README.md", "hi\n");
    try fx.gitCommit("init");

    try writeNamespaceRules(&fx, "{}");

    const out = try std.fmt.allocPrint(gpa, "{s}/_namespaces.tsv", .{fx.work});
    defer gpa.free(out);
    const rc = try buildNamespaces(gpa, fx.io(), &fx.env, fx.repo, out);
    try testing.expectEqual(@as(u8, 0), rc);

    const content = try Io.Dir.cwd().readFileAlloc(fx.io(), out, gpa, .limited(1 << 20));
    defer gpa.free(content);
    try testing.expectEqualStrings("", content);
}
