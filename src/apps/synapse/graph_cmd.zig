//! `synapse graph-clean` and `synapse graph-wipe` -- the two destructive tools.
//!
//!   graph-clean [--dry-run]   remove namespaces whose branch was deleted upstream
//!   graph-wipe  [--dry-run]   remove this namespace, preserving hand-written Notes
//!
//! One file: both `rm -rf` a directory inside a permanent vault -- on a
//! `SYNAPSE_VAULT_STORE=git` vault, recoverable from its own git history
//! (`GitStore` commits every edit), but not harmless regardless of backend,
//! so both only remove a path inside `{vault}/synapse/` whose name was just
//! matched.
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

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try clean(gpa, io, env, dry_run, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture repo directly.
pub fn clean(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    dry_run: bool,
    w: *Io.Writer,
) !u8 {
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

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const code = try wipe(gpa, io, env, dry_run, &out.interface);
    try out.interface.flush();
    return code;
}

/// The command itself, minus argument parsing -- separated so a test can
/// drive it against a real fixture `Context` directly.
pub fn wipe(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    dry_run: bool,
    w: *Io.Writer,
) !u8 {
    var ctx = (try context.resolve(gpa, io, env, wipe_prog)) orelse return 1;
    defer ctx.deinit();

    if (Io.Dir.cwd().statFile(io, ctx.abs_dir, .{})) |_| {} else |_| {
        std.debug.print(
            "{s}: no namespace at {s} -- nothing to wipe (first build? use /synapse-init)\n",
            .{ wipe_prog, ctx.dir },
        );
        return 1;
    }

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
        return 0;
    }

    if (preserved.written().len != 0) {
        const staged = try stagePreserved(gpa, io, &ctx, preserved.written());
        defer gpa.free(staged);
        try w.print("preserved -> {s}\n", .{staged});
    }

    if (!try removeNamespace(gpa, io, ctx.vault, ctx.abs_dir, wipe_prog)) return 1;
    try w.print("removed {s}\n", .{ctx.dir});
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

const testing = std.testing;
const fixture = @import("cmd_test_support.zig");

/// `Node A.md` has hand-written `## Notes` content (at risk); `Node B.md`
/// has the section present but empty (not at risk) -- the exact shape
/// `write-node` produces, not a simplified stand-in, since the extraction
/// logic depends on the literal generated-fence markers.
fn makeNamespace(fx: *fixture.Fixture) !void {
    try fx.writeIndex("", "main");
    try fx.writeNodeFile("Node A",
        \\---
        \\title: "Node A"
        \\summary: "Node A in one line."
        \\node_type: synapse-node
        \\---
        \\
        \\# Node A
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Generated stuff about Node A.
        \\
        \\## Sources
        \\- `src` (1)
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\Hand-written finding worth keeping: the retry logic here is load-bearing for the batch job, do not simplify it away.
        \\
    );
    try fx.writeNodeFile("Node B",
        \\---
        \\title: "Node B"
        \\summary: "Node B in one line."
        \\node_type: synapse-node
        \\---
        \\
        \\# Node B
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Generated stuff about Node B.
        \\
        \\## Sources
        \\- `src` (1)
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\
    );
}

fn stagingNotePath(gpa: Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "vault/scratchpad/repo@main — preserved notes before full rebuild.md", .{});
}

test "--dry-run reports node count and which nodes are at risk, deletes nothing" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeNamespace(&fx);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, true, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "2 nodes") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 with ## Notes content") != null);
    try testing.expect(std.mem.indexOf(u8, text, "at-risk\tNode A") != null);
    try testing.expect(std.mem.indexOf(u8, text, "at-risk\tNode B") == null);
    try testing.expect(std.mem.indexOf(u8, text, "would-remove") != null);

    try testing.expect(try fx.nodeExists("Node A"));
    const staging = try stagingNotePath(gpa);
    defer gpa.free(staging);
    try testing.expectEqual(error.FileNotFound, fx.tmp.dir.access(testing.io, staging, .{}));
}

