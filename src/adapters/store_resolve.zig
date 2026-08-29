//! One place that decides which `ports.Store` backend a caller gets, from
//! `SYNAPSE_VAULT_STORE=obsidian|disk` (default `disk` -- no Obsidian
//! dependency unless a caller opts into the live-app-preferred `obsidian`
//! backend explicitly) and `SYNAPSE_VAULT_DIR`. Both resolve through
//! `core.conf.resolve`/`vaultDir` -- a real environment variable wins, then
//! the first conf file that defines the key -- so setting either in
//! `synapse.conf` works exactly like exporting it. Every CLI subcommand and
//! every hook that needs a `Store` calls this instead of resolving one
//! itself.
//!
//! `ObsidianStore` reaches Obsidian through the official CLI's own local
//! socket, which needs neither a plugin installed nor any file this
//! function has to go find.
//!
//! A future backend (`SqliteStore`, `NotionStore`) is one more arm here and
//! nowhere else -- every caller already goes through this function.

const std = @import("std");
const core = @import("core");
const ports = @import("ports");
const obsidian = @import("obsidian/store.zig");
const disk_store = @import("disk/store.zig");
const git_store = @import("git/store.zig");
const env_bridge = @import("env.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;
const Renamer = ports.Renamer;

/// Owns whichever concrete backend was resolved -- a caller holds this as a
/// local `var`, exactly like today's `var os_store = try ObsidianStore.init(...)`,
/// just polymorphic over which backend it turned out to be. `Store` itself
/// stays at exactly four methods with no `deinit`; lifecycle management
/// lives here instead; a new backend adds one more union field, not a
/// change to `ports.Store`.
pub const ResolvedStore = union(enum) {
    obsidian: obsidian.ObsidianStore,
    disk: disk_store.DiskStore,
    git: git_store.GitStore,

    pub fn store(self: *ResolvedStore) Store {
        return switch (self.*) {
            .obsidian => |*s| s.store(),
            .disk => |*s| s.store(),
            .git => |*s| s.store(),
        };
    }

    /// `null` when the resolved backend has no `LinkGraph` of its own --
    /// asked structurally (does this type declare a `linkGraph()` method),
    /// never by naming a specific backend. Both real coding-vault backends
    /// have one now; `?LinkGraph` means "not every `Store` is a vault-store"
    /// (true of Bard's stores specifically), not "nice-to-have" here.
    pub fn linkGraph(self: *ResolvedStore) ?LinkGraph {
        return switch (self.*) {
            inline else => |*s| {
                const T = @TypeOf(s.*);
                if (@hasDecl(T, "linkGraph")) return s.linkGraph();
                return null;
            },
        };
    }

    /// Same structural-duck-typing dispatch as `linkGraph`, for `Renamer`.
    pub fn renamer(self: *ResolvedStore) ?Renamer {
        return switch (self.*) {
            inline else => |*s| {
                const T = @TypeOf(s.*);
                if (@hasDecl(T, "renamer")) return s.renamer();
                return null;
            },
        };
    }

    /// Full-text search, first scoped to whichever candidate paths pass
    /// `path_filter` (`DiskStore.searchFiltered`'s own doc comment has the
    /// exact contract: a JsonLogic rule expected to reference nothing but
    /// `path`). `null` runs the resolved backend's ordinary `search`
    /// (through the live app under `.obsidian`, same as `store().search(...)`
    /// would), so a caller with no filter to apply sees no behavior change
    /// at all.
    ///
    /// Same structural-duck-typing dispatch as `linkGraph`/`renamer` -- but
    /// unlike those two, a missing `searchFiltered` is a `@compileError`,
    /// not a `null`: a caller that explicitly asked to scope a search has
    /// to get a scoped answer or a build failure, never a silently
    /// unscoped one, so a future `ResolvedStore` variant is forced to add
    /// its own `searchFiltered` (typically a one-line delegation to its own
    /// `DiskStore` field, the same shape `ObsidianStore.searchFiltered`
    /// already is) before it compiles, rather than degrading at runtime
    /// with nothing to catch it.
    pub fn searchFiltered(
        self: *ResolvedStore,
        gpa: Allocator,
        io: Io,
        query: []const u8,
        path_filter: ?std.json.Value,
    ) anyerror![]const Store.Hit {
        if (path_filter == null) return self.store().search(gpa, io, query);
        return switch (self.*) {
            inline else => |*s| {
                const T = @TypeOf(s.*);
                if (!@hasDecl(T, "searchFiltered"))
                    @compileError(@typeName(T) ++ " has no searchFiltered -- add one, e.g. a delegation to its own DiskStore field");
                return s.searchFiltered(gpa, io, query, path_filter);
            },
        };
    }

    /// A no-op for every variant but `.git` -- sets the path `GitStore`
    /// re-invokes via `argv[0]` to spawn its own detached Pusher. Called
    /// once by a write-capable CLI entry point right after resolving,
    /// before the store does any real work; every other caller (a read-only
    /// command, a hook) simply never calls this, and `GitStore.write()`'s
    /// own `self_path.len == 0` check degrades to "never spawn" exactly
    /// like `stop_nudge.maybeSync` already does with no `self_path` known.
    pub fn setSelfPath(self: *ResolvedStore, path: []const u8) void {
        switch (self.*) {
            .git => |*s| s.self_path = path,
            else => {},
        }
    }

    pub fn deinit(self: *ResolvedStore) void {
        switch (self.*) {
            .obsidian => |*s| s.deinit(),
            .disk => |*s| s.deinit(),
            .git => |*s| s.deinit(),
        }
    }
};

/// `vault` is the already-resolved vault root (`core.conf.vaultDir`'s
/// result); `namespace` is what `ObsidianStore`/`DiskStore` alike prefix
/// onto every node name (`"synapse/{repo}@{branch}"`, or `""` to address
/// any note in the vault by its full path). `prog` prefixes diagnostics,
/// matching every other resolver in this codebase (`context.resolve`,
/// `context.workDirFor`) -- `null` instead of a name means stay silent:
/// hooks in this codebase treat every missing precondition as silence
/// (`common.vault`'s own doc comment states this directly), and a hook
/// calling this directly (see `sb — Vault store backend selection`'s own
/// "hooks skip the CLI layer" reasoning) needs that same silence, not a
/// stray stderr line CLI callers want but a hook never did. Null return is
/// an unrecoverable config problem, reported to stderr only when `prog` is
/// non-null -- the caller's job is just "no store, stop," not re-deciding
/// what the message should say.
pub fn resolveStore(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    namespace: []const u8,
    prog: ?[]const u8,
) !?ResolvedStore {
    // Same env-then-conf-file cascade `core.conf.vaultDir` already uses for
    // `SYNAPSE_VAULT_DIR` -- the shipped conf template documents this as a
    // settable conf-file key, not a real-environment-only one.
    const backend_owned = try core.conf.resolve(gpa, io, env_bridge.vars(env), "SYNAPSE_VAULT_STORE");
    defer if (backend_owned) |b| gpa.free(b);
    const backend = backend_owned orelse "disk";

    if (std.mem.eql(u8, backend, "disk")) {
        var store = try disk_store.DiskStore.init(gpa, vault, namespace);
        store.vars = env_bridge.vars(env);
        return .{ .disk = store };
    }
    if (std.mem.eql(u8, backend, "obsidian")) {
        var store = try obsidian.ObsidianStore.init(gpa, vault, namespace);
        store.disk.vars = env_bridge.vars(env);
        return .{ .obsidian = store };
    }
    if (std.mem.eql(u8, backend, "git")) {
        var store = try git_store.GitStore.init(gpa, vault, namespace);
        store.disk.vars = env_bridge.vars(env);
        // `self_path` stays empty until a write-capable caller sets it via
        // `ResolvedStore.setSelfPath` -- most callers (reads, hooks) never
        // will, and `GitStore.write()` degrades to "never spawn a Pusher"
        // exactly like `stop_nudge.maybeSync` already does with none known.
        store.env = env;
        return .{ .git = store };
    }
    report(prog, "unknown SYNAPSE_VAULT_STORE '{s}' -- want 'obsidian', 'disk', or 'git'\n", .{backend});
    return null;
}

fn report(prog: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const name = prog orelse return;
    std.debug.print("{s}: " ++ fmt, .{name} ++ args);
}

const testing = std.testing;

test "SYNAPSE_VAULT_STORE unset defaults to disk, no Obsidian dependency at all" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    _ = env.swapRemove("SYNAPSE_VAULT_STORE");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    // `SYNAPSE_VAULT_STORE` now cascades to a real conf file the same way
    // `SYNAPSE_VAULT_DIR` already does, so "no config file to find" has to
    // be true of the environment this test actually resolves against --
    // the real machine's own `HOME` might have a real `synapse.conf` with
    // a real value, which would otherwise leak into this test's result.
    try env.put("HOME", vault);
    _ = env.swapRemove("XDG_CONFIG_HOME");
    _ = env.swapRemove("CLAUDE_PLUGIN_ROOT");
    _ = env.swapRemove("SYNAPSE_CONTENT_ROOT");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // Resolves straight away, `.disk` -- no config file to find, no
    // `obsidian` CLI needed either.
    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test")).?;
    defer resolved.deinit();
    try testing.expect(resolved == .disk);

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "SYNAPSE_VAULT_STORE=obsidian resolves an ObsidianStore explicitly, no longer the default" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "obsidian");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // `read`/`write`/`list` are plain disk I/O even under `.obsidian`, so
    // this round-trips with no fake-CLI fixture.
    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test")).?;
    defer resolved.deinit();
    try testing.expect(resolved == .obsidian);

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "searchFiltered under .obsidian delegates to its own DiskStore, no live CLI needed" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "obsidian");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test")).?;
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

