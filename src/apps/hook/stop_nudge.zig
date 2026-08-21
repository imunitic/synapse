//! `synapse-hook stop-nudge` -- Stop.
//!
//! Two jobs, keyed off Stop being the only per-turn event: every `N` turns,
//! force a "worth capturing in Synapse Vault" check-in; every
//! `PUSH_EVERY` turns, push the vault's auto-commits to its remote.
//!
//! The push lives here, not in db-sync, because db-sync is PostToolUse
//! (fires per tool call, several times a turn, and can't count turns) --
//! this reuses the hook's own turn counter instead of adding a second one.
//! Piggybacking is safe since every path here falls through to the push
//! block, but the push must stay silent on stdout: the nudge above may
//! already have written this hook's JSON.
//!
//! The nudge uses `additionalContext`, not `decision: block`, since the CLI
//! labels the former "Stop hook feedback" rather than the alarming "Stop
//! hook error".

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Turns between check-ins.
const n = 25;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, self_path: []const u8) !void {
    const home = env.get("HOME") orelse return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const sid = payload.str("session_id") orelse "default";

    const result = try tick(gpa, io, env, home, sid);
    defer if (result.text) |t| gpa.free(t);
    if (result.text) |t| try common.emitContext(gpa, io, "Stop", t);

    try maybePush(gpa, io, env, result.total, self_path);
}

pub const Tick = struct {
    /// The check-in nudge, when this call just re-armed. Caller owns it.
    text: ?[]u8,
    /// The running total turn count, across every call for this session --
    /// what `maybePush` gates on, independent of whether a nudge fired.
    total: usize,
};

/// Advances this session's turn counters and decides whether a check-in
/// nudge is due -- separated from `run()` so a test can drive it directly,
/// against real state files, without a real stdin payload.
pub fn tick(gpa: Allocator, io: Io, env: *std.process.Environ.Map, home: []const u8, sid: []const u8) !Tick {
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.claude/state", .{home});
    defer gpa.free(state_dir);
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};

    const total_path = try std.fmt.allocPrint(gpa, "{s}/synapse-stop-nudge-total-{s}", .{ state_dir, sid });
    defer gpa.free(total_path);
    const since_path = try std.fmt.allocPrint(gpa, "{s}/synapse-stop-nudge-since-{s}", .{ state_dir, sid });
    defer gpa.free(since_path);

    const total = readCount(gpa, io, total_path) + 1;
    const since = readCount(gpa, io, since_path) + 1;
    try writeCount(gpa, io, total_path, total);

    if (since >= n) {
        try writeCount(gpa, io, since_path, 0);
        // Vault path when known, the phrase when not -- a path would be a lie otherwise.
        const resolved_vault = common.vault(gpa, io, env);
        defer if (resolved_vault) |v| gpa.free(v);
        const location = resolved_vault orelse "the Obsidian vault";
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.print(
            "This session has grown substantial ({d} turns, re-armed at the {d}-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to Synapse Vault ({s})? If so, write it up now (see the global CLAUDE.md \"Synapse Vault as permanent memory\" section, or use /synapse-note) while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.",
            .{ total, n, location },
        );
        return .{ .text = try gpa.dupe(u8, text.written()), .total = total };
    } else {
        try writeCount(gpa, io, since_path, since);
        return .{ .text = null, .total = total };
    }
}

fn readCount(gpa: Allocator, io: Io, path: []const u8) usize {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch return 0;
    defer gpa.free(text);
    return std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0;
}

fn writeCount(gpa: Allocator, io: Io, path: []const u8, value: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{value});
    _ = gpa;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// Hands the push to a detached copy of this binary, at most every
