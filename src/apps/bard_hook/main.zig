//! `synapse-bard-hook` -- Claude Code hooks for the `synapse-bard` plugin,
//! same relationship to `synapse-bard` that `synapse-hook` has to `synapse`.
//! Imports `core`/`adapters`, never `treesitter`, matching `synapse-hook`'s
//! own reasoning: a hook runs on every edit and turn, so it must not carry
//! the C toolchain a hook has no use for.
//!
//! Placeholder: no hook is implemented yet -- SessionStart (inject the
//! vault's Index.md) is the first one due, in a later step of the
//! synapse-bard-001 task note. Every missing precondition exits 0, same
//! contract `synapse-hook` already follows -- a hook that errors interrupts
//! a turn about something the user usually can't act on.

const std = @import("std");

const usage =
    \\usage: synapse-bard-hook <hook>
    \\
    \\No hooks implemented yet -- see the synapse-bard-001 task note.
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

    // Every missing precondition is silence, same contract synapse-hook
    // follows -- no hook is wired yet, so every hook name is "missing."
    return 0;
}
