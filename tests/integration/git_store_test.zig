//! `GitStore`'s own detached Pusher spawn (`SYNAPSE_VAULT_INTEGRATIONS=git`):
//! proving `vault-write` actually spawns `synapse vault-git-pusher` as a
//! detached child and that it fires a real push -- the one thing that can't
//! move to native coverage. Everything else (commit-or-skip under lock
//! contention, lock staleness recovery, no-upstream-never-spawns) has
//! native coverage already.

const std = @import("std");
const adapters = @import("adapters");
const support = @import("support.zig");

const testing = std.testing;
const Fixture = support.Fixture;

fn gitAt(fx: *Fixture, cwd: []const u8, args: []const []const u8) !adapters.process.Result {
    var argv = try fx.gpa.alloc([]const u8, args.len + 1);
    defer fx.gpa.free(argv);
    argv[0] = "git";
    for (args, 0..) |a, i| argv[i + 1] = a;
    return adapters.process.run(fx.io(), fx.gpa, argv, .{ .cwd = .{ .path = cwd } });
}

fn gitOutputAt(fx: *Fixture, gpa: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const r = try gitAt(fx, cwd, args);
    defer r.deinit(fx.gpa);
    return gpa.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
}

/// A bare "remote" and a vault repo tracking it, both local paths -- so a
/// push here is real git plumbing with no network involved. Returns the
/// remote's path (owned by `fx.root`-relative construction, caller frees).
fn seedVaultWithRemote(fx: *Fixture) ![]u8 {
    const remote = try std.fmt.allocPrint(fx.gpa, "{s}/vault-remote.git", .{fx.root});
    errdefer fx.gpa.free(remote);

    const r1 = try gitAt(fx, fx.root, &.{ "init", "-q", "--bare", "-b", "main", remote });
    r1.deinit(fx.gpa);
    const r2 = try gitAt(fx, fx.vault, &.{ "init", "-q", "-b", "main", fx.vault });
    r2.deinit(fx.gpa);
    const r3 = try gitAt(fx, fx.vault, &.{ "remote", "add", "origin", remote });
    r3.deinit(fx.gpa);
    try fx.dir.writeFile(std.testing.io, .{ .sub_path = "vault/seed.md", .data = "seed\n" });
    const r4 = try gitAt(fx, fx.vault, &.{ "add", "seed.md" });
    r4.deinit(fx.gpa);
    const r5 = try gitAt(fx, fx.vault, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "seed" });
    r5.deinit(fx.gpa);
    const r6 = try gitAt(fx, fx.vault, &.{ "push", "-q", "-u", "origin", "main" });
    r6.deinit(fx.gpa);

    return remote;
}

test "vault-write under SYNAPSE_VAULT_INTEGRATIONS=git spawns a real Pusher that pushes to a local remote" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer fx.gpa.free(remote);
    try fx.setEnv("SYNAPSE_VAULT_INTEGRATIONS", "git");
    try fx.setEnv("SYNAPSE_VAULT_PUSH_EVERY", "1");

    const r = try fx.runFakeStdin(&.{ "vault-write", "more.md" }, "more\n");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    // The Pusher is detached and write() does not wait on it, so give the
    // child a bounded window to finish the local push rather than
    // asserting immediately.
    var got: []u8 = try testing.allocator.dupe(u8, "");
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        testing.allocator.free(got);
        got = gitOutputAt(&fx, testing.allocator, remote, &.{ "log", "-1", "--format=%s", "main" }) catch try testing.allocator.dupe(u8, "");
        if (std.mem.eql(u8, got, "vault: more.md")) break;
        std.Io.sleep(fx.io(), .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("vault: more.md", got);
}

test "vault-write under SYNAPSE_VAULT_INTEGRATIONS=git commits but spawns no Pusher below the push-every threshold" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer fx.gpa.free(remote);
    try fx.setEnv("SYNAPSE_VAULT_INTEGRATIONS", "git");
    try fx.setEnv("SYNAPSE_VAULT_PUSH_EVERY", "5");

    const r = try fx.runFakeStdin(&.{ "vault-write", "more.md" }, "more\n");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), r.exitCode());

    // The commit lands locally either way; only the push is threshold-gated.
    const local_subject = try gitOutputAt(&fx, testing.allocator, fx.vault, &.{ "log", "-1", "--format=%s" });
    defer testing.allocator.free(local_subject);
    try testing.expectEqualStrings("vault: more.md", local_subject);

    std.Io.sleep(fx.io(), .{ .nanoseconds = 300 * std.time.ns_per_ms }, .real) catch {};
    const remote_subject = try gitOutputAt(&fx, testing.allocator, remote, &.{ "log", "-1", "--format=%s", "main" });
    defer testing.allocator.free(remote_subject);
    try testing.expectEqualStrings("seed", remote_subject);
}
