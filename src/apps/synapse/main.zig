//! The `synapse` executable: subcommand dispatch over the shared core, wired
//! to the code profile's adapters (tree-sitter extraction, the vault
//! store, inferred clustering, the full node lifecycle).
//!
//! CLI contract is frozen: every flag, stdout line and exit code matches the
//! old `claude/lib/synapse/` bash scripts, since `tests/*.bats` is the spec
//! for this port. CLI improvements are a separate change, never inside it.

const std = @import("std");

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
const frontmatter_cmd = @import("frontmatter_cmd.zig");
const vault_cmd = @import("vault_cmd.zig");
const refs_cmd = @import("refs_cmd.zig");
const deps_cmd = @import("deps_cmd.zig");
const namespaces_cmd = @import("namespaces_cmd.zig");
const links_cmd = @import("links_cmd.zig");
const brief_cmd = @import("brief_cmd.zig");
const gate_cmd = @import("gate_cmd.zig");
const push_nodes_cmd = @import("push_nodes_cmd.zig");
const project_index_cmd = @import("project_index_cmd.zig");
const graph_cmd = @import("graph_cmd.zig");
const namespace_cmd = @import("namespace_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");

comptime {
    _ = @import("test_root.zig");
}

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

    if (std.mem.eql(u8, sub, "frontmatter"))
        return frontmatter_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-read"))
        return vault_cmd.runRead(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-write"))
        return vault_cmd.runWrite(init.gpa, init.io, init.environ_map, &args, argv0);

    if (std.mem.eql(u8, sub, "vault-list"))
        return vault_cmd.runList(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-check"))
        return vault_cmd.runCheck(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-search"))
        return vault_cmd.runSearch(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-search-text"))
        return vault_cmd.runSearchText(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-doc-map"))
        return vault_cmd.runDocMap(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-patch"))
        return vault_cmd.runPatch(init.gpa, init.io, init.environ_map, &args, argv0);

    if (std.mem.eql(u8, sub, "vault-backlinks"))
        return vault_cmd.runBacklinks(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-links"))
        return vault_cmd.runLinks(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-unresolved"))
        return vault_cmd.runUnresolved(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-orphans"))
        return vault_cmd.runOrphans(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-deadends"))
        return vault_cmd.runDeadends(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "vault-ambiguous"))
        return vault_cmd.runAmbiguous(init.gpa, init.io, init.environ_map, &args);

    // Not documented in `usage`: `GitStore.write()`'s own detached spawn
    // target, the same "not registered as a hook" shape `synapse-hook
    // vault-sync`/`vault-pull` already have.
    if (std.mem.eql(u8, sub, "vault-git-pusher"))
        return vault_cmd.runVaultGitPusher(init.gpa, init.io, &args);

    if (std.mem.eql(u8, sub, "vault-rename"))
        return vault_cmd.runRename(init.gpa, init.io, init.environ_map, &args);

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

    if (std.mem.eql(u8, sub, "build-deps"))
        return deps_cmd.run(init.gpa, init.io, init.environ_map, &args);

    if (std.mem.eql(u8, sub, "build-namespaces"))
        return namespaces_cmd.run(init.gpa, init.io, init.environ_map, &args);

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
