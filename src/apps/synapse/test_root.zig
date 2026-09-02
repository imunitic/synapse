//! Force-inclusion for `core`/`ports`/`adapters` and every `*_cmd.zig`
//! file's own tests -- referenced here, not merely imported, since Zig
//! analyses lazily: `main.zig`'s own imports of these are only reachable
//! through `main()`'s body, which the test runner never calls, so nothing
//! would otherwise pull their `test` blocks in. `treesitter` needs no line
//! here: `tags.zig` uses it for real.

const core = @import("core");
const ports = @import("ports");
const adapters = @import("adapters");
const write_node_cmd = @import("write_node_cmd.zig");
const frontmatter_cmd = @import("frontmatter_cmd.zig");
const vault_cmd = @import("vault_cmd.zig");
const namespace_cmd = @import("namespace_cmd.zig");
const gate_cmd = @import("gate_cmd.zig");
const links_cmd = @import("links_cmd.zig");
const refs_cmd = @import("refs_cmd.zig");
const deps_cmd = @import("deps_cmd.zig");
const namespaces_cmd = @import("namespaces_cmd.zig");
const query_cmd = @import("query_cmd.zig");
const index_cmd = @import("index_cmd.zig");
const enumerate_cmd = @import("enumerate_cmd.zig");
const build_lists_cmd = @import("build_lists_cmd.zig");
const push_nodes_cmd = @import("push_nodes_cmd.zig");
const project_index_cmd = @import("project_index_cmd.zig");
const rank_cmd = @import("rank_cmd.zig");
const tags_cache_cmd = @import("tags_cache_cmd.zig");
const tags_cmd = @import("tags.zig");
const vocab_cmd = @import("vocab_cmd.zig");
const brief_cmd = @import("brief_cmd.zig");
const graph_cmd = @import("graph_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const dispatch = @import("dispatch.zig");

comptime {
    _ = core;
    _ = ports;
    _ = adapters;
    _ = write_node_cmd;
    _ = frontmatter_cmd;
    _ = vault_cmd;
    _ = namespace_cmd;
    _ = gate_cmd;
    _ = links_cmd;
    _ = refs_cmd;
    _ = deps_cmd;
    _ = namespaces_cmd;
    _ = query_cmd;
    _ = index_cmd;
    _ = enumerate_cmd;
    _ = build_lists_cmd;
    _ = push_nodes_cmd;
    _ = project_index_cmd;
    _ = rank_cmd;
    _ = tags_cache_cmd;
    _ = tags_cmd;
    _ = vocab_cmd;
    _ = brief_cmd;
    _ = graph_cmd;
    _ = doctor_cmd;
    _ = dispatch;
}
