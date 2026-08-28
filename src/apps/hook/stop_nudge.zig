//! `synapse-hook stop-nudge` -- Stop.
//!
//! Two jobs, keyed off Stop being the only per-turn event: every `N` turns,
//! force a "worth capturing in Synapse Vault" check-in; every
//! `PUSH_EVERY` turns, sync the vault with its remote -- pull first, then
//! push, so an edit from elsewhere (a phone-side editor with its own
//! git-sync, say) gets folded in before this machine's auto-commits go out,
//! rather than the two histories quietly diverging until a push finally
//! fails.
//!
//! The sync lives here, not in db-sync, because db-sync is PostToolUse
//! (fires per tool call, several times a turn, and can't count turns) --
//! this reuses the hook's own turn counter instead of adding a second one.
//! Piggybacking is safe since every path here falls through to the sync
//! block, but the sync must stay silent on stdout: the nudge above may
//! already have written this hook's JSON.
//!
//! `pull()` also runs standalone, undetached-throttle, spawned once at
//! SessionStart -- freshness at the start of a session matters more than
//! mid-session drift, so that call site skips the turn-count gate entirely
//! and never pushes (nothing local to push yet at session start).
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

/// The `synapse-claude.md` heading the nudge text points readers at -- named
/// once so a test can confirm the heading it cites still exists, instead of
/// two copies (nudge prose, test expectation) drifting apart silently.
const vault_note_heading = "Synapse Vault as permanent memory";

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map, self_path: []const u8) !void {
    const home = env.get("HOME") orelse return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const sid = payload.str("session_id") orelse "default";

    const result = try tick(gpa, io, env, home, sid);
    defer if (result.text) |t| gpa.free(t);
    if (result.text) |t| try common.emitContext(gpa, io, "Stop", t);

    try maybeSync(gpa, io, env, result.total, self_path);
}

