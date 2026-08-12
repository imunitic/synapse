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
const index_cmd = @import("index_cmd.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");
const build_lists_cmd = @import("build_lists_cmd.zig");
const vocab_cmd = @import("vocab_cmd.zig");
const rank_cmd = @import("rank_cmd.zig");
const query_cmd = @import("query_cmd.zig");
const write_node_cmd = @import("write_node_cmd.zig");
const refs_cmd = @import("refs_cmd.zig");
const gate_cmd = @import("gate_cmd.zig");
const push_nodes_cmd = @import("push_nodes_cmd.zig");
const project_index_cmd = @import("project_index_cmd.zig");
const graph_cmd = @import("graph_cmd.zig");

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
    \\  index build --unassigned <file>   _index.bin from path<TAB>node on stdin
    \\  index unassigned           every path no node claims
    \\  index lookup <path>        the nodes claiming one path
    \\  enumerate [--reenumerate]  tracked files worth graphing, into the work dir
    \\  build-lists [--reenumerate]  manifest.tsv into one path list per node
    \\  vocab [--lists <dir>]      symbol vocabulary by group
    \\  rank --sources <file>      a node's sources by reading value
    \\  query <subcommand> [args]  read-only queries against the graph
    \\  write-node --title <t> --summary <s> --paths <f> --body <f>
    \\  build-refs [--cache <f>] [--out <f>]   _refs.tsv from the tags cache
    \\  callers <name> [--all]     repo-wide sites of an exact name
    \\  gate --vocab <file> [--all] [--top N]   clusters owning no vocabulary
    \\  push-nodes [NN ...]        write one node per authored body
    \\  build-project-index        the namespace's Index.md node map
    \\  graph-clean [--dry-run]    drop namespaces whose branch is gone upstream
    \\  graph-wipe [--dry-run]     drop this namespace, preserving hand Notes
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

    // No extractor and no grammar: the index is a projection of lists the
    // clustering already produced, so this form needs nothing tree-sitter.
    if (std.mem.eql(u8, sub, "index"))
        return index_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "enumerate"))
        return enumerate_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-lists"))
        return build_lists_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vocab"))
        return vocab_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "rank"))
        return rank_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "query"))
        return query_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "write-node"))
        return write_node_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "graph-clean"))
        return graph_cmd.runClean(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "graph-wipe"))
        return graph_cmd.runWipe(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-project-index"))
        return project_index_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "push-nodes"))
        return push_nodes_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "gate"))
        return gate_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-refs"))
        return refs_cmd.runBuild(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "callers"))
        return refs_cmd.runCallers(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    std.debug.print("synapse: unknown subcommand '{s}'\n{s}", .{ sub, usage });
    return 2;
}
