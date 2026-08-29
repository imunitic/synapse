//! `GitStore`: a decorator around `DiskStore`, same idea as `ObsidianStore`
//! but for the vault's own version control instead of a live app. `read`/
//! `list`/`linkGraph`/`searchFiltered` are pure delegations -- nothing
//! about git changes what those answer. `write` and `renamer` are the two
//! real differences: both mutate the vault, so both own the vault's git
//! lifecycle themselves (init a repo on first write, commit under a shared
//! lock, push once enough commits pile up) rather than a separate mechanism
//! reacting after the fact. See the design note this implements
//! (`sb — GitStore extended store`) for the full reasoning behind every
//! choice below -- comments here are deliberately short.
//!
//! `renamer`'s own commit is a plain `commitIfDirty` after the fact, not a
//! literal `git mv` -- worth naming because it looks like the obvious
//! choice and isn't: git has no rename object anywhere in its model (blobs
//! are content-addressed snapshots; `git log --follow`/`diff -M`'s rename
//! detection is always a similarity heuristic run at diff time between two
//! trees), and `git mv` is documented as exactly `mv` + `git add` + `git rm
//! --cached` -- it produces the identical tree/commit a plain rewrite +
//! `add -A` already does. Nothing here would change by typing it out.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const disk_store = @import("../disk/store.zig");
const git_sync = @import("../git_sync.zig");
const process = @import("../process.zig");
const env_bridge = @import("../env.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;
const DiskStore = disk_store.DiskStore;

/// Past this many local commits ahead of upstream, `write` spawns a
/// detached Pusher instead of leaving them to pile up -- the same knob
/// `SYNAPSE_VAULT_PUSH_EVERY` was under `stop_nudge.zig`'s turn-based
/// throttle, now counted in commits instead of turns, since a `Store` has
/// writes to count but no turn concept of its own.
fn pushEvery(gpa: Allocator, io: Io, vars: *std.process.Environ.Map) usize {
    const raw = (core.conf.resolve(gpa, io, env_bridge.vars(vars), "SYNAPSE_VAULT_PUSH_EVERY") catch return 5) orelse return 5;
    defer gpa.free(raw);
    return std.fmt.parseInt(usize, raw, 10) catch 5;
}

pub const GitStore = struct {
    gpa: Allocator,
    /// The vault's own filesystem path -- an explicit dependency, not
    /// derived from `inner`: `inner` is a type-erased `Store` value with no
    /// `.vault` field to read, and `GitStore`'s own git mechanics (`write`'s
    /// commit, the Pusher) operate on this path directly via subprocesses,
    /// never through `inner` at all.
    vault: []const u8,
    /// What `read`/`write`/`list`/`search` actually delegate to -- `DiskStore`
    /// for a plain `git` chain, or another integration's own store for a
    /// longer one (`git,obsidian` composes `ObsidianStore` here).
    inner: Store,
    /// Never overridden by `GitStore` -- committing has nothing to add to
    /// the link graph, so this is exactly whatever `inner` resolved to.
    inner_link_graph: LinkGraph,
    rename_impl: GitRenamer,
    inner_search_filtered: ports.SearchFiltered,
    /// Set by `resolveStore` the same way `DiskStore.vars` already is --
    /// needed here only to read `SYNAPSE_VAULT_PUSH_EVERY`. `null` (the
    /// default for a caller with no environment, e.g. a test) disables the
    /// push threshold entirely rather than guessing a value; every commit
    /// still lands, just nothing ever pushes on its own.
    env: ?*std.process.Environ.Map = null,
    /// This process's own path, for spawning a detached Pusher via
    /// `argv[0]` re-invocation -- the same mechanism `stop_nudge.zig`
    /// already uses. Empty disables spawning (no self path known), the
    /// same graceful-no-op `stop_nudge.maybeSync` already has.
    self_path: []const u8 = "",

    /// Every dependency named explicitly -- `gpa`/`vault` for `GitStore`'s
    /// own git mechanics, `inner`/`inner_link_graph`/`inner_renamer`/
    /// `inner_search_filtered` for whatever it's composing. Never derives
    /// any of these from `inner` itself: relying on the thing you wrap to
    /// also hand you your own dependencies doesn't hold once `inner` is
    /// generic rather than always a concrete `DiskStore`.
    pub fn init(
        gpa: Allocator,
        vault: []const u8,
        inner: Store,
        inner_link_graph: LinkGraph,
        inner_renamer: Renamer,
        inner_search_filtered: ports.SearchFiltered,
    ) GitStore {
        return .{
            .gpa = gpa,
            .vault = vault,
            .inner = inner,
            .inner_link_graph = inner_link_graph,
            .rename_impl = .{ .vault = vault, .inner = inner_renamer },
            .inner_search_filtered = inner_search_filtered,
        };
    }

    pub fn store(self: *GitStore) Store {
        return Store.from(GitStore, self);
    }

    /// A pure passthrough -- see `inner_link_graph`'s own doc comment.
    pub fn linkGraph(self: *GitStore) LinkGraph {
        return self.inner_link_graph;
    }
    /// Not a passthrough: `renamer` mutates the vault, same as `write`, so
    /// it needs its own commit -- see `GitRenamer` below.
    pub fn renamer(self: *GitStore) Renamer {
        return self.rename_impl.renamer();
    }
    pub fn searchFiltered(
        self: *GitStore,
        gpa: Allocator,
        io: Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        return self.inner_search_filtered.searchFiltered(gpa, io, query, path_filter);
    }

    pub fn read(self: *GitStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        return self.inner.read(gpa, io, node);
    }

    pub fn list(self: *GitStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return self.inner.list(gpa, io);
    }

    pub fn search(self: *GitStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return self.inner.search(gpa, io, query);
    }

    /// The inner write first, unconditionally -- nothing here ever waits on
    /// git or the network for the data itself to land. Then: ensure a repo
    /// exists (init on first write), try the shared lock non-blocking, and
    /// either commit or skip -- see `git_sync.zig` and the design note for
    /// why a skip is always safe. A successful commit checks the push
    /// threshold and spawns a detached Pusher once it's crossed.
    pub fn write(self: *GitStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const result = try self.inner.write(io, node, body);
        if (!result.accepted) return result;

        const gpa = self.gpa;
        const vault = self.vault;

        git_sync.ensureRepo(gpa, io, vault) catch return result;

        const lock = git_sync.tryAcquire(gpa, io, vault) catch return result;
        if (lock) |l| {
            defer git_sync.release(io, gpa, l);
            git_sync.commitIfDirty(gpa, io, vault) catch return result;
            self.maybeSpawnPusher(gpa, io, vault) catch {};
        }
        // Lock held by a Pusher: skip the commit outright. The write
        // already landed on disk; the Pusher's own final commitIfDirty, or
        // whichever future write does acquire the lock, picks this up.

        return result;
    }

    fn maybeSpawnPusher(self: *GitStore, gpa: Allocator, io: Io, vault: []const u8) !void {
        const env = self.env orelse return;
        if (self.self_path.len == 0) return;

        const ahead = try git_sync.commitsAhead(gpa, io, vault);
        if (ahead == 0 or ahead % pushEvery(gpa, io, env) != 0) return;

        // Never waited on: this call is already inside a write, and a
        // network push has no business being on that critical path.
        _ = std.process.spawn(io, .{
            .argv = &.{ self.self_path, "vault-git-pusher", vault },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
    }
};

/// The detached Pusher's own body -- spawned by `GitStore.write()` via
/// `argv[0] vault-git-pusher {vault}`, never run inline. Acquires the lock
/// with a short bounded retry (already detached, nothing user-facing is
/// waiting), pulls, commits anything left dirty by a write that had to skip
/// its own commit while this held the lock, then pushes -- in that order,
/// so the catch-up commit rides the same push cycle instead of waiting for
/// a later one to notice it.
pub fn runPusher(gpa: Allocator, io: Io, vault: []const u8) void {
    const lock = (git_sync.acquireWithRetry(gpa, io, vault, 10) catch return) orelse return;
    defer git_sync.release(io, gpa, lock);

    if (!git_sync.pull(gpa, io, vault)) return;
    // Catch-up commit before the push, not after: the whole point of doing
    // this here is folding a skipped write's change into the same push
    // cycle, not just eventually landing it in history on some later one.
    git_sync.commitIfDirty(gpa, io, vault) catch {};
    git_sync.pushIfAhead(gpa, io, vault) catch {};
}

/// Delegates the actual rewrite/move mechanics to whatever `inner` resolved
/// to -- `DiskRenamer` for a plain `git` chain, `ObsidianRenamer` for
/// `git,obsidian` -- an explicit dependency, never hardcoded: a rename under
/// `git,obsidian` has to go through Obsidian's own rename mechanism, not
/// silently bypass it with a raw file move underneath. Then commits under
/// the same lock-or-skip discipline `write()` uses. No push-threshold check
/// here -- a rename that lands between two `write()` calls still gets
/// pushed once either side's own commit count crosses the threshold;
/// nothing is lost, just not pushed by this call specifically.
pub const GitRenamer = struct {
    vault: []const u8,
    inner: Renamer,

    pub fn renamer(self: *GitRenamer) Renamer {
        return Renamer.from(GitRenamer, self);
    }

    pub fn rename(self: *GitRenamer, gpa: Allocator, io: Io, old_path: []const u8, new_path: []const u8) anyerror!void {
        try self.inner.rename(gpa, io, old_path, new_path);

        git_sync.ensureRepo(gpa, io, self.vault) catch return;
        const lock = git_sync.tryAcquire(gpa, io, self.vault) catch return;
        const l = lock orelse return; // held by a Pusher: skip, the next commit sweeps this up too
        defer git_sync.release(io, gpa, l);
        git_sync.commitIfDirty(gpa, io, self.vault) catch {};
    }
};

const testing = std.testing;

fn vaultGit(gpa: Allocator, vault: []const u8, args: []const []const u8) !process.Result {
    var argv_buf: [16][]const u8 = undefined;
    argv_buf[0] = "git";
    @memcpy(argv_buf[1 .. 1 + args.len], args);
    return process.run(testing.io, gpa, argv_buf[0 .. 1 + args.len], .{ .cwd = .{ .path = vault } });
}

fn headSubject(gpa: Allocator, vault: []const u8) ![]u8 {
    const res = try vaultGit(gpa, vault, &.{ "log", "-1", "--format=%s" });
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

fn commitCount(gpa: Allocator, vault: []const u8) !usize {
    const res = try vaultGit(gpa, vault, &.{ "rev-list", "--count", "HEAD" });
    defer res.deinit(gpa);
    if (!res.ok()) return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
}

/// A `GitStore` composing a plain `DiskStore`, the shape every test below
/// needs -- `disk` is heap-allocated so its address stays stable regardless
/// of how this returned struct itself gets copied around (the same reason
/// `resolveStore` heap-allocates every layer: a `Store` value embeds a
/// pointer to the concrete instance beneath it, which has to outlive
/// whatever moved).
const TestFixture = struct {
    disk: *DiskStore,
    git: GitStore,

    fn deinit(self: *TestFixture) void {
        self.disk.deinit();
        testing.allocator.destroy(self.disk);
    }
};

fn initGitStore(gpa: Allocator, vault: []const u8, namespace: []const u8) !TestFixture {
    const disk = try gpa.create(DiskStore);
    disk.* = try DiskStore.init(gpa, vault, namespace);
    const git = GitStore.init(gpa, vault, disk.store(), disk.linkGraph(), disk.renamer(), ports.SearchFiltered.from(DiskStore, disk));
    return .{ .disk = disk, .git = git };
}

test "write initializes a repo on first write and commits the change" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();

    const wr = try store.write(testing.io, "a.md", "hello\n");
    try testing.expect(wr.accepted);

    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(testing.io, dot_git, .{});

    const head = try headSubject(gpa, vault);
    defer gpa.free(head);
    try testing.expectEqualStrings("vault: a.md", head);
}

test "a second write against an already-initialized repo commits again, not twice-init" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();

    _ = try store.write(testing.io, "a.md", "one\n");
    _ = try store.write(testing.io, "b.md", "two\n");

    try testing.expectEqual(@as(usize, 2), try commitCount(gpa, vault));
}

test "a write that loses the lock race still lands on disk with no commit" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();

    // First write establishes the repo so the lock path exists.
    _ = try store.write(testing.io, "a.md", "one\n");

    const held = (try git_sync.tryAcquire(gpa, testing.io, vault)).?;
    const wr = try store.write(testing.io, "b.md", "two\n");
    git_sync.release(testing.io, gpa, held);
    try testing.expect(wr.accepted);

    // The file landed even though the commit was skipped.
    const got = (try store.read(gpa, testing.io, "b.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("two\n", got);
    try testing.expectEqual(@as(usize, 1), try commitCount(gpa, vault));

    // The next successful write's own `add -A` sweeps up the skipped one.
    _ = try store.write(testing.io, "c.md", "three\n");
    try testing.expectEqual(@as(usize, 2), try commitCount(gpa, vault));
}

test "linkGraph and searchFiltered pass straight through to the resolved inner" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();
    _ = try store.write(testing.io, "designs/x.md", "widget prose\n");
    _ = try store.write(testing.io, "tasks/y.md", "widget prose too\n");

    var filter = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"glob": ["designs/*", {"var": "path"}]}
    , .{});
    defer filter.deinit();
    const hits = try fx.git.searchFiltered(gpa, testing.io, "widget", filter.value);
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("designs/x.md", hits[0].node);

    _ = fx.git.linkGraph();
}

