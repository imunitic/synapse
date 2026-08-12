//! `synapse-hook stop-nudge` -- Stop.
//!
//! Two jobs, both keyed off the fact that Stop is the only per-turn event:
//!
//! 1. every `N` turns, force a genuine "is anything worth capturing in Synapse Vault"
//!    check-in;
//! 2. every `PUSH_EVERY` turns, push the vault's auto-commits to its remote.
//!
//! ## Why the push lives here and not in db-sync
//!
//! `db-sync` is PostToolUse, so it fires once per vault-mutating tool call -- several
//! times in a single turn -- and a network round trip there would be paid on every
//! Write/Edit. It also has no way to count turns. So committing stays there and
//! pushing happens here, reusing this hook's per-session turn counter rather than
//! adding a second one.
//!
//! **Piggybacking is safe because this hook has no early exits**: every path falls
//! through to the push block. It must stay silent on stdout though -- the nudge above
//! may already have written this hook's JSON, and a second write would corrupt it.
//!
//! ## The nudge uses additionalContext, not decision:block
//!
//! A predecessor hook used this same shape and reliably produced immediate, visible
//! action, with the CLI labelling it "Stop hook feedback" instead of the
//! alarming-looking "Stop hook error" that `decision: block` renders as. Switched back
//! to this shape 2026-07-23 specifically for the better label.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Turns between check-ins.
const n = 25;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const home = env.get("HOME") orelse return;
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.claude/state", .{home});
    defer gpa.free(state_dir);
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    const sid = payload.str("session_id") orelse "default";

    const total_path = try std.fmt.allocPrint(gpa, "{s}/synapse-stop-nudge-total-{s}", .{ state_dir, sid });
    defer gpa.free(total_path);
    const since_path = try std.fmt.allocPrint(gpa, "{s}/synapse-stop-nudge-since-{s}", .{ state_dir, sid });
    defer gpa.free(since_path);

    const total = readCount(gpa, io, total_path) + 1;
    const since = readCount(gpa, io, since_path) + 1;
    try writeCount(gpa, io, total_path, total);

    if (since >= n) {
        try writeCount(gpa, io, since_path, 0);
        // `LOCATION` is the vault path when known, and the phrase when not: the
        // message names where to write, and "the Obsidian vault" is still an
        // instruction where a path would be a lie.
        const location = env.get("OBSIDIAN_VAULT_DIR") orelse "the Obsidian vault";
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.print(
            "This session has grown substantial ({d} turns, re-armed at the {d}-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to Synapse Vault ({s})? If so, write it up now (see the global CLAUDE.md \"Synapse Vault as permanent memory\" section, or use /synapse-note) while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.",
            .{ total, n, location },
        );
        try common.emitContext(gpa, io, "Stop", text.written());
    } else {
        try writeCount(gpa, io, since_path, since);
    }

    try maybePush(gpa, io, env, total);
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

/// Hand the push to a detached copy of this binary, at most every `PUSH_EVERY` turns.
///
/// **Detached, so the turn never waits on the network.** That was the script's reason
/// for backgrounding a subshell and it is unchanged: a Stop hook that stalls delays
/// the visible end of every turn, and an unreachable remote (VPN off) is the ordinary
/// case, not the exception. The work moved into `synapse-hook vault-push` rather than
/// staying inline because a child that outlives us has to own the lock and the log
/// too -- a parent that spawned and exited could not clean up either.
///
/// A vault with no remote is a supported, ordinary configuration -- local versioned
/// undo only -- so everything here is a silent no-op when anything is missing.
fn maybePush(gpa: Allocator, io: Io, env: *std.process.Environ.Map, total: usize) !void {
    // `gpa` is used by the path formatting below; the spawn needs none.
    const vault = env.get("OBSIDIAN_VAULT_DIR") orelse return;
    if (vault.len == 0) return;
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch return;
    if (st.kind != .directory) return;

    const every = blk: {
        const raw = env.get("SYNAPSE_VAULT_PUSH_EVERY") orelse break :blk 5;
        break :blk std.fmt.parseInt(usize, raw, 10) catch 0;
    };
    if (every == 0 or total % every != 0) return;

    // The wrapper exports our own path, because a process cannot portably ask where
    // its executable is and guessing `~/.claude/bin` would break every test run.
    const self = env.get("SYNAPSE_HOOK_BIN") orelse return;

    // Spawned and never waited on: this process exits immediately after, and the
    // child is reparented. That is the whole point -- `wait` here would put the
    // network back on the turn's critical path. Every stream is detached so the
    // child cannot hold the turn's stdout open either.
    _ = std.process.spawn(io, .{
        .argv = &.{ self, "vault-push" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

/// `synapse-hook vault-push` -- the detached half of the Stop hook.
pub fn push(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = env.get("OBSIDIAN_VAULT_DIR") orelse return;
    if (vault.len == 0) return;
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
    // Only when there is genuinely something to send: "push if needed".
    if (ahead == 0) return;

    const lock = try std.fmt.allocPrint(gpa, "{s}/.git/synapse-push.lock", .{vault});
    defer gpa.free(lock);
    // `mkdir` is the atomic test-and-set. A lock is left behind only by a crashed
    // run, so one that exists is honoured -- and this process owns it for its whole
    // life, which is why it can be removed on the way out rather than aged out.
    Io.Dir.cwd().createDir(io, lock, .default_dir) catch return;
    defer Io.Dir.cwd().deleteDir(io, lock) catch {};

    // The bound is set at the SSH layer, not with `timeout`: macOS ships neither
    // `timeout` nor `gtimeout`. `ConnectTimeout` caps an unreachable remote, and
    // `BatchMode=yes` is load-bearing -- without it a key whose passphrase is not in
    // the agent makes ssh wait forever on a prompt nobody can see. Passed as
    // `-c core.sshCommand` rather than through the environment, which is the same
    // setting by a route that does not need a mutable env map.
    const res = adapters.process.run(io, gpa, &.{
        "git",
        "-c",
        "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10",
        "push",
        "--quiet",
    }, .{ .cwd = cwd }) catch return;
    defer res.deinit(gpa);
    if (res.ok()) return;

    // A failure is recorded where the script recorded it and nowhere else: the turn
    // says nothing, and someone debugging a vault that stopped syncing finds the log.
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
