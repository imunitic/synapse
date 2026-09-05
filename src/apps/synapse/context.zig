//! The shared preamble `synapse-query.sh` and `synapse-write-node.sh` each
//! used to run separately: find the vault, resolve the namespace, load the
//! module boilerplate, refuse if `Index.md` names a different repo/branch.
//! One resolution chain, not two that could disagree.
//!
//! Identity resolves from `.git`/`HEAD`/`config` (no spawn); the environment
//! still wins when set, which is how a test fixture pins a namespace/repo
//! deliberately without needing a real git remote. Reads
//! (`Index.md`, a node, `_manifest.tsv`) go straight to disk -- a known path
//! never needs a search round trip. Writes (`write-node`) go through
//! `Store`, which keeps an extended store's own live view and the vault's
//! git history correct -- see docs/synapse/synapse-extended-store.md.
//!
//! `resolveExplicit` is the third way in: `query --namespace <repo>@<branch>`
//! names a namespace directly rather than deriving it from the cwd, so a
//! query can address another checkout's graph without being inside it.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Everything both commands need about where they are, resolved once.
pub const Context = struct {
    gpa: Allocator,
    /// The vault root, from `SYNAPSE_VAULT_DIR` in `~/.claude/synapse.conf`.
    vault: []const u8,
    /// `{repo}@{branch}` -- the namespace directory name, never a bare repo name.
    namespace: []const u8,
    repo_root: []const u8,
    /// Where `_index.bin` and `_tags_cache.bin` live. Disposable, outside the vault.
    work_dir: []const u8,
    branch: []const u8,
    remote: []const u8,
    /// Set by `resolveExplicit`: the namespace was named directly (`query
    /// --namespace`), not derived from the cwd's git identity, so there is
    /// no cwd remote to compare it against -- `verifyNamespace` skips that check.
    namespace_explicit: bool = false,
    /// Boilerplate path-segment chains for `node.moduleOf`. Empty just stops
    /// collapsing an ecosystem's `src/` scaffolding, not a failure.
    chains: []const []const u8,

    /// `synapse/{namespace}`, the vault-relative namespace directory.
    dir: []const u8,
    /// The same directory as an absolute filesystem path.
    abs_dir: []const u8,

    /// Owns `chains`, its text, `dir`, `abs_dir`. Others borrow the environment/`resolved`.
    chains_text: ?[]u8,
    chains_list: std.ArrayListUnmanaged([]const u8),
    /// Present when identity came from git; several fields above point into it.
    resolved: ?core.identity.Resolved = null,
    owned_work: ?[]u8 = null,
    /// The vault path, owned because it may have come out of the conf file.
    owned_vault: []u8 = &.{},

    pub fn deinit(self: *Context) void {
        if (self.owned_vault.len != 0) self.gpa.free(self.owned_vault);
        self.chains_list.deinit(self.gpa);
        if (self.chains_text) |t| self.gpa.free(t);
        self.gpa.free(self.dir);
        self.gpa.free(self.abs_dir);
        if (self.owned_work) |w| self.gpa.free(w);
        if (self.resolved) |r| r.deinit(self.gpa);
    }
};

/// Resolve the environment, or explain what is missing and return null.
/// `prog` prefixes the diagnostics (`synapse-query:`, etc.) -- callers match on it.
pub fn resolve(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    prog: []const u8,
) !?Context {
    const vault = (try core.conf.vaultDir(gpa, io, adapters.env.vars(env))) orelse {
        std.debug.print("{s}: no vault\n", .{prog});
        return null;
    };
    // Resolved from the checkout unless every field is already exported --
    // all four together, never a mixture (namespace from env + branch from
    // git would be exactly the disagreement this exists to prevent).
    var resolved: ?core.identity.Resolved = null;
    errdefer if (resolved) |r| r.deinit(gpa);
    if (nonEmpty(env, "SYNAPSE_NAMESPACE") == null or
        nonEmpty(env, "SYNAPSE_REPO_ROOT") == null or
        nonEmpty(env, "SYNAPSE_BRANCH") == null)
    {
        resolved = core.identity.resolve(gpa, io, ".") catch |e| {
            switch (e) {
                error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
                error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
                else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
            }
            return null;
        };
    }

    const namespace = nonEmpty(env, "SYNAPSE_NAMESPACE") orelse resolved.?.key;
    const repo_root = nonEmpty(env, "SYNAPSE_REPO_ROOT") orelse resolved.?.layout.repo_root;
    const branch = nonEmpty(env, "SYNAPSE_BRANCH") orelse resolved.?.branch_key;
    // Compared against the index's own field; absent must mismatch, not
    // pass by comparing empty-string to empty-string.
    const remote = nonEmpty(env, "SYNAPSE_REMOTE") orelse
        if (resolved) |r| r.remote else "";
    var owned_work: ?[]u8 = null;
    const work_dir = nonEmpty(env, "SYNAPSE_WORK_DIR") orelse blk: {
        const home = env.get("HOME") orelse "";
        owned_work = try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/work/{s}", .{ home, namespace });
        break :blk owned_work.?;
    };

    var ctx: Context = .{
        .gpa = gpa,
        .vault = vault,
        .namespace = namespace,
        .repo_root = repo_root,
        .work_dir = work_dir,
        .branch = branch,
        .remote = remote,
        .chains = &.{},
        .dir = try std.fmt.allocPrint(gpa, "synapse/{s}", .{namespace}),
        .abs_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, namespace }),
        .chains_text = null,
        .chains_list = .empty,
        .resolved = resolved,
        .owned_work = owned_work,
        .owned_vault = vault,
    };
    try loadChains(&ctx, io, env);
    return ctx;
}

