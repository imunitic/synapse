//! `synapse-bard-hook stop-nudge` -- Stop: every `N` turns, forces a "worth
//! capturing in the Writer's notes vault" check-in. `SessionStart` only
//! raises this once, at the very start of a session; nothing else re-raises
//! it for the rest of a long one, so cross-cutting findings that surface
//! mid-session default to whatever task-shaped location is already open
//! instead of `_bard/vault/`. Mirrors `synapse-hook stop-nudge`'s own
//! turn-count shape exactly, minus that hook's git pull/push half --
//! `_bard/vault/` is a plain directory in the bible repo's own commits, with
//! no separate remote-sync mechanism of its own to drive.
//!
//! Gated on `session_start.bardEnabled`: a repo where the plugin merely
//! happens to be installed, with `_bard/` never created, gets no nudge --
//! same reasoning `session_start.zig`'s own gate already documents.
//!
//! The nudge uses `additionalContext`, not `decision: block`, since the CLI
//! labels the former "Stop hook feedback" rather than the alarming "Stop
//! hook error".

const std = @import("std");
const core = @import("core");
const common = @import("common.zig");
const session_start = @import("session_start.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Turns between check-ins -- same cadence `synapse-hook stop-nudge` uses.
const n = 25;

/// The `synapse-bard-claude.md` heading the nudge text points readers at --
/// named once so a test can confirm the heading it cites still exists,
/// instead of two copies (nudge prose, test expectation) drifting apart
/// silently.
const vault_note_heading = "The Writer's notes vault as permanent memory";

pub fn run(gpa: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const home = env.get("HOME") orelse return;

    var payload = common.Payload.read(gpa, io);
    defer payload.deinit();

    const id = core.identity.resolve(gpa, io, payload.str("cwd") orelse ".") catch return;
    defer id.deinit(gpa);
    if (!session_start.bardEnabled(gpa, io, id.layout.repo_root)) return;

    const sid = payload.str("session_id") orelse "default";

    const result = try tick(gpa, io, home, sid);
    defer if (result.text) |t| gpa.free(t);
    if (result.text) |t| try common.emitContext(gpa, io, "Stop", t);
}

pub const Tick = struct {
    /// The check-in nudge, when this call just re-armed. Caller owns it.
    text: ?[]u8,
    /// The running total turn count, across every call for this session.
    total: usize,
};

/// Advances this session's turn counters and decides whether a check-in
/// nudge is due -- separated from `run()` so a test can drive it directly,
/// against real state files, without a real stdin payload or a real `_bard/`
/// repo.
pub fn tick(gpa: Allocator, io: Io, home: []const u8, sid: []const u8) !Tick {
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.claude/state", .{home});
    defer gpa.free(state_dir);
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};

    const total_path = try std.fmt.allocPrint(gpa, "{s}/synapse-bard-stop-nudge-total-{s}", .{ state_dir, sid });
    defer gpa.free(total_path);
    const since_path = try std.fmt.allocPrint(gpa, "{s}/synapse-bard-stop-nudge-since-{s}", .{ state_dir, sid });
    defer gpa.free(since_path);

    const total = readCount(gpa, io, total_path) + 1;
    const since = readCount(gpa, io, since_path) + 1;
    try writeCount(gpa, io, total_path, total);

    if (since >= n) {
        try writeCount(gpa, io, since_path, 0);
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.print(
            "This session has grown substantial ({d} turns, re-armed at the {d}-turn mark). Before continuing: did this session settle a plot/worldbuilding/continuity decision, surface research worth keeping, or reach a milestone worth persisting to the Writer's notes vault (_bard/vault/)? If so, write it up now (see \"{s}\" in synapse-bard-claude.md, or use /synapse-bard-note) while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.",
            .{ total, n, vault_note_heading },
        );
        return .{ .text = try gpa.dupe(u8, text.written()), .total = total };
    } else {
        try writeCount(gpa, io, since_path, since);
        return .{ .text = null, .total = total };
    }
}

fn readCount(gpa: Allocator, io: Io, path: []const u8) usize {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch |e| {
        // FileNotFound is the ordinary first-run case, not a failure.
        if (e != error.FileNotFound)
            std.debug.print("synapse-bard-hook: unreadable stop-nudge counter, restarting from 0 ({s}, {t})\n", .{ path, e });
        return 0;
    };
    defer gpa.free(text);
    return std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t\r\n"), 10) catch |e| {
        std.debug.print("synapse-bard-hook: corrupt stop-nudge counter, restarting from 0 ({s}, {t})\n", .{ path, e });
        return 0;
    };
}

fn writeCount(gpa: Allocator, io: Io, path: []const u8, value: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{value});
    _ = gpa;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |e| {
        std.debug.print("synapse-bard-hook: could not write the stop-nudge counter, it may not fire on schedule ({s}, {t})\n", .{ path, e });
    };
}

const testing = std.testing;

test "no nudge before the check-in turn" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var i: usize = 0;
    while (i < n - 1) : (i += 1) {
        const r = try tick(gpa, testing.io, home, "s1");
        try testing.expectEqual(@as(?[]u8, null), r.text);
    }
}

test "nudge fires on the Nth turn, naming the check-in mark" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var i: usize = 0;
    var last: ?[]u8 = null;
    while (i < n) : (i += 1) {
        if (last) |t| gpa.free(t);
        const r = try tick(gpa, testing.io, home, "s1");
        last = r.text;
    }
    const text = last.?;
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "_bard/vault/") != null);
    try testing.expect(std.mem.indexOf(u8, text, "25 turns") != null);
}

test "the nudge re-arms after another cycle" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var i: usize = 0;
    var fires: usize = 0;
    while (i < 2 * n) : (i += 1) {
        const r = try tick(gpa, testing.io, home, "s1");
        if (r.text) |t| {
            fires += 1;
            gpa.free(t);
        }
    }
    try testing.expectEqual(@as(usize, 2), fires);
}

test "separate sessions count turns independently" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = try tick(gpa, testing.io, home, "s1");
        if (r.text) |t| gpa.free(t);
    }
    // A fresh session hasn't accumulated any turns yet.
    const r2 = try tick(gpa, testing.io, home, "s2");
    try testing.expectEqual(@as(?[]u8, null), r2.text);
    try testing.expectEqual(@as(usize, 1), r2.total);
}

test "the nudge cites a synapse-bard-claude.md heading that actually exists" {
    // Same self-check `synapse-hook stop-nudge`'s own test runs: renaming
    // the heading without this constant (or the reverse) leaves a pointer
    // to a section that isn't there, and nothing about reading the nudge
    // would reveal it. `zig build test`'s working directory is the repo
    // root, so this reads the real shipped file rather than a fixture copy.
    const gpa = testing.allocator;
    const heading_line = try std.fmt.allocPrint(gpa, "# {s}", .{vault_note_heading});
    defer gpa.free(heading_line);
    const content = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        "packages/synapse-bard/synapse-bard-claude.md",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, heading_line)) return;
    }
    try testing.expect(false);
}

test "bardEnabled gates the nudge the same way it gates SessionStart's own injection" {
    // `run()` itself isn't exercised end-to-end here -- it reads its payload
    // from real stdin, same as `session_start.run()`, and neither file tests
    // that path directly for the same reason. What matters is that the gate
    // this hook calls is the same one, already proven in session_start.zig's
    // own tests -- confirmed directly rather than assumed.
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try testing.expect(!session_start.bardEnabled(gpa, testing.io, root));
    try tmp.dir.createDirPath(testing.io, "_bard/graph");
    try testing.expect(session_start.bardEnabled(gpa, testing.io, root));
}
