//! `synapse comments-check <path>` -- Tier 2 of docstring staleness
//! detection for one file: a real parse via `docstring_check.checkFile`,
//! reporting what's new or changed and refreshing the index. Read-time,
//! scoped to whatever file is already being read -- not edit-time (that's
//! `synapse-hook`'s Tier 1) and not a whole-repo sweep (`comments-sweep`).

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const docstring_check = @import("docstring_check.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-comments-check";

const usage_text =
    \\usage: synapse comments-check <path>
    \\
    \\  Checks one file's docstrings against the docstring index, refreshing
    \\  it with what a fresh parse finds. Silent to stdout when nothing is
    \\  new or changed. Requires SYNAPSE_DOCSTRING_STALENESS_DETECTION (see
    \\  synapse.conf) -- a no-op otherwise.
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    const path_arg = args.next() orelse {
        std.debug.print("{s}", .{usage_text});
        return 2;
    };
    if (std.mem.eql(u8, path_arg, "-h") or std.mem.eql(u8, path_arg, "--help")) {
        std.debug.print("{s}", .{usage_text});
        return 0;
    }

    const id = core.identity.resolve(gpa, io, ".") catch |e| {
        switch (e) {
            error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
            error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
            else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
        }
        return 1;
    };
    defer id.deinit(gpa);
    const repo_root = id.layout.repo_root;

    const wd = (try context.workDirFor(gpa, io, env, ".", prog)) orelse {
        std.debug.print("{s}: could not resolve a work directory\n", .{prog});
        return 1;
    };
    defer wd.deinit(gpa);

    // `std.fs.path.resolve` is purely lexical -- it never consults the
    // real cwd, so a relative `path_arg` needs it joined in explicitly
    // before normalizing.
    const abs_path = if (std.fs.path.isAbsolute(path_arg)) blk: {
        break :blk try std.fs.path.resolve(gpa, &.{path_arg});
    } else blk: {
        // `Dir.cwd().realPath` directly on the bare cwd handle fails --
        // `core.identity.zig`'s own equivalent helper opens the target
        // first (`Dir.cwd().openDir(io, ".", .{})`) and calls `realPath`
        // on *that* handle instead.
        var cwd_dir = try Io.Dir.cwd().openDir(io, ".", .{});
        defer cwd_dir.close(io);
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd = buf[0..try cwd_dir.realPath(io, &buf)];
        break :blk try std.fs.path.resolve(gpa, &.{ cwd, path_arg });
    };
    defer gpa.free(abs_path);

    const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{repo_root});
    defer gpa.free(prefix);
    if (!std.mem.startsWith(u8, abs_path, prefix)) {
        std.debug.print("{s}: {s} is not inside {s}\n", .{ prog, path_arg, repo_root });
        return 1;
    }
    const rel_path = abs_path[prefix.len..];

    const result = try docstring_check.checkFile(gpa, io, env, repo_root, wd.path, rel_path);
    defer if (result.report) |r| gpa.free(r);

    if (result.report) |r| {
        var buf: [4096]u8 = undefined;
        var out = Io.File.stdout().writer(io, &buf);
        try out.interface.writeAll(r);
        try out.interface.flush();
    }
    return 0;
}
