//! Shared git mechanics for the vault's own version control -- the lock,
//! pull, commit, and push primitives `GitStore` (`git/store.zig`) and the
//! `stop-nudge`/`session-start` hooks both need, so there is exactly one
//! implementation of each, not one per caller.
//!
//! Every function here takes a vault path directly rather than resolving one
//! itself -- the caller (a `Store` method, a hook) already knows which vault
//! it's working against and how it found that path; this stays a pure set of
//! git-over-one-directory primitives.

const std = @import("std");
const process = @import("process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How long the sync lock must go untouched before it's treated as
/// abandoned. Every legitimate holder here does either a local commit or a
/// small vault's pull/push (bounded by the 10s SSH connect timeout `pull`/
/// `pushIfAhead` already set) -- nowhere near the grammar-fetch lock's own
/// 15 minutes (a full clone can legitimately take a while; nothing here
/// does anything close).
pub const lock_stale_after_ns: i96 = 3 * std.time.ns_per_min;

fn lockPath(gpa: Allocator, vault: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.git/synapse-sync.lock", .{vault});
}

/// Unreadable counts as not-abandoned: a lock that vanished mid-check isn't
/// ours to reason about. Wall clock, since it's compared against an mtime --
/// the lock directory's own mtime is the timestamp, no separate marker file
/// needed (the exact mechanism `treesitter/grammar.zig`'s own fetch/compile
/// locks already use and this one is deliberately kept identical to).
fn lockAbandoned(io: Io, lock_dir: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, lock_dir, .{}) catch return false;
    const now = Io.Timestamp.now(io, .real).nanoseconds;
    return now - st.mtime.nanoseconds > lock_stale_after_ns;
}

/// One non-blocking attempt: `mkdir` is the atomic test-and-set. Steals an
/// abandoned lock once if the first attempt finds one, but never loops or
/// sleeps -- a write path can't afford to wait on anything here. Caller
/// frees the returned path via `release`.
pub fn tryAcquire(gpa: Allocator, io: Io, vault: []const u8) !?[]u8 {
    const lock = try lockPath(gpa, vault);
    errdefer gpa.free(lock);
    if (Io.Dir.cwd().createDir(io, lock, .default_dir)) |_| return lock else |_| {}
    if (lockAbandoned(io, lock)) {
        Io.Dir.cwd().deleteDir(io, lock) catch {};
        if (Io.Dir.cwd().createDir(io, lock, .default_dir)) |_| return lock else |_| {}
    }
    gpa.free(lock);
    return null;
}

/// Bounded retry over `tryAcquire`, for a caller that's already detached and
/// can afford a short wait rather than losing its one attempt outright (the
/// Pusher). 200ms between attempts, the same spacing `grammar.zig`'s own
/// lock-wait loop uses.
pub fn acquireWithRetry(gpa: Allocator, io: Io, vault: []const u8, max_tries: usize) !?[]u8 {
    var tries: usize = 0;
    while (tries < max_tries) : (tries += 1) {
        if (try tryAcquire(gpa, io, vault)) |lock| return lock;
        Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
    return null;
}

pub fn release(io: Io, gpa: Allocator, lock: []u8) void {
    Io.Dir.cwd().deleteDir(io, lock) catch {};
    gpa.free(lock);
}

/// The tracked upstream's short name (e.g. `origin/main`), or null when
/// there isn't one -- no upstream is ordinary (no remote configured, or one
/// never pushed to yet), not an error.
pub fn upstreamOf(gpa: Allocator, io: Io, vault: []const u8) !?[]u8 {
    const res = try process.run(io, gpa, &.{
        "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
    }, .{ .cwd = .{ .path = vault } });
    defer res.deinit(gpa);
    if (!res.ok()) return null;
    const name = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (name.len == 0) return null;
    return try gpa.dupe(u8, name);
}

/// Fetches and rebases any local, not-yet-pushed commits onto the tracked
/// upstream. A conflict is aborted immediately rather than ever left
/// half-applied -- `git rebase` writes conflict markers straight into the
/// working-tree file, and that file is a note read as-is by whatever's
/// viewing the vault. Returns whether it's safe to continue (already up to
/// date, or pulled cleanly); a no-upstream vault is trivially safe, nothing
/// to pull.
pub fn pull(gpa: Allocator, io: Io, vault: []const u8) bool {
    const upstream = upstreamOf(gpa, io, vault) catch return true;
    defer if (upstream) |u| gpa.free(u);
    if (upstream == null) return true;

    // `BatchMode=yes` keeps a passphrase-locked key from waiting forever on
    // a prompt nobody sees; macOS ships neither `timeout` nor `gtimeout`, so
    // the bound has to come from ssh's own option instead.
    const res = process.run(io, gpa, &.{
        "git",
        "-c",
        "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10",
        "pull",
        "--rebase",
        "--autostash",
        "--quiet",
    }, .{ .cwd = .{ .path = vault } }) catch return false;
    defer res.deinit(gpa);
    if (res.ok()) return true;

    const abort = process.run(io, gpa, &.{ "git", "rebase", "--abort" }, .{ .cwd = .{ .path = vault } }) catch return false;
    abort.deinit(gpa);
    return false;
}

/// How many staged paths get named directly in the commit message before
/// it switches to a plain count -- past this, a one-line message listing
/// every path stops being more useful than a summary.
const max_named_files = 4;

/// `git add -A`, then commits only if that staged something -- an empty
/// commit on every call would otherwise be the common case, not the
/// exception. Silent on failure: a write shouldn't fail over an
/// auto-commit.
///
/// The message names what's actually staged (`git diff --cached
/// --name-only`), not whatever path the caller last touched -- a commit
/// here can hold more than one write's file (a Pusher's own catch-up
/// sweep, or a later write's `add -A` picking up an earlier one that had
/// to skip its own commit), so trusting "the path I was just asked to
/// write" would misname a commit that turns out to hold something else
/// too.
pub fn commitIfDirty(gpa: Allocator, io: Io, vault: []const u8) !void {
    const cwd: std.process.Child.Cwd = .{ .path = vault };
    {
        const add = try process.run(io, gpa, &.{ "git", "add", "-A" }, .{ .cwd = cwd });
        defer add.deinit(gpa);
        if (!add.ok()) return;
    }
    const staged = blk: {
        const res = try process.run(io, gpa, &.{ "git", "diff", "--cached", "--name-only" }, .{ .cwd = cwd });
        defer res.deinit(gpa);
        if (!res.ok()) return;
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len == 0) return; // nothing staged
        break :blk try gpa.dupe(u8, trimmed);
    };
    defer gpa.free(staged);

    const message = try commitMessage(gpa, staged);
    defer gpa.free(message);

    const commit = try process.run(io, gpa, &.{
        "git", "commit", "--quiet", "-m", message,
    }, .{ .cwd = cwd });
    commit.deinit(gpa);
}

