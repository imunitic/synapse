//! Resolving a namespace from a checkout, by asking git.
//!
//! An adapter rather than part of `core/identity.zig`, because it spawns: `core` takes
//! an injected `std.Io` and spawns nothing. What is here is only the three questions
//! git has to answer -- where is the repo root, what is the remote, which branch is
//! checked out -- and `core.identity` turns those answers into a key.
//!
//! ## Three spawns, and why not zero
//!
//! Reading `.git` directly would be spawn-free and wrong; `core/identity.zig`'s header
//! has the reason (`insteadOf` rewriting). Three spawns once per process is the price,
//! against the shell library's own three-to-six per call and its `basename` on top.

const std = @import("std");
const core = @import("core");
const process = @import("process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Everything a component needs to name the namespace it belongs to.
pub const Identity = struct {
    repo_root: []const u8,
    /// The remote URL used as identity, or the repo root when there is none.
    remote: []const u8,
    /// The branch as git reports it, unsanitised.
    branch: []const u8,
    /// The branch as a directory name.
    branch_key: []const u8,
    /// `{repo}@{branch_key}`.
    key: []const u8,

    pub fn deinit(self: Identity, gpa: Allocator) void {
        gpa.free(self.repo_root);
        gpa.free(self.remote);
        gpa.free(self.branch);
        gpa.free(self.branch_key);
        gpa.free(self.key);
    }
};

pub const Error = error{
    NotAGitRepo,
    /// A detached HEAD has no branch and therefore no namespace. Not a failure of
    /// this function -- the correct answer for that checkout.
    DetachedHead,
};

/// Resolve the namespace for the repository containing `cwd`.
pub fn resolve(gpa: Allocator, io: Io, cwd: []const u8) !Identity {
    const root = try gitOut(gpa, io, cwd, &.{ "rev-parse", "--show-toplevel" }) orelse
        return Error.NotAGitRepo;
    errdefer gpa.free(root);

    // `symbolic-ref`, never `rev-parse --abbrev-ref` -- see `core.identity`'s
    // `detached_message` for both reasons.
    const branch = try gitOut(gpa, io, root, &.{ "symbolic-ref", "--short", "HEAD" }) orelse
        return Error.DetachedHead;
    errdefer gpa.free(branch);

    const remote = try resolveRemote(gpa, io, root);
    errdefer gpa.free(remote);

    const branch_key = try core.identity.sanitizeBranch(gpa, branch);
    errdefer gpa.free(branch_key);
    const key = try core.identity.namespace(gpa, core.identity.repoName(remote), branch_key);

    return .{
        .repo_root = root,
        .remote = remote,
        .branch = branch,
        .branch_key = branch_key,
        .key = key,
    };
}

/// `origin`, else the first listed remote, else the repo root path.
///
/// Unchanged from what every component already did. A repo with no remote at all still
/// gets a stable value, and refusing those outright would turn a working local-only
/// project into an error.
fn resolveRemote(gpa: Allocator, io: Io, root: []const u8) ![]u8 {
    if (try gitOut(gpa, io, root, &.{ "remote", "get-url", "origin" })) |origin| return origin;
    if (try gitOut(gpa, io, root, &.{"remote"})) |list| {
        defer gpa.free(list);
        var lines = std.mem.splitScalar(u8, list, '\n');
        if (lines.next()) |first| {
            if (first.len != 0) {
                if (try gitOut(gpa, io, root, &.{ "remote", "get-url", first })) |url| return url;
            }
        }
    }
    return gpa.dupe(u8, root);
}

/// One git call's trimmed stdout, or null when it failed or said nothing.
fn gitOut(gpa: Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !?[]u8 {
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, "git");
    try full.appendSlice(gpa, argv);

    const res = try process.run(io, gpa, full.items, .{ .cwd = .{ .path = cwd } });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}
