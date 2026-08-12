//! `synapse-hook db-sync` -- PostToolUse on a vault mutation.
//!
//! Commits any agent-driven vault change to the vault's own local git repo, if one
//! exists. **Opt-in per vault, not assumed**: a vault with no `.git` is a supported,
//! ordinary configuration, so the whole hook is a no-op there.
//!
//! Registered against the MCP vault tools as well as native Write/Edit, because
//! `/synapse-note` and the `synapse-task` skill write through
//! `mcp__obsidian__vault_*` rather than editing files.
//!
//! This is the vault-wide undo every other destructive tool call leans on: the
//! `synapse-vault` skill's answer to "if you do destroy something" is `git show
//! <sha>:<path>` in this repo, which only works because this hook commits on every
//! edit rather than only on intentional ones.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const vault = common.vault(io, env) orelse return;
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    // A `.git` *directory*, as `[ -d ]` tested: a vault that is a linked worktree
    // has a file there, and this hook has never been claimed to handle that.
    const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch return;
    if (st.kind != .directory) return;

    const cwd: std.process.Child.Cwd = .{ .path = vault };
    {
        const add = try adapters.process.run(io, gpa, &.{ "git", "add", "-A" }, .{ .cwd = cwd });
        defer add.deinit(gpa);
        if (!add.ok()) return;
    }
    {
        // Nothing staged is the common case -- a tool call that changed no bytes --
        // and committing then would make an empty commit on every edit.
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
    // A failed commit is silence, as `|| true` made it: a hook that reports a git
    // problem interrupts a turn about something else entirely.
}
