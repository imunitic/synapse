//! One place that decides which `ports.Store` chain a caller gets, from
//! `SYNAPSE_VAULT_INTEGRATIONS` (a comma-separated list, outer-to-inner:
//! `git,obsidian` means `GitStore` wraps `ObsidianStore` wraps the one real
//! store, `DiskStore`) and `SYNAPSE_VAULT_DIR`. Both resolve through
//! `core.conf.resolve`/`vaultDir` -- a real environment variable wins, then
//! the first conf file that defines the key -- so setting either in
//! `synapse.conf` works exactly like exporting it. Every CLI subcommand and
//! every hook that needs a `Store` calls this instead of resolving one
//! itself.
//!
//! `disk` is never named in the value -- it's always the implicit innermost
//! element, whether the list is empty, one integration long, or several.
//! Naming it, or naming any integration more than once, is a hard error,
//! not a silent fallback -- same "report the bad value, never substitute a
//! guess" precedent an unrecognized name already has.
//!
//! `ObsidianStore` reaches Obsidian through the official CLI's own local
//! socket, which needs neither a plugin installed nor any file this
//! function has to go find.
//!
//! A future integration (`NotionStore`, say) is one more name in
//! `known_integrations` and one more branch in `resolveStore`'s own compose
//! loop, nowhere else -- it would be shaped the same way `git`/`obsidian`
//! already are, a decorator over the one real store, not a new kind of peer
//! backend.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const obsidian = @import("obsidian/store.zig");
const disk_store = @import("disk/store.zig");
const git_store = @import("git/store.zig");
const env_bridge = @import("env.zig");
const process = @import("process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;
const SearchFiltered = ports.SearchFiltered;
const DiskStore = disk_store.DiskStore;
const ObsidianStore = obsidian.ObsidianStore;
const GitStore = git_store.GitStore;

/// One heap-allocated layer of the composed chain, plus how to destroy it --
/// captured at construction time, when `T` is still known, since a plain
/// `*anyopaque` alone can't tell `gpa.destroy` its own size and alignment.
const OwnedLayer = struct {
    ptr: *anyopaque,
    destroy: *const fn (gpa: Allocator, ptr: *anyopaque) void,

    fn of(comptime T: type, ptr: *T) OwnedLayer {
        const Impl = struct {
            fn destroy(g: Allocator, p: *anyopaque) void {
                g.destroy(@as(*T, @ptrCast(@alignCast(p))));
            }
        };
        return .{ .ptr = ptr, .destroy = Impl.destroy };
    }
};

/// Owns the whole composed chain -- every layer is heap-allocated (a
/// `Store`/`LinkGraph`/`Renamer` value embeds a pointer into the concrete
/// instance beneath it, which has to outlive this struct, not just the
/// function that built it) and freed together in `deinit`. Holds the
/// already-resolved `Store`/`LinkGraph`/`Renamer`/`SearchFiltered` values
/// directly rather than a tagged union of concrete outer types: capability
/// resolution happens once, during compose, while every layer is still a
/// concrete type -- see the design note (`sb — Generic Store decorator
/// stacking`) for why that's sufficient and nothing needs rediscovering
/// from an already-erased value later.
pub const ResolvedStore = struct {
    resolved_store: Store,
    resolved_link_graph: LinkGraph,
    resolved_renamer: Renamer,
    resolved_search_filtered: SearchFiltered,
    gpa: Allocator,
    disk: *DiskStore,
    layers: std.ArrayListUnmanaged(OwnedLayer),

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
    /// `path`). `null` runs the resolved chain's ordinary `search` (through
    /// the live app, if `obsidian` is anywhere in it, same as
    /// `store().search(...)` would), so a caller with no filter to apply
    /// sees no behavior change at all.
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

    pub fn deinit(self: *ResolvedStore) void {
        self.disk.deinit();
        self.gpa.destroy(self.disk);
        for (self.layers.items) |l| l.destroy(self.gpa, l.ptr);
        self.layers.deinit(self.gpa);
    }
};

const known_integrations = [_][]const u8{ "git", "obsidian" };

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
        for (known_integrations) |k| {
            if (std.mem.eql(u8, name, k)) known = true;
        }
        if (!known) {
            report(prog, "unknown integration '{s}' in SYNAPSE_VAULT_INTEGRATIONS -- want 'git', 'obsidian', or a comma-separated combination\n", .{name});
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
pub fn resolveStore(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    namespace: []const u8,
    prog: ?[]const u8,
    self_path: []const u8,
) !?ResolvedStore {
    const value_owned = try core.conf.resolve(gpa, io, env_bridge.vars(env), "SYNAPSE_VAULT_INTEGRATIONS");
    defer if (value_owned) |v| gpa.free(v);

    var count: usize = 0;
    var buf: [8][]const u8 = undefined;
    _ = parseIntegrationsImpl(value_owned orelse "", prog, &buf, &count) orelse return null;
    const names = buf[0..count];

    const disk = try gpa.create(DiskStore);
    errdefer gpa.destroy(disk);
    disk.* = try DiskStore.init(gpa, vault, namespace);
    errdefer disk.deinit();
    disk.vars = env_bridge.vars(env);

    var layers: std.ArrayListUnmanaged(OwnedLayer) = .empty;
    errdefer layers.deinit(gpa);

    var current_store: Store = disk.store();
    var current_link_graph: LinkGraph = disk.linkGraph();
    var current_renamer: Renamer = disk.renamer();
    const current_search_filtered: SearchFiltered = SearchFiltered.from(DiskStore, disk);

    // Outer-to-inner in `names`, so build innermost-first: walk in reverse.
    var i = names.len;
    while (i > 0) {
        i -= 1;
        const name = names[i];
        if (std.mem.eql(u8, name, "git")) {
            const git = try gpa.create(GitStore);
            errdefer gpa.destroy(git);
            git.* = GitStore.init(gpa, vault, current_store, current_link_graph, current_renamer, current_search_filtered);
            git.env = env;
            git.self_path = self_path;
            try layers.append(gpa, OwnedLayer.of(GitStore, git));
            current_store = git.store();
            current_renamer = git.renamer();
            // `linkGraph`/`searchFiltered` pass straight through -- `git`
            // never overrides either.
        } else if (std.mem.eql(u8, name, "obsidian")) {
            const os = try gpa.create(ObsidianStore);
            errdefer gpa.destroy(os);
            os.* = ObsidianStore.init(vault, namespace, current_store, current_link_graph, current_renamer, current_search_filtered);
            try layers.append(gpa, OwnedLayer.of(ObsidianStore, os));
            current_store = os.store();
            current_link_graph = os.linkGraph();
            current_renamer = os.renamer();
            // `searchFiltered` passes straight through -- Obsidian's own
            // query language has no path-filter concept to translate a
            // JsonLogic rule into.
        } else unreachable; // parseIntegrationsImpl already validated every name
    }

    return .{
        .resolved_store = current_store,
        .resolved_link_graph = current_link_graph,
        .resolved_renamer = current_renamer,
        .resolved_search_filtered = current_search_filtered,
        .gpa = gpa,
        .disk = disk,
        .layers = layers,
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

test "SYNAPSE_VAULT_INTEGRATIONS unset defaults to the plain disk store" {
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

    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test", "")).?;
    defer resolved.deinit();

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

    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test", "")).?;
    defer resolved.deinit();

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);

    // The write also committed -- confirms this actually reached
    // `GitStore.write()`, not just the composed `DiskStore`'s own I/O.
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(io, dot_git, .{});
}

test "SYNAPSE_VAULT_INTEGRATIONS=obsidian resolves an ObsidianStore, plain disk I/O with no live CLI needed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "obsidian");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test", "")).?;
    defer resolved.deinit();

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "searchFiltered runs against disk directly regardless of which integrations are configured" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var env = try isolatedEnv(gpa, vault);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "obsidian");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test", "")).?;
    defer resolved.deinit();

    var store = resolved.store();
    _ = try store.write(io, "designs/x.md", "widget prose\n");
    _ = try store.write(io, "tasks/y.md", "widget prose too\n");

    // A `path_filter` is non-null, so this must never try the (unreachable
    // in a test) live Obsidian CLI at all -- it goes straight to disk.
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
    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test", "/does/not/matter")).?;
    defer resolved.deinit();
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

    const resolved = try resolveStore(gpa, io_threaded.io(), &env, vault, "", null, "");
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

    const resolved = try resolveStore(gpa, io_threaded.io(), &env, vault, "", null, "");
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

    const resolved = try resolveStore(gpa, io_threaded.io(), &env, vault, "", null, "");
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
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git,obsidian");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    try testing.expect(try hasIntegration(gpa, io, &env, "git"));
    try testing.expect(try hasIntegration(gpa, io, &env, "obsidian"));
    try testing.expect(!(try hasIntegration(gpa, io, &env, "notion")));
}

