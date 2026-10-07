//! `synapse callers`'s dispatch: the real binary skips the shared vault/
//! namespace preamble entirely for this subcommand, so it works with no
//! vault configured at all -- something only a real process boundary can
//! prove. The lookup logic itself has native coverage (`refs_cmd.zig`'s own
//! tests, via `callers()`).

const std = @import("std");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

const h1 = "1111111111111111111111111111111111111111";

test "callers: needs no vault, no namespace and no nodes" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.makeRepo("ssh://git@example.invalid/x/repo.git");
    try fx.setEnv("SYNAPSE_WORK_DIR", fx.work);

    const cache = try std.fmt.allocPrint(fx.gpa, "{s}/_tags_cache.bin", .{fx.work});
    defer fx.gpa.free(cache);
    const index = try std.fmt.allocPrint(fx.gpa, "{s}/_refs.tsv", .{fx.work});
    defer fx.gpa.free(index);

    // One `def` tag for `doThing`, in the exact `--dump`/`--load` format.
    const tagline = "doThing   \t | method \tdef (10, 13) - (10, 39) `public void doThing() {`";
    const dump = try std.fmt.allocPrint(fx.gpa, "H\tsrc/A.bb\t{s}\nT\tsrc/A.bb\t{s}\n", .{ h1, tagline });
    defer fx.gpa.free(dump);

    const load_res = try fx.runFakeStdin(&.{ "tags-cache", "--load", cache }, dump);
    defer load_res.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), load_res.exitCode());

    const refs_res = try fx.runFake(&.{ "build-refs", "--cache", cache, "--out", index });
    defer refs_res.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), refs_res.exitCode());

    // No vault configured at all, and no vault directory even exists.
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");
    std.Io.Dir.cwd().deleteTree(std.testing.io, fx.vault) catch {};

    const r = try fx.runFake(&.{ "callers", "doThing" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
}

test "callers --namespace reads another checkout's index directly, no repo at cwd needed" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const other_ns = "other-repo@main";
    const other_work = try std.fmt.allocPrint(fx.gpa, "{s}/.cache/synapse/work/{s}", .{ fx.home, other_ns });
    defer fx.gpa.free(other_work);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, other_work);

    const cache = try std.fmt.allocPrint(fx.gpa, "{s}/_tags_cache.bin", .{other_work});
    defer fx.gpa.free(cache);
    const index = try std.fmt.allocPrint(fx.gpa, "{s}/_refs.tsv", .{other_work});
    defer fx.gpa.free(index);

    const tagline = "doThing   \t | method \tdef (10, 13) - (10, 39) `public void doThing() {`";
    const dump = try std.fmt.allocPrint(fx.gpa, "H\tsrc/A.bb\t{s}\nT\tsrc/A.bb\t{s}\n", .{ h1, tagline });
    defer fx.gpa.free(dump);

    const load_res = try fx.runFakeStdin(&.{ "tags-cache", "--load", cache }, dump);
    defer load_res.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), load_res.exitCode());

    const refs_res = try fx.runFake(&.{ "build-refs", "--cache", cache, "--out", index });
    defer refs_res.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), refs_res.exitCode());

    // No vault, and `self.repo` (the fixture's default cwd) is never turned
    // into a real git repo at all -- `--namespace` addresses the other
    // namespace's already-built index directly, with nothing about cwd's
    // own identity ever consulted.
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    // `--all`, not the default calls-only view: the seeded tag is a `def`,
    // which the default view never reports at all.
    const r = try fx.runFake(&.{ "callers", "--namespace", other_ns, "--all", "doThing" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "src/A.bb:10") != null);
}

test "callers: --refs and --namespace together is a usage error, not a silent pick" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try fx.unsetEnv("SYNAPSE_VAULT_DIR");

    const r = try fx.runFake(&.{ "callers", "doThing", "--refs", "/nonexistent/_refs.tsv", "--namespace", "other-repo@main" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), r.exitCode());
}
