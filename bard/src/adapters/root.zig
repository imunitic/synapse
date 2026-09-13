//! synapse-bard's own adapters: the Bible-graph and Writer's notes vault
//! implementations, built on the `synapse` dependency's shared `disk_store`
//! rather than duplicating it.

const std = @import("std");

/// synapse-bard's real Extractor -- YAML frontmatter only, no C dependency.
/// `pub`, unlike the conformance file below: `synapse-bard`'s own main.zig
/// constructs and uses this directly, not just tests it.
pub const frontmatter = @import("frontmatter.zig");

/// `_bard/graph/`'s `Store` -- plain files, no daemon, no network.
pub const graph_store = @import("graph_store.zig");

/// `_bard/graph/` cluster nodes: `sources:` manifest parsing/rendering and
/// slug resolution -- built on `graph_store` and `frontmatter`, not a
/// `Store`/`Extractor` implementation itself.
pub const cluster = @import("cluster.zig");

/// `_bard/vault/`'s `Store` -- design/task notes, subdirectories, backlink-
/// ranked search.
pub const vault_store = @import("vault_store.zig");

/// The clustering/extraction plan `sync` computes, factored out here so
/// `synapse-bard-hook`'s `SessionStart` can compute the same plan in-process
/// for drift detection, without shelling out to the `synapse-bard` binary.
pub const sync_plan = @import("sync_plan.zig");

test {
    std.testing.refAllDecls(@This());
    _ = frontmatter;
    _ = graph_store;
    _ = cluster;
    _ = vault_store;
    _ = sync_plan;
}
