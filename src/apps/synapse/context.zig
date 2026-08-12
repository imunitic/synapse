//! The preamble `synapse-query.sh` and `synapse-write-node.sh` each ran, once.
//!
//! Both scripts opened with the same fifty lines: source the conf, find the vault,
//! resolve the namespace through `synapse-identity.sh`, load the module
//! boilerplate, and refuse to proceed if the namespace's `Index.md` names a
//! different repo or branch. Two copies of that is two chances to disagree about
//! which graph a checkout belongs to, and disagreeing there means one component
//! refusing where another proceeds.
//!
//! ## Identity is resolved here, and the environment can still override it
//!
//! `adapters.git_identity` asks git the three questions and `core.identity` turns the
//! answers into a key, so a command run from a checkout needs nothing exported. The
//! environment still wins when set, and that is not vestigial: it is how a caller
//! pins a namespace deliberately (the bats suite does, against fixture repos), and it
//! is what let the shell wrappers hand identity down while `synapse-identity.sh` was
//! still the only implementation. What matters either way is that there is exactly
//! one resolution chain -- a second one that disagreed is the bug this arrangement
//! exists to prevent.
//!
//! ## Reads come from disk; writes go through the API
//!
//! The scripts fetched `Index.md`, the node, `_manifest.tsv` and (for `grounding`)
//! a JsonLogic search over the whole vault through the Local REST API. Reading a
//! *known path* through it was already the wrong shape and the script said so:
//! the response carries a node's entire `sources` block, 4.5 MB on a hub node, to
//! print a few hundred words. `stale`, `drift` and `links` had already moved to
//! disk for that reason; the remaining reads follow them here.
//!
//! What the API is for is search, traversal and *writes* -- so `write-node`'s PUT
//! still goes through it, which is what keeps Obsidian's own view and the vault's
//! git history correct. See `adapters/obsidian/store.zig`.

const std = @import("std");
const core = @import("core");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Everything both commands need about where they are, resolved once.
pub const Context = struct {
    gpa: Allocator,
    /// The vault root, from `OBSIDIAN_VAULT_DIR` in `~/.claude/synapse.conf`.
    vault: []const u8,
    /// `{repo}@{branch}` -- the namespace directory name, never a bare repo name.
    namespace: []const u8,
    repo_root: []const u8,
    /// Where `_index.bin` and `_tags_cache.bin` live. Derived, disposable, and
    /// deliberately outside the version-controlled vault.
    work_dir: []const u8,
    branch: []const u8,
    remote: []const u8,
    /// Boilerplate path-segment chains for `node.moduleOf`. Empty is not a
    /// failure: grouping still works, it just stops collapsing any ecosystem's
    /// `src/` scaffolding.
    chains: []const []const u8,

    /// `synapse/{namespace}`, the vault-relative namespace directory.
    dir: []const u8,
    /// The same directory as an absolute filesystem path.
    abs_dir: []const u8,

    /// Owns `chains`, its backing text, `dir` and `abs_dir`. Every other field
    /// borrows either the environment or `resolved`, both of which outlive us.
    chains_text: ?[]u8,
    chains_list: std.ArrayListUnmanaged([]const u8),
    /// Present when identity came from git rather than the environment. Several
    /// fields above point into it.
    resolved: ?adapters.git_identity.Identity = null,
    owned_work: ?[]u8 = null,

    pub fn deinit(self: *Context) void {
        self.chains_list.deinit(self.gpa);
        if (self.chains_text) |t| self.gpa.free(t);
        self.gpa.free(self.dir);
        self.gpa.free(self.abs_dir);
        if (self.owned_work) |w| self.gpa.free(w);
        if (self.resolved) |r| r.deinit(self.gpa);
    }
};

