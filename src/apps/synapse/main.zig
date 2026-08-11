//! The `synapse` executable: subcommand dispatch over the shared core, wired
//! to the code profile's adapters (tree-sitter extraction, the Obsidian REST
//! store, inferred clustering, the full node lifecycle).
//!
//! The CLI contract is frozen. Every flag, every line of stdout and every exit
//! code matches what the bash scripts in `claude/lib/synapse/` produce today,
//! because `tests/*.bats` is the specification for this port and stays valid
//! only as long as that holds. A CLI improvement is a separate change, before
//! or after this rewrite, never inside it.
//!
//! Skeleton: dispatch and the adapter wiring arrive with the ports and the
//! first ported script.

const std = @import("std");

// Referenced, not merely imported. Zig analyses declarations lazily, so an
// `@import` nothing touches is never compiled -- and a build that never
// compiles `core` cannot be said to have checked anything about it, including
// that its own imports point the right way. Keep a real reference here for as
// long as dispatch is a stub.
const core = @import("core");
const ports = @import("ports");

comptime {
    _ = core;
    _ = ports;
}

const usage =
    \\usage: synapse <subcommand> [args]
    \\
    \\No subcommands are wired yet -- this binary is the skeleton for the port
    \\tracked as second-brain-setup-008. The bash implementations under
    \\~/.claude/lib/synapse are still the ones doing the work.
    \\
;

pub fn main() !u8 {
    std.debug.print("{s}", .{usage});
    return 2;
}
