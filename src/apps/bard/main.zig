//! `synapse-bard` -- the Bible-graph and Writer's notes vault binary for a
//! YAML-templated fiction bible. Imports `model`/`ports`/`core`/`adapters`,
//! never `treesitter`: this binary parses YAML frontmatter only, so it links
//! no libtree-sitter and needs no C compiler. See the compiled task note
//! `synapse-bard-001` and its three design notes for the full contract.
//!
//! Placeholder: no subcommand exists yet. This satisfies `zig build` so the
//! executable target can be wired and tested before the extractor, the two
//! `_bard/graph`/`_bard/vault` `Store` implementations, and the query layer
//! land in later steps of that same task.

const std = @import("std");

const usage =
    \\usage: synapse-bard <command>
    \\
    \\No commands implemented yet -- see the synapse-bard-001 task note.
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

    std.debug.print("synapse-bard: unknown command '{s}'\n{s}", .{ which, usage });
    return 2;
}
