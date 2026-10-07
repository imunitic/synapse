//! Spawn a child process and capture what it writes.
//!
//! A helper over `std.Io`, not a port: `Io`'s vtable already carries
//! `processSpawn`/`childWait`/`childKill`, substitutable through the same
//! boundary as the filesystem and clock. Only adapters call this; core
//! spawns nothing.
//!
//! `argv[0]` resolves against the parent environment's PATH, so
//! `tests/fixtures/fake-bin` prepended to PATH intercepts `git`
//! here too, same as it does for shell scripts.

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

    /// Null when the child did not exit normally (killed, stopped) -- not
    /// the same as a non-zero exit.
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
    /// Written to the child's stdin, then closed. Null means no stdin at
    /// all, not inherited -- avoids a hook hanging on terminal input.
    stdin: ?[]const u8 = null,
    /// Bounds allocation if a child floods a stream.
    max_output: Io.Limit = .limited(64 << 20),
};

/// The three streams are serviced concurrently -- a correctness requirement,
/// not a performance one: writing all of stdin before reading stdout
/// deadlocks once the child's output fills the pipe buffer while it's still
/// waiting for input (`git hash-object --stdin-paths` hits this exactly).
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

/// Does not close the file -- `childWait` closes it, and closing it here
/// too would be a double close (EBADF).
fn drain(io: Io, gpa: Allocator, file: Io.File, limit: Io.Limit) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(gpa, limit);
}

fn feedStdin(io: Io, child: *std.process.Child, data: []const u8) void {
    const file = child.stdin.?;
    // Must close this ourselves, or the child never sees end-of-input.
    // Clearing the field stops `childWait` closing it again.
    defer {
        file.close(io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    // EPIPE from a child that exits without reading is not our failure --
    // `wait` reports the exit status; don't mask it with a write error.
    w.interface.writeAll(data) catch return;
    w.interface.flush() catch return;
}

const testing = std.testing;

// `std.testing.io`, not a hand-built `Io.Threaded`: the latter's default
// `environ = .empty` silently falls back to `Threaded.default_PATH`, which
// looks like it works on a developer machine but ignores the real PATH.

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

    // Both directions well past a pipe buffer -- hangs if serviced one after
    // another instead of concurrently.
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
    // Puts an executable somewhere no PATH fallback could reach, so finding
    // it by bare name proves the real PATH drives resolution -- running
    // `echo` wouldn't, since `/bin` is in `Threaded.default_PATH` too.
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

    // An Io whose whole environment is one PATH entry. Resolution is driven
    // by the Io's environ, not anything passed per-spawn, so this is the
    // only way to vary it.
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
