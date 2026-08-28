//! `synapse-hook db-sync` -- PostToolUse on a vault mutation.
//!
//! Commits any agent-driven vault change to the vault's own local git repo,
//! if one exists -- opt-in per vault, so a vault with no `.git` is an
//! ordinary no-op. Registered against the MCP vault tools as well as native
//! Write/Edit, for a session with an actual `mcp__obsidian__vault_*` tool
//! connected and used directly instead of the CLI door below. This is the
//! vault-wide undo: `git show <sha>:<path>` only works because every edit
//! is committed, not just intentional ones.
//!
//! `synapse vault-write`/`vault-patch` -- the CLI door skills actually use --
//! run through the generic `Bash` tool, indistinguishable
//! from any other shell command at the `hooks.json` `matcher` level: `matcher`
//! only ever sees a tool *name*, never its arguments. `hooks.json` widens the
//! matcher to include `Bash` so this hook fires at all for those writes, and
//! `shouldSkipBash` below is the actual filter, run against the real command
//! text -- everything else the matcher already named (`Write`, `Edit`,
//! `mcp__obsidian__vault_*`) is unconditionally a real vault write and skips
//! this check entirely, matching the behavior before `Bash` was ever added.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();
    try sync(gpa, io, env, payload);
}

/// The testable core, taking an already-parsed payload so a test can drive
/// it without spawning a process to feed real stdin.
fn sync(gpa: Allocator, io: Io, env: *std.process.Environ.Map, payload: common.Payload) !void {
    if (shouldSkipBash(payload)) return;

    const vault = common.vault(gpa, io, env) orelse return;
    defer gpa.free(vault);
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch return;
    if (st.kind != .directory) return; // a linked worktree has a file here, not a dir

    const cwd: std.process.Child.Cwd = .{ .path = vault };
    {
        const add = try adapters.process.run(io, gpa, &.{ "git", "add", "-A" }, .{ .cwd = cwd });
        defer add.deinit(gpa);
        if (!add.ok()) return;
    }
    {
        // Nothing staged is the common case; committing then would make an
        // empty commit on every edit.
        const diff = try adapters.process.run(io, gpa, &.{
            "git", "diff", "--cached", "--quiet",
        }, .{ .cwd = cwd });
        defer diff.deinit(gpa);
        if (diff.ok()) return;
    }
    const commit = try adapters.process.run(io, gpa, &.{
        "git", "commit", "--quiet", "-m", "auto: vault edit via Claude Code",
    }, .{ .cwd = cwd });
    defer commit.deinit(gpa);
    // A failed commit is silence: a hook shouldn't interrupt an unrelated turn.
}

/// True only for a `Bash` firing whose command isn't a `synapse vault-write`/
/// `vault-patch` call -- every other tool name (including an unparseable or
/// absent payload, e.g. a direct `sync` call in a test) is never skipped
/// here, preserving this hook's original unconditional behavior for the
/// signals `hooks.json` already named precisely (`Write`, `Edit`,
/// `mcp__obsidian__vault_*`).
fn shouldSkipBash(payload: common.Payload) bool {
    const name = payload.str("tool_name") orelse return false;
    if (!std.mem.eql(u8, name, "Bash")) return false;
    const cmd = payload.nested("tool_input", "command") orelse return true;
    return std.mem.indexOf(u8, cmd, "vault-write") == null and
        std.mem.indexOf(u8, cmd, "vault-patch") == null;
}

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

fn vaultGit(fx: *fixture.Fixture, args: []const []const u8) !adapters.process.Result {
    var argv_buf: [16][]const u8 = undefined;
    argv_buf[0] = "git";
    @memcpy(argv_buf[1 .. 1 + args.len], args);
    return adapters.process.run(fx.io(), fx.gpa, argv_buf[0 .. 1 + args.len], .{ .cwd = .{ .path = fx.vault } });
}

fn initVaultGitRepo(fx: *fixture.Fixture) !void {
    const init_vault = try vaultGit(fx, &.{ "init", "-q", "-b", "main" });
    init_vault.deinit(fx.gpa);
    const email = try vaultGit(fx, &.{ "config", "user.email", "t@e" });
    email.deinit(fx.gpa);
    const name = try vaultGit(fx, &.{ "config", "user.name", "t" });
    name.deinit(fx.gpa);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/seed.md", .data = "seed\n" });
    const add = try vaultGit(fx, &.{ "add", "seed.md" });
    add.deinit(fx.gpa);
    const commit = try vaultGit(fx, &.{ "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "seed" });
    commit.deinit(fx.gpa);
}

fn headSubject(fx: *fixture.Fixture, gpa: Allocator) ![]u8 {
    const res = try vaultGit(fx, &.{ "log", "-1", "--format=%s" });
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

test "a native Write/Edit firing (no payload at all) commits, matching the original unconditional behavior" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(gpa, "{}");
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("auto: vault edit via Claude Code", head);
}

test "an mcp__obsidian__vault_write firing commits, tool_name alone is enough" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(gpa, "{\"tool_name\":\"mcp__obsidian__vault_write\"}");
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("auto: vault edit via Claude Code", head);
}

test "a Bash firing running synapse vault-write commits" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(
        gpa,
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"synapse vault-write tasks/x.md\"}}",
    );
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("auto: vault edit via Claude Code", head);
}

test "a Bash firing running synapse vault-patch commits" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(
        gpa,
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"synapse vault-patch tasks/x.md --heading Notes --append\"}}",
    );
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("auto: vault edit via Claude Code", head);
}

test "a Bash firing running an unrelated command does not commit, even with real staged changes" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(
        gpa,
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}",
    );
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "a Bash firing with no command text at all does not commit" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try initVaultGitRepo(&fx);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/more.md", .data = "more\n" });

    var payload = common.parsedPayload(gpa, "{\"tool_name\":\"Bash\"}");
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload);

    const head = try headSubject(&fx, gpa);
    defer gpa.free(head);
    try testing.expectEqualStrings("seed", head);
}

test "no vault configured is a silent no-op, payload notwithstanding" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    _ = fx.env.swapRemove("SYNAPSE_VAULT_DIR");

    var payload = common.parsedPayload(gpa, "{}");
    defer payload.deinit();
    try sync(gpa, fx.io(), &fx.env, payload); // must not error
}
