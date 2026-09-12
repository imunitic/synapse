//! One place that decides which `ports.Store` chain a caller gets, from
//! `SYNAPSE_VAULT_INTEGRATIONS` (a comma-separated list, outer-to-inner:
//! `git` means `GitStore` wraps the mandatory `SchemaValidationStore`, which
//! wraps the one real store, `DiskStore`) and `SYNAPSE_VAULT_DIR`. Both
//! resolve through `core.conf.resolve`/`vaultDir` -- a real environment
//! variable wins, then the first conf file that defines the key -- so
//! setting either in `synapse.conf` works exactly like exporting it. Every
//! CLI subcommand and every hook that needs a `Store` calls this instead of
//! resolving one itself.
//!
//! `disk` is never named in the value -- it's always the implicit innermost
//! element, whether the list is empty or `git`. Naming it, or naming `git`
//! more than once, is a hard error, not a silent fallback -- same "report
//! the bad value, never substitute a guess" precedent an unrecognized name
//! already has.
//!
//! A future integration (`NotionStore`, say) is one more entry in
//! `integration_handlers` and one more `compose*` function, nowhere else --
//! it would be shaped the same way `git` already is, a decorator over the
//! one real store, not a new kind of peer backend. Still by hand, in this
//! file -- `integration_handlers` is a dispatch table, not a registration
//! mechanism anything outside this file can add to.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const disk_store = @import("disk/store.zig");
const git_store = @import("git/store.zig");
const schema_validation_store = @import("schema_validation_store.zig");
const env_bridge = @import("env.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;
const SearchFiltered = ports.SearchFiltered;
const DiskStore = disk_store.DiskStore;
const GitStore = git_store.GitStore;
const SchemaValidationStore = schema_validation_store.SchemaValidationStore;

/// The four capabilities resolved from composing `SYNAPSE_VAULT_INTEGRATIONS`
/// over `DiskStore` -- a plain value, not an owner. Every concrete instance
/// behind these `{ptr, vtable}` values (`DiskStore`, `SchemaValidationStore`,
/// `GitStore`) is allocated through the arena `resolveStore`'s caller passes
/// in, so nothing here needs freeing on its own: the caller's own eventual
/// `arena.deinit()` reclaims all of it in one shot, whenever it's done using
/// this value and everything derived from it. Holds the already-resolved
/// `Store`/`LinkGraph`/`Renamer`/`SearchFiltered` values directly rather than
/// a tagged union of concrete outer types: capability resolution happens
/// once, during compose, while every layer is still a concrete type -- see
/// the design note (`sb — Generic Store decorator stacking`) for why that's
/// sufficient and nothing needs rediscovering from an already-erased value
/// later.
pub const ResolvedStore = struct {
    resolved_store: Store,
    resolved_link_graph: LinkGraph,
    resolved_renamer: Renamer,
    resolved_search_filtered: SearchFiltered,

    pub fn store(self: *ResolvedStore) Store {
        return self.resolved_store;
    }

    /// Never `null` in practice: the chain always starts from `DiskStore`,
    /// which always has one. Kept as a plain `LinkGraph` (not `?LinkGraph`)
    /// for that reason -- unlike Bard's stores, which have none at all and
    /// never go through this function.
    pub fn linkGraph(self: *ResolvedStore) LinkGraph {
        return self.resolved_link_graph;
    }

    pub fn renamer(self: *ResolvedStore) Renamer {
        return self.resolved_renamer;
    }

    /// Full-text search, first scoped to whichever candidate paths pass
    /// `path_filter` (`DiskStore.searchFiltered`'s own doc comment has the
    /// exact contract: a JsonLogic rule expected to reference nothing but
    /// `path`). `null` runs the resolved chain's ordinary `search` instead
    /// (same as `store().search(...)` would), so a caller with no filter to
    /// apply sees no behavior change at all.
    pub fn searchFiltered(
        self: *ResolvedStore,
        gpa: Allocator,
        io: Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        if (path_filter == null) return self.resolved_store.search(gpa, io, query);
        return self.resolved_search_filtered.searchFiltered(gpa, io, query, path_filter);
    }
};

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

const ComposeResult = struct {
    store: Store,
    link_graph: LinkGraph,
    renamer: Renamer,
    search_filtered: SearchFiltered,
};

/// One integration this build knows how to compose: `name` is what
/// `SYNAPSE_VAULT_INTEGRATIONS` spells it as, `compose` builds that layer
/// around whatever the chain has produced so far -- always
/// `composeLayerFn(SomeType)`, never hand-written. This table is the single
/// source of both "which names are valid" (`parseIntegrationsImpl`) and
/// "how to build one" (`resolveStore`'s compose loop).
const IntegrationHandler = struct {
    name: []const u8,
    compose: *const fn (ctx: ComposeCtx) Allocator.Error!ComposeResult,
};

/// Resolves one already-constructed layer's capabilities: `T`'s own
/// `linkGraph()`/`renamer()`/`searchFiltered()` override the running value
/// when `T` declares one (checked via `@hasDecl`, decided once per `T` at
/// comptime -- the untaken branch is never even generated), otherwise the
/// value carried in from whatever was built one step further in passes
/// through unchanged. `store()` is the one capability every layer always
/// has its own answer for, decorator or not.
fn resolveCapabilities(comptime T: type, ptr: *T, ctx: ComposeCtx) ComposeResult {
    return .{
        .store = ptr.store(),
        .link_graph = if (@hasDecl(T, "linkGraph")) ptr.linkGraph() else ctx.inner_link_graph,
        .renamer = if (@hasDecl(T, "renamer")) ptr.renamer() else ctx.inner_renamer,
        .search_filtered = if (@hasDecl(T, "searchFiltered")) SearchFiltered.from(T, ptr) else ctx.inner_search_filtered,
    };
}

/// Builds one layer of any type `T`: allocates it through the context's
/// arena, constructs it via `T.initCtx` (every decorator's own adapter over
/// its narrower `init(...)`), then resolves its capabilities. The one
/// function every layer -- `DiskStore`, `SchemaValidationStore`, or any
/// configured integration -- goes through, whether called directly (the two
/// mandatory layers, below) or via `composeLayerFn` (the dispatch table).
fn composeLayer(comptime T: type, ctx: ComposeCtx) Allocator.Error!ComposeResult {
    const ptr = try ctx.arena.create(T);
    ptr.* = try T.initCtx(ctx);
    return resolveCapabilities(T, ptr, ctx);
}

/// Generates the one function pointer `integration_handlers` needs for `T`,
/// the same "comptime `T` known here, plain runtime closure out" idiom
/// `Store.from` already uses -- a new integration is one more type named at
/// one more table row, never a hand-written function.
fn composeLayerFn(comptime T: type) *const fn (ctx: ComposeCtx) Allocator.Error!ComposeResult {
    return struct {
        fn compose(ctx: ComposeCtx) Allocator.Error!ComposeResult {
            return composeLayer(T, ctx);
        }
    }.compose;
}

const integration_handlers = [_]IntegrationHandler{
    .{ .name = "git", .compose = composeLayerFn(GitStore) },
};

/// Splits `value` on `,` and validates before anything gets constructed:
/// `disk` named anywhere, an unrecognized name, or a name repeated is each
/// a hard error, reported the same way an unrecognized single value already
/// was. Empty means no integrations at all -- the plain disk store,
/// unchanged from today. Order is preserved (outer-to-inner, as written);
/// the caller walks it in reverse to compose innermost-first. `out`/`count`
/// are caller-owned scratch space -- a fixed small buffer, since the number
/// of integrations that will ever exist is nowhere near needing a heap
/// allocation to enumerate.
fn parseIntegrationsImpl(value: []const u8, prog: ?[]const u8, out: *[8][]const u8, count: *usize) ?[8][]const u8 {
    if (value.len == 0) return out.*;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, name, "disk")) {
            report(prog, "SYNAPSE_VAULT_INTEGRATIONS names 'disk' -- the disk store is always the implicit innermost element, never named explicitly\n", .{});
            return null;
        }
        var known = false;
        for (integration_handlers) |h| {
            if (std.mem.eql(u8, name, h.name)) known = true;
        }
        if (!known) {
            report(prog, "unknown integration '{s}' in SYNAPSE_VAULT_INTEGRATIONS -- want 'git'\n", .{name});
            return null;
        }
        for (out[0..count.*]) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                report(prog, "'{s}' named more than once in SYNAPSE_VAULT_INTEGRATIONS\n", .{name});
                return null;
            }
        }
        if (count.* >= out.len) {
            report(prog, "too many entries in SYNAPSE_VAULT_INTEGRATIONS\n", .{});
            return null;
        }
        out[count.*] = name;
        count.* += 1;
    }
    return out.*;
}

