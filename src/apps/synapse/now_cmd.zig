//! `synapse now` -- machine-local timestamp, in the two shapes every write
//! path already needs, so a caller has no reason left to shell out to `date`.
//!
//!   now              RFC3339, e.g. 2026-09-07T14:32:05+02:00 (created/updated)
//!   now --built-at   YYYY-MM-DD HH:MM, e.g. 2026-09-07 14:32 (built_at)
//!
//! Same `adapters.local_timestamp` zeit path every internal write already
//! uses (schema_validation_store, write-node, project-index) -- this just
//! exposes it so an agent asks the binary instead of reading the system
//! clock through a subprocess of its own.

const std = @import("std");
const adapters = @import("adapters");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage_text =
    \\usage: synapse now [--built-at]
    \\
    \\  (default)    RFC3339 with a numeric offset -- `created`/`updated`'s shape
    \\  --built-at   `YYYY-MM-DD HH:MM`, no seconds or offset -- `built_at`'s shape
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
) !u8 {
    _ = env;
    var built_at = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage_text});
            return 0;
        } else if (std.mem.eql(u8, arg, "--built-at")) {
            built_at = true;
        } else {
            std.debug.print("{s}", .{usage_text});
            return 2;
        }
    }

    const value = if (built_at)
        try adapters.local_timestamp.builtAt(gpa, io)
    else
        try adapters.local_timestamp.now(gpa, io);
    defer gpa.free(value);

    var buf: [64]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    // No trailing newline: same convention as `namespace`, for the same
    // reason -- a caller substituting this into a value shouldn't have to
    // strip one first.
    try out.interface.writeAll(value);
    try out.interface.flush();
    return 0;
}
