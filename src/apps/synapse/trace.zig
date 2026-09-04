//! The `--trace` diagnostic file every tagging command accepts: one `tags
//! <paths...>` line, then one `path <p>` line per path -- the format the old
//! fake tree-sitter binary wrote, kept byte-compatible. Appended, not
//! truncated, so a test that runs the binary more than once accumulates a
//! full record rather than losing every run but the last.

const std = @import("std");
const Io = std.Io;

pub fn write(io: Io, trace: ?[]const u8, paths: []const []const u8) !void {
    const path = trace orelse return;
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    w.pos = (try f.stat(io)).size;
    try w.interface.writeAll("tags");
    for (paths) |p| try w.interface.print(" {s}", .{p});
    try w.interface.writeAll("\n");
    for (paths) |p| try w.interface.print("path {s}\n", .{p});
    try w.interface.flush();
}
