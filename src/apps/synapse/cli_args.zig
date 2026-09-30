//! Small shared helpers for hand-rolled CLI argument loops -- every
//! `*_cmd.zig` file parses its own flags with a bare `while (args.next())`,
//! not a shared parser, so a fix that belongs in the loop shape itself
//! lives here once instead of being patched into each file separately.

const std = @import("std");
const command_map = @import("core").command_map;

/// Rejects a captured value that looks like a flag itself (starts with
/// `--`). Pass `args.next()`'s result straight through this before
/// accepting it as a flag's own value -- `--repo --help` would otherwise
/// swallow `--help` as `--repo`'s value, silently hiding the real flag
/// from ever being recognized. Pure over the already-fetched optional
/// (not the iterator itself) so it's testable with plain values.
pub fn takenValue(next: ?[]const u8) ?[]const u8 {
    const v = next orelse return null;
    if (std.mem.startsWith(u8, v, "--")) return null;
    return v;
}

const testing = std.testing;

test "takenValue passes through an ordinary value" {
    try testing.expectEqualStrings("foo", takenValue("foo").?);
}

test "takenValue refuses a value that looks like a flag, so --help is never swallowed" {
    try testing.expectEqual(@as(?[]const u8, null), takenValue("--help"));
}

test "takenValue returns null when there was no next argument at all" {
    try testing.expectEqual(@as(?[]const u8, null), takenValue(null));
}

/// After a usage error, the question-to-command map entries for `sub`, on
/// stderr: the commands a session was reaching for, in the form they take.
/// Prints nothing for a subcommand the map does not cover.
pub fn printMapFor(sub: []const u8) void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    command_map.renderFor(&w, sub) catch return;
    if (w.buffered().len != 0) std.debug.print("\nSynapse commands by question:\n{s}", .{w.buffered()});
}