test "a real run preserves hand-written ## Notes verbatim to a scratchpad staging note, then deletes the namespace" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeNamespace(&fx);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "preserved ->") != null);
    try testing.expect(std.mem.indexOf(u8, text, "removed synapse/repo@main") != null);

    try testing.expectEqual(error.FileNotFound, fx.tmp.dir.access(testing.io, "vault/synapse/repo@main", .{}));
    const staging = try stagingNotePath(gpa);
    defer gpa.free(staging);
    const staged = try fx.tmp.dir.readFileAlloc(testing.io, staging, gpa, .limited(1 << 20));
    defer gpa.free(staged);
    try testing.expect(std.mem.indexOf(u8, staged, "retry logic here is load-bearing") != null);
    try testing.expect(std.mem.indexOf(u8, staged, "## Node A\n") != null);
    // Node B had nothing worth keeping and must not clutter the staging note.
    try testing.expect(std.mem.indexOf(u8, staged, "## Node B\n") == null);
}

test "a node with an empty ## Notes section is never flagged or preserved" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeIndex("", "main");
    try fx.writeNodeFile("Node B",
        \\---
        \\title: "Node B"
        \\---
        \\
        \\# Node B
        \\<!-- synapse:generated:start -->
        \\
        \\## Summary
        \\Nothing notable.
        \\<!-- synapse:generated:end -->
        \\
        \\## Notes
        \\
        \\
    );

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    try testing.expect(std.mem.indexOf(u8, out.written(), "0 with ## Notes content") != null);
    const staging = try stagingNotePath(gpa);
    defer gpa.free(staging);
    try testing.expectEqual(error.FileNotFound, fx.tmp.dir.access(testing.io, staging, .{}));
    try testing.expectEqual(error.FileNotFound, fx.tmp.dir.access(testing.io, "vault/synapse/repo@main", .{}));
}

test "no namespace at all refuses cleanly rather than wiping nothing silently" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    // No Index.md, no nodes -- the namespace directory itself never exists.

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, false, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
}

test "--dry-run on a namespace with no ## Notes at risk still reports cleanly" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try fx.writeIndex("", "main");
    // Index.md exists, no node files at all.

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, true, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "0 nodes") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0 with ## Notes content") != null);
}

test "another namespace in the same vault is never touched" {
    const gpa = testing.allocator;
    var fx = try fixture.Fixture.init(gpa);
    defer fx.deinit();
    try makeNamespace(&fx);
    try fx.tmp.dir.createDirPath(testing.io, "vault/synapse/unrelated-project@main");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "vault/synapse/unrelated-project@main/Index.md",
        .data = "---\nbranch: main\n---\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try wipe(gpa, fx.io(), &fx.env, false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);

    try fx.tmp.dir.access(testing.io, "vault/synapse/unrelated-project@main", .{});
}