/// Resolve the environment, or explain what is missing and return null.
///
/// `prog` prefixes the diagnostics, so the same message says `synapse-query:` or
/// `synapse-write-node:` depending on who asked -- the scripts' own prefixes,
/// which the bats suite matches on.
pub fn resolve(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    prog: []const u8,
) !?Context {
    const vault = nonEmpty(env, "OBSIDIAN_VAULT_DIR") orelse {
        std.debug.print("{s}: no vault\n", .{prog});
        return null;
    };
    // Resolved from the checkout unless every field is already exported. All four
    // together, never a mixture: a namespace from the environment paired with a branch
    // from git is exactly the disagreement one resolution chain exists to prevent.
    var resolved: ?adapters.git_identity.Identity = null;
    errdefer if (resolved) |r| r.deinit(gpa);
    if (nonEmpty(env, "SYNAPSE_NAMESPACE") == null or
        nonEmpty(env, "SYNAPSE_REPO_ROOT") == null or
        nonEmpty(env, "SYNAPSE_BRANCH") == null)
    {
        resolved = adapters.git_identity.resolve(gpa, io, ".") catch |e| {
            switch (e) {
                // Exit 1 with a message, not silence: a caller that asked for a graph
                // operation outside a repo has made a mistake worth naming.
                error.NotAGitRepo => std.debug.print("{s}: not inside a git repo\n", .{prog}),
                error.DetachedHead => std.debug.print("{s}\n", .{core.identity.detached_message}),
                else => std.debug.print("{s}: could not resolve the namespace\n", .{prog}),
            }
            return null;
        };
    }

    const namespace = nonEmpty(env, "SYNAPSE_NAMESPACE") orelse resolved.?.key;
    const repo_root = nonEmpty(env, "SYNAPSE_REPO_ROOT") orelse resolved.?.repo_root;
    const branch = nonEmpty(env, "SYNAPSE_BRANCH") orelse resolved.?.branch_key;
    // The remote is compared against the namespace index's own field. Absent is not a
    // skipped check: a comparison against the empty string would pass for any index
    // missing the field, which is the exact case the check exists to catch.
    const remote = nonEmpty(env, "SYNAPSE_REMOTE") orelse
        if (resolved) |r| r.remote else "";
    // The work dir is derived rather than required -- it is the one field with an
    // obvious default, and every script spelled that default the same way.
    var owned_work: ?[]u8 = null;
    const work_dir = nonEmpty(env, "SYNAPSE_WORK_DIR") orelse blk: {
        const home = env.get("HOME") orelse "";
        owned_work = try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-work/{s}", .{ home, namespace });
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
    };
    try loadChains(&ctx, io, env);
    return ctx;
}

fn nonEmpty(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// `~/.claude/synapse-module-boilerplate.conf`: one chain per line, `#` comments
/// and blank lines ignored.
///
/// An absent file means no chains are known, which is not an error. The script
/// spent one `sed` per line here -- including on the comment lines, which is every
/// line of the shipped default.
fn loadChains(ctx: *Context, io: Io, env: *std.process.Environ.Map) !void {
    const gpa = ctx.gpa;
    const path = if (env.get("SYNAPSE_MODULE_BOILERPLATE_CONF")) |p|
        try gpa.dupe(u8, p)
    else if (env.get("HOME")) |home|
        try std.fmt.allocPrint(gpa, "{s}/.claude/synapse-module-boilerplate.conf", .{home})
    else
        return;
    defer gpa.free(path);

    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return;
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
///
/// The directory name already encodes the branch, so these agree by construction
/// on anything this tooling wrote. The check is for what it did not write: a folder
/// renamed by hand -- including by a migration that renamed the directory and
/// forgot the field -- which would otherwise let one branch's graph answer for
/// another. An absent field is a mismatch, not a match against the empty string.
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

    const existing_remote = core.query.field(text, "remote") orelse "";
    if (!std.mem.eql(u8, existing_remote, ctx.remote)) {
        // Silent, as the script was: an exit code is the whole message here, and
        // the mismatch is reported by whoever asked for the write.
        return false;
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

/// One node's text, or null when there is no such node.
///
/// Accepts the title with or without `.md`, like `fetch_node`. A targeted read of
/// a known path, from disk -- see this file's header for why that is not the API's
/// job.
pub fn readNode(ctx: *const Context, io: Io, name: []const u8) !?[]u8 {
    const gpa = ctx.gpa;
    const path = if (std.mem.endsWith(u8, name, ".md"))
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.abs_dir, name })
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ ctx.abs_dir, name });
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch null;
}

/// `name` without its `.md`, which is how every finding names a node.
pub fn stripMd(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".md")) name[0 .. name.len - 3] else name;
}

/// Every node file in the namespace, sorted by name, `Index.md` excluded.
///
/// A node is any `*.md` directly under the namespace except `Index.md`;
/// `_manifest.tsv` and `_profile.txt` are machine-only and not nodes. Sorted
/// because a directory's own order is arbitrary and a report a human diffs must
/// not reorder between runs.
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
