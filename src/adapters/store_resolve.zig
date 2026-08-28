//! One place that decides which `ports.Store` backend a caller gets, from
//! `SYNAPSE_VAULT_STORE=obsidian|disk` (default `obsidian`, so an existing
//! install works unchanged after the `SYNAPSE_VAULT_DIR` rename alone) and
//! `SYNAPSE_VAULT_DIR`. Every CLI subcommand and every hook that needs a
//! `Store` calls this instead of resolving one itself.
//!
//! `ObsidianStore` reaches Obsidian through the official CLI's own local
//! socket, which needs neither a plugin installed nor any file this
//! function has to go find.
//!
//! A future backend (`SqliteStore`, `NotionStore`) is one more arm here and
//! nowhere else -- every caller already goes through this function.

const std = @import("std");
const ports = @import("ports");
const obsidian = @import("obsidian/store.zig");
const disk_store = @import("disk/store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;

/// Owns whichever concrete backend was resolved -- a caller holds this as a
/// local `var`, exactly like today's `var os_store = try ObsidianStore.init(...)`,
/// just polymorphic over which backend it turned out to be. `Store` itself
/// stays at exactly four methods with no `deinit`; lifecycle management
/// lives here instead; a new backend adds one more union field, not a
/// change to `ports.Store`.
pub const ResolvedStore = union(enum) {
    obsidian: obsidian.ObsidianStore,
    disk: disk_store.DiskStore,

    pub fn store(self: *ResolvedStore) Store {
        return switch (self.*) {
            .obsidian => |*s| s.store(),
            .disk => |*s| s.store(),
        };
    }

    /// `null` when the resolved backend has no `LinkGraph` of its own --
    /// asked structurally (does this type declare a `linkGraph()` method),
    /// never by naming a specific backend. `DiskStore` has none yet;
    /// `?LinkGraph` means "not every `Store` is a vault-store," not
    /// "nice-to-have" -- `DiskStore` is expected to grow its own over time.
    pub fn linkGraph(self: *ResolvedStore) ?LinkGraph {
        return switch (self.*) {
            inline else => |*s| {
                const T = @TypeOf(s.*);
                if (@hasDecl(T, "linkGraph")) return s.linkGraph();
                return null;
            },
        };
    }

    pub fn deinit(self: *ResolvedStore) void {
        switch (self.*) {
            .obsidian => |*s| s.deinit(),
            .disk => |*s| s.deinit(),
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
    // Neither backend needs `io` to resolve. Kept in the signature anyway:
    // every caller already threads it through, and a future backend (a
    // local index file, a socket probe) plausibly will.
    _ = io;
    const backend = env.get("SYNAPSE_VAULT_STORE") orelse "obsidian";

    if (std.mem.eql(u8, backend, "disk")) {
        return .{ .disk = try disk_store.DiskStore.init(gpa, vault, namespace) };
    }
    if (std.mem.eql(u8, backend, "obsidian")) {
        return .{ .obsidian = try obsidian.ObsidianStore.init(gpa, vault, namespace) };
    }
    report(prog, "unknown SYNAPSE_VAULT_STORE '{s}' -- want 'obsidian' or 'disk'\n", .{backend});
    return null;
}

fn report(prog: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const name = prog orelse return;
    std.debug.print("{s}: " ++ fmt, .{name} ++ args);
}

const testing = std.testing;

test "SYNAPSE_VAULT_STORE unset defaults to obsidian, resolving with no config file needed" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    _ = env.swapRemove("SYNAPSE_VAULT_STORE");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // Resolves straight away, `.obsidian` -- no config file to find.
    // `read`/`write`/`list` are plain disk I/O, so this round-trips with
    // no fake-CLI fixture.
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
