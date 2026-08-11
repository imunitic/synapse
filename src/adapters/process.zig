//! Spawn a child process and capture what it writes.
//!
//! This is a helper over `std.Io`, deliberately **not** a port. Zig 0.16's
//! `Io` vtable already carries `processSpawn`, `childWait` and `childKill`, so
//! process spawning is substitutable through the same boundary as the
//! filesystem, the clock and the network. Wrapping it in a vtable of our own
//! would re-derive what std already defines and leave us maintaining it
//! against a moving standard library, for nothing.
//!
//! Only adapters call this. Core spawns nothing.
//!
//! Test substitution keeps working the way the bats suite already does it:
//! `processSpawn` resolves `argv[0]` against the *parent* environment's PATH,
//! so a `tests/fixtures/fake-bin` prepended to PATH still intercepts `git` and
//! `curl` for a compiled binary exactly as it does for the shell scripts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Result, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    /// Null when the child did not exit normally -- killed by a signal,
    /// stopped, or something the OS reported that we do not model. Callers
    /// must not conflate that with an exit status: a `curl` killed mid-flight
    /// has not "returned non-zero", it never returned at all.
    pub fn exitCode(self: Result) ?u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => null,
        };
    }

    pub fn ok(self: Result) bool {
        return self.exitCode() == 0;
    }
};

pub const Options = struct {
    cwd: std.process.Child.Cwd = .inherit,
    /// Written to the child's stdin, which is then closed. Null means the
    /// child gets no stdin at all rather than inheriting ours -- a subprocess
    /// that unexpectedly blocks on terminal input inside a hook would hang a
    /// session with no visible cause.
    stdin: ?[]const u8 = null,
    /// Refuse rather than allocate without bound if a child floods a stream.
    max_output: Io.Limit = .limited(64 << 20),
};

/// The three streams are serviced concurrently, and that is a correctness
/// requirement rather than a performance one. Writing all of stdin before
/// reading stdout deadlocks as soon as the child's output fills the pipe
/// buffer while it is still waiting for input -- `git hash-object
/// --stdin-paths` over a hub node's sources is exactly that shape, tens of
/// kilobytes in each direction against a ~64 KB buffer. Reading stdout before
/// stderr deadlocks the same way when a child is chatty on stderr.
pub fn run(io: Io, gpa: Allocator, argv: []const []const u8, opts: Options) !Result {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = opts.cwd,
        .stdin = if (opts.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    var feed = if (opts.stdin) |data| io.async(feedStdin, .{ io, &child, data }) else null;
    var drain_err = io.async(drain, .{ io, gpa, child.stderr.?, opts.max_output });

    const out = drain(io, gpa, child.stdout.?, opts.max_output);
    const err = drain_err.await(io);
    if (feed) |*f| f.await(io);

    const stdout = try out;
    errdefer gpa.free(stdout);
    const stderr = try err;

    return .{ .term = try child.wait(io), .stdout = stdout, .stderr = stderr };
}

/// Does not close the file. `childWait` closes the child's own handles as
/// part of its cleanup, and closing them here first makes that a double close
/// -- EBADF, which `Io.Threaded` correctly treats as a use-after-free and
/// panics on rather than swallowing.
fn drain(io: Io, gpa: Allocator, file: Io.File, limit: Io.Limit) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(gpa, limit);
}

