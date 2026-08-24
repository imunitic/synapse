//! `synapse-hook db-sync` -- PostToolUse on a vault mutation.
//!
//! Commits any agent-driven vault change to the vault's own local git repo,
//! if one exists -- opt-in per vault, so a vault with no `.git` is an
//! ordinary no-op. Registered against the MCP vault tools as well as native
//! Write/Edit, since `/synapse-note`/`synapse-task` write through
//! `mcp__obsidian__vault_*` rather than editing files. This is the
//! vault-wide undo: `git show <sha>:<path>` only works because every edit
//! is committed, not just intentional ones.
//!
//! No pull here, deliberately, even though a phone-side edit (Obsidian's
//! own git-sync plugin, say) is exactly what a pull would catch: this fires
//! per tool call, several times a turn, and network I/O has no business on
//! that path. The pull lives in `stop_nudge.zig` instead -- once, detached,
//! at SessionStart, plus periodically alongside the same file's throttled
//! push -- for the identical reason the push already lives there and not
//! here.

const std = @import("std");
const adapters = @import("adapters");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
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
