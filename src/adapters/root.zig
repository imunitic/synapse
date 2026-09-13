//! Adapters: concrete implementations behind the domain ports, plus shared
//! helpers. Anything touching a C library, network, or another process
//! lives here or below, never in `core`.
//!
//! The tree-sitter Extractor is deliberately not re-exported here despite
//! living under `src/adapters/` -- it's its own build module, so an
//! executable that never lists it links no libtree-sitter, no C compiler.

const std = @import("std");

pub const process = @import("process.zig");
pub const local_timestamp = @import("local_timestamp.zig");
pub const env = @import("env.zig");
pub const fakes = @import("fakes/root.zig");

/// The directory-as-lock primitive (`mkdir` as atomic test-and-set,
/// mtime-aged staleness, bounded retry) -- shared by `git_sync.zig` and
/// `treesitter/grammar.zig`'s clone/compile locks, each supplying its own
/// lock path and staleness window.
pub const dir_lock = @import("dir_lock.zig");

/// Shared git mechanics (lock, pull, commit, push) for the vault's own
/// version control -- one implementation `GitStore` and the sync-related
/// hooks both call into, not one per caller.
pub const git_sync = @import("git_sync.zig");

/// Plain markdown files directly on disk behind the Store port -- no
/// network dependency at all. The implicit innermost backend, and
/// what an extended store's own `read`/`write`/`list` decorate.
pub const disk_store = @import("disk/store.zig");

/// Mandatory validation decorator between DiskStore and every configured
/// external integration. Legacy notes without a schema pass through.
pub const schema_validation_store = @import("schema_validation_store.zig");

/// A `DiskStore` decorator owning the vault's own git lifecycle --
/// `SYNAPSE_VAULT_INTEGRATIONS=git`'s backend.
pub const git_store = @import("git/store.zig");

/// Picks and constructs the `Store` a caller should use, from
/// `SYNAPSE_VAULT_INTEGRATIONS`/`SYNAPSE_VAULT_DIR` -- shared by every CLI
/// subcommand and hook that needs a `Store`, so a backend swap changes only
/// this function.
pub const store_resolve = @import("store_resolve.zig");

test {
    std.testing.refAllDecls(@This());
    _ = process;
    _ = env;
    _ = fakes;
    _ = dir_lock;
    _ = git_sync;
    _ = disk_store;
    _ = git_store;
    _ = store_resolve;
    // Not `pub`: a conformance check on the port, compiled for tests only.
    _ = @import("frontmatter_conformance.zig");
}