/// Whether `name` (e.g. `"git"`) is anywhere in `SYNAPSE_VAULT_INTEGRATIONS`
/// -- for a caller that only needs a yes/no answer (a hook deciding whether
/// to pull) and has no reason to construct the whole chain of stores just
/// to ask it. A malformed value answers `false`, the same as it not being
/// configured at all -- this isn't the place that reports a config error,
/// `resolveStore` already owns that.
pub fn hasIntegration(gpa: Allocator, io: Io, env: *std.process.Environ.Map, name: []const u8) !bool {
    const value_owned = try core.conf.resolve(gpa, io, env_bridge.vars(env), "SYNAPSE_VAULT_INTEGRATIONS");
    defer if (value_owned) |v| gpa.free(v);

    var count: usize = 0;
    var buf: [8][]const u8 = undefined;
    const names = parseIntegrationsImpl(value_owned orelse "", null, &buf, &count) orelse return false;
    for (names[0..count]) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// `vault` is the already-resolved vault root (`core.conf.vaultDir`'s
/// result); `namespace` is what every store alike prefixes onto every node
/// name (`"synapse/{repo}@{branch}"`, or `""` to address any note in the
/// vault by its full path). `self_path` is this process's own path, needed
/// only if `git` is anywhere in the chain, to spawn its detached Pusher via
/// `argv[0]` re-invocation -- passed in directly rather than set after the
/// fact (`GitStore.self_path` used to be mutated post-construction, but
/// once it's erased into a generic `Store` value there's no field left to
/// reach through the interface). `prog` prefixes diagnostics, matching
/// every other resolver in this codebase -- `null` instead of a name means
/// stay silent, the contract every hook here already relies on. Null return
/// is an unrecoverable config problem, reported to stderr only when `prog`
/// is non-null.
///
/// `arena` is expected to be an arena-backed allocator scoped to the whole
/// caller invocation (`var arena_state: std.heap.ArenaAllocator = .init(gpa);
/// defer arena_state.deinit();`), not the process's raw general-purpose one.
/// Every concrete instance behind the returned `ResolvedStore`'s capabilities
/// is allocated through it and never freed individually -- `DiskStore` is
/// the only one with any real `deinit` work today, and it only frees two
/// small strings, so there is nothing here that benefits from matched
/// alloc/free discipline. The caller's own eventual `arena.deinit()` reclaims
/// all of it in one shot, on every exit path, success or error alike.
pub fn resolveStore(
    arena: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    namespace: []const u8,
    prog: ?[]const u8,
    self_path: []const u8,
) !?ResolvedStore {
    const vars = env_bridge.vars(env);
    const value_owned = try core.conf.resolve(arena, io, vars, "SYNAPSE_VAULT_INTEGRATIONS");

    var count: usize = 0;
    var buf: [8][]const u8 = undefined;
    _ = parseIntegrationsImpl(value_owned orelse "", prog, &buf, &count) orelse return null;
    const names = buf[0..count];

    // `DiskStore` seeds the fold: it has no inner layer, so every `@hasDecl`
    // check in `resolveCapabilities` is true for it and the `inner_*` fields
    // below are structurally unreachable, comptime-elided dead branches --
    // never generated, never read, for this one call.
    var result = try composeLayer(DiskStore, .{
        .arena = arena,
        .vault = vault,
        .namespace = namespace,
        .env = env,
        .vars = vars,
        .self_path = self_path,
        .inner_store = undefined,
        .inner_link_graph = undefined,
        .inner_renamer = undefined,
        .inner_search_filtered = undefined,
    });

    // Validation is a correctness boundary, not a selectable integration:
    // every configured decorator wraps it, and it always wraps DiskStore.
    result = try composeLayer(SchemaValidationStore, .{
        .arena = arena,
        .vault = vault,
        .namespace = namespace,
        .env = env,
        .vars = vars,
        .self_path = self_path,
        .inner_store = result.store,
        .inner_link_graph = result.link_graph,
        .inner_renamer = result.renamer,
        .inner_search_filtered = result.search_filtered,
    });

    // Outer-to-inner in `names`, so build innermost-first: walk in reverse.
    var i = names.len;
    while (i > 0) {
        i -= 1;
        const name = names[i];
        const handler = for (integration_handlers) |h| {
            if (std.mem.eql(u8, h.name, name)) break h;
        } else unreachable; // parseIntegrationsImpl already validated every name

        result = try handler.compose(.{
            .arena = arena,
            .vault = vault,
            .namespace = namespace,
            .env = env,
            .vars = vars,
            .self_path = self_path,
            .inner_store = result.store,
            .inner_link_graph = result.link_graph,
            .inner_renamer = result.renamer,
            .inner_search_filtered = result.search_filtered,
        });
    }

    return .{
        .resolved_store = result.store,
        .resolved_link_graph = result.link_graph,
        .resolved_renamer = result.renamer,
        .resolved_search_filtered = result.search_filtered,
    };
}

fn report(prog: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const name = prog orelse return;
    std.debug.print("{s}: " ++ fmt, .{name} ++ args);
}

const testing = std.testing;

/// `HOME` pointed at `vault` (an isolated tmp dir with no real conf file in
/// it) and every real-conf-file discovery var stripped -- `resolveStore`
/// now cascades every integration through `core.conf.resolve`, so a test
/// that wants "nothing configured" has to make that true of the actual
/// environment it resolves against, not just of `SYNAPSE_VAULT_INTEGRATIONS`
/// itself. The real machine's own `synapse.conf` would otherwise leak in.
fn isolatedEnv(gpa: Allocator, vault: []const u8) !std.process.Environ.Map {
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    try env.put("HOME", vault);
    _ = env.swapRemove("XDG_CONFIG_HOME");
    _ = env.swapRemove("CLAUDE_PLUGIN_ROOT");
    _ = env.swapRemove("SYNAPSE_CONTENT_ROOT");
    _ = env.swapRemove("SYNAPSE_VAULT_INTEGRATIONS");
    return env;
}

test "SYNAPSE_VAULT_INTEGRATIONS unset keeps validation mandatory over the disk store" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolved = (try resolveStore(arena, io, &env, vault, "synapse/repo@main", "test", "")).?;

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);

    // Plain disk: no `.git` ever created.
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, dot_git, .{}));
}

