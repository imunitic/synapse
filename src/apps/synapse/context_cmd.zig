//! `synapse context` -- print what a session needs to use this repo's graph:
//! the absolute namespace directory and the task-to-command map.
//!
//!   context   the graph path and the map, for the checkout containing $PWD
//!
//! The same map the SessionStart hook injects (`core.command_map`), so what a
//! person sees here is what a session was told.

const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const prog = "synapse-context";

const usage_text =
    \\usage: synapse context
    \\
    \\  Prints this checkout's graph directory and the question-to-command map
    \\  the SessionStart hook injects.
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    if (args.next()) |arg| {
        std.debug.print("{s}", .{usage_text});
        return if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) 0 else 2;
    }

    var ctx = (try context.resolve(gpa, io, env, prog)) orelse return 1;
    defer ctx.deinit();
    if (!try context.verifyNamespace(&ctx, io, prog)) return 1;

    var buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try write(&out.interface, ctx.abs_dir);
    try out.interface.flush();
    return 0;
}

/// The graph directory line, then the map.
pub fn write(w: *Io.Writer, abs_dir: []const u8) !void {
    try w.print("Synapse graph for this repo and branch: {s}/ (map: {s}/Index.md)\n", .{ abs_dir, abs_dir });
    try core.command_map.render(w);
}

const testing = std.testing;

test "write names the absolute graph directory and every map entry" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, "/v/synapse/repo@main");
    try testing.expect(std.mem.indexOf(u8, out.written(), "/v/synapse/repo@main/Index.md") != null);
    for (core.command_map.entries) |e| {
        try testing.expect(std.mem.indexOf(u8, out.written(), e.command) != null);
    }
}
