//! `synapse graph-clean` and `synapse graph-wipe` -- the two destructive tools.
//!
//!   graph-clean [--dry-run]   remove namespaces whose branch was deleted upstream
//!   graph-wipe  [--dry-run]   remove this namespace, preserving hand-written Notes
//!
//! One file: both `rm -rf` a directory inside a permanent vault, recoverable
//! from the vault's own git history (`synapse-hook db-sync` commits every
//! edit) but not harmless, so both only remove a path inside
//! `{vault}/synapse/` whose name was just matched.
//!
//! `graph-clean` never deletes on an ambiguous signal -- the decision tree
//! is `core/graph_clean.zig`, and anything it can't confirm is *reported*
//! instead. It fetches `--prune` first, or a deleted branch's stale
//! remote-tracking ref makes every namespace look alive.
//!
//! `graph-wipe` deletes one namespace deliberately, so it stages every
//! node's hand-written `## Notes` content into `scratchpad/` first -- the
//! one thing a rebuild can't regenerate.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = context.Context;

// --- graph-clean ------------------------------------------------------------

const clean_prog = "synapse-graph-clean";

pub fn runClean(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var dry_run = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse graph-clean [--dry-run]\n", .{});
            return 0;
        } else {
            std.debug.print("usage: synapse graph-clean [--dry-run]\n", .{});
            return 2;
        }
    }

    var ctx = (try context.resolve(gpa, io, env, clean_prog)) orelse return 1;
    defer ctx.deinit();
    // The repo half of the key: walks every branch's namespace, not just this one.
    const repo = ctx.namespace[0 .. std.mem.indexOfScalar(u8, ctx.namespace, '@') orelse ctx.namespace.len];
    const cwd: std.process.Child.Cwd = .{ .path = ctx.repo_root };

    const has_remote = blk: {
        // Asked of `git remote` directly: `synapse_remote` falls back to the
        // repo root path, so it can't answer this.
        const res = try adapters.process.run(io, gpa, &.{ "git", "remote" }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        break :blk res.ok() and std.mem.trim(u8, res.stdout, " \t\r\n").len != 0;
    };

    if (has_remote and !dry_run) {
        // Not fatal: offline, the prune just doesn't happen and nothing is
        // removed -- erring toward keeping notes.
        const res = try adapters.process.run(io, gpa, &.{
            "git", "fetch", "--prune", "--quiet",
        }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        if (!res.ok()) std.debug.print(
            "{s}: fetch failed -- deciding from local refs, which may be stale\n",
            .{clean_prog},
        );
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    var removed: usize = 0;
    var reported: usize = 0;

    var names = try namespacesFor(gpa, io, ctx.vault, repo);
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    for (names.items) |ns| {
        const ns_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ ctx.vault, ns });
        defer gpa.free(ns_dir);
        const index_path = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{ns_dir});
        defer gpa.free(index_path);

        var branch: ?[]const u8 = null;
        const index_text = Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(64 << 20)) catch null;
        defer if (index_text) |t| gpa.free(t);
        if (index_text) |t| branch = core.query.field(t, "branch");

        const facts = try gatherFacts(gpa, io, cwd, branch, has_remote);
        defer freeFacts(gpa, facts);

        switch (core.graph_clean.classify(facts)) {
            .keep => {},
            .report => |reason| {
                try w.print("report\t{s}\t", .{ns});
                try core.graph_clean.reasonText(reason, branch orelse "", w);
                try w.writeAll("\n");
                reported += 1;
            },
            .remove => |up| {
                if (dry_run) {
                    try w.print("would-remove\t{s}\tupstream {s}/{s} is gone\n", .{
                        ns, up.upstream_remote, up.upstream_branch,
                    });
                } else {
                    if (!try removeNamespace(gpa, io, ctx.vault, ns_dir, clean_prog)) continue;
                    try w.print("removed\t{s}\tupstream {s}/{s} is gone\n", .{
                        ns, up.upstream_remote, up.upstream_branch,
                    });
                }
                removed += 1;
            },
        }
    }

    if (removed == 0 and reported == 0) try w.writeAll("nothing to clean\n");
    try w.flush();
    return 0;
}

