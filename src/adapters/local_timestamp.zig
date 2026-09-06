//! Machine-local timestamp formatting, shared by every write path that used
//! to shell out to `date` independently.
//!
//! `zeit` resolves the local timezone by reading the system's own
//! already-installed tzdata (`/etc/localtime`) -- no subprocess, no bundled
//! data, and its `Io`-native `now` source is the same injectable-clock seam
//! this codebase already threads everywhere else, so both formatters below
//! are fixture-testable for the first time.

const std = @import("std");
const zeit = @import("zeit");

/// RFC3339 with a numeric, colon-separated offset (`Z` for UTC) --
/// `YYYY-MM-DDTHH:MM:SS±HH:MM` -- via zeit's own Go-style reference format,
/// not `Time.bufPrint(.rfc3339)` (which always appends a `.sss` fractional
/// part) or strftime's `%z` (which omits the colon). For `created`/`updated`
/// (`type: timestamp` in the vault-note-family schemas).
const rfc3339_format = "2006-01-02T15:04:05Z07:00";

/// `YYYY-MM-DD HH:MM`, local time, no seconds or offset -- `built_at`'s own
/// long-standing shape (`type: string` + `pattern:` in graph-node/v1, not a
/// `type: timestamp` field, deliberately left alone by the RFC3339 move
/// above: nothing compares it across a DST boundary the way `not_before`
/// does for `created`/`updated`, so there is no correctness reason to widen
/// it, only a reason to stop shelling to `date` under it).
const built_at_format = "2006-01-02 15:04";

pub fn now(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return format(gpa, io, rfc3339_format, 40);
}

pub fn builtAt(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return format(gpa, io, built_at_format, 20);
}

fn format(gpa: std.mem.Allocator, io: std.Io, comptime layout: []const u8, comptime buf_len: usize) ![]u8 {
    const local = try zeit.local(gpa, io, .{});
    defer local.deinit();
    const t = zeit.instant(.{ .now = io }, &zeit.utc).in(&local).time();

    var buf: [buf_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try t.gofmt(&writer, layout);
    return gpa.dupe(u8, writer.buffered());
}

const testing = std.testing;

test "local timestamp is RFC3339 with a colon-separated numeric offset" {
    const value = try now(testing.allocator, testing.io);
    defer testing.allocator.free(value);
    try testing.expect(coreShape(value));
}

fn coreShape(value: []const u8) bool {
    if (value.len < 20) return false;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':') return false;
    const tail = value[19..];
    if (std.mem.eql(u8, tail, "Z")) return true;
    return tail.len == 6 and (tail[0] == '+' or tail[0] == '-') and tail[3] == ':';
}

test "builtAt is YYYY-MM-DD HH:MM, no seconds or offset" {
    const value = try builtAt(testing.allocator, testing.io);
    defer testing.allocator.free(value);
    try testing.expectEqual(@as(usize, 16), value.len);
    try testing.expect(value[4] == '-' and value[7] == '-' and value[10] == ' ' and value[13] == ':');
}