fn fakeObsidianEnv(gpa: Allocator, vault: []const u8, log_path: []const u8, script_path: []const u8) !std.process.Environ.Map {
    var env = try isolatedEnv(gpa, vault);
    try env.put("FAKE_OBSIDIAN_LOG", log_path);
    try env.put("FAKE_OBSIDIAN_SCRIPT", script_path);

    var fake_bin_dir = try Io.Dir.cwd().openDir(testing.io, "tests/fixtures/fake-bin", .{});
    defer fake_bin_dir.close(testing.io);
    var fake_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(testing.io, &fake_bin_buf)];
    const real_path = env.get("PATH") orelse "";
    const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
    defer gpa.free(fake_bin);
    try env.put("PATH", fake_bin);
    return env;
}

// The actual point of this task: `git,obsidian` composes `GitStore`
// wrapping `ObsidianStore` wrapping the disk store, so a write through the
// resolved chain both prefers Obsidian's own live search (not disk's) and
// commits under git (not silently, the way a pure delegation would).
test "SYNAPSE_VAULT_INTEGRATIONS=git,obsidian: a write commits, and search prefers the live app" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{vault});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{vault});
    defer gpa.free(script);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "obsidian.script",
        .data =
        \\search:context [{"file":"Foo.md","matches":[{"line":1,"text":"live hit"}]}]
        \\
        ,
    });

    var env = try fakeObsidianEnv(gpa, vault, log, script);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git,obsidian");

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test", "")).?;
    defer resolved.deinit();

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);

    // Committed under git -- proves `GitStore` is actually the outermost
    // layer, not bypassed.
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(io, dot_git, .{});

    // Search answers from the fake live app, not a disk scan -- proves the
    // chain actually reaches `ObsidianStore.search`, not skipping straight
    // to the disk store beneath it.
    const hits = try store.search(gpa, io, "hit");
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("live hit", hits[0].context);
}

