//! `synapse-hook` -- the five Claude Code hooks, in one binary that links no C.
//!
//!   synapse-hook staleness        PostToolUse (Write|Edit|MultiEdit)
//!   synapse-hook prompt-context   UserPromptSubmit
//!   synapse-hook session-start    SessionStart
//!   synapse-hook stop-nudge       Stop
//!   synapse-hook db-sync          PostToolUse (vault mutations)
//!
//! A separate binary rather than subcommands of `synapse`, and the reason is the one
//! place this system is measured against a person waiting: a hook runs on every edit
//! and every turn, so its startup must depend on nothing else the stage links. This
//! one imports `core` and `adapters` and never `treesitter`, so it links no
//! libtree-sitter and needs no C compiler -- which is what `build.zig`'s per-app
//! dependency sets exist for.
//!
//! ## Every missing precondition exits 0
//!
//! No vault, no certificate, no namespace, a remote mismatch, a branch mismatch, no
//! index, a file outside the repo: all of them are silence and exit 0. **A hook that
//! errors is worse than one that quietly does nothing** -- it interrupts a turn to
//! report a condition the user did not ask about and usually cannot act on. The
//! scripts made that choice everywhere and it is preserved everywhere.
//!
//! That is also why `main` catches: an unexpected error inside a hook is still a
//! hook failing in front of someone, so it becomes exit 0 and a silent turn.
//!
//! ## Identity still arrives from the wrapper
//!
//! `synapse-identity.sh` is bash until the last sourcer is ported, and these five
//! were among the sourcers. So each hook keeps a thin wrapper that resolves the
//! namespace and exports it, exactly as the eight ported scripts do. The ordering
//! rule holds -- no Zig caller against a bash callee -- and the wrappers collapse
//! when identity lands.

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
    \\  stop-nudge       Stop: the periodic capture check-in, and the vault push
    \\  db-sync          PostToolUse: commit a vault edit to the vault's own git
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse ""; // stop-nudge's own path, to re-invoke for vault-push

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

    // Every hook returns void and reports nothing: the exit code is always 0, and
    // the payload is whatever it wrote to stdout. `catch` rather than `try`, because
    // an unexpected failure in a hook is still a hook failing in front of a person.
    if (std.mem.eql(u8, which, "staleness")) {
        staleness.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "prompt-context")) {
        prompt_context.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "session-start")) {
        session_start.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "stop-nudge")) {
        stop_nudge.run(gpa, io, env, argv0) catch {};
    } else if (std.mem.eql(u8, which, "db-sync")) {
        db_sync.run(gpa, io, env) catch {};
    } else if (std.mem.eql(u8, which, "vault-push")) {
        // Not registered as a hook: `stop-nudge` spawns this detached so the turn
        // never waits on the network. See `stop_nudge.push`.
        stop_nudge.push(gpa, io, env) catch {};
    } else {
        std.debug.print("synapse-hook: unknown hook '{s}'\n{s}", .{ which, usage });
        return 2;
    }
    return 0;
}

test {
    // Zig analyses lazily, so a test root that only declares `main` reaches none of
    // the hook files' own tests -- `zig build test` reported the same count before
    // and after this block existed. Referencing them is what collects them.
    _ = @import("common.zig");
    _ = staleness;
    _ = prompt_context;
    _ = session_start;
    _ = stop_nudge;
    _ = db_sync;
}
