//! `synapse comments-sweep` -- the on-demand, whole-repo counterpart to
//! `comments-check`: the third sibling to `/synapse-rebuild-diff` (code-graph
//! drift) and `/synapse-vault-tidy` (vault-note health), for revisiting
//! docstrings nothing else has touched lately. Enumerates the same
//! `all.txt` `enumerate`/`build-lists` already maintain, then runs
//! `docstring_check.checkFile` (the identical Tier 2 logic `comments-check`
//! uses) over every tracked path, so a sweep and a single-file check can
//! never disagree on what "checking a file" means.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");
const docstring_check = @import("docstring_check.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-comments-sweep";

const usage_text =
    \\usage: synapse comments-sweep [--reenumerate]
    \\
    \\  Checks every tracked file's docstrings against the docstring index,
    \\  refreshing it with what a fresh parse finds -- the whole-repo sweep
    \\  counterpart to `comments-check <path>`. Requires
    \\  SYNAPSE_DOCSTRING_STALENESS_DETECTION (see synapse.conf) -- a no-op
    \\  otherwise.
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var reenumerate = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--reenumerate")) {
            reenumerate = true;
        } else {
            std.debug.print("{s}", .{usage_text});
            return 2;
        }
    }

    var out_buf: [256 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try sweep(gpa, io, env, ".", reenumerate, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture repo, matching `enumerate_cmd.runEnumerate`/
/// `build_lists_cmd.build`'s own split.
pub fn sweep(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    identity_path: []const u8,
    reenumerate: bool,
    out: *Io.Writer,
) !u8 {
    const id = core.identity.resolve(gpa, io, identity_path) catch |e| {
        switch (e) {
            error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
            error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
            else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
        }
        return 1;
    };
    defer id.deinit(gpa);
    const repo_root = id.layout.repo_root;

    const wd = (try context.workDirFor(gpa, io, env, identity_path, prog)) orelse {
        std.debug.print("{s}: could not resolve a work directory\n", .{prog});
        return 1;
    };
    defer wd.deinit(gpa);

    try enumerate_cmd.ensure(gpa, io, env, repo_root, wd.path, reenumerate, out);

    const all_path = try std.fmt.allocPrint(gpa, "{s}/all.txt", .{wd.path});
    defer gpa.free(all_path);
    const all = try Io.Dir.cwd().readFileAlloc(io, all_path, gpa, context.maxListingBytes(env, 256 << 20));
    defer gpa.free(all);

    var files: usize = 0;
    var changed: usize = 0;
    var evicted: usize = 0;
    var lines = std.mem.splitScalar(u8, all, '\n');
    while (lines.next()) |rel_path| {
        if (rel_path.len == 0) continue;
        const result = try docstring_check.checkFile(gpa, io, env, repo_root, wd.path, rel_path);
        defer if (result.report) |r| gpa.free(r);
        files += 1;
        changed += result.updated;
        evicted += result.evicted;
        if (result.report) |r| {
            try out.print("-- {s} --\n", .{rel_path});
            try out.writeAll(r);
            try out.writeAll("\n\n");
        }
    }

    try out.print("comments-sweep: {d} files checked, {d} changed, {d} evicted\n", .{ files, changed, evicted });
    return 0;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

const fake_parser_c = @embedFile("testdata/fake_docstrings_grammar/src/parser.c");
const fake_node_types_json = @embedFile("testdata/fake_docstrings_grammar/src/node-types.json");
const fake_parser_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/parser.h");
const fake_alloc_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/alloc.h");
const fake_array_h = @embedFile("testdata/fake_docstrings_grammar/src/tree_sitter/array.h");

fn setupFakeGrammar(fx: *fixture.Fixture) !void {
    const gpa = fx.gpa;
    const grammars_dir = try std.fmt.allocPrint(gpa, "{s}/grammars", .{fx.root});
    defer gpa.free(grammars_dir);
    try fx.tmp.dir.createDirPath(fx.io(), "grammars");
    try fx.env.put("SYNAPSE_GRAMMARS_DIR", grammars_dir);

    const repo_sub = "grammars/repos/fake-docstrings";
    try fx.tmp.dir.createDirPath(fx.io(), repo_sub ++ "/src/tree_sitter");
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/parser.c", .data = fake_parser_c });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/node-types.json", .data = fake_node_types_json });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/parser.h", .data = fake_parser_h });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/alloc.h", .data = fake_alloc_h });
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = repo_sub ++ "/src/tree_sitter/array.h", .data = fake_array_h });

    const registry_json =
        \\{"fakedoc": {"repo": "https://example.com/fake-docstrings.git", "scope": "source.fake_docstrings", "symbol": "tree_sitter_fake_docstrings"}}
    ;
    try fx.tmp.dir.writeFile(fx.io(), .{ .sub_path = "home/.claude/synapse-grammars.conf", .data = registry_json });

    try fx.env.put("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
}

test "sweep: checks every tracked file, reports the changed one, and totals correctly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);

    try fx.writeRepoFile("a.fakedoc", "// does a thing\nfn foo()\n");
    try fx.writeRepoFile("b.fakedoc", "no comments here at all\n");
    try fx.gitCommit("fixtures");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try sweep(gpa, fx.io(), &fx.env, fx.repo, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "-- a.fakedoc --") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-- b.fakedoc --") == null);
    try testing.expect(std.mem.indexOf(u8, text, "comments-sweep: 2 files checked, 1 changed, 0 evicted") != null);
}

test "sweep: disabled by default is a silent no-op sweep" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try setupFakeGrammar(&fx);
    _ = fx.env.swapRemove("SYNAPSE_DOCSTRING_STALENESS_DETECTION");

    try fx.writeRepoFile("a.fakedoc", "// does a thing\nfn foo()\n");
    try fx.gitCommit("fixture");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try sweep(gpa, fx.io(), &fx.env, fx.repo, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "-- a.fakedoc --") == null);
    try testing.expect(std.mem.indexOf(u8, text, "comments-sweep: 1 files checked, 0 changed, 0 evicted") != null);
}
