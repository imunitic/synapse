//! `synapse-hook` -- the five Claude Code hooks, in one binary that links no C.
//!
//!   synapse-hook staleness        PostToolUse (Write|Edit|MultiEdit)
//!   synapse-hook prompt-context   UserPromptSubmit
//!   synapse-hook session-start    SessionStart
//!   synapse-hook stop-nudge       Stop
//!   synapse-hook db-sync          PostToolUse (vault mutations)
//!
//! A separate binary, not `synapse` subcommands, since a hook runs on every
//! edit and turn: this imports `core`/`adapters`, never `treesitter`, so it
//! links no libtree-sitter and needs no C compiler.
//!
//! **Every missing precondition exits 0** -- no vault, no namespace, a
//! remote/branch mismatch, no index: all silence. A hook that errors
//! interrupts a turn about something the user usually can't act on, so
//! `main` catches too: an unexpected failure is still a hook failing in
//! front of someone.
//!
//! Identity resolves in-process via `core.identity.resolve()` -- no
//! external wrapper script.

const std = @import("std");
const staleness = @import("staleness.zig");
const prompt_context = @import("prompt_context.zig");
const session_start = @import("session_start.zig");
const stop_nudge = @import("stop_nudge.zig");
const db_sync = @import("db_sync.zig");

const usage =
    \\usage: synapse-hook <hook>
    \\
    \\  staleness        PostToolUse: flag owning nodes, check cited evidence
    \\  prompt-context   UserPromptSubmit: the standing one-line pointer
    \\  session-start    SessionStart: inject the vault index and the pointer
    \\  stop-nudge       Stop: the periodic capture check-in, and the vault sync
    \\  db-sync          PostToolUse: commit a vault edit to the vault's own git
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse ""; // this binary's own invoked path -- stop-nudge re-invokes it for vault-push; session-start resolves synapse-claude.md relative to it

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
    if (std.mem.eql(u8, which, "staleness")) {
        staleness.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "prompt-context")) {
        prompt_context.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "session-start")) {
        session_start.run(gpa, io, env, argv0) catch {};
    } else if (std.mem.eql(u8, which, "stop-nudge")) {
        stop_nudge.run(gpa, io, env, argv0) catch {};
    } else if (std.mem.eql(u8, which, "db-sync")) {
        db_sync.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "vault-sync")) {
        // Not registered as a hook: stop-nudge spawns this detached so the
        // turn never waits on the network.
        stop_nudge.sync(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "vault-pull")) {
        // Not registered as a hook either: session-start spawns this
        // detached, same reason as vault-sync above.
        stop_nudge.pull(gpa, io, env) catch {};
    } else {
        std.debug.print("synapse-hook: unknown hook '{s}'\n{s}", .{ which, usage });
        return 2;
    }
    return 0;
}

test {
    _ = @import("test_root.zig");
}
