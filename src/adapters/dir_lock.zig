//! One directory-as-lock primitive, shared by every caller that needs
//! mutual exclusion over a filesystem resource: the vault's own git sync
//! (`git_sync.zig`) and the grammar cache's clone/compile steps
//! (`treesitter/grammar.zig`), which duplicated this exact shape three
//! times between them -- `mkdir` as the atomic test-and-set, an mtime-aged
//! lock treated as abandoned and stolen once, a short bounded retry with a
//! fixed sleep between attempts. Each caller keeps its own lock path and
//! staleness window (git_sync's sync lock times out in minutes; a grammar
//! clone can legitimately take much longer) -- only the mechanism moves
//! here, not any caller's own policy or its own "did someone else already
//! finish" re-check, which stays exactly where it was, next to the work
//! it's checking on.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Unreadable counts as not-abandoned: a lock that vanished mid-check
/// isn't ours to reason about. Wall clock, compared against the lock
/// directory's own mtime -- no separate marker file needed.
fn abandoned(io: Io, lock_path: []const u8, stale_after_ns: i96) bool {
    const st = Io.Dir.cwd().statFile(io, lock_path, .{}) catch return false;
    const now = Io.Timestamp.now(io, .real).nanoseconds;
    return now - st.mtime.nanoseconds > stale_after_ns;
}

/// One non-blocking attempt: `mkdir` is the atomic test-and-set. Steals an
/// abandoned lock once if the first attempt finds one, but never loops or
/// sleeps itself -- a caller on a write path can't afford to wait here;
/// that's what `acquireWithRetry` is for. Returns an owned copy of
/// `lock_path`, freed by `release`.
pub fn tryAcquire(gpa: Allocator, io: Io, lock_path: []const u8, stale_after_ns: i96) !?[]u8 {
    const lock = try gpa.dupe(u8, lock_path);
    errdefer gpa.free(lock);
    if (Io.Dir.cwd().createDir(io, lock, .default_dir)) |_| return lock else |_| {}
    if (abandoned(io, lock, stale_after_ns)) {
        Io.Dir.cwd().deleteDir(io, lock) catch {};
        if (Io.Dir.cwd().createDir(io, lock, .default_dir)) |_| return lock else |_| {}
    }
    gpa.free(lock);
    return null;
}

/// Bounded retry over `tryAcquire`, 200ms between attempts, for a caller
/// that can afford a short wait rather than losing its one attempt
/// outright.
pub fn acquireWithRetry(gpa: Allocator, io: Io, lock_path: []const u8, stale_after_ns: i96, max_tries: usize) !?[]u8 {
    var tries: usize = 0;
    while (tries < max_tries) : (tries += 1) {
        if (try tryAcquire(gpa, io, lock_path, stale_after_ns)) |lock| return lock;
        Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
    return null;
}

pub fn release(io: Io, gpa: Allocator, lock: []u8) void {
    Io.Dir.cwd().deleteDir(io, lock) catch {};
    gpa.free(lock);
}

const testing = std.testing;

test "tryAcquire creates the lock directory and reports success" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/x.lock", .{root});
    defer gpa.free(lock_path);

    const lock = (try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min)).?;
    defer release(testing.io, gpa, lock);
    _ = try Io.Dir.cwd().statFile(testing.io, lock_path, .{});
}

test "a second tryAcquire against a fresh lock fails" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/x.lock", .{root});
    defer gpa.free(lock_path);

    const first = (try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min)).?;
    defer release(testing.io, gpa, first);

    try testing.expectEqual(@as(?[]u8, null), try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min));
}

test "release removes the lock directory so a later acquire succeeds" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/x.lock", .{root});
    defer gpa.free(lock_path);

    const first = (try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min)).?;
    release(testing.io, gpa, first);

    const second = (try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min)).?;
    release(testing.io, gpa, second);
}

test "a lock older than the staleness window is stolen, not respected" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/x.lock", .{root});
    defer gpa.free(lock_path);

    try Io.Dir.cwd().createDirPath(testing.io, lock_path);
    const long_ago = Io.Timestamp.now(testing.io, .real).nanoseconds - std.time.ns_per_min - std.time.ns_per_s;
    try Io.Dir.cwd().setTimestamps(testing.io, lock_path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = long_ago } } });

    const stolen = (try tryAcquire(gpa, testing.io, lock_path, std.time.ns_per_min)).?;
    defer release(testing.io, gpa, stolen);
}

test "acquireWithRetry waits out a short-lived holder" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/x.lock", .{root});
    defer gpa.free(lock_path);

    // Fresh (not stale), so the retry loop has to actually wait for it,
    // not just steal it on the first abandoned check.
    try Io.Dir.cwd().createDirPath(testing.io, lock_path);
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // Released by a detached thread shortly after the retry loop starts,
    // so acquireWithRetry has to genuinely retry rather than succeed on
    // its first attempt.
    const Releaser = struct {
        fn run(release_io: Io, path: []const u8) void {
            Io.sleep(release_io, .fromMilliseconds(50), .awake) catch {};
            Io.Dir.cwd().deleteDir(release_io, path) catch {};
        }
    };
    var thread = try std.Thread.spawn(.{}, Releaser.run, .{ io, lock_path });
    defer thread.join();

    const lock = (try acquireWithRetry(gpa, io, lock_path, std.time.ns_per_min, 10)).?;
    release(io, gpa, lock);
}