/// `staged` is `git diff --cached --name-only`'s trimmed output, one path
/// per line, guaranteed non-empty by the only caller. Names every path
/// directly up to `max_named_files`; past that, a plain count reads better
/// than a message a terminal has to wrap.
fn commitMessage(gpa: Allocator, staged: []const u8) ![]u8 {
    var count: usize = 1;
    for (staged) |c| {
        if (c == '\n') count += 1;
    }
    if (count > max_named_files) return std.fmt.allocPrint(gpa, "vault: {d} files", .{count});

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("vault: ");
    var it = std.mem.splitScalar(u8, staged, '\n');
    var first = true;
    while (it.next()) |path| {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(path);
        first = false;
    }
    return out.toOwnedSlice();
}

/// Pushes only what's still ahead of upstream after a `pull` -- computed
/// fresh here rather than trusted from before the pull, since pulling can
/// itself move `HEAD`. A no-upstream vault is a silent no-op, same as every
/// other step here.
pub fn pushIfAhead(gpa: Allocator, io: Io, vault: []const u8) !void {
    const upstream = try upstreamOf(gpa, io, vault) orelse return;
    defer gpa.free(upstream);

    const ahead = blk: {
        const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{upstream});
        defer gpa.free(spec);
        const res = try process.run(io, gpa, &.{ "git", "rev-list", "--count", spec }, .{ .cwd = .{ .path = vault } });
        defer res.deinit(gpa);
        if (!res.ok()) return;
        break :blk std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
    };
    if (ahead == 0) return;

    const res = process.run(io, gpa, &.{
        "git",
        "-c",
        "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=10",
        "push",
        "--quiet",
    }, .{ .cwd = .{ .path = vault } }) catch return;
    res.deinit(gpa);
}

/// The number of local commits not yet on `upstream`, or 0 with no upstream
/// at all -- the same measure `pushIfAhead` computes internally, exposed so
/// a caller (`GitStore`, deciding whether to spawn a Pusher) can check it
/// without paying for a push attempt just to find out.
pub fn commitsAhead(gpa: Allocator, io: Io, vault: []const u8) !usize {
    const upstream = try upstreamOf(gpa, io, vault) orelse return 0;
    defer gpa.free(upstream);
    const spec = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{upstream});
    defer gpa.free(spec);
    const res = try process.run(io, gpa, &.{ "git", "rev-list", "--count", spec }, .{ .cwd = .{ .path = vault } });
    defer res.deinit(gpa);
    if (!res.ok()) return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
}

