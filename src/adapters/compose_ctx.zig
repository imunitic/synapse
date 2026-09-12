//! `ComposeCtx` on its own, below both `store_resolve.zig` and every
//! decorator it composes -- it references nothing concrete (`Allocator`,
//! `core.conf.Vars`, `std.process.Environ.Map`, and the four port
//! interfaces only, never `DiskStore`/`GitStore`/`SchemaValidationStore` by
//! name), so it belongs here rather than inside the orchestrator that
//! happened to be where it was first written. Living in `store_resolve.zig`
//! meant every decorator's `initCtx` had to import that file for the type,
//! which already imports every decorator back for its concrete type -- a
//! real cycle, not just an awkward one. As a leaf, the three decorators and
//! `store_resolve.zig` all depend on this file; none of them depend on each
//! other in that direction.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");

const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;
const SearchFiltered = ports.SearchFiltered;

/// What every layer needs to construct itself around whatever the chain has
/// produced so far -- `env`/`self_path` are only meaningful to `git`, but
/// every `initCtx` gets the same context so none of them need a bespoke
/// signature. `arena` is expected to live at least as long as whatever
/// `resolveStore` eventually returns -- every concrete instance built from
/// this context is allocated through it, never freed individually. `vars`
/// is `env` pre-wrapped as `core.conf.Vars`, computed once by `resolveStore`,
/// so a decorator that needs it (`DiskStore`, `SchemaValidationStore`)
/// doesn't need its own dependency on `env.zig` just to derive it again.
pub const ComposeCtx = struct {
    arena: Allocator,
    vault: []const u8,
    namespace: []const u8,
    env: *std.process.Environ.Map,
    vars: core.conf.Vars,
    self_path: []const u8,
    inner_store: Store,
    inner_link_graph: LinkGraph,
    inner_renamer: Renamer,
    inner_search_filtered: SearchFiltered,
};
