//! Machine-local Vault timestamp formatting.
//!
//! Vault notes deliberately preserve local wall-clock context, including the
//! timezone abbreviation. The supported release platforms all provide
//! POSIX `date`; keeping this in adapters preserves core's no-process/no-time
//! boundary and makes the exact format one small, testable operation.

const std = @import("std");
const process = @import("process.zig");

pub fn now(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const result = try process.run(io, gpa, &.{ "date", "+%Y-%m-%d %H:%M:%S %Z" }, .{ .max_output = .limited(256) });
    defer result.deinit(gpa);
    if (!result.ok()) return error.DateFailed;
    const value = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (value.len == 0) return error.DateFailed;
    return gpa.dupe(u8, value);
}

const testing = std.testing;

test "local timestamp has the Vault schema's serialized shape" {
    const value = try now(testing.allocator, testing.io);
    defer testing.allocator.free(value);
    try testing.expect(coreShape(value));
}

fn coreShape(value: []const u8) bool {
    return value.len >= 23 and value[4] == '-' and value[7] == '-' and value[10] == ' ' and
        value[13] == ':' and value[16] == ':' and value[19] == ' ';
}