// The other real fork this task settled: a rename under `git,obsidian` has
// to go through Obsidian's own rename mechanism (so the CLI's live index
// stays correct), not silently bypass it with a raw file move -- and it
// still has to commit under git afterward.
test "SYNAPSE_VAULT_INTEGRATIONS=git,obsidian: rename goes through Obsidian, then commits" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{vault});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{vault});
    defer gpa.free(script);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "obsidian.script", .data = "rename \n" });

    var env = try fakeObsidianEnv(gpa, vault, log, script);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_INTEGRATIONS", "git,obsidian");

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test", "")).?;
    defer resolved.deinit();

    var store = resolved.store();
    _ = try store.write(io, "Old.md", "body\n");

    var renamer = resolved.renamer();
    try renamer.rename(gpa, io, "Old.md", "New.md");

    // The fake CLI, not a raw file move, actually did the rename -- proves
    // `GitRenamer` delegated to Obsidian's own renamer, not a hardcoded
    // `DiskRenamer`.
    const log_content = try tmp.dir.readFileAlloc(testing.io, "obsidian.log", gpa, .unlimited);
    defer gpa.free(log_content);
    try testing.expect(std.mem.indexOf(u8, log_content, "rename path=Old.md name=New.md") != null);

    // And it still committed under git afterward.
    const head_res = try process.run(io, gpa, &.{ "git", "log", "-1", "--format=%s" }, .{ .cwd = .{ .path = vault } });
    defer head_res.deinit(gpa);
    try testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, head_res.stdout, " \t\r\n"), "vault: "));
}