/// `PUSH_EVERY` turns. Detached so the turn never waits on the network --
/// an unreachable remote (VPN off) is the ordinary case, not the exception
/// -- and run via `synapse-hook vault-push` rather than inline, since a
/// child that outlives us has to own the lock and log itself. A vault with
/// no remote is ordinary (local versioned undo only), so everything here
/// is a silent no-op when anything is missing.
fn maybePush(gpa: Allocator, io: Io, env: *std.process.Environ.Map, total: usize, self_path: []const u8) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch return;
    if (st.kind != .directory) return;

    const every = blk: {
        const raw = env.get("SYNAPSE_VAULT_PUSH_EVERY") orelse break :blk 5;
        break :blk std.fmt.parseInt(usize, raw, 10) catch 0;
    };
    if (every == 0 or total % every != 0) return;

    // `argv[0]`, threaded from `main`, not `$SYNAPSE_HOOK_BIN` (sb-013):
    // settings.json's hook entry never sets that variable, so reading it
    // made the push silently a no-op on every real install. `argv[0]` is
    // guaranteed to already be this process's own invoked path.
    if (self_path.len == 0) return;
    const self = self_path;

    // Never waited on: this process exits immediately, the child is
    // reparented -- `wait` here would put the network on the turn's
    // critical path.
    _ = std.process.spawn(io, .{
        .argv = &.{ self, "vault-push" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

/// `synapse-hook vault-push` -- the detached half of the Stop hook.
pub fn push(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);
    const cwd: std.process.Child.Cwd = .{ .path = vault };

    const upstream = blk: {
        const res = try adapters.process.run(io, gpa, &.{
            "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
        }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        if (!res.ok()) return;
        const name = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (name.len == 0) return;
        break :blk try gpa.dupe(u8, name);
    };
    defer gpa.free(upstream);

    const ahead = blk: {
        const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{upstream});
        defer gpa.free(spec);
        const res = try adapters.process.run(io, gpa, &.{ "git", "rev-list", "--count", spec }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        if (!res.ok()) return;
        break :blk std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
    };
    if (ahead == 0) return; // push only if needed

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-push.lock", .{vault});
    defer gpa.free(lock);
    // `mkdir` is the atomic test-and-set. Left behind only by a crash, so
    // an existing lock is honoured, and removed on the way out since this
    // process owns it for its whole life.
    Io.Dir.cwd().createDir(io, lock, .default_dir) catch return;
    defer Io.Dir.cwd().deleteDir(io, lock) catch {};

    // Bound set at the SSH layer, since macOS ships neither `timeout` nor
    // `gtimeout`. `BatchMode=yes` is load-bearing -- without it a
    // passphrase-locked key makes ssh wait forever on a prompt nobody sees.
    const res = adapters.process.run(io, gpa, &.{
        "git",
        "-c",
        "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10",
        "push",
        "--quiet",
    }, .{ .cwd = cwd }) catch return;
    defer res.deinit(gpa);
    if (res.ok()) return;

    // Failure is logged, not surfaced -- the turn says nothing, but someone
    // debugging a vault that stopped syncing finds it here.
    const log_path = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-push.log", .{vault});
    defer gpa.free(log_path);
    appendPushFailure(gpa, io, log_path, ahead) catch {};
}

fn appendPushFailure(gpa: Allocator, io: Io, log_path: []const u8, ahead: usize) !void {
    const stamp = blk: {
        const res = try adapters.process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M" }, .{});
        defer res.deinit(gpa);
        if (!res.ok()) break :blk try gpa.dupe(u8, "");
        break :blk try gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    };
    defer gpa.free(stamp);

    const existing = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 << 20)) catch
        try gpa.dupe(u8, "");
    defer gpa.free(existing);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(existing);
    try out.writer.print("{s} push failed, {d} commit(s) still pending\n", .{ stamp, ahead });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = out.written() });
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn vaultGit(fx: *fixture.Fixture, args: []const []const u8) !adapters.process.Result {
    var argv_buf: [16][]const u8 = undefined;
    argv_buf[0] = "git";
    @memcpy(argv_buf[1 .. 1 + args.len], args);
    return adapters.process.run(fx.io(), fx.gpa, argv_buf[0 .. 1 + args.len], .{ .cwd = .{ .path = fx.vault } });
}

/// A bare "remote" and a vault repo tracking it, both local paths -- so a
/// push in these tests is real git plumbing with no network involved, same
/// as the bats fixture this was ported from. Caller frees the returned
/// remote path.
fn seedVaultWithRemote(fx: *fixture.Fixture) ![]u8 {
    const remote = try std.fmt.allocPrint(fx.gpa, "{s}/vault-remote.git", .{fx.root});
    errdefer fx.gpa.free(remote);

    const init_remote = try adapters.process.run(fx.io(), fx.gpa, &.{ "git", "init", "-q", "--bare", "-b", "main", remote }, .{});
    init_remote.deinit(fx.gpa);
    const init_vault = try vaultGit(fx, &.{ "init", "-q", "-b", "main" });
    init_vault.deinit(fx.gpa);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/seed.md", .data = "seed\n" });
    const add = try vaultGit(fx, &.{ "add", "seed.md" });
    add.deinit(fx.gpa);
    const commit = try vaultGit(fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "seed" });
    commit.deinit(fx.gpa);
    const add_remote = try vaultGit(fx, &.{ "remote", "add", "origin", remote });
    add_remote.deinit(fx.gpa);
    const do_push = try vaultGit(fx, &.{ "push", "-q", "-u", "origin", "main" });
    do_push.deinit(fx.gpa);

    return remote;
}

