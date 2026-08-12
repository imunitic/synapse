//! The report `synapse doctor` prints, and the rule for what it exits with.
//!
//! ## Why this command exists at all
//!
//! Every silent guard in the system is individually correct. A hook that errors is
//! worse than one that quietly does nothing: it interrupts a turn to report a
//! condition the person did not ask about and usually cannot act on. The staleness
//! hook alone exits 0 on a missing vault, a missing certificate, an absent namespace,
//! a remote mismatch and a branch mismatch.
//!
//! Collectively, though, those guards mean **a broken install is indistinguishable
//! from a working one with nothing to say**. Silence is the success signal everywhere,
//! so silence cannot also be the failure signal. This is the one place every guard has
//! a counterpart that speaks.
//!
//! That is the whole design rule for adding a check here: it must mirror a specific
//! guard somewhere else. A check with no corresponding silent failure is a check
//! nobody needed.
//!
//! ## Three levels, and `warn` is the interesting one
//!
//! `fail` is a broken install: something the tooling needs is absent or contradicts
//! itself. `ok` needs no explanation. `warn` is for a state that is **ordinary but
//! worth seeing** -- no namespace for this branch, no tags cache yet -- because the
//! same absence that is normal on a fresh checkout is a symptom on one where
//! `/synapse-init` was supposed to have run. Only `fail` affects the exit code, so a
//! warning never turns a working machine into a failing command.

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
    /// What was found, or what is missing and what to do. Empty is allowed for an
    /// `ok` whose name says everything.
    detail: []const u8,
};

/// 1 when anything failed, else 0.
///
/// Warnings deliberately do not count: an absent namespace is the normal state for a
/// branch nobody has clustered, and a doctor that exited non-zero for it could not be
/// used in a script.
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

/// One line per check, the status first so a reader scans the left edge.
///
/// `FAIL` is upper-case for the same reason: a report where every line starts with a
/// lower-case word is a report whose one important line does not stand out.
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
    // Nothing checked is not a failure -- it is a doctor that found nothing to say,
    // which cannot happen in practice but must not invent a verdict.
    try testing.expectEqual(@as(u8, 0), exitCode(&.{}));
}

test "the report puts the status first and aligns the details" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, &.{
        .{ .name = "vault", .status = .ok, .detail = "/Users/x/Obsidian/Claude" },
        .{ .name = "namespace", .status = .warn, .detail = "none for fw-core@wip" },
        .{ .name = "certificate", .status = .fail, .detail = "absent: run setup-obsidian-mcp.sh" },
    });
    try testing.expectEqualStrings(
        "ok    vault        /Users/x/Obsidian/Claude\n" ++
            "warn  namespace    none for fw-core@wip\n" ++
            "FAIL  certificate  absent: run setup-obsidian-mcp.sh\n" ++
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
