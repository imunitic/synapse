//! The report `synapse doctor` prints, and the rule for what it exits with.
//!
//! Every silent guard elsewhere is individually correct (a hook that errors
//! is worse than one that quietly does nothing), but collectively they mean a
//! broken install is indistinguishable from a working one with nothing to
//! say. This is the one place every guard has a counterpart that speaks --
//! a check with no corresponding silent failure elsewhere doesn't belong here.
//!
//! Three levels: `fail` is a broken install; `ok` needs no explanation;
//! `warn` is ordinary-but-worth-seeing (no namespace for this branch, no tags
//! cache yet) -- the same absence is normal on a fresh checkout and a symptom
//! on one where `/synapse-init` should have run. Only `fail` affects the exit
//! code.

const std = @import("std");

pub const Status = enum {
    ok,
    warn,
    fail,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warn => "warn",
            .fail => "FAIL",
        };
    }
};

pub const Check = struct {
    /// A short noun phrase, aligned in the report.
    name: []const u8,
    status: Status,
    /// What was found, or what's missing and what to do. Empty is fine for
    /// an `ok` whose name says everything.
    detail: []const u8,
};

/// 1 when anything failed, else 0. Warnings don't count -- an absent
/// namespace is normal for an unclustered branch, and a doctor that failed
/// on it couldn't be used in a script.
pub fn exitCode(checks: []const Check) u8 {
    for (checks) |c| if (c.status == .fail) return 1;
    return 0;
}

pub const Counts = struct { ok: usize = 0, warn: usize = 0, fail: usize = 0 };

pub fn counts(checks: []const Check) Counts {
    var n: Counts = .{};
    for (checks) |c| switch (c.status) {
        .ok => n.ok += 1,
        .warn => n.warn += 1,
        .fail => n.fail += 1,
    };
    return n;
}

/// One line per check, status first so a reader scans the left edge. `FAIL`
/// is upper-case so the one important line stands out.
pub fn writeReport(w: *std.Io.Writer, checks: []const Check) !void {
    var width: usize = 0;
    for (checks) |c| width = @max(width, c.name.len);
    for (checks) |c| {
        try w.print("{s: <4}  {s}", .{ c.status.label(), c.name });
        if (c.detail.len != 0) {
            var pad = width - c.name.len;
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
            try w.print("  {s}", .{c.detail});
        }
        try w.writeAll("\n");
    }
    const n = counts(checks);
    try w.print("\n{d} ok, {d} warning(s), {d} failure(s)\n", .{ n.ok, n.warn, n.fail });
}

const testing = std.testing;

test "a warning never fails the command, and a failure always does" {
    try testing.expectEqual(@as(u8, 0), exitCode(&.{
        .{ .name = "a", .status = .ok, .detail = "" },
        .{ .name = "b", .status = .warn, .detail = "" },
    }));
    try testing.expectEqual(@as(u8, 1), exitCode(&.{
        .{ .name = "a", .status = .ok, .detail = "" },
        .{ .name = "b", .status = .fail, .detail = "" },
    }));
    try testing.expectEqual(@as(u8, 0), exitCode(&.{})); // nothing checked is not a failure
}

test "the report puts the status first and aligns the details" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, &.{
        .{ .name = "vault", .status = .ok, .detail = "/Users/x/Vault/Claude" },
        .{ .name = "namespace", .status = .warn, .detail = "none for fw-core@wip" },
        .{ .name = "certificate", .status = .fail, .detail = "absent: run setup-cert.sh" },
    });
    try testing.expectEqualStrings(
        "ok    vault        /Users/x/Vault/Claude\n" ++
            "warn  namespace    none for fw-core@wip\n" ++
            "FAIL  certificate  absent: run setup-cert.sh\n" ++
            "\n1 ok, 1 warning(s), 1 failure(s)\n",
        out.written(),
    );
}

test "a check with no detail prints only its name" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, &.{.{ .name = "git", .status = .ok, .detail = "" }});
    try testing.expectEqualStrings("ok    git\n\n1 ok, 0 warning(s), 0 failure(s)\n", out.written());
}
