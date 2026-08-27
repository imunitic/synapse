//! One place that decides which `ports.Store` backend a caller gets, from
//! `SYNAPSE_VAULT_STORE=obsidian|disk` (default `obsidian`, so an existing
//! install works unchanged after the `SYNAPSE_VAULT_DIR` rename alone) and
//! `SYNAPSE_VAULT_DIR`. Every CLI subcommand and every hook that needs a
//! `Store` calls this instead of its own copy of the Obsidian REST API's
//! config-discovery dance (`data.json`'s port/apiKey, the plugin's CA
//! cert) -- that logic used to be duplicated once per caller
//! (`write_node_cmd.zig`, `frontmatter_cmd.zig`, `project_index_cmd.zig`,
//! `staleness.zig`); this is the one copy.
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
    const backend = env.get("SYNAPSE_VAULT_STORE") orelse "obsidian";

    if (std.mem.eql(u8, backend, "disk")) {
        return .{ .disk = try disk_store.DiskStore.init(gpa, vault, namespace) };
    }
    if (!std.mem.eql(u8, backend, "obsidian")) {
        report(prog, "unknown SYNAPSE_VAULT_STORE '{s}' -- want 'obsidian' or 'disk'\n", .{backend});
        return null;
    }

    const os_store = (try resolveObsidian(gpa, io, env, vault, namespace, prog)) orelse return null;
    return .{ .obsidian = os_store };
}

fn report(prog: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const name = prog orelse return;
    std.debug.print("{s}: " ++ fmt, .{name} ++ args);
}

/// The plugin's port and API key, from the vault's own `data.json` -- read
/// here rather than passed in `argv`, which stays visible to `ps`. Same
/// resolution every `openStore`-shaped helper used to duplicate.
fn resolveObsidian(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    vault: []const u8,
    namespace: []const u8,
    prog: ?[]const u8,
) !?obsidian.ObsidianStore {
    const plugin_path = try std.fmt.allocPrint(
        gpa,
        "{s}/.obsidian/plugins/obsidian-local-rest-api/data.json",
        .{vault},
    );
    defer gpa.free(plugin_path);
    const text = Io.Dir.cwd().readFileAlloc(io, plugin_path, gpa, .limited(1 << 20)) catch {
        report(prog, "REST API not configured\n", .{});
        return null;
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        report(prog, "no API key/port\n", .{});
        return null;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            report(prog, "no API key/port\n", .{});
            return null;
        },
    };
    const api_key = switch (obj.get("apiKey") orelse .null) {
        .string => |s| s,
        else => "",
    };
    const port: u16 = switch (obj.get("port") orelse .null) { // plugin writes a number; hand-edited may be a string
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
        else => 0,
    };
    if (api_key.len == 0 or port == 0) {
        report(prog, "no API key/port\n", .{});
        return null;
    }

    const cert = try certPath(gpa, env);
    defer gpa.free(cert);
    // Checked here, not left to the first `curl` call to discover: a missing
    // cert file otherwise fails every subsequent op with an unhelpful
    // "curl did not complete" rather than saying what's actually wrong.
    _ = Io.Dir.cwd().statFile(io, cert, .{}) catch {
        report(prog, "no CA cert at {s}\n", .{cert});
        return null;
    };
    return try obsidian.ObsidianStore.init(gpa, port, cert, api_key, vault, namespace);
}

/// `~/.claude/obsidian-local-rest-api-ca.pem`, the plugin's own CA.
fn certPath(gpa: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/.claude/obsidian-local-rest-api-ca.pem", .{env.get("HOME") orelse ""});
}

const testing = std.testing;

test "SYNAPSE_VAULT_STORE unset defaults to obsidian" {
    const gpa = testing.allocator;
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    _ = env.swapRemove("SYNAPSE_VAULT_STORE");
    try env.put("HOME", "/nonexistent-home");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const vault = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();

    // No data.json at all -- resolves null with the "REST API not
    // configured" diagnostic, proving the default path is obsidian (a
    // disk resolution would never look for data.json at all).
    const resolved = try resolveStore(gpa, io_threaded.io(), &env, vault, "synapse/repo@main", "test");
    try testing.expectEqual(@as(?ResolvedStore, null), resolved);
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
