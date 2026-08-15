//! The `synapse` executable: subcommand dispatch over the shared core, wired
//! to the code profile's adapters (tree-sitter extraction, the Obsidian REST
//! store, inferred clustering, the full node lifecycle).
//!
//! CLI contract is frozen: every flag, stdout line and exit code matches the
//! old `claude/lib/synapse/` bash scripts, since `tests/*.bats` is the spec
//! for this port. CLI improvements are a separate change, never inside it.


const std = @import("std");

// Referenced, not merely imported: Zig analyses lazily, so an untouched
// `@import` is never compiled or checked.
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
const usage = @import("usage.zig").text;
const write_node_cmd = @import("write_node_cmd.zig");
const refs_cmd = @import("refs_cmd.zig");
const links_cmd = @import("links_cmd.zig");
const brief_cmd = @import("brief_cmd.zig");
const gate_cmd = @import("gate_cmd.zig");
const push_nodes_cmd = @import("push_nodes_cmd.zig");
const project_index_cmd = @import("project_index_cmd.zig");
const graph_cmd = @import("graph_cmd.zig");
const namespace_cmd = @import("namespace_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");

comptime {
    // `treesitter` needs no line here: tags.zig uses it for real.
    _ = core;
    _ = ports;
    _ = adapters;
}


pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]

    const sub = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    // `null` trace: that instrumentation is `synapse-fake`'s only.
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

    // No extractor: the index is a projection of lists clustering already produced.
    if (std.mem.eql(u8, sub, "index"))
        return index_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "enumerate"))
        return enumerate_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-lists"))
        return build_lists_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vocab"))
        return vocab_cmd.run(
            treesitter.extractor.TreeSitterExtractor,
            init.gpa,
            init.io,
            init.environ_map,
            &args,
            null,
        );

    if (std.mem.eql(u8, sub, "rank"))
        return rank_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "query"))
        return query_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "write-node"))
        return write_node_cmd.run(treesitter.extractor.TreeSitterExtractor, init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "doctor"))
        return doctor_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "namespace"))
        return namespace_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-index"))
        return index_cmd.runBuildIndex(init.gpa, init.io, init.environ_map, &args);

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

    if (std.mem.eql(u8, sub, "link-graph"))
        return links_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "brief"))
        return brief_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }

    std.debug.print("synapse: unknown subcommand '{s}'\n{s}", .{ sub, usage });
    return 2;
}