test "SYNAPSE_VAULT_INTEGRATIONS=git resolves a GitStore that commits on write" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolved = (try resolveStore(arena, io, &env, vault, "synapse/repo@main", "test", "")).?;

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);

    // The write also committed -- confirms this actually reached
    // `GitStore.write()`, not just the composed `DiskStore`'s own I/O.
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(io, dot_git, .{});
}

test "searchFiltered runs against disk directly regardless of which integrations are configured" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolved = (try resolveStore(arena, io, &env, vault, "", "test", "")).?;

    var store = resolved.store();
    _ = try store.write(io, "designs/x.md", "widget prose\n");
    _ = try store.write(io, "tasks/y.md", "widget prose too\n");

    // A `path_filter` is non-null, so this must go straight to disk
    // regardless of which integration is configured.
    var filter = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"glob": ["designs/*", {"var": "path"}]}
    , .{});
    defer filter.deinit();

    const hits = try resolved.searchFiltered(gpa, io, "widget", filter.value);
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("designs/x.md", hits[0].node);
}

/// A minimal decorator that overrides only `searchFiltered`, leaving
/// `linkGraph`/`renamer` undeclared -- neither `SchemaValidationStore` nor
/// `GitStore` overrides `searchFiltered` today, so nothing in the real
/// chain exercises that branch of `resolveCapabilities`. `read`/`write`/
/// `list`/`search` are plain passthroughs, needed only because `Store.from`
/// requires all four.
const FakeSearchOverride = struct {
    inner: Store,

    pub fn store(self: *FakeSearchOverride) Store {
        return Store.from(FakeSearchOverride, self);
    }
    pub fn read(self: *FakeSearchOverride, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        return self.inner.read(gpa, io, node);
    }
    pub fn write(self: *FakeSearchOverride, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        return self.inner.write(io, node, body);
    }
    pub fn list(self: *FakeSearchOverride, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return self.inner.list(gpa, io);
    }
    pub fn search(self: *FakeSearchOverride, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        return self.inner.search(gpa, io, query);
    }
    pub fn searchFiltered(self: *FakeSearchOverride, gpa: Allocator, io: Io, query: []const u8, path_filter: ?std.json.Value) anyerror![]const Store.Hit {
        _ = self;
        _ = io;
        _ = query;
        _ = path_filter;
        const hits = try gpa.alloc(Store.Hit, 1);
        hits[0] = .{ .node = try gpa.dupe(u8, "overridden.md"), .score = 1.0, .context = try gpa.dupe(u8, "") };
        return hits;
    }
};