test "SYNAPSE_VAULT_STORE=git resolves a GitStore that round-trips read/write/list" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test")).?;
    defer resolved.deinit();
    try testing.expect(resolved == .git);

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);

    // The write also committed -- confirms `.git` actually reached
    // `GitStore.write()`, not just the composed `DiskStore`'s own I/O.
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{vault});
    defer gpa.free(dot_git);
    _ = try Io.Dir.cwd().statFile(io, dot_git, .{});
}

test "setSelfPath is a no-op for every backend but .git" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "disk");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "", "test")).?;
    defer resolved.deinit();
    resolved.setSelfPath("/some/path"); // must not crash on a non-.git variant
}

test "SYNAPSE_VAULT_STORE=disk resolves a DiskStore with no config file needed" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "disk");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var resolved = (try resolveStore(gpa, io, &env, vault, "synapse/repo@main", "test")).?;
    defer resolved.deinit();
    try testing.expect(resolved == .disk);

    var store = resolved.store();
    const wr = try store.write(io, "Foo.md", "body\n");
    try testing.expect(wr.accepted);
    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("body\n", got);
}

test "an unknown SYNAPSE_VAULT_STORE value resolves null, not a crash or a silent fallback" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("SYNAPSE_VAULT_STORE", "sqlite");

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();

    const resolved = try resolveStore(gpa, io_threaded.io(), &env, "/nonexistent-vault", "synapse/repo@main", "test");
    try testing.expectEqual(@as(?ResolvedStore, null), resolved);
}
