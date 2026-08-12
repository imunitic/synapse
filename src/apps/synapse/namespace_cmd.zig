//! `synapse namespace` -- print the namespace key for a checkout.
//!
//!   namespace [--repo <dir>]   `{repo}@{branch}`
//!   namespace --branch         the branch half, sanitised
//!   namespace --repo-name      the repo half
//!
//! The one thing `synapse-identity.sh` was for that had no other home. Every
//! component resolves its own namespace now, so nothing internal needs this -- but
//! two callers outside the binary do, and both have the same reason: they must not
//! reimplement the derivation.
//!
//! `tests/test_helper.bash` builds every fixture path from it, and its comment says
//! why it delegates rather than deriving: *"a test helper with its own copy of the
//! rule could agree with a wrong implementation"*. And a person debugging an install
//! needs to see which namespace a checkout resolves to, which is otherwise only
//! visible in an error message about a namespace not covering it.
//!
//! Exit 1 outside a repo or on a detached HEAD, with the same wording every other
//! subcommand uses -- a detached HEAD has no branch, so there is no namespace, and
//! that is an answer rather than a failure.

const std = @import("std");
const core = @import("core");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-namespace";

const usage_text =
    \\usage: synapse namespace [--repo <dir>] [--branch|--repo-name]
    \\
    \\  --repo       the checkout to resolve. Default: the one containing $PWD.
    \\  --branch     print only the branch half, sanitised for a directory name
    \\  --repo-name  print only the repo half
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    _ = env;
    var repo: []const u8 = ".";
    const Want = enum { key, branch, repo_name };
    var want: Want = .key;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            repo = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--branch")) {
            want = .branch;
        } else if (std.mem.eql(u8, arg, "--repo-name")) {
            want = .repo_name;
        } else return usage();
    }

    const id = core.identity.resolve(gpa, io, repo) catch |e| {
        switch (e) {
            error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
            error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
            else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
        }
        return 1;
    };
    defer id.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    // No trailing newline on the key: every caller substitutes it into a path, and
    // `$(…)` strips one newline anyway -- printing none means a caller that does not
    // use a substitution gets the same bytes.
    try out.interface.writeAll(switch (want) {
        .key => id.key,
        .branch => id.branch_key,
        .repo_name => core.identity.repoName(id.remote),
    });
    try out.interface.flush();
    return 0;
}

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}