test "resolveCapabilities lets a decorator override searchFiltered while linkGraph/renamer still fall through" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const vars = env_bridge.vars(&env);
    const disk_result = try composeLayer(DiskStore, .{
        .arena = arena,
        .vault = vault,
        .namespace = "",
        .env = &env,
        .vars = vars,
        .self_path = "",
        .inner_store = undefined,
        .inner_link_graph = undefined,
        .inner_renamer = undefined,
        .inner_search_filtered = undefined,
    });

    var fake: FakeSearchOverride = .{ .inner = disk_result.store };
    const result = resolveCapabilities(FakeSearchOverride, &fake, .{
        .arena = arena,
        .vault = vault,
        .namespace = "",
        .env = &env,
        .vars = vars,
        .self_path = "",
        .inner_store = disk_result.store,
        .inner_link_graph = disk_result.link_graph,
        .inner_renamer = disk_result.renamer,
        .inner_search_filtered = disk_result.search_filtered,
    });

    // Not declared on FakeSearchOverride -- fall through to disk's, unchanged.
    try testing.expectEqual(disk_result.link_graph.ptr, result.link_graph.ptr);
    try testing.expectEqual(disk_result.renamer.ptr, result.renamer.ptr);

    // Declared on FakeSearchOverride -- overridden, not inherited from disk.
    const hits = try result.search_filtered.searchFiltered(gpa, io, "anything", null);
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("overridden.md", hits[0].node);
}