/// Real refs, real upstream config, real pruning -- the entire subject of
/// `graph-clean`'s decision tree, so no fake git here. `commit()` (real git
/// spawns) is a separate step from `init()`, called by every test right
/// after construction -- see `BriefFixture`'s own comment in `brief_cmd.zig`
/// for why that split matters.
const CleanFixture = struct {
    fx: fixture.Fixture,

    fn init(gpa: Allocator) !CleanFixture {
        const fx = try fixture.Fixture.init(gpa);
        return .{ .fx = fx };
    }

    fn deinit(self: *CleanFixture) void {
        self.fx.deinit();
    }

    fn commit(self: *CleanFixture) !void {
        // A real file first: `git commit` with nothing staged exits nonzero
        // and `gitCommit()` doesn't check that -- an empty first commit leaves
        // every branch this helper creates on an unborn HEAD: `git rev-parse
        // --abbrev-ref HEAD` returns the literal string "HEAD" instead of a
        // real branch name.
        try self.fx.writeRepoFile("README.md", "seed\n");
        try self.fx.gitCommit("init");
    }

    /// A real bare remote, added as `origin` and pushed to once (`HEAD` on
    /// whatever branch is currently checked out). Caller frees.
    fn addRemote(self: *CleanFixture) ![]u8 {
        const gpa = self.fx.gpa;
        const remote = try std.fmt.allocPrint(gpa, "{s}/remote.git", .{self.fx.root});
        errdefer gpa.free(remote);
        const init_res = try adapters.process.run(self.fx.io(), gpa, &.{ "git", "init", "-q", "--bare", remote }, .{});
        init_res.deinit(gpa);
        const add_res = try self.fx.git(&.{ "remote", "add", "origin", remote });
        add_res.deinit(gpa);
        const push_res = try self.fx.git(&.{ "push", "-q", "-u", "origin", "HEAD" });
        push_res.deinit(gpa);
        return remote;
    }

    fn checkout(self: *CleanFixture, branch: []const u8) !void {
        const res = try self.fx.git(&.{ "checkout", "-q", "-b", branch });
        res.deinit(self.fx.gpa);
    }

    fn push(self: *CleanFixture, branch: []const u8) !void {
        const res = try self.fx.git(&.{ "push", "-q", "-u", "origin", branch });
        res.deinit(self.fx.gpa);
    }

    fn deleteRemoteBranch(self: *CleanFixture, branch: []const u8) !void {
        const res = try self.fx.git(&.{ "push", "-q", "origin", "--delete", branch });
        res.deinit(self.fx.gpa);
    }

    fn fetchPrune(self: *CleanFixture) !void {
        const res = try self.fx.git(&.{ "fetch", "--prune", "-q" });
        res.deinit(self.fx.gpa);
    }

    /// `repo@{branch, slashes dashed}`, with the real `branch:`/`remote:`
    /// fields the cleaner reads. Content beyond that is a stand-in -- what
    /// matters is that it is a directory of notes that must not vanish by
    /// accident. Caller frees.
    fn writeNamespace(self: *CleanFixture, branch: []const u8, remote: []const u8) ![]u8 {
        const gpa = self.fx.gpa;
        const dashed = try gpa.dupe(u8, branch);
        defer gpa.free(dashed);
        for (dashed) |*c| {
            if (c.* == '/') c.* = '-';
        }
        const ns = try std.fmt.allocPrint(gpa, "repo@{s}", .{dashed});
        errdefer gpa.free(ns);

        const dir = try std.fmt.allocPrint(gpa, "vault/synapse/{s}", .{ns});
        defer gpa.free(dir);
        try self.fx.tmp.dir.createDirPath(testing.io, dir);
        const idx = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{dir});
        defer gpa.free(idx);
        const data = try std.fmt.allocPrint(
            gpa,
            "---\ntitle: \"{s} — Synapse index\"\nnode_type: synapse-index\nproject: repo\nbranch: {s}\nremote: \"{s}\"\nbuilt_at: \"test\"\n---\n# {s}\n",
            .{ ns, branch, remote, ns },
        );
        defer gpa.free(data);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = idx, .data = data });
        const node_path = try std.fmt.allocPrint(gpa, "{s}/Some Node.md", .{dir});
        defer gpa.free(node_path);
        try self.fx.tmp.dir.writeFile(testing.io, .{ .sub_path = node_path, .data = "a node\n" });
        return ns;
    }

    /// A namespace with no `branch:` field at all -- deliberately malformed.
    fn writeMysteryNamespace(self: *CleanFixture) !void {
        try self.fx.tmp.dir.createDirPath(testing.io, "vault/synapse/repo@mystery");
        try self.fx.tmp.dir.writeFile(testing.io, .{
            .sub_path = "vault/synapse/repo@mystery/Index.md",
            .data = "---\ntitle: \"x\"\nremote: \"y\"\n---\n",
        });
    }

    fn nsExists(self: *CleanFixture, ns: []const u8) !bool {
        const dir = try std.fmt.allocPrint(self.fx.gpa, "vault/synapse/{s}", .{ns});
        defer self.fx.gpa.free(dir);
        self.fx.tmp.dir.access(testing.io, dir, .{}) catch return false;
        return true;
    }

    fn run(self: *CleanFixture, dry_run: bool, w: *Io.Writer) !u8 {
        return clean(self.fx.gpa, self.fx.io(), &self.fx.env, dry_run, w);
    }
};

