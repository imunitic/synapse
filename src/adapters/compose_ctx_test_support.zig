//! A "base" `ComposeCtx`, real and safe in every field regardless of which
//! decorator's `initCtx` consumes it -- a test clones it and overrides only
//! the field(s) it actually cares about, rather than hand-filling all ten at
//! every call site or resorting to `undefined` for the rest. Test-only:
//! referenced from a `test` block in whichever file needs it, never from
//! `adapters/root.zig`'s own public surface.

const std = @import("std");
const fakes = @import("fakes/root.zig");
const compose_ctx = @import("compose_ctx.zig");

pub const ComposeCtx = compose_ctx.ComposeCtx;

pub const BaseCtx = struct {
    store: fakes.Store,
    link_graph: fakes.LinkGraph,
    renamer: fakes.Renamer,
    search_filtered: fakes.SearchFiltered,
    env: std.process.Environ.Map,

    pub fn init(gpa: std.mem.Allocator) !BaseCtx {
        return .{
            .store = .init(gpa),
            .link_graph = .{},
            .renamer = .{},
            .search_filtered = .{},
            .env = try std.process.Environ.createMap(std.testing.environ, gpa),
        };
    }

    pub fn deinit(self: *BaseCtx) void {
        self.store.deinit();
        self.env.deinit();
    }

    /// `vault`/`namespace` are plain placeholders -- override them on the
    /// returned value when a test actually addresses the vault by path.
    pub fn ctx(self: *BaseCtx, gpa: std.mem.Allocator) ComposeCtx {
        return .{
            .arena = gpa,
            .vault = "vault",
            .namespace = "",
            .env = &self.env,
            .vars = .none,
            .self_path = "",
            .inner_store = self.store.port(),
            .inner_link_graph = self.link_graph.linkGraph(),
            .inner_renamer = self.renamer.renamer(),
            .inner_search_filtered = self.search_filtered.searchFiltered_(),
        };
    }
};

const testing = std.testing;

test "the base fixture's port fields are wired to their fake's documented behavior, not undefined" {
    var base = try BaseCtx.init(testing.allocator);
    defer base.deinit();
    const ctx = base.ctx(testing.allocator);

    // A field left `undefined` would crash on the first call below (reading
    // a garbage vtable pointer) rather than fail an assertion -- but each
    // call also checks the real fake contract (empty/no-op), so wiring a
    // field to the wrong fake, or the right fake's wrong method, fails an
    // assertion here too, not just a crash-only check. `env` isn't checked
    // here: `BaseCtx.init` builds it with one unconditional, unbranched
    // call, so there's no plausible wrong-but-not-crashing state for an
    // assertion to catch.
    try testing.expectEqual(@as(usize, 0), (try ctx.inner_link_graph.orphans(testing.allocator, undefined)).len);
    try ctx.inner_renamer.rename(testing.allocator, undefined, "a.md", "b.md");
    try testing.expectEqual(@as(usize, 0), (try ctx.inner_search_filtered.searchFiltered(testing.allocator, undefined, "q", null)).len);
}
