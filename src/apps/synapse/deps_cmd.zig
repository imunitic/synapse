//! `synapse build-deps` -- writes `_deps.tsv`, `core/deps.zig`'s per-file
//! declared-dependency artifact, from `synapse-dependency-rules.conf`.
//!
//!   build-deps [--repo <path>] [--out <path>]
//!
//! Its own enumeration pass, the same "every tracked path, minus the user's
//! own exclusions" shape `synapse vocab` already uses -- this artifact isn't
//! derived from the tags cache the way `_refs.tsv` is, since a dependency
//! declaration lives in ordinary source/build files any grammar-less file
//! can carry, not in tagged code.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const adapters = @import("adapters");
const enumerate_cmd = @import("enumerate_cmd.zig");
const cli_args = @import("cli_args.zig");
const repo_root = @import("repo_root.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-build-deps";

const usage_text =
    \\usage: synapse build-deps [--repo <path>] [--out <path>]
    \\
    \\  --repo   the checkout to scan. Default: the one containing $PWD.
    \\  --out    where to write the index. Default $SYNAPSE_WORK_DIR/_deps.tsv.
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
        dest.* = cli_args.takenValue(args.next()) orelse {
            std.debug.print("{s}", .{usage_text});
            return 2;
        };
    }

    const root = try repo_root.resolve(gpa, io, repo);
    defer gpa.free(root);
    if (root.len == 0) {
        std.debug.print("{s}: not inside a git repo\n", .{prog});
        return 1;
    }

    return buildDeps(gpa, io, env, root, out_path);
}

/// The projection itself, minus argument parsing and root resolution --
/// separated so a test can drive it directly against a real fixture repo,
/// the same split `refs_cmd.zig`'s `runBuild`/`buildRefs` already uses.
pub fn buildDeps(
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
    const registry_path = if (env.get("SYNAPSE_DEPENDENCY_RULES_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-dependency-rules.conf")) |p|
        p
    else
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-dependency-rules.conf", .{home});
    defer gpa.free(registry_path);
    var registry = core.namespace.Registry.load(gpa, io, registry_path) catch {
        std.debug.print("{s}: cannot read the dependency-rules registry\n", .{prog});
        return 1;
    };
    defer registry.deinit();

    var out_path = out_path_in;
    var owned_out: ?[]u8 = null;
    defer if (owned_out) |p| gpa.free(p);
    if (out_path == null) {
        const resolved = (try context.workDirFor(gpa, io, env, root, prog)) orelse return 1;
        defer resolved.deinit(gpa);
        owned_out = try std.fmt.allocPrint(gpa, "{s}/_deps.tsv", .{resolved.path});
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

    var rows = try core.deps.compute(gpa, arena, io, root, kept.items, registry);
    defer rows.deinit(gpa);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    for (rows.items) |r| try core.deps.writeRow(&body.writer, r);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path.?, .data = body.written() });

    std.debug.print("{s}: {d} edge(s) -> {s}\n", .{ prog, rows.items.len, out_path.? });
    return 0;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn writeDependencyRules(fx: *fixture.Fixture, json: []const u8) !void {
    try fx.tmp.dir.createDirPath(testing.io, "home/.claude");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "home/.claude/synapse-dependency-rules.conf",
        .data = json,
    });
}

test "build-deps: a build-file rule produces edges from the nearest ancestor's declared list" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    try fx.writeRepoFile("widget/src/build.deps", "name widget\ndepends gadget str\n");
    try fx.writeRepoFile("widget/src/main.xx", "run\n");
    try fx.gitCommit("init");

    try writeDependencyRules(&fx,
        \\{"xx": {"kind": "build-file", "file": "build.deps", "prefix": "depends "}}
    );

    const out = try std.fmt.allocPrint(gpa, "{s}/_deps.tsv", .{fx.work});
    defer gpa.free(out);
    const rc = try buildDeps(gpa, fx.io(), &fx.env, fx.repo, out);
    try testing.expectEqual(@as(u8, 0), rc);

    const content = try Io.Dir.cwd().readFileAlloc(fx.io(), out, gpa, .limited(1 << 20));
    defer gpa.free(content);
    try testing.expectEqualStrings("widget/src/main.xx\tgadget\nwidget/src/main.xx\tstr\n", content);
}

test "build-deps: an empty registry writes an empty file, not an error" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();

    try fx.writeRepoFile("README.md", "hi\n");
    try fx.gitCommit("init");

    try writeDependencyRules(&fx, "{}");

    const out = try std.fmt.allocPrint(gpa, "{s}/_deps.tsv", .{fx.work});
    defer gpa.free(out);
    const rc = try buildDeps(gpa, fx.io(), &fx.env, fx.repo, out);
    try testing.expectEqual(@as(u8, 0), rc);

    const content = try Io.Dir.cwd().readFileAlloc(fx.io(), out, gpa, .limited(1 << 20));
    defer gpa.free(content);
    try testing.expectEqualStrings("", content);
}