/// `git init`s `vault` if it has no `.git` yet. No identity setup needed on
/// the fresh repo -- checked directly (see the design note this implements):
/// `git commit` with no `user.name`/`user.email` configured anywhere still
/// succeeds, auto-deriving an identity from the OS.
pub fn ensureRepo(gpa: Allocator, io: Io, vault: []const u8) !void {
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    if (Io.Dir.cwd().statFile(io, dot_git, .{})) |st| {
        if (st.kind == .directory) return; // already a repo (or the root of one)
    } else |_| {}
    const res = try process.run(io, gpa, &.{ "git", "init", "-q" }, .{ .cwd = .{ .path = vault } });
    res.deinit(gpa);
}

const testing = std.testing;

fn vaultGit(gpa: Allocator, vault: []const u8, args: []const []const u8) !process.Result {
    var argv_buf: [16][]const u8 = undefined;
    argv_buf[0] = "git";
    @memcpy(argv_buf[1 .. 1 + args.len], args);
    return process.run(testing.io, gpa, argv_buf[0 .. 1 + args.len], .{ .cwd = .{ .path = vault } });
}

fn initRepo(gpa: Allocator, vault: []const u8) !void {
    (try vaultGit(gpa, vault, &.{ "init", "-q", "-b", "main" })).deinit(gpa);
    (try vaultGit(gpa, vault, &.{ "config", "user.email", "t@e" })).deinit(gpa);
    (try vaultGit(gpa, vault, &.{ "config", "user.name", "t" })).deinit(gpa);
}

fn headSubject(gpa: Allocator, vault: []const u8) ![]u8 {
    const res = try vaultGit(gpa, vault, &.{ "log", "-1", "--format=%s" });
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

test "ensureRepo initializes a fresh repo only when .git is missing" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try ensureRepo(gpa, testing.io, vault);
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    const st = try Io.Dir.cwd().statFile(testing.io, dot_git, .{});
    try testing.expect(st.kind == .directory);

    // A second call against the same vault is a no-op, not a re-init.
    try ensureRepo(gpa, testing.io, vault);
}

test "commitIfDirty stages and commits only when something changed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    // Nothing changed yet: no commit.
    try commitIfDirty(gpa, testing.io, vault);
    const empty_log = try vaultGit(gpa, vault, &.{ "log", "--oneline" });
    defer empty_log.deinit(gpa);
    try testing.expectEqualStrings("", empty_log.stdout);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "hello\n" });
    try commitIfDirty(gpa, testing.io, vault);
    const head = try headSubject(gpa, vault);
    defer gpa.free(head);
    try testing.expectEqualStrings("vault: a.md", head);
}

test "commitIfDirty names every staged path up to the cap, then falls back to a count" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.md", .data = "a\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.md", .data = "b\n" });
    try commitIfDirty(gpa, testing.io, vault);
    const two = try headSubject(gpa, vault);
    defer gpa.free(two);
    try testing.expectEqualStrings("vault: a.md, b.md", two);

    inline for (.{ "c.md", "d.md", "e.md", "f.md", "g.md" }) |name|
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x\n" });
    try commitIfDirty(gpa, testing.io, vault);
    const many = try headSubject(gpa, vault);
    defer gpa.free(many);
    try testing.expectEqualStrings("vault: 5 files", many);
}

test "tryAcquire is exclusive until release, then a fresh lock is honored" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    const first = (try tryAcquire(gpa, testing.io, vault)).?;
    try testing.expectEqual(@as(?[]u8, null), try tryAcquire(gpa, testing.io, vault));
    release(testing.io, gpa, first);

    const second = (try tryAcquire(gpa, testing.io, vault)).?;
    release(testing.io, gpa, second);
}

test "a lock older than the staleness threshold is stolen, not honored forever" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    const lock = try lockPath(gpa, vault);
    defer gpa.free(lock);
    try Io.Dir.cwd().createDir(testing.io, lock, .default_dir);
    // Back-date it past the staleness threshold instead of sleeping the
    // test for real minutes.
    const long_ago = Io.Timestamp.now(testing.io, .real).nanoseconds - lock_stale_after_ns - std.time.ns_per_s;
    try Io.Dir.cwd().setTimestamps(testing.io, lock, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = long_ago } } });

    const stolen = try tryAcquire(gpa, testing.io, vault);
    try testing.expect(stolen != null);
    release(testing.io, gpa, stolen.?);
}

test "acquireWithRetry gives up after max_tries against a lock that never frees" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    const held = (try tryAcquire(gpa, testing.io, vault)).?;
    defer release(testing.io, gpa, held);

    const got = try acquireWithRetry(gpa, testing.io, vault, 2);
    try testing.expectEqual(@as(?[]u8, null), got);
}

test "upstreamOf and pushIfAhead are silent no-ops with no remote configured" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try initRepo(gpa, vault);

    try testing.expectEqual(@as(?[]u8, null), try upstreamOf(gpa, testing.io, vault));
    try testing.expectEqual(@as(usize, 0), try commitsAhead(gpa, testing.io, vault));
    try pushIfAhead(gpa, testing.io, vault); // must not error
    try testing.expect(pull(gpa, testing.io, vault)); // no upstream: trivially safe
}