test "a branch whose upstream was deleted is removed" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.checkout("feature/gone");
    try cf.push("feature/gone");
    const ns = try cf.writeNamespace("feature/gone", remote);
    defer gpa.free(ns);
    // Merged and deleted on the remote, which is what the command exists for.
    try cf.deleteRemoteBranch("feature/gone");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "removed") != null);
    try testing.expect(!try cf.nsExists(ns));
}

test "a branch that was never pushed and still exists is kept" {
    // The failure that would matter most: deleting the namespace of the
    // branch someone is working on right now, because it has no remote
    // counterpart.
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.checkout("local-only-wip");
    const ns = try cf.writeNamespace("local-only-wip", remote);
    defer gpa.free(ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try cf.nsExists(ns));
    try testing.expect(std.mem.indexOf(u8, out.written(), "removed") == null);
}

test "a branch still present on the remote is kept" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.checkout("alive");
    try cf.push("alive");
    const ns = try cf.writeNamespace("alive", remote);
    defer gpa.free(ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try cf.nsExists(ns));
}

test "a remoteless repo keeps every namespace whose branch still exists" {
    // Without the no-remote fallback the first run here would read every
    // namespace as "upstream gone" and wipe the lot.
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    try cf.checkout("work");
    const ns = try cf.writeNamespace("work", "");
    defer gpa.free(ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try cf.nsExists(ns));
    try testing.expect(std.mem.indexOf(u8, out.written(), "removed") == null);
}

test "a gone branch in a remoteless repo is reported, never removed" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const ns = try cf.writeNamespace("vanished", "");
    defer gpa.free(ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "report") != null);
    try testing.expect(try cf.nsExists(ns));
}

test "a branch absent locally with no upstream config is reported, not removed" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    const ns = try cf.writeNamespace("never-existed", remote);
    defer gpa.free(ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "report") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "removed") == null);
    try testing.expect(try cf.nsExists(ns));
}

test "a namespace with no branch field is reported rather than guessed at" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.writeMysteryNamespace();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "no branch field") != null);
    try testing.expect(try cf.nsExists("repo@mystery"));
}

test "the branch field, not the directory name, decides -- sanitizing is not reversible" {
    // The directory is `repo@feature-slashed`, which could be branch
    // `feature/slashed` or a branch literally named `feature-slashed`. Only
    // the field knows.
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.checkout("feature/slashed");
    try cf.push("feature/slashed");
    const ns = try cf.writeNamespace("feature/slashed", remote);
    defer gpa.free(ns);
    try testing.expectEqualStrings("repo@feature-slashed", ns);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(try cf.nsExists(ns)); // still on the remote, so kept
}

test "--dry-run reports what it would remove and deletes nothing" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.checkout("doomed");
    try cf.push("doomed");
    const ns = try cf.writeNamespace("doomed", remote);
    defer gpa.free(ns);
    try cf.deleteRemoteBranch("doomed");
    try cf.fetchPrune();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(true, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "would-remove") != null);
    try testing.expect(try cf.nsExists(ns));
}

test "another repo's namespaces are never touched" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);
    try cf.fx.tmp.dir.createDirPath(testing.io, "vault/synapse/unrelated-project@main");
    try cf.fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "vault/synapse/unrelated-project@main/Index.md",
        .data = "---\nbranch: main\n---\n",
    });

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try cf.fx.tmp.dir.access(testing.io, "vault/synapse/unrelated-project@main", .{});
}

test "nothing to clean says so, rather than exiting mute" {
    const gpa = testing.allocator;
    var cf = try CleanFixture.init(gpa);
    defer cf.deinit();
    try cf.commit();
    const remote = try cf.addRemote();
    defer gpa.free(remote);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const code = try cf.run(false, &out.writer);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nothing to clean") != null);
}
