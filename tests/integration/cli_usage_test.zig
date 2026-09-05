//! CLI-layer usage-error checks for commands whose actual logic is fully
//! covered natively -- these assert only the bare argv-parsing/exit-code
//! contract, spawning `synapse-fake` (the grammar-stub build) rather than
//! the real `synapse`, since grammar compilation itself is irrelevant here.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;

test "brief: usage and environment errors" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();

    const r1 = try fx.runFake(&.{"brief"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try fx.runFake(&.{ "brief", "--nope" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());
}

test "build-refs: --help is exit 0, a bad flag is exit 2" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();

    const r1 = try fx.runFake(&.{ "build-refs", "--help" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());

    const r2 = try fx.runFake(&.{ "build-refs", "--nonsense" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());
}

test "doctor: --help works outside a repo and with no environment at all" {
    // A fully empty environment except PATH, which `adapters.process.run`'s
    // ambient `Io` environ can't express (it always carries the fixture's
    // full env) -- needs its own scoped `Io.Threaded` built with a minimal
    // PATH-only environ, same pattern `adapters/process.zig`'s own
    // PATH-resolution test uses.
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();

    const gpa = testing.allocator;
    var real_env = try std.process.Environ.createMap(testing.environ, gpa);
    defer real_env.deinit();
    const real_path = real_env.get("PATH") orelse "/usr/bin:/bin";
    const entry = try std.fmt.allocPrintSentinel(gpa, "PATH={s}", .{real_path}, 0);
    defer gpa.free(entry);
    const envp = try gpa.allocSentinel(?[*:0]u8, 1, null);
    defer gpa.free(envp);
    envp[0] = entry.ptr;

    var scoped: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = .{ .slice = envp } } });
    defer scoped.deinit();

    const r = try adapters.process.run(scoped.io(), gpa, &.{ fx.synapse_bin, "doctor", "--help" }, .{ .cwd = .{ .path = fx.root } });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "usage: synapse doctor") != null or
        std.mem.indexOf(u8, r.stderr, "usage: synapse doctor") != null);
}

test "gate: usage errors exit 2" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.writeRepoFile("groupwords.tsv", "");
    const vocab = try std.fmt.allocPrint(testing.allocator, "{s}/groupwords.tsv", .{fx.repo});
    defer testing.allocator.free(vocab);

    const r1 = try fx.runFake(&.{"gate"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try fx.runFake(&.{ "gate", "--vocab", vocab, "--top", "zero" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());

    const r3 = try fx.runFake(&.{ "gate", "--nope" });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r3.exitCode());
}

test "graph-clean: outside a git repo it exits 1, and an unknown flag exits 2" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();

    const r1 = try fx.runSynapseOutsideRepo(&.{"graph-clean"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 1), r1.exitCode());

    try fx.makeRepo(null);
    const r2 = try fx.runFake(&.{ "graph-clean", "--bogus" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());
}

test "link-graph: usage and environment errors" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.writeRepoFile("_refs.tsv", "");
    try fx.writeRepoFile("lists/.keep", "");
    const lists = try std.fmt.allocPrint(testing.allocator, "{s}/lists", .{fx.repo});
    defer testing.allocator.free(lists);

    const r1 = try fx.runFake(&.{"link-graph"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try fx.runFake(&.{ "link-graph", "--lists", lists, "--top", "bogus" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());

    const r3 = try fx.runFake(&.{ "link-graph", "--nope" });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r3.exitCode());
}

test "rank: usage errors" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);
    try fx.writeRepoFile("sources.txt", "");
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/sources.txt", .{fx.repo});
    defer testing.allocator.free(src);
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/out", .{fx.repo});
    defer testing.allocator.free(out);
    const out_lists = try std.fmt.allocPrint(testing.allocator, "{s}/lists", .{out});
    defer testing.allocator.free(out_lists);

    const r1 = try fx.runFake(&.{"rank"});
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r1.exitCode());

    const r2 = try fx.runFake(&.{ "rank", "--sources", src, "--tier", "bogus" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r2.exitCode());

    // --lists and --sources pick two different input modes; giving both is a
    // usage error, not a silent pick of one.
    const r3 = try fx.runFake(&.{ "rank", "--sources", src, "--lists", out_lists, "--repo", fx.repo, "--out", out });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r3.exitCode());

    // --pool and --tier each select one pool/tier for a single stream;
    // --lists always writes both pools per node, so combining them is a
    // usage error too.
    const r4 = try fx.runFake(&.{ "rank", "--lists", out_lists, "--repo", fx.repo, "--out", out, "--pool", "crux" });
    defer r4.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r4.exitCode());

    const r5 = try fx.runFake(&.{ "rank", "--lists", out_lists, "--repo", fx.repo, "--out", out, "--tier", "code" });
    defer r5.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r5.exitCode());
}

test "vault-check/vault-ambiguous/vault-rename: reachable through synapse-fake" {
    // `main_fake.zig`'s dispatch table used to be missing these three
    // entirely -- every call fell through to "unknown subcommand" (exit 2),
    // the same code a bad flag would already produce, so this suite (which
    // always spawns synapse-fake) had zero coverage for any of them with no
    // way to add it. --help's own exit 0 only happens once dispatch reaches
    // the real command; the fallback path never returns 0.
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();

    const r1 = try fx.runFake(&.{ "vault-check", "--help" });
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r1.exitCode());
    try testing.expect(std.mem.indexOf(u8, r1.stdout, "unknown subcommand") == null and
        std.mem.indexOf(u8, r1.stderr, "unknown subcommand") == null);

    const r2 = try fx.runFake(&.{ "vault-ambiguous", "--help" });
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r2.exitCode());
    try testing.expect(std.mem.indexOf(u8, r2.stdout, "unknown subcommand") == null and
        std.mem.indexOf(u8, r2.stderr, "unknown subcommand") == null);

    const r3 = try fx.runFake(&.{ "vault-rename", "--help" });
    defer r3.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r3.exitCode());
    try testing.expect(std.mem.indexOf(u8, r3.stdout, "unknown subcommand") == null and
        std.mem.indexOf(u8, r3.stderr, "unknown subcommand") == null);
}

test "tags-cache: missing arguments is a usage error, exit 2" {
    var fx = try support.Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo(null);

    const r = try fx.runFake(&.{ "tags-cache", "--repo-root", fx.repo });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r.exitCode());
}
