//! `synapse-hook stop-nudge` -- Stop: every `N` turns, forces a "worth
//! capturing in Synapse Vault" check-in. A `GitStore`-backed vault
//! (`SYNAPSE_VAULT_STORE=git`) commits from inside `Store.write()` itself
//! and pushes on its own commit-count threshold, so no turn-keyed hook
//! drives either half of vault sync.
//!
//! `pull()` runs standalone, spawned once at SessionStart -- freshness at
//! the start of a session matters more than mid-session drift, and
//! mid-session freshness comes free from `GitStore`'s own pull-before-push.
//! Backend-aware: only a `.git`-backed vault actually pulls anything, even
//! if a stray `.git` directory happens to sit in a `disk`/`obsidian`
//! vault's folder -- the opt-in is the backend choice, not `.git`'s mere
//! presence.
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

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const home = env.get("HOME") orelse return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const sid = payload.str("session_id") orelse "default";

    const result = try tick(gpa, io, env, home, sid);
    defer if (result.text) |t| gpa.free(t);
    if (result.text) |t| try common.emitContext(gpa, io, "Stop", t);
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

/// `synapse-hook vault-pull` -- spawned detached, once, at SessionStart.
/// Backend-aware: resolves the vault's actual `Store` and does nothing
/// unless it's `.git` -- `disk`/`obsidian` are silent no-ops here even if a
/// stray `.git` directory happens to sit in the vault folder, since the
/// opt-in is the backend choice now, not `.git`'s mere presence. Shares
/// `GitStore`'s own lock (a short bounded wait, same as the Pusher), so the
/// rare case of a session starting the same instant a write's commit or a
/// Pusher is mid-flight just skips this round rather than racing it.
pub fn pull(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);

    var resolved = (try adapters.store_resolve.resolveStore(gpa, io, env, vault, "", null)) orelse return;
    defer resolved.deinit();
    if (resolved != .git) return;

    const lock = (try adapters.git_sync.acquireWithRetry(gpa, io, vault, 5)) orelse return;
    defer adapters.git_sync.release(io, gpa, lock);

    if (!adapters.git_sync.pull(gpa, io, vault)) {
        appendSyncFailure(gpa, io, vault) catch {};
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
/// Appends one failure line to the vault's own sync log -- never surfaced to
/// the turn, same tolerance every other network failure here gets; someone
/// debugging a vault that stopped pulling finds it here instead.
fn appendSyncFailure(gpa: Allocator, io: Io, vault: []const u8) !void {
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
    try out.writer.print("{s} pull failed, vault left as it was\n", .{stamp});
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

test "pull: a real pull lands the remote-only commit, with no push involved" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.env.put("SYNAPSE_VAULT_STORE", "git");
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
    try fx.env.put("SYNAPSE_VAULT_STORE", "git");
    _ = fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    try pull(gpa, fx.io(), &fx.env); // must not error
}

test "pull: no upstream tracking branch is a silent no-op" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.env.put("SYNAPSE_VAULT_STORE", "git");
    const init_vault = try vaultGit(&fx, &.{ "init", "-q", "-b", "main" });
    init_vault.deinit(gpa);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/seed.md", .data = "seed\n" });
    const add = try vaultGit(&fx, &.{ "add", "seed.md" });
    add.deinit(gpa);
    const commit = try vaultGit(&fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "seed" });
    commit.deinit(gpa);

    try pull(gpa, fx.io(), &fx.env); // must not error
}

test "pull: a disk-backed vault never pulls, even with a real .git and a real upstream ahead" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    // Default backend (`disk`) deliberately left as-is: the opt-in is the
    // backend choice, not whatever `.git` state happens to sit in the
    // vault folder.
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
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(fx.io(), vault_phone_md, .{}));
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
