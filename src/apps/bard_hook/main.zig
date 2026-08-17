//! `synapse-bard-hook` -- Claude Code hooks for the `synapse-bard` plugin,
//! same relationship to `synapse-bard` that `synapse-hook` has to `synapse`.
//! Imports `core`/`adapters`, never `treesitter`, matching `synapse-hook`'s
//! own reasoning: a hook runs on every edit and turn, so it must not carry
//! the C toolchain a hook has no use for.
//!
//!   synapse-bard-hook session-start    SessionStart: inject _bard/vault/Index.md
//!
//! Every missing precondition exits 0, same contract `synapse-hook` already
//! follows -- a hook that errors interrupts a turn about something the user
//! usually can't act on.

const std = @import("std");
const session_start = @import("session_start.zig");

const usage =
    \\usage: synapse-bard-hook <hook>
    \\
    \\  session-start    SessionStart: inject _bard/vault/Index.md
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // this binary's own invoked path

    const which = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (std.mem.eql(u8, which, "-h") or std.mem.eql(u8, which, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    // `catch`, not `try`: exit code is always 0, payload is whatever the
    // hook wrote to stdout.
    if (std.mem.eql(u8, which, "session-start")) {
        session_start.run(gpa, io, env) catch {};
    } else {
        std.debug.print("synapse-bard-hook: unknown hook '{s}'\n{s}", .{ which, usage });
        return 2;
    }
    return 0;
}

test {
    _ = @import("common.zig");
    _ = session_start;
}
