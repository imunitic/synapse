//! `synapse namespace` -- print the namespace key for a checkout.
//!
//!   namespace [--repo <dir>]   `{repo}@{branch}`
//!   namespace --branch         the branch half, sanitised
//!   namespace --repo-name      the repo half
//!
//! Two external callers need this rather than reimplementing the
//! derivation: `tests/test_helper.bash` builds fixture paths from it, and a
//! person debugging an install wants to see the resolved namespace.
//!
//! Exit 1 outside a repo or on a detached HEAD -- no branch means no
//! namespace, which is an answer, not a failure.

const std = @import("std");
const core = @import("core");
const cli_args = @import("cli_args.zig");

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
            repo = cli_args.takenValue(args.next()) orelse return usage();
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
    // No trailing newline: callers substitute this into a path, and `$(…)`
    // strips one anyway.
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