test "renamer moves the file and commits the result, unlike a pure delegation" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();
    // No `title:`/self-link rewrite to check here -- `DiskRenamer` rewrites
    // `[[wikilink]]` occurrences, not arbitrary frontmatter fields, and
    // that behavior is already `DiskStore`'s own tests' job. This test is
    // only about whether the move commits, not re-proving the rewrite.
    _ = try store.write(testing.io, "Old Title.md", "body\n");

    var renamer = fx.git.renamer();
    try renamer.rename(gpa, testing.io, "Old Title.md", "New Title.md");

    const moved = (try store.read(gpa, testing.io, "New Title.md")).?;
    defer gpa.free(moved);
    try testing.expectEqualStrings("body\n", moved);
    try testing.expectEqual(@as(?[]u8, null), try store.read(gpa, testing.io, "Old Title.md"));

    // Two real commits: the write, then the rename -- not just the file
    // moved on disk with nothing recording it.
    try testing.expectEqual(@as(usize, 2), try commitCount(gpa, vault));
    const head = try headSubject(gpa, vault);
    defer gpa.free(head);
    try testing.expect(std.mem.startsWith(u8, head, "vault: "));
}

test "runPusher pushes what's ahead and commits anything a concurrent write skipped" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = buf: {
        var b: [Io.Dir.max_path_bytes]u8 = undefined;
        break :buf try gpa.dupe(u8, b[0..try tmp.dir.realPath(testing.io, &b)]);
    };
    defer gpa.free(root);

    const remote = try std.fmt.allocPrint(gpa, "{s}/remote.git", .{root});
    defer gpa.free(remote);
    (try process.run(testing.io, gpa, &.{ "git", "init", "-q", "--bare", "-b", "main", remote }, .{})).deinit(gpa);

    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    try Io.Dir.cwd().createDirPath(testing.io, vault);

    var fx = try initGitStore(gpa, vault, "");
    defer fx.deinit();
    var store = fx.git.store();
    _ = try store.write(testing.io, "a.md", "one\n");

    (try vaultGit(gpa, vault, &.{ "branch", "-M", "main" })).deinit(gpa);
    (try vaultGit(gpa, vault, &.{ "remote", "add", "origin", remote })).deinit(gpa);
    (try vaultGit(gpa, vault, &.{ "push", "-q", "-u", "origin", "main" })).deinit(gpa);

    // Simulate a write that landed on disk but skipped its commit because
    // the Pusher already held the lock (the same shape the write-side test
    // above exercises, held manually here so `runPusher` sees a dirty tree
    // when it goes to release).
    const lock = (try git_sync.tryAcquire(gpa, testing.io, vault)).?;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/b.md", .data = "two\n" });
    git_sync.release(testing.io, gpa, lock);

    runPusher(gpa, testing.io, vault);

    try testing.expectEqual(@as(usize, 2), try commitCount(gpa, vault));
    const remote_head = try headSubject(gpa, remote);
    defer gpa.free(remote_head);
    try testing.expectEqualStrings("vault: b.md", remote_head);
}