fn remoteHeadSubject(fx: *fixture.Fixture, gpa: Allocator, remote: []const u8) ![]u8 {
    const res = try adapters.process.run(fx.io(), gpa, &.{ "git", "-C", remote, "log", "-1", "--format=%s", "main" }, .{});
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

test "push: a real push lands on the local remote when the vault is ahead" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });
    const add = try vaultGit(&fx, &.{ "add", "more.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "more" });
    commit.deinit(gpa);

    try push(gpa, fx.io(), &fx.env);

    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("more", head);
}

test "push: nothing to push when the vault is already up to date with its remote" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    try push(gpa, fx.io(), &fx.env);

    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "push: no vault configured is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("OBSIDIAN_VAULT_DIR");

    try push(gpa, fx.io(), &fx.env); // must not error
}

test "push: a vault with no .git repo is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    // Fixture's own vault dir exists but was never `git init`'d.

    try push(gpa, fx.io(), &fx.env); // must not error or crash
}

test "push: no upstream tracking branch is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const init_vault = try vaultGit(&fx, &.{ "init", "-q", "-b", "main" });
    init_vault.deinit(gpa);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/seed.md", .data = "seed\n" });
    const add = try vaultGit(&fx, &.{ "add", "seed.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "seed" });
    commit.deinit(gpa);
    // No `git push -u` ever done, so no upstream tracking branch exists.

    try push(gpa, fx.io(), &fx.env); // must not error
}

test "push: an existing lock is honoured, not raced -- and left in place" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });
    const add = try vaultGit(&fx, &.{ "add", "more.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "more" });
    commit.deinit(gpa);

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-push.lock", .{fx.vault});
    defer gpa.free(lock);
    try Io.Dir.cwd().createDir(fx.io(), lock, .default_dir);

    try push(gpa, fx.io(), &fx.env);

    // Left in place: `push()` only ever removes a lock it created itself.
    try Io.Dir.cwd().access(fx.io(), lock, .{});
    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "push: a failed push is logged, not surfaced" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);
    // The remote is gone, but upstream tracking (set locally by the earlier
    // `push -u`) survives -- `git rev-parse @{upstream}` still resolves.
    try Io.Dir.cwd().deleteTree(fx.io(), remote);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });
    const add = try vaultGit(&fx, &.{ "add", "more.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "more" });
    commit.deinit(gpa);

    try push(gpa, fx.io(), &fx.env);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-push.log", .{fx.vault});
    defer gpa.free(log_path);
    const log = try Io.Dir.cwd().readFileAlloc(fx.io(), log_path, gpa, .limited(1 << 20));
    defer gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "push failed") != null);
    try testing.expect(std.mem.indexOf(u8, log, "1 commit(s) still pending") != null);
}

test "no nudge before the check-in turn" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    var i: usize = 0;
    while (i < n - 1) : (i += 1) {
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        try testing.expectEqual(@as(?[]u8, null), r.text);
    }
}

test "nudge fires on the Nth turn, naming the vault" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    var i: usize = 0;
    var last: ?[]u8 = null;
    while (i < n) : (i += 1) {
        if (last) |t| gpa.free(t);
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        last = r.text;
    }
    const text = last.?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, fx.vault) != null);
    try testing.expect(std.mem.indexOf(u8, text, "25 turns") != null);
}

test "the nudge re-arms after another cycle" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    var i: usize = 0;
    var fires: usize = 0;
    while (i < 2 * n) : (i += 1) {
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        if (r.text) |t| {
            fires += 1;
            gpa.free(t);
        }
    }
    try testing.expectEqual(@as(usize, 2), fires);
}

test "vault unresolvable: the nudge still fires, naming the generic phrase" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("OBSIDIAN_VAULT_DIR");

    var i: usize = 0;
    var last: ?[]u8 = null;
    while (i < n) : (i += 1) {
        if (last) |t| gpa.free(t);
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        last = r.text;
    }
    const text = last.?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "the Obsidian vault") != null);
}

test "separate sessions count turns independently" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        if (r.text) |t| gpa.free(t);
    }
    // A fresh session hasn't accumulated any turns yet.
    const r2 = try tick(gpa, fx.io(), &fx.env, fx.home, "s2");
    try testing.expectEqual(@as(?[]u8, null), r2.text);
    try testing.expectEqual(@as(usize, 1), r2.total);
}