fn gatherFacts(
    gpa: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    branch: ?[]const u8,
    has_remote: bool,
) !core.graph_clean.Facts {
    var facts: core.graph_clean.Facts = .{
        .branch = branch,
        .has_remote = has_remote,
        .local_exists = false,
        .upstream_remote = null,
        .upstream_branch = null,
        .upstream_ref_exists = false,
    };
    const b = branch orelse return facts;
    if (b.len == 0) return facts;

    facts.local_exists = try refExists(gpa, io, cwd, "refs/heads/", b);
    facts.upstream_remote = try gitConfig(gpa, io, cwd, "branch.", b, ".remote");
    if (try gitConfig(gpa, io, cwd, "branch.", b, ".merge")) |merge| {
        // Strip `refs/heads/` -- the form the remote-tracking ref uses.
        const short = if (std.mem.startsWith(u8, merge, "refs/heads/"))
            try gpa.dupe(u8, merge["refs/heads/".len..])
        else
            try gpa.dupe(u8, merge);
        gpa.free(merge);
        facts.upstream_branch = short;
    }
    if (facts.upstream_remote) |ur| if (facts.upstream_branch) |ub| {
        const prefix = try std.fmt.allocPrint(gpa, "refs/remotes/{s}/", .{ur});
        defer gpa.free(prefix);
        facts.upstream_ref_exists = try refExists(gpa, io, cwd, prefix, ub);
    };
    return facts;
}

fn freeFacts(gpa: Allocator, facts: core.graph_clean.Facts) void {
    if (facts.upstream_remote) |s| gpa.free(s);
    if (facts.upstream_branch) |s| gpa.free(s);
}

fn refExists(
    gpa: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    prefix: []const u8,
    name: []const u8,
) !bool {
    const ref = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
    defer gpa.free(ref);
    const res = try adapters.process.run(io, gpa, &.{
        "git", "show-ref", "--verify", "--quiet", ref,
    }, .{ .cwd = cwd });
    defer res.deinit(gpa);
    return res.ok();
}

fn gitConfig(
    gpa: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    prefix: []const u8,
    name: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const key = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, name, suffix });
    defer gpa.free(key);
    const res = try adapters.process.run(io, gpa, &.{ "git", "config", "--get", key }, .{ .cwd = cwd });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const value = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (value.len == 0) return null;
    return try gpa.dupe(u8, value);
}

/// Every `{repo}@*` namespace directory in the vault, byte-sorted.
fn namespacesFor(
    gpa: Allocator,
    io: Io,
    vault: []const u8,
    repo: []const u8,
) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    const root = try std.fmt.allocPrint(gpa, "{s}/synapse", .{vault});
    defer gpa.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    const prefix = try std.fmt.allocPrint(gpa, "{s}@", .{repo});
    defer gpa.free(prefix);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out;
}

/// `rm -rf`, but only ever inside `{vault}/synapse/` -- a recursive delete
/// on a resolved path is one substitution away from a much larger one.
fn removeNamespace(
    gpa: Allocator,
    io: Io,
    vault: []const u8,
    ns_dir: []const u8,
    prog: []const u8,
) !bool {
    const allowed = try std.fmt.allocPrint(gpa, "{s}/synapse/", .{vault});
    defer gpa.free(allowed);
    if (!std.mem.startsWith(u8, ns_dir, allowed) or ns_dir.len == allowed.len) {
        std.debug.print("{s}: refusing to remove {s}\n", .{ prog, ns_dir });
        return false;
    }
    Io.Dir.cwd().deleteTree(io, ns_dir) catch {
        std.debug.print("{s}: could not remove {s}\n", .{ prog, ns_dir });
        return false;
    };
    return true;
}

