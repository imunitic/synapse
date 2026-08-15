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
        try common.emitContext(gpa, io, "Stop", text.written());
    } else {
        try writeCount(gpa, io, since_path, since);
    }

    try maybePush(gpa, io, env, total, self_path);
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
