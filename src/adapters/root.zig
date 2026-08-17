//! Adapters: concrete implementations behind the domain ports, plus shared
//! helpers. Anything touching a C library, network, or another process
//! lives here or below, never in `core`.
//!
//! The tree-sitter Extractor is deliberately not re-exported here despite
//! living under `src/adapters/` -- it's its own build module, so an
//! executable that never lists it links no libtree-sitter, no C compiler.

const std = @import("std");

pub const process = @import("process.zig");
pub const env = @import("env.zig");
pub const fakes = @import("fakes/root.zig");

/// The Obsidian Local REST API behind the Store port. Spawns `curl` and
/// links nothing, so wanting a vault doesn't imply wanting a C compiler.
pub const obsidian = @import("obsidian/store.zig");

/// synapse-bard's real Extractor -- YAML frontmatter only, no C dependency.
/// `pub`, unlike the conformance file below: `synapse-bard`'s own main.zig
/// constructs and uses this directly, not just tests it.
pub const bard_frontmatter = @import("bard/frontmatter.zig");

/// `_bard/graph/`'s `Store` -- plain files, no daemon, no network.
pub const bard_graph_store = @import("bard/graph_store.zig");

/// `_bard/graph/` cluster nodes: `sources:` manifest parsing/rendering and
/// slug resolution (`synapse-bard-005`) -- built on `bard_graph_store` and
/// `bard_frontmatter`, not a `Store`/`Extractor` implementation itself.
pub const bard_cluster = @import("bard/cluster.zig");

/// `_bard/vault/`'s `Store` -- design/task notes, subdirectories, backlink-
/// ranked search.
pub const bard_vault_store = @import("bard/vault_store.zig");

test {
    std.testing.refAllDecls(@This());
    _ = process;
    _ = env;
    _ = fakes;
    _ = obsidian;
    _ = bard_frontmatter;
    _ = bard_graph_store;
    _ = bard_cluster;
    _ = bard_vault_store;
    // Not `pub`: a conformance check on the port, compiled for tests only.
    _ = @import("frontmatter_conformance.zig");
}