// --- graph-wipe -------------------------------------------------------------

const wipe_prog = "synapse-graph-wipe";

pub fn runWipe(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    var dry_run = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: synapse graph-wipe [--dry-run]\n", .{});
            return 0;
        } else {
            std.debug.print("usage: synapse graph-wipe [--dry-run]\n", .{});
            return 2;
        }
    }

    var ctx = (try context.resolve(gpa, io, env, wipe_prog)) orelse return 1;
    defer ctx.deinit();

    if (Io.Dir.cwd().statFile(io, ctx.abs_dir, .{})) |_| {} else |_| {
        std.debug.print(
            "{s}: no namespace at {s} -- nothing to wipe (first build? use /synapse-init)\n",
            .{ wipe_prog, ctx.dir },
        );
        return 1;
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    var files = try context.listNodeFiles(&ctx, io);
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var preserved: Io.Writer.Allocating = .init(gpa);
    defer preserved.deinit();
    var at_risk: usize = 0;
    for (files.items) |file| {
        const text = try context.readNode(&ctx, io, file) orelse continue;
        defer gpa.free(text);
        const notes = core.emit.notesBody(text);
        if (notes.len == 0) continue;
        at_risk += 1;
        const title = context.stripMd(file);
        try w.print("at-risk\t{s}\thas hand-written ## Notes content\n", .{title});
        try preserved.writer.print("## {s}\n\n{s}\n\n", .{ title, notes });
    }

    try w.print("namespace: {s} ({d} nodes, {d} with ## Notes content)\n", .{
        ctx.dir, files.items.len, at_risk,
    });

    if (dry_run) {
        try w.print("would-remove {s}\n", .{ctx.dir});
        try w.flush();
        return 0;
    }

    if (preserved.written().len != 0) {
        const staged = try stagePreserved(gpa, io, &ctx, preserved.written());
        defer gpa.free(staged);
        try w.print("preserved -> {s}\n", .{staged});
    }

    if (!try removeNamespace(gpa, io, ctx.vault, ctx.abs_dir, wipe_prog)) {
        try w.flush();
        return 1;
    }
    try w.print("removed {s}\n", .{ctx.dir});
    try w.flush();
    return 0;
}

/// Writes recovered Notes into `scratchpad/`, returns the vault-relative
/// path. Direct filesystem write, not the API -- must succeed before the
/// delete that follows it.
fn stagePreserved(gpa: Allocator, io: Io, ctx: *const Context, body: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(gpa, "{s}/scratchpad", .{ctx.vault});
    defer gpa.free(dir);
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    const rel = try std.fmt.allocPrint(
        gpa,
        "scratchpad/{s} — preserved notes before full rebuild.md",
        .{ctx.namespace},
    );
    errdefer gpa.free(rel);
    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.vault, rel });
    defer gpa.free(full);

    const stamp = blk: {
        const res = try adapters.process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M" }, .{});
        defer res.deinit(gpa);
        break :blk try gpa.dupe(u8, if (res.ok()) std.mem.trim(u8, res.stdout, " \t\r\n") else "");
    };
    defer gpa.free(stamp);

    var note: Io.Writer.Allocating = .init(gpa);
    defer note.deinit();
    try note.writer.print(
        "---\ntitle: \"{s} — preserved notes before full rebuild\"\ncreated: \"{s}\"\n---\n\n",
        .{ ctx.namespace, stamp },
    );
    try note.writer.print("# {s} — preserved notes before full rebuild\n\n", .{ctx.namespace});
    try note.writer.print(
        "Hand-written `## Notes` content recovered from `synapse/{s}` before it was wiped for a full rebuild. `/synapse-rebuild-full` merges what it can back into the new nodes once the rebuild completes; whatever is still here after that needs a manual look.\n\n",
        .{ctx.namespace},
    );
    try note.writer.writeAll(body);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = note.written() });
    return rel;
}