/// Build a `Context` for a `{repo}@{branch}` namespace named directly
/// (`query --namespace`), bypassing git identity resolution entirely --
/// this is how a query addresses another checkout's graph without being
/// inside it. `repo_root` stays empty unless `SYNAPSE_REPO_ROOT` supplies
/// one -- `query_cmd.zig`'s `requireRepoRoot` refuses outright, rather than
/// reading through it, the subcommands (`stale`, `drift`, `grounding`,
/// `symbol`) that need real source files on disk.
pub fn resolveExplicit(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    prog: []const u8,
    namespace: []const u8,
) !?Context {
    const vault = (try core.conf.vaultDir(gpa, io, adapters.env.vars(env))) orelse {
        std.debug.print("{s}: no vault\n", .{prog});
        return null;
    };
    const at = std.mem.indexOfScalar(u8, namespace, '@') orelse {
        gpa.free(vault);
        std.debug.print("{s}: --namespace expects <repo>@<branch>, got '{s}'\n", .{ prog, namespace });
        return null;
    };
    const branch = namespace[at + 1 ..];

    var owned_work: ?[]u8 = null;
    const work_dir = nonEmpty(env, "SYNAPSE_WORK_DIR") orelse blk: {
        const home = env.get("HOME") orelse "";
        owned_work = try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/work/{s}", .{ home, namespace });
        break :blk owned_work.?;
    };

    var ctx: Context = .{
        .gpa = gpa,
        .vault = vault,
        .namespace = namespace,
        .repo_root = nonEmpty(env, "SYNAPSE_REPO_ROOT") orelse "",
        .work_dir = work_dir,
        .branch = branch,
        .remote = "",
        .namespace_explicit = true,
        .chains = &.{},
        .dir = try std.fmt.allocPrint(gpa, "synapse/{s}", .{namespace}),
        .abs_dir = try std.fmt.allocPrint(gpa, "{s}/synapse/{s}", .{ vault, namespace }),
        .chains_text = null,
        .chains_list = .empty,
        .resolved = null,
        .owned_work = owned_work,
        .owned_vault = vault,
    };
    try loadChains(&ctx, io, env);
    return ctx;
}