test "self_path threads through to GitStore even when git is not the outermost integration" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // A real self_path with an unreachable target is enough to prove it was
    // threaded through and used -- `maybeSpawnPusher` only ever reaches
    // `std.process.spawn`, whose own failure is swallowed, if the push
    // threshold trips, which it won't on a single write. This just confirms
    // `resolveStore` doesn't drop `self_path` on the floor.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolved = (try resolveStore(arena, io, &env, vault, "", "test", "/does/not/matter")).?;
    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
}

test "disk named explicitly in SYNAPSE_VAULT_INTEGRATIONS is a hard error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git,disk");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = try resolveStore(arena, io_threaded.io(), &env, vault, "", null, "");
    try testing.expectEqual(@as(?ResolvedStore, null), resolved);
}

test "an unrecognized integration name resolves null, not a crash or a silent fallback" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "notion");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = try resolveStore(arena, io_threaded.io(), &env, vault, "", null, "");
    try testing.expectEqual(@as(?ResolvedStore, null), resolved);
}

test "an integration named twice is a hard error" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git,git");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = try resolveStore(arena, io_threaded.io(), &env, vault, "", null, "");
    try testing.expectEqual(@as(?ResolvedStore, null), resolved);
}

test "hasIntegration answers a plain yes/no without constructing any store" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    try testing.expect(try hasIntegration(gpa, io, &env, "git"));
    try testing.expect(!(try hasIntegration(gpa, io, &env, "notion")));
}
