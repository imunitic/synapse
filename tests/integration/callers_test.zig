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
    const dump = try std.fmt.allocPrint(fx.gpa, "H\tsrc/A.bb\t{s}\nP\tsrc/A.bb\n{s}\n", .{ h1, tagline });
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
