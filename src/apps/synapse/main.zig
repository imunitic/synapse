//! The `synapse` executable: subcommand dispatch over the shared core, wired
//! to the code profile's adapters (tree-sitter extraction, the vault
//! store, inferred clustering, the full node lifecycle).
//!
//! CLI contract is frozen: `tests/*.bats` is the spec for every flag, stdout
//! line and exit code. CLI improvements are a separate change, never inside
//! one that isn't about the CLI itself.
//!
//! The subcommand table itself lives in `dispatch.zig`, shared with
//! `main_fake.zig` -- this file only supplies what's genuinely specific to
//! the real binary: which `Extractor` backs a table lookup, and how an
//! unknown/missing subcommand is reported.

const std = @import("std");

const treesitter = @import("treesitter");
const dispatch = @import("dispatch.zig");
const usage = @import("usage.zig").text;

comptime {
    _ = @import("test_root.zig");
}

const table = dispatch.Table(treesitter.extractor.TreeSitterExtractor).entries;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    // Kept, not discarded: `vault-write`/`vault-patch` thread this down to
    // `GitStore` so it can spawn its own detached Pusher via `argv[0]`
    // re-invocation, the same mechanism `synapse-hook` already uses for
    // `vault-sync`/`vault-pull`.
    const argv0 = args.next() orelse "";

    const sub = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    // `null` trace: that instrumentation is `synapse-fake`'s only.
    if (dispatch.run(&table, init.gpa, init.io, init.environ_map, &args, argv0, sub, null)) |result|
        return result;

    std.debug.print("synapse: unknown subcommand '{s}'\n{s}", .{ sub, usage });
    return 2;
}
