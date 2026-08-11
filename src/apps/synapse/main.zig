//! The `synapse` executable: subcommand dispatch over the shared core, wired
//! to the code profile's adapters (tree-sitter extraction, the Obsidian REST
//! store, inferred clustering, the full node lifecycle).
//!
//! The CLI contract is frozen. Every flag, every line of stdout and every exit
//! code matches what the bash scripts in `claude/lib/synapse/` produce today,
//! because `tests/*.bats` is the specification for this port and stays valid
//! only as long as that holds. A CLI improvement is a separate change, before
//! or after this rewrite, never inside it.


const std = @import("std");

// Referenced, not merely imported. Zig analyses declarations lazily, so an
// `@import` nothing touches is never compiled -- and a build that never
// compiles `core` cannot be said to have checked anything about it, including
// that its own imports point the right way. Keep a real reference here for as
// long as dispatch is a stub.
const core = @import("core");
const ports = @import("ports");
const adapters = @import("adapters");
const treesitter = @import("treesitter");
const tags_cmd = @import("tags.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");

comptime {
    // `treesitter` needs no line here: tags.zig uses it for real.
    _ = core;
    _ = ports;
    _ = adapters;
}

const usage =
    \\usage: synapse <subcommand> [args]
    \\
    \\  tags <file>                tags for one file
    \\  tags --paths <list-file>   tags for every listed file, in one batch
    \\  tags --list-extensions     every extension with a usable grammar
    \\  tags-cache --repo-root <dir> --cache <file> --paths <tsv>
    \\  tags-cache --dump <file>   what the cache holds
    \\  tags-cache --refs <file>   _refs.tsv rows from the cache
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]

    const sub = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    // `null` for the trace, not a value read from the environment: the trace
    // is `synapse-fake`'s instrumentation, and the real binary should not be
    // able to write one however it is invoked.
    if (std.mem.eql(u8, sub, "tags"))
        return tags_cmd.run(
            treesitter.extractor.TreeSitterExtractor,
            init.gpa,
            init.io,
            init.environ_map,
            &args,
            null,
        );

    if (std.mem.eql(u8, sub, "tags-cache"))
        return tags_cache_cmd.run(
            treesitter.extractor.TreeSitterExtractor,
            init.gpa,
            init.io,
            init.environ_map,
            &args,
            null,
        );

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    std.debug.print("synapse: unknown subcommand '{s}'\n{s}", .{ sub, usage });
    return 2;
}