pub const Tick = struct {
    /// The check-in nudge, when this call just re-armed. Caller owns it.
    text: ?[]u8,
    /// The running total turn count, across every call for this session --
    /// what `maybeSync` gates on, independent of whether a nudge fired.
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
        const location = resolved_vault orelse "the vault";
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.print(
            "This session has grown substantial ({d} turns, re-armed at the {d}-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to Synapse Vault ({s})? If so, write it up now (see the global CLAUDE.md \"{s}\" section, or use /synapse-note) while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.",
            .{ total, n, location, vault_note_heading },
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

/// Hands the sync to a detached copy of this binary, at most every
/// `PUSH_EVERY` turns. Detached so the turn never waits on the network --
/// an unreachable remote (VPN off) is the ordinary case, not the exception
/// -- and run via `synapse-hook vault-sync` rather than inline, since a
/// child that outlives us has to own the lock and log itself. A vault with
/// no remote is ordinary (local versioned undo only), so everything here
/// is a silent no-op when anything is missing.
fn maybeSync(gpa: Allocator, io: Io, env: *std.process.Environ.Map, total: usize, self_path: []const u8) !void {
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

    // `argv[0]`, threaded from `main`, not `$SYNAPSE_HOOK_BIN`:
    // settings.json's hook entry never sets that variable, so reading it
    // made the sync silently a no-op on every real install. `argv[0]` is
    // guaranteed to already be this process's own invoked path.
    if (self_path.len == 0) return;
    const self = self_path;

    // Never waited on: this process exits immediately, the child is
    // reparented -- `wait` here would put the network on the turn's
    // critical path.
    _ = std.process.spawn(io, .{
        .argv = &.{ self, "vault-sync" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

/// The tracked upstream's short name (e.g. `origin/main`), or null when
/// there isn't one -- no upstream is ordinary (a vault with no remote, or
/// one never pushed yet), the same "everything is a silent no-op" contract
/// every precondition here follows. Shared by `sync` and `pull`, which both
/// need it before deciding whether there's anything to do at all.
fn upstreamOf(gpa: Allocator, io: Io, cwd: std.process.Child.Cwd) !?[]u8 {
    const res = try adapters.process.run(io, gpa, &.{
        "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
    }, .{ .cwd = cwd });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const name = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (name.len == 0) return null;
    return try gpa.dupe(u8, name);
}

/// Fetches and rebases any local, not-yet-pushed auto-commits onto the
/// tracked upstream -- the read half of vault sync. Safe to run whenever the
/// working tree is clean, which both call sites guarantee (`pull` runs at
/// SessionStart, before anything this session could have touched; `sync`
/// runs it immediately before its own push, by which point every write this
/// turn already went through db-sync's own per-edit commit). `--autostash`
/// is defensive insurance against that invariant, not reliance on it.
///
/// A conflict is aborted immediately rather than ever left half-applied --
/// `git rebase` writes conflict markers straight into the working-tree file,
/// and that file is a note read as-is by whatever's viewing the vault.
/// Losing this round's pull to a manual-resolution log line is a far
/// smaller cost than a note silently gaining `<<<<<<<` in its body. Returns
/// whether it's safe to continue (already up to date, or pulled cleanly).
fn pullUpstream(gpa: Allocator, io: Io, cwd: std.process.Child.Cwd) bool {
    // Same SSH bound as the push below, for the same reason: macOS ships
    // neither `timeout` nor `gtimeout`, and `BatchMode=yes` keeps a
    // passphrase-locked key from waiting forever on a prompt nobody sees.
    const res = adapters.process.run(io, gpa, &.{
        "git",
        "-c",
        "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10",
        "pull",
        "--rebase",
        "--autostash",
        "--quiet",
    }, .{ .cwd = cwd }) catch return false;
    defer res.deinit(gpa);
    if (res.ok()) return true;

    const abort = adapters.process.run(io, gpa, &.{ "git", "rebase", "--abort" }, .{ .cwd = cwd }) catch return false;
    abort.deinit(gpa);
    return false;
}

/// `synapse-hook vault-sync` -- the detached half of the Stop hook. Pulls
/// first, then pushes only what's still ahead afterward -- pulling after
/// computing `ahead` would push against a since-moved upstream.
pub fn sync(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);
    const cwd: std.process.Child.Cwd = .{ .path = vault };

    const upstream = try upstreamOf(gpa, io, cwd) orelse return;
    defer gpa.free(upstream);

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.lock", .{vault});
    defer gpa.free(lock);
    // `mkdir` is the atomic test-and-set. Left behind only by a crash, so
    // an existing lock is honoured, and removed on the way out since this
    // process owns it for its whole life. One lock for both halves: `pull`
    // (SessionStart) and `sync` (Stop) mutate the same repo and must never
    // interleave.
    Io.Dir.cwd().createDir(io, lock, .default_dir) catch return;
    defer Io.Dir.cwd().deleteDir(io, lock) catch {};

    if (!pullUpstream(gpa, io, cwd)) {
        appendSyncFailure(gpa, io, vault, "pull", null) catch {};
        return; // HEAD's state is uncertain -- don't push on top of it
    }

    const ahead = blk: {
        const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{upstream});
        defer gpa.free(spec);
        const res = try adapters.process.run(io, gpa, &.{ "git", "rev-list", "--count", spec }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        if (!res.ok()) return;
        break :blk std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
    };
    if (ahead == 0) return; // push only if needed

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
    appendSyncFailure(gpa, io, vault, "push", ahead) catch {};
}

/// `synapse-hook vault-pull` -- spawned detached, once, at SessionStart.
/// Pull only, no push: freshness for what this session is about to read
/// matters here, not draining this machine's own not-yet-pushed commits
/// (`sync` above already does that periodically). Shares `sync`'s lock, so
/// the rare case of a session starting the same instant a throttled `sync`
/// is mid-flight just skips this round rather than racing it.
pub fn pull(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);
    const cwd: std.process.Child.Cwd = .{ .path = vault };

    const upstream = try upstreamOf(gpa, io, cwd) orelse return;
    gpa.free(upstream);

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.lock", .{vault});
    defer gpa.free(lock);
    Io.Dir.cwd().createDir(io, lock, .default_dir) catch return;
    defer Io.Dir.cwd().deleteDir(io, lock) catch {};

    if (!pullUpstream(gpa, io, cwd)) {
        appendSyncFailure(gpa, io, vault, "pull", null) catch {};
    }
}

/// Hands the pull to a detached copy of this binary -- unthrottled, unlike
/// `maybeSync`, since SessionStart is already naturally infrequent and
/// freshness at the very start of a session is the whole point. Called from
/// `session_start.zig`'s `run()`, not `build()`: `build()` stays a pure,
/// synchronous read so its own tests never spawn a real process.
pub fn spawnPull(io: Io, self_path: []const u8) void {
    if (self_path.len == 0) return;
    _ = std.process.spawn(io, .{
        .argv = &.{ self_path, "vault-pull" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

/// Appends one failure line to the vault's own sync log -- `op` is `"pull"`
/// or `"push"`; `ahead` is the pending-commit count for a push failure,
/// null for a pull failure (nothing about the local commit count is the
/// issue there). Never surfaced to the turn, same tolerance as every other
/// network failure in this file.
fn appendSyncFailure(gpa: Allocator, io: Io, vault: []const u8, op: []const u8, ahead: ?usize) !void {
    const log_path = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.log", .{vault});
    defer gpa.free(log_path);

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
    if (ahead) |count| {
        try out.writer.print("{s} {s} failed, {d} commit(s) still pending\n", .{ stamp, op, count });
    } else {
        try out.writer.print("{s} {s} failed, vault left as it was\n", .{ stamp, op });
    }
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
    // Repo-local, not just per-commit `-c` flags: `git rebase` re-commits
    // each replayed patch itself, which needs a resolvable identity even
    // when nothing here calls `commit` directly -- a CI runner with no
    // global user.email/name configured (unlike a real dev machine) fails
    // that step outright, aborts, and gets misread as a genuine conflict.
    const email = try vaultGit(fx, &.{ "config", "user.email", "t@e" });
    email.deinit(fx.gpa);
    const name = try vaultGit(fx, &.{ "config", "user.name", "t" });
    name.deinit(fx.gpa);
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

/// A second working copy of `remote`, standing in for the phone in the pull
/// tests below -- `init` + `remote add` + `pull` rather than `git clone`,
/// which doesn't behave reliably against these tmp-rooted local paths in
/// this environment: an otherwise-successful, zero-stderr `git clone` of a
/// `.zig-cache/tmp/...`-rooted local bare repo leaves the destination
/// completely empty, no `.git`, no working tree. Every
/// other git sequence in this file already goes through this same
/// init/add/commit/push shape successfully, so this stays on the proven
/// path instead. Caller-owned `other` path.
fn seedOtherClone(fx: *fixture.Fixture, remote: []const u8) ![]u8 {
    const gpa = fx.gpa;
    const other = try std.fmt.allocPrint(gpa, "{s}/other-clone", .{fx.root});
    errdefer gpa.free(other);
    const cwd: std.process.Child.Cwd = .{ .path = other };

    try Io.Dir.cwd().createDirPath(fx.io(), other);
    const init = try adapters.process.run(fx.io(), gpa, &.{ "git", "init", "-q", "-b", "main" }, .{ .cwd = cwd });
    init.deinit(gpa);
    // Same reasoning as seedVaultWithRemote's own config: repo-local
    // identity for anything git does internally, not just the explicit
    // `-c` flags on this file's own `commit` calls.
    const email = try adapters.process.run(fx.io(), gpa, &.{ "git", "config", "user.email", "t@e" }, .{ .cwd = cwd });
    email.deinit(gpa);
    const name = try adapters.process.run(fx.io(), gpa, &.{ "git", "config", "user.name", "t" }, .{ .cwd = cwd });
    name.deinit(gpa);
    const add_remote = try adapters.process.run(fx.io(), gpa, &.{ "git", "remote", "add", "origin", remote }, .{ .cwd = cwd });
    add_remote.deinit(gpa);
    const pull_res = try adapters.process.run(fx.io(), gpa, &.{ "git", "pull", "-q", "origin", "main" }, .{ .cwd = cwd });
    pull_res.deinit(gpa);

    return other;
}

test "sync: a real push lands on the local remote when the vault is ahead" {
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

    try sync(gpa, fx.io(), &fx.env);

    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("more", head);
}

test "sync: nothing to push when the vault is already up to date with its remote" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    try sync(gpa, fx.io(), &fx.env);

    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "sync: no vault configured is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    try sync(gpa, fx.io(), &fx.env); // must not error
}

test "sync: a vault with no .git repo is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    // Fixture's own vault dir exists but was never `git init`'d.

    try sync(gpa, fx.io(), &fx.env); // must not error or crash
}

test "sync: no upstream tracking branch is a silent no-op" {
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

    try sync(gpa, fx.io(), &fx.env); // must not error
}

test "sync: an existing lock is honoured, not raced -- and left in place" {
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

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.lock", .{fx.vault});
    defer gpa.free(lock);
    try Io.Dir.cwd().createDir(fx.io(), lock, .default_dir);

    try sync(gpa, fx.io(), &fx.env);

    // Left in place: `sync()` only ever removes a lock it created itself.
    try Io.Dir.cwd().access(fx.io(), lock, .{});
    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "sync: a failed push is logged, not surfaced" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);
    // Pull now always runs before push, and both use the same remote --
    // an unreachable remote breaks pull first (the next test covers that
    // path), so a push-only failure needs the remote reachable for fetch
    // but rejecting the push itself. A `pre-receive` hook that always
    // exits nonzero does exactly that: it only ever fires on push.
    const hooks_dir = try std.fmt.allocPrint(gpa, "{s}/hooks", .{remote});
    defer gpa.free(hooks_dir);
    const hook_path = try std.fmt.allocPrint(gpa, "{s}/pre-receive", .{hooks_dir});
    defer gpa.free(hook_path);
    try Io.Dir.cwd().writeFile(fx.io(), .{ .sub_path = hook_path, .data = "#!/bin/sh\nexit 1\n" });
    const chmod = try adapters.process.run(fx.io(), gpa, &.{ "chmod", "+x", hook_path }, .{});
    chmod.deinit(gpa);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });
    const add = try vaultGit(&fx, &.{ "add", "more.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "more" });
    commit.deinit(gpa);

    try sync(gpa, fx.io(), &fx.env);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.log", .{fx.vault});
    defer gpa.free(log_path);
    const log = try Io.Dir.cwd().readFileAlloc(fx.io(), log_path, gpa, .limited(1 << 20));
    defer gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "push failed") != null);
    try testing.expect(std.mem.indexOf(u8, log, "1 commit(s) still pending") != null);
}

test "sync: pulls a remote-only commit before pushing, so a fast-forward push succeeds" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    // A second working copy stands in for the phone: it pushes a commit the
    // vault clone here has never seen.
    const other = try seedOtherClone(&fx, remote);
    defer gpa.free(other);
    const phone_md = try std.fmt.allocPrint(gpa, "{s}/phone.md", .{other});
    defer gpa.free(phone_md);
    try Io.Dir.cwd().writeFile(fx.io(), .{ .sub_path = phone_md, .data = "from phone\n" });
    const phone_add = try adapters.process.run(fx.io(), gpa, &.{ "git", "add", "phone.md" }, .{ .cwd = .{ .path = other } });
    phone_add.deinit(gpa);
    const phone_commit = try adapters.process.run(fx.io(), gpa, &.{ "git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "from phone" }, .{ .cwd = .{ .path = other } });
    phone_commit.deinit(gpa);
    const phone_push = try adapters.process.run(fx.io(), gpa, &.{ "git", "push", "-q", "origin", "main" }, .{ .cwd = .{ .path = other } });
    phone_push.deinit(gpa);

    // Meanwhile this machine made its own local, not-yet-pushed commit.
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/local.md", .data = "from this machine\n" });
    const add = try vaultGit(&fx, &.{ "add", "local.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "from this machine" });
    commit.deinit(gpa);

    try sync(gpa, fx.io(), &fx.env);

    // Both ends now have both commits.
    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("from this machine", head);
    const vault_phone_md = try std.fmt.allocPrint(gpa, "{s}/phone.md", .{fx.vault});
    defer gpa.free(vault_phone_md);
    try Io.Dir.cwd().access(fx.io(), vault_phone_md, .{});
}

test "sync: a conflicting pull is aborted, never left as conflict markers in a note" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    // The phone edits the same file the vault clone is about to edit too.
    const other = try seedOtherClone(&fx, remote);
    defer gpa.free(other);
    const other_seed_md = try std.fmt.allocPrint(gpa, "{s}/seed.md", .{other});
    defer gpa.free(other_seed_md);
    try Io.Dir.cwd().writeFile(fx.io(), .{ .sub_path = other_seed_md, .data = "from phone\n" });
    const phone_add = try adapters.process.run(fx.io(), gpa, &.{ "git", "add", "seed.md" }, .{ .cwd = .{ .path = other } });
    phone_add.deinit(gpa);
    const phone_commit = try adapters.process.run(fx.io(), gpa, &.{ "git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "from phone" }, .{ .cwd = .{ .path = other } });
    phone_commit.deinit(gpa);
    const phone_push = try adapters.process.run(fx.io(), gpa, &.{ "git", "push", "-q", "origin", "main" }, .{ .cwd = .{ .path = other } });
    phone_push.deinit(gpa);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/seed.md", .data = "from this machine\n" });
    const add = try vaultGit(&fx, &.{ "add", "seed.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "from this machine" });
    commit.deinit(gpa);

    try sync(gpa, fx.io(), &fx.env);

    // The note holds exactly this machine's content -- no conflict markers,
    // no half-applied rebase -- and nothing was pushed on top of it.
    const seed = try fx.tmp.dir.readFileAlloc(testing.io, "vault/seed.md", gpa, .limited(4096));
    defer gpa.free(seed);
    try testing.expectEqualStrings("from this machine\n", seed);
    try testing.expect(std.mem.indexOf(u8, seed, "<<<<<<<") == null);

    const head = try remoteHeadSubject(&fx, gpa, remote);
    defer gpa.free(head);
    try testing.expectEqualStrings("from phone", head);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.log", .{fx.vault});
    defer gpa.free(log_path);
    const log = try Io.Dir.cwd().readFileAlloc(fx.io(), log_path, gpa, .limited(1 << 20));
    defer gpa.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "pull failed") != null);
}

test "pull: a real pull lands the remote-only commit, with no push involved" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    const remote = try seedVaultWithRemote(&fx);
    defer gpa.free(remote);

    const other = try seedOtherClone(&fx, remote);
    defer gpa.free(other);
    const phone_md = try std.fmt.allocPrint(gpa, "{s}/phone.md", .{other});
    defer gpa.free(phone_md);
    try Io.Dir.cwd().writeFile(fx.io(), .{ .sub_path = phone_md, .data = "from phone\n" });
    const phone_add = try adapters.process.run(fx.io(), gpa, &.{ "git", "add", "phone.md" }, .{ .cwd = .{ .path = other } });
    phone_add.deinit(gpa);
    const phone_commit = try adapters.process.run(fx.io(), gpa, &.{ "git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "from phone" }, .{ .cwd = .{ .path = other } });
    phone_commit.deinit(gpa);
    const phone_push = try adapters.process.run(fx.io(), gpa, &.{ "git", "push", "-q", "origin", "main" }, .{ .cwd = .{ .path = other } });
    phone_push.deinit(gpa);

    try pull(gpa, fx.io(), &fx.env);

    const vault_phone_md = try std.fmt.allocPrint(gpa, "{s}/phone.md", .{fx.vault});
    defer gpa.free(vault_phone_md);
    try Io.Dir.cwd().access(fx.io(), vault_phone_md, .{});
}

test "pull: no vault configured is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    try pull(gpa, fx.io(), &fx.env); // must not error
}

test "pull: no upstream tracking branch is a silent no-op" {
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

    try pull(gpa, fx.io(), &fx.env); // must not error
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
    _ = fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    var i: usize = 0;
    var last: ?[]u8 = null;
    while (i < n) : (i += 1) {
        if (last) |t| gpa.free(t);
        const r = try tick(gpa, fx.io(), &fx.env, fx.home, "s1");
        last = r.text;
    }
    const text = last.?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "the vault") != null);
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

test "the nudge cites a synapse-claude.md heading that actually exists" {
    // The nudge points the reader at a section of the shipped synapse-claude.md
    // by name -- renaming the heading without this constant (or the reverse)
    // leaves a pointer to a section that isn't there, and nothing about reading
    // the nudge would reveal it. `zig build test`'s working directory is the
    // repo root, so this reads the real shipped file rather than a fixture copy.
    const gpa = testing.allocator;
    const heading_line = try std.fmt.allocPrint(gpa, "# {s}", .{vault_note_heading});
    defer gpa.free(heading_line);
    const content = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        "packages/synapse/synapse-claude.md",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, heading_line)) return;
    }
    try testing.expect(false);
}