fn nonEmpty(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Read cap for a listing that grows with the repo's file count --
/// `manifest.tsv`, `all.txt`, tags-cache's `--paths` -- overridden by
/// `SYNAPSE_MAX_LISTING_BYTES` for all of them at once. One knob, not one
/// per file: they all fail the same way (too small for how many rows a
/// large repo produces), and raising it is a deliberate per-invocation act
/// rather than a `synapse.conf` value that would follow every future clone.
pub fn maxListingBytes(env: *std.process.Environ.Map, default: u64) Io.Limit {
    const raw = env.get("SYNAPSE_MAX_LISTING_BYTES") orelse return .limited(default);
    const n = std.fmt.parseInt(u64, raw, 10) catch return .limited(default);
    return .limited(n);
}

/// `~/.claude/synapse-module-boilerplate.conf`: one chain per line, `#`
/// comments and blank lines ignored. An absent file means no chains known,
/// not an error.
fn loadChains(ctx: *Context, io: Io, env: *std.process.Environ.Map) !void {
    const gpa = ctx.gpa;
    const path = if (env.get("SYNAPSE_MODULE_BOILERPLATE_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (try core.conf.resolveConfPath(gpa, io, adapters.env.vars(env), "synapse-module-boilerplate.conf")) |p|
        p
    else if (env.get("HOME")) |home|
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-module-boilerplate.conf", .{home})
    else
        return;
    defer gpa.free(path);

    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
        if (e != error.FileNotFound)
            std.debug.print("synapse: unreadable module-boilerplate conf: {s} ({t})\n", .{ path, e });
        return;
    };
    ctx.chains_text = text;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const cut = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        const chain = std.mem.trim(u8, cut, " \t\r");
        if (chain.len == 0) continue;
        try ctx.chains_list.append(gpa, chain);
    }
    ctx.chains = ctx.chains_list.items;
}

/// The namespace exists, and belongs to this repo *and* this branch.
/// Catches a hand-renamed folder (directory name and recorded fields
/// disagreeing) that would otherwise let one branch's graph answer for
/// another. An absent field is a mismatch, not a match against "".
pub fn verifyNamespace(ctx: *const Context, io: Io, prog: []const u8) !bool {
    const gpa = ctx.gpa;
    const path = try std.fmt.allocPrint(gpa, "{s}/Index.md", .{ctx.abs_dir});
    defer gpa.free(path);

    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch {
        std.debug.print(
            "{s}: no namespace covers {s}/ -- this branch has no graph\n",
            .{ prog, ctx.dir },
        );
        return false;
    };
    defer gpa.free(text);

    // An explicit --namespace has no cwd remote to agree with; skip that check.
    if (!ctx.namespace_explicit) {
        const existing_remote = core.query.field(text, "remote") orelse "";
        if (!std.mem.eql(u8, existing_remote, ctx.remote)) return false; // caller reports the mismatch
    }
    const existing_branch = core.query.field(text, "branch") orelse "";
    if (!std.mem.eql(u8, existing_branch, ctx.branch)) {
        std.debug.print(
            "{s}: {s}/ records branch '{s}', not '{s}'\n",
            .{ prog, ctx.dir, existing_branch, ctx.branch },
        );
        return false;
    }
    return true;
}

/// A node's absolute path on disk, caller-owned. Accepts the title with or
/// without `.md`. Exposed on its own for a caller that wants to open the
/// file itself (a streaming read) rather than go through `readNode`.
pub fn nodePath(ctx: *const Context, gpa: Allocator, name: []const u8) ![]u8 {
    return if (std.mem.endsWith(u8, name, ".md"))
        std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.abs_dir, name })
    else
        std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ ctx.abs_dir, name });
}

/// One node's text, or null when there is no such node. Accepts the title
/// with or without `.md`.
pub fn readNode(ctx: *const Context, io: Io, name: []const u8) !?[]u8 {
    const gpa = ctx.gpa;
    const path = try nodePath(ctx, gpa, name);
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch null;
}

/// `name` without its `.md`, which is how every finding names a node.
pub fn stripMd(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".md")) name[0 .. name.len - 3] else name;
}

/// Every node file (`*.md`, excluding `Index.md`) in the namespace, sorted
/// by name so a human-diffed report doesn't reorder between runs.
pub fn listNodeFiles(ctx: *const Context, io: Io) !std.ArrayListUnmanaged([]u8) {
    const gpa = ctx.gpa;
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }

    var dir = Io.Dir.cwd().openDir(io, ctx.abs_dir, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "Index.md")) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out;
}

/// The work dir, without requiring a vault: `$SYNAPSE_WORK_DIR` when set,
/// else `~/.cache/synapse/work/{namespace}`. `enumerate`/`build-lists`/
/// `build-refs`/`callers` don't need a vault at all. Caller owns the result
/// when `owned` is true.
pub const WorkDir = struct {
    path: []const u8,
    owned: bool,

    pub fn deinit(self: WorkDir, gpa: Allocator) void {
        if (self.owned) gpa.free(self.path);
    }
};

pub fn workDir(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    prog: []const u8,
) !?WorkDir {
    return workDirFor(gpa, io, env, ".", prog);
}

/// Same, for a repository other than the one at cwd -- `vocab`/`rank` take
/// `--repo`, and the work dir belongs to the repo being read.
pub fn workDirFor(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    repo: []const u8,
    prog: []const u8,
) !?WorkDir {
    if (nonEmpty(env, "SYNAPSE_WORK_DIR")) |w| return .{ .path = w, .owned = false };

    const key = if (nonEmpty(env, "SYNAPSE_NAMESPACE")) |k|
        try gpa.dupe(u8, k)
    else blk: {
        const id = core.identity.resolve(gpa, io, repo) catch |e| {
            switch (e) {
                error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
                error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
                else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
            }
            return null;
        };
        defer id.deinit(gpa);
        break :blk try gpa.dupe(u8, id.key);
    };
    defer gpa.free(key);

    const home = env.get("HOME") orelse {
        std.debug.print("{s}: no HOME, so no default work dir\n", .{prog});
        return null;
    };
    return .{
        .path = try std.fmt.allocPrint(gpa, "{s}/.cache/synapse/work/{s}", .{ home, key }),
        .owned = true,
    };
}