fn feedStdin(io: Io, child: *std.process.Child, data: []const u8) void {
    const file = child.stdin.?;
    // Closed here and cleared, which is the one handle we must close
    // ourselves: without it the child never sees end-of-input and a `cat -`
    // or a `git hash-object --stdin-paths` waits forever. Clearing the field
    // is what keeps `childWait`'s cleanup from closing it a second time.
    defer {
        file.close(io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    // A child that exits without reading its input gives us EPIPE, which is
    // its prerogative and not our failure: the exit status is the answer the
    // caller is waiting for, so let `wait` report it rather than masking it
    // with a write error from a stream nobody is reading.
    w.interface.writeAll(data) catch return;
    w.interface.flush() catch return;
}

const testing = std.testing;

// `std.testing.io` rather than an `Io.Threaded` built here. The test runner
// initialises that one per test with the process's real environment, and a
// hand-built `.init(gpa, .{})` gets `environ = .empty` instead -- which does
// not fail, it silently falls back to `Threaded.default_PATH`
// ("/usr/local/bin:/bin/:/usr/bin"). Every PATH-dependent spawn then resolves
// against three fixed directories rather than the caller's PATH, and on a
// developer machine that is nearly always indistinguishable from working.

test "captures stdout and a zero exit" {
    const io = testing.io;

    const res = try run(io, testing.allocator, &.{ "/bin/echo", "hello" }, .{});
    defer res.deinit(testing.allocator);

    try testing.expectEqualStrings("hello\n", res.stdout);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(res.ok());
    try testing.expectEqual(@as(?u8, 0), res.exitCode());
}

test "a non-zero exit is reported, not raised as an error" {
    const io = testing.io;

    const res = try run(io, testing.allocator, &.{ "/bin/sh", "-c", "exit 3" }, .{});
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(?u8, 3), res.exitCode());
    try testing.expect(!res.ok());
}

test "stdout and stderr are kept apart" {
    const io = testing.io;

    const res = try run(io, testing.allocator, &.{ "/bin/sh", "-c", "echo out; echo err >&2" }, .{});
    defer res.deinit(testing.allocator);

    try testing.expectEqualStrings("out\n", res.stdout);
    try testing.expectEqualStrings("err\n", res.stderr);
}

test "stdin is fed and the child sees end-of-input" {
    const io = testing.io;

    const res = try run(io, testing.allocator, &.{ "/bin/cat", "-" }, .{ .stdin = "piped\n" });
    defer res.deinit(testing.allocator);

    try testing.expectEqualStrings("piped\n", res.stdout);
    try testing.expect(res.ok());
}

test "large stdin against streaming stdout does not deadlock" {
    const io = testing.io;

    // Both directions well past a pipe buffer, which is the case that hangs if
    // the streams are serviced one after another instead of concurrently.
    const big = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    big[big.len - 1] = '\n';

    const res = try run(io, testing.allocator, &.{ "/bin/cat", "-" }, .{ .stdin = big });
    defer res.deinit(testing.allocator);

    try testing.expectEqual(big.len, res.stdout.len);
    try testing.expect(res.ok());
}

test "argv[0] resolves against the caller's PATH, which is what keeps fake-bin working" {
    // The earlier version of this test ran `echo` and passed everywhere,
    // including where PATH was not consulted at all -- `/bin` is inside
    // `Threaded.default_PATH`, so a fallback search finds it just the same. It
    // therefore proved that *a* search happens, not that the *process's* PATH
    // drives it, which is the only version of the claim `tests/fixtures/
    // fake-bin` depends on. This one puts an executable somewhere no fallback
    // could reach and requires it to be found by bare name.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.writeFile(io, .{
        .sub_path = "synapse-path-probe",
        .data = "#!/bin/sh\necho found via PATH\n",
        .flags = .{ .permissions = .executable_file },
    });

    // An Io whose whole environment is one PATH entry, pointing at that
    // directory and nothing else. Resolution is driven by the *Io's* environ,
    // not by anything passed per-spawn -- `SpawnOptions.environ_map` says so in
    // its own doc comment -- so this is the only way to vary it.
    const entry = try std.fmt.allocPrintSentinel(gpa, "PATH={s}", .{dir}, 0);
    defer gpa.free(entry);
    const envp = try gpa.allocSentinel(?[*:0]u8, 1, null);
    defer gpa.free(envp);
    envp[0] = entry.ptr;

    var scoped: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = .{ .slice = envp } } });
    defer scoped.deinit();

    const res = try run(scoped.io(), gpa, &.{"synapse-path-probe"}, .{});
    defer res.deinit(gpa);

    try testing.expectEqualStrings("found via PATH\n", res.stdout);
    try testing.expect(res.ok());
}
