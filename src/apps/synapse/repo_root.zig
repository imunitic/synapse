//! Resolves a checkout's root by spawning `git rev-parse --show-toplevel` --
//! deliberately a real subprocess call, unlike `context.zig`'s own
//! `.git`/`HEAD`/`config` resolution, which stays spawn-free on purpose.
//! Several `*_cmd.zig` commands accept a bare `--repo <dir>` pointing
//! anywhere inside a checkout, not necessarily its root, and need the real
//! root before doing anything path-relative.

const std = @import("std");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Empty string, not an error, when `repo` isn't inside a git checkout at
/// all or the spawn itself fails -- callers already treat an empty root as
/// "couldn't resolve," matching how every one of them handled the
/// unresolvable case before this was pulled out to one place.
pub fn resolve(gpa: Allocator, io: Io, repo: ?[]const u8) ![]u8 {
    const res = adapters.process.run(io, gpa, &.{ "git", "rev-parse", "--show-toplevel" }, .{
        .cwd = if (repo) |r| .{ .path = r } else .inherit,
    }) catch return gpa.dupe(u8, "");
    defer res.deinit(gpa);
    if (!res.ok()) return gpa.dupe(u8, "");
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}
