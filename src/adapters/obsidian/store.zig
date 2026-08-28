//! `ObsidianStore`: a decorator around `DiskStore`, not a from-scratch
//! `ports.Store` implementation. `read`/`write`/`list` are plain disk I/O --
//! delegated straight to a composed `DiskStore`, since an Obsidian vault
//! already *is* the same folder of markdown files `DiskStore` reads and
//! writes directly. `search` and the composed `LinkGraph` (`link_graph`)
//! are the two things a live Obsidian app can answer that a bare disk read
//! can't: relevance search and the resolved wikilink graph -- both reached
//! through the official `obsidian` CLI, a local Unix-socket binary
//! (`/opt/homebrew/bin/obsidian` on this machine) with no REST plugin, no
//! CA cert, and no port/API-key config file needed. Obsidian itself must
//! still be running.
//!
//! `write-node`/`build-project-index` call `write` directly on the concrete
//! type, bypassing the port -- the same pattern this file's own two Bard
//! siblings (`BardGraphStore`/`BardVaultStore`) already use for their real
//! callers.

const std = @import("std");
const ports = @import("ports");
const core = @import("core");
const process = @import("../process.zig");
const disk_store = @import("../disk/store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;
const LinkGraph = ports.LinkGraph;

/// Resolves `vault_path` to `vault={name}` via `obsidian vaults verbose`'s
/// own `{name}\t{path}` listing -- explicit targeting, not whichever vault
/// the CLI treats as "current" when more than one is open, which is
/// unspecified behavior a live multi-vault Obsidian instance actually hits.
/// `null` (not a missing `vault=`) only when no listed vault's path matches,
/// so this degrades to the old unscoped behavior rather than failing an
/// otherwise-working call over it. Caller-owned when non-null.
fn resolveVaultArg(gpa: Allocator, io: Io, vault_path: []const u8) !?[]u8 {
    var res = try process.run(io, gpa, &.{ "obsidian", "vaults", "verbose" }, .{});
    defer res.deinit(gpa);
    if (!res.ok()) return null;

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, res.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        const path = line[tab + 1 ..];
        if (std.mem.eql(u8, path, vault_path)) {
            return try std.fmt.allocPrint(gpa, "vault={s}", .{name});
        }
    }
    return null;
}

/// Every CLI-backed call goes through this, so `vault=` targeting happens
/// exactly once, rather than once per call site with room for one to be
/// missed. `sub_args` is everything after `obsidian` itself.
fn runObsidian(gpa: Allocator, io: Io, vault_path: []const u8, sub_args: []const []const u8) !process.Result {
    const vault_arg = try resolveVaultArg(gpa, io, vault_path);
    defer if (vault_arg) |v| gpa.free(v);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "obsidian");
    if (vault_arg) |v| try argv.append(gpa, v);
    try argv.appendSlice(gpa, sub_args);

    return process.run(io, gpa, argv.items, .{});
}

pub const ObsidianStore = struct {
    disk: disk_store.DiskStore,
    link_graph: ObsidianLinkGraph,

    pub fn init(gpa: Allocator, vault: []const u8, namespace: []const u8) !ObsidianStore {
        var disk = try disk_store.DiskStore.init(gpa, vault, namespace);
        errdefer disk.deinit();
        return .{
            .disk = disk,
            // Borrows `disk.vault`/`disk.namespace`'s bytes -- same lifetime
            // as `disk` itself (both live and die together as fields of
            // this struct), so no separate copy or `deinit` of its own is
            // needed.
            .link_graph = .{ .vault = disk.vault, .namespace = disk.namespace },
        };
    }

    pub fn deinit(self: *ObsidianStore) void {
        self.disk.deinit();
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque` cast from
    /// `ObsidianStore` alone, so it can never disagree with `.ptr` the way a
    /// hand-written vtable literal could.
    pub fn store(self: *ObsidianStore) Store {
        return Store.from(ObsidianStore, self);
    }

    /// One-line delegation to the composed field -- `ObsidianStore` doesn't
    /// implement any `LinkGraph` method itself.
    pub fn linkGraph(self: *ObsidianStore) LinkGraph {
        return self.link_graph.linkGraph();
    }

    pub fn read(self: *ObsidianStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        return self.disk.read(gpa, io, node);
    }

    pub fn write(self: *ObsidianStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        return self.disk.write(io, node, body);
    }

    pub fn list(self: *ObsidianStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        return self.disk.list(gpa, io);
    }

    /// `obsidian search:context query=... format=json`, vault-wide by
    /// construction (the CLI has no namespace concept of its own) --
    /// filtered here to this store's own namespace and re-keyed to the same
    /// bare node name `read`/`write`/`list` use, so a caller can pass a
    /// `Store.Hit.node` straight into `read` without knowing this is the CLI
    /// underneath. `matches` has no relevance score of its own -- match
    /// count stands in for one, the same proxy `DiskStore.search` already
    /// uses.
    pub fn search(self: *ObsidianStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        const query_arg = try std.fmt.allocPrint(gpa, "query={s}", .{query});
        defer gpa.free(query_arg);

        var res = try runObsidian(gpa, io, self.disk.vault, &.{ "search:context", query_arg, "format=json" });
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;

        var out: std.ArrayListUnmanaged(Store.Hit) = .empty;
        errdefer {
            for (out.items) |h| {
                gpa.free(h.node);
                gpa.free(h.context);
            }
            out.deinit(gpa);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{}) catch
            return error.VaultUnreachable;
        defer parsed.deinit();
        const results = switch (parsed.value) {
            .array => |a| a,
            else => return try out.toOwnedSlice(gpa),
        };

        // Empty namespace means "no prefix at all" -- the same
        // full-vault-relative-path convention `read`/`write`/`list` already
        // use. Without this branch, `prefix` would be a bare "/" and no
        // real filename starts with a leading slash, so a whole-vault store
        // (the one `vault-search-text` opens) would silently filter out
        // every result.
        const prefix: ?[]u8 = if (self.disk.namespace.len == 0)
            null
        else
            try std.fmt.allocPrint(gpa, "{s}/", .{self.disk.namespace});
        defer if (prefix) |p| gpa.free(p);

        for (results.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const file = switch (obj.get("file") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const bare = if (prefix) |p| blk: {
                if (!std.mem.startsWith(u8, file, p)) continue; // outside this namespace
                break :blk file[p.len..];
            } else file;

            const matches = switch (obj.get("matches") orelse .null) {
                .array => |a| a,
                else => continue,
            };
            const context = ctx: {
                if (matches.items.len == 0) break :ctx "";
                const first = switch (matches.items[0]) {
                    .object => |o| o,
                    else => break :ctx "",
                };
                break :ctx switch (first.get("text") orelse .null) {
                    .string => |s| s,
                    else => "",
                };
            };

            try out.append(gpa, .{
                .node = try gpa.dupe(u8, bare),
                .score = @floatFromInt(matches.items.len),
                .context = try gpa.dupe(u8, context),
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

/// `LinkGraph` backed by the `obsidian` CLI. Composed into `ObsidianStore`
/// as a genuine field, not a second interface's worth of methods folded
/// onto `ObsidianStore` itself -- composition over inheritance, and the
/// closest thing Zig's structural typing has to a hand-rolled
/// trait/typeclass: `LinkGraph.from` checking this type's method shape at
/// comptime *is* the "implements" check, just structural rather than
/// declared.
pub const ObsidianLinkGraph = struct {
    /// The vault's own filesystem path -- resolved to a `vault=<name>` CLI
    /// argument on every call via `resolveVaultArg`, not left to whichever
    /// vault the CLI treats as "current" when more than one is open.
    vault: []const u8,
    /// `synapse/{repo}@{branch}`, same convention as `ObsidianStore`'s own
    /// namespace -- empty means a `node` passed to `backlinks`/`links` is
    /// already a full vault-relative path. `unresolved`/`orphans`/`deadends`
    /// are vault-wide by construction (the CLI has no scoping flag for any
    /// of them) and ignore this field entirely.
    namespace: []const u8,

    pub fn linkGraph(self: *ObsidianLinkGraph) LinkGraph {
        return LinkGraph.from(ObsidianLinkGraph, self);
    }

    fn nodePath(self: *ObsidianLinkGraph, gpa: Allocator, node: []const u8) ![]u8 {
        if (!core.node_path.isSafe(node)) return error.UnsafeNodePath;
        if (self.namespace.len == 0) return gpa.dupe(u8, node);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.namespace, node });
    }

    /// Strips this store's namespace prefix from a vault-relative path the
    /// CLI returned, re-keying it to the same bare node name `backlinks`'s
    /// own `node` argument uses. `null` when `path` falls outside this
    /// namespace -- the caller skips it, matching `ObsidianStore.search`'s
    /// own out-of-namespace handling.
    fn bareNode(self: *ObsidianLinkGraph, path: []const u8) ?[]const u8 {
        if (self.namespace.len == 0) return path;
        if (path.len <= self.namespace.len + 1) return null;
        if (!std.mem.startsWith(u8, path, self.namespace)) return null;
        if (path[self.namespace.len] != '/') return null;
        return path[self.namespace.len + 1 ..];
    }

    /// `obsidian backlinks path=... format=json counts` -- `count` comes
    /// back as a JSON string (`"2"`, not `2`), not the integer its own name
    /// suggests, checked live against the real CLI.
    pub fn backlinks(self: *ObsidianLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const LinkGraph.Backlink {
        const path = try self.nodePath(gpa, node);
        defer gpa.free(path);
        const path_arg = try std.fmt.allocPrint(gpa, "path={s}", .{path});
        defer gpa.free(path_arg);

        var res = try runObsidian(gpa, io, self.vault, &.{ "backlinks", path_arg, "format=json", "counts" });
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;

        var out: std.ArrayListUnmanaged(LinkGraph.Backlink) = .empty;
        errdefer {
            for (out.items) |b| gpa.free(b.node);
            out.deinit(gpa);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{}) catch
            return error.VaultUnreachable;
        defer parsed.deinit();
        const items = switch (parsed.value) {
            .array => |a| a,
            else => return try out.toOwnedSlice(gpa),
        };
        for (items.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const file = switch (obj.get("file") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const bare = self.bareNode(file) orelse continue;
            try out.append(gpa, .{
                .node = try gpa.dupe(u8, bare),
                .count = parseCount(obj.get("count") orelse .null),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// `obsidian links path=...` -- plain newline-separated paths, no
    /// `format=json` option exists for this command (checked against the
    /// CLI's own `--help` output).
    pub fn links(self: *ObsidianLinkGraph, gpa: Allocator, io: Io, node: []const u8) anyerror![]const []const u8 {
        const path = try self.nodePath(gpa, node);
        defer gpa.free(path);
        const path_arg = try std.fmt.allocPrint(gpa, "path={s}", .{path});
        defer gpa.free(path_arg);

        var res = try runObsidian(gpa, io, self.vault, &.{ "links", path_arg });
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, res.stdout, "\n"), '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const bare = self.bareNode(line) orelse continue;
            try out.append(gpa, try gpa.dupe(u8, bare));
        }
        return out.toOwnedSlice(gpa);
    }

    /// `obsidian unresolved format=json verbose` -- `sources` comes back as
    /// one comma-space-joined string (`"a.md, b.md"`), not a JSON array,
    /// checked live: a link named from two files is one row, not two, with
    /// both source paths joined this way.
    pub fn unresolved(self: *ObsidianLinkGraph, gpa: Allocator, io: Io) anyerror![]const LinkGraph.Unresolved {
        var res = try runObsidian(gpa, io, self.vault, &.{ "unresolved", "format=json", "verbose" });
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;

        var out: std.ArrayListUnmanaged(LinkGraph.Unresolved) = .empty;
        errdefer {
            for (out.items) |u| {
                gpa.free(u.target);
                for (u.sources) |s| gpa.free(s);
                gpa.free(u.sources);
            }
            out.deinit(gpa);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{}) catch
            return error.VaultUnreachable;
        defer parsed.deinit();
        const items = switch (parsed.value) {
            .array => |a| a,
            else => return try out.toOwnedSlice(gpa),
        };
        for (items.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const link = switch (obj.get("link") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const sources_raw = switch (obj.get("sources") orelse .null) {
                .string => |s| s,
                else => "",
            };

            var sources: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer {
                for (sources.items) |s| gpa.free(s);
                sources.deinit(gpa);
            }
            var sit = std.mem.splitSequence(u8, sources_raw, ", ");
            while (sit.next()) |s| {
                if (s.len == 0) continue;
                try sources.append(gpa, try gpa.dupe(u8, s));
            }

            try out.append(gpa, .{
                .target = try gpa.dupe(u8, link),
                .count = parseCount(obj.get("count") orelse .null),
                .sources = try sources.toOwnedSlice(gpa),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// `obsidian orphans` -- plain newline-separated paths, vault-wide, no
    /// `format=json` option, matching `links`. Never namespace-filtered:
    /// `/synapse-vault-tidy`'s own use is vault-wide (an empty-namespace
    /// store), and the CLI itself has no folder-scoping flag for this
    /// command to filter with server-side.
    pub fn orphans(self: *ObsidianLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        var res = try runObsidian(gpa, io, self.vault, &.{"orphans"});
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;
        return linesUnscoped(gpa, res.stdout);
    }

    /// `obsidian deadends` -- same shape as `orphans`.
    pub fn deadends(self: *ObsidianLinkGraph, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        var res = try runObsidian(gpa, io, self.vault, &.{"deadends"});
        defer res.deinit(gpa);
        if (!res.ok()) return error.VaultUnreachable;
        return linesUnscoped(gpa, res.stdout);
    }
};

fn linesUnscoped(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, line));
    }
    return out.toOwnedSlice(gpa);
}

/// The CLI reports counts as JSON strings, not integers (checked live) --
/// parsed defensively either way, defaulting to 0 rather than erroring on a
/// shape a future CLI version might change back.
fn parseCount(v: std.json.Value) usize {
    return switch (v) {
        .string => |s| std.fmt.parseInt(usize, s, 10) catch 0,
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

const testing = std.testing;

fn fakeObsidianEnv(gpa: Allocator, log_path: []const u8, script_path: []const u8) !std.process.Environ.Map {
    var env = try std.process.Environ.createMap(testing.environ, gpa);
    try env.put("FAKE_OBSIDIAN_LOG", log_path);
    try env.put("FAKE_OBSIDIAN_SCRIPT", script_path);

    var fake_bin_dir = try std.Io.Dir.cwd().openDir(testing.io, "tests/fixtures/fake-bin", .{});
    defer fake_bin_dir.close(testing.io);
    var fake_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(testing.io, &fake_bin_buf)];
    const real_path = env.get("PATH") orelse "";
    const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
    defer gpa.free(fake_bin);
    try env.put("PATH", fake_bin);
    return env;
}

// `Store.from(ObsidianStore, self)` and `LinkGraph.from(ObsidianLinkGraph,
// self)` both need every method to exist on their type to compile -- but
// only the moment something actually calls `.store()`/`.linkGraph()`. Zig's
// lazy analysis skips a function body nothing references, so these two
// calls are the reference that proves both compile, exercised end to end
// against a real fake `obsidian` fixture -- not just "it compiles," every
// op's real output is checked too.
test "ObsidianStore.store() and .linkGraph() compile, and read/write/list/search round-trip" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{root});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{root});
    defer gpa.free(script);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "obsidian.script",
        .data =
        \\search:context [{"file":"synapse/repo@main/Foo.md","matches":[{"line":1,"text":"body"}]}]
        \\
        ,
    });

    var env = try fakeObsidianEnv(gpa, log, script);
    defer env.deinit();

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "synapse/repo@main");
    defer os_store.deinit();
    var store = os_store.store();
    _ = os_store.linkGraph();

    const wr = try store.write(io, "Foo.md", "---\ntitle: Foo\n---\nbody\n");
    try testing.expect(wr.accepted);

    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", got);

    const names = try store.list(gpa, io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("Foo.md", names[0]);

    const hits = try store.search(gpa, io, "body");
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("Foo.md", hits[0].node);
    try testing.expectEqualStrings("body", hits[0].context);
}

test "search: an empty namespace addresses hits by their full vault-relative path, unprefixed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/tasks/synapse");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{root});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{root});
    defer gpa.free(script);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "obsidian.script",
        .data =
        \\search:context [{"file":"tasks/synapse/sb-037 — Task.md","matches":[{"line":1,"text":"body"}]}]
        \\
        ,
    });

    var env = try fakeObsidianEnv(gpa, log, script);
    defer env.deinit();

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "");
    defer os_store.deinit();
    var store = os_store.store();

    // An empty namespace means no prefix filtering at all, not a bare "/"
    // prefix -- no real filename starts with one, so every result would
    // otherwise be silently filtered out.
    const hits = try store.search(gpa, io, "body");
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("tasks/synapse/sb-037 — Task.md", hits[0].node);
}

test "linkGraph: backlinks/links/unresolved/orphans/deadends round-trip through the real fixture" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{root});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{root});
    defer gpa.free(script);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "obsidian.script",
        .data =
        \\backlinks [{"file":"synapse/repo@main/Bar.md","count":"2"},{"file":"tasks/synapse/sb-001.md","count":"1"}]
        \\links synapse/repo@main/Baz.md
        \\unresolved [{"link":"Missing Thing","count":"2","sources":"a.md, b.md"}]
        \\orphans synapse/repo@main/Orphan.md
        \\deadends synapse/repo@main/Deadend.md
        \\
        ,
    });

    var env = try fakeObsidianEnv(gpa, log, script);
    defer env.deinit();

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "synapse/repo@main");
    defer os_store.deinit();
    var lg = os_store.linkGraph();

    const bl = try lg.backlinks(gpa, io, "Foo.md");
    defer {
        for (bl) |b| gpa.free(b.node);
        gpa.free(bl);
    }
    // Only the in-namespace backlink survives; the `tasks/` one is filtered.
    try testing.expectEqual(@as(usize, 1), bl.len);
    try testing.expectEqualStrings("Bar.md", bl[0].node);
    try testing.expectEqual(@as(usize, 2), bl[0].count);

    const ls = try lg.links(gpa, io, "Foo.md");
    defer {
        for (ls) |n| gpa.free(n);
        gpa.free(ls);
    }
    try testing.expectEqual(@as(usize, 1), ls.len);
    try testing.expectEqualStrings("Baz.md", ls[0]);

    const un = try lg.unresolved(gpa, io);
    defer {
        for (un) |u| {
            gpa.free(u.target);
            for (u.sources) |s| gpa.free(s);
            gpa.free(u.sources);
        }
        gpa.free(un);
    }
    try testing.expectEqual(@as(usize, 1), un.len);
    try testing.expectEqualStrings("Missing Thing", un[0].target);
    try testing.expectEqual(@as(usize, 2), un[0].count);
    try testing.expectEqual(@as(usize, 2), un[0].sources.len);
    try testing.expectEqualStrings("a.md", un[0].sources[0]);
    try testing.expectEqualStrings("b.md", un[0].sources[1]);

    const orph = try lg.orphans(gpa, io);
    defer {
        for (orph) |n| gpa.free(n);
        gpa.free(orph);
    }
    try testing.expectEqual(@as(usize, 1), orph.len);
    try testing.expectEqualStrings("synapse/repo@main/Orphan.md", orph[0]);

    const de = try lg.deadends(gpa, io);
    defer {
        for (de) |n| gpa.free(n);
        gpa.free(de);
    }
    try testing.expectEqual(@as(usize, 1), de.len);
    try testing.expectEqualStrings("synapse/repo@main/Deadend.md", de[0]);
}

test "a call is scoped with vault= when `obsidian vaults verbose` lists a matching path" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const log = try std.fmt.allocPrint(gpa, "{s}/obsidian.log", .{root});
    defer gpa.free(log);
    const script = try std.fmt.allocPrint(gpa, "{s}/obsidian.script", .{root});
    defer gpa.free(script);

    // Two vaults listed, matching the multi-vault case this fix targets --
    // only "devvault"'s path matches, so that name is the one that must show
    // up as vault= on every subsequent call.
    const script_data = try std.fmt.allocPrint(
        gpa,
        "vaults Default\\t/does/not/match\\ndevvault\\t{s}\nsearch:context [{{\"file\":\"synapse/repo@main/Foo.md\",\"matches\":[{{\"line\":1,\"text\":\"body\"}}]}}]\n",
        .{vault},
    );
    defer gpa.free(script_data);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "obsidian.script", .data = script_data });

    var env = try fakeObsidianEnv(gpa, log, script);
    defer env.deinit();

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "synapse/repo@main");
    defer os_store.deinit();
    var store = os_store.store();

    const hits = try store.search(gpa, io, "body");
    defer {
        for (hits) |h| {
            gpa.free(h.node);
            gpa.free(h.context);
        }
        gpa.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);

    const log_content = try tmp.dir.readFileAlloc(testing.io, "obsidian.log", gpa, .unlimited);
    defer gpa.free(log_content);
    var found_vaults_call = false;
    var found_scoped_search = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log_content, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "vaults verbose")) found_vaults_call = true;
        if (std.mem.eql(u8, line, "vault=devvault search:context query=body format=json")) found_scoped_search = true;
    }
    try testing.expect(found_vaults_call);
    try testing.expect(found_scoped_search);
}

test "a node with a .. segment or a leading / is rejected before any request is made" {
    const gpa = testing.allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, "/dev/null", "synapse/repo@main");
    defer os_store.deinit();
    var store = os_store.store();
    var lg = os_store.linkGraph();

    // No fake-obsidian fixture needed for read/write: `DiskStore.nodePath`'s
    // guard fires first, before any I/O at all. `linkGraph`'s guard fires
    // inside `nodePath` too, before a process is spawned.
    try testing.expectError(error.UnsafeNodePath, store.write(io, "../../../../etc/passwd", "pwned"));
    try testing.expectError(error.UnsafeNodePath, store.read(gpa, io, "/etc/passwd"));
    try testing.expectError(error.UnsafeNodePath, lg.backlinks(gpa, io, "../../../../etc/passwd"));
    try testing.expectError(error.UnsafeNodePath, lg.links(gpa, io, "/etc/passwd"));
}

test "list recurses into subdirectories, prefixing names, and skips dot-prefixed ones" {
    // `list` is a plain `DiskStore.list` delegation -- no fake-obsidian
    // fixture wiring needed at all.
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/designs/synapse");
    try tmp.dir.createDirPath(testing.io, "vault/designs/eon");
    try tmp.dir.createDirPath(testing.io, "vault/designs/.trash");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/designs/synapse/sb-001.md", .data = "a\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/designs/eon/ecs-001.md", .data = "b\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/designs/.trash/deleted.md", .data = "not content\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "designs");
    defer os_store.deinit();
    var store = os_store.store();

    const names = try store.list(gpa, io);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_synapse = false;
    var saw_eon = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "synapse/sb-001.md")) saw_synapse = true;
        if (std.mem.eql(u8, n, "eon/ecs-001.md")) saw_eon = true;
    }
    try testing.expect(saw_synapse);
    try testing.expect(saw_eon);
}

// `frontmatter` opens a store with an empty namespace so it can reach any
// note in the vault, not just one repo's code-graph nodes -- this pins that
// `node` is then used as-is, with no `namespace/` prefix added.
test "an empty namespace addresses a node by its full vault-relative path, unprefixed" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/tasks/synapse");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, vault, "");
    defer os_store.deinit();
    var store = os_store.store();

    const wr = try store.write(io, "tasks/synapse/sb-037 — Task.md", "---\ntitle: Task\n---\nbody\n");
    try testing.expect(wr.accepted);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/tasks/synapse/sb-037 — Task.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", on_disk);

    const got = (try store.read(gpa, io, "tasks/synapse/sb-037 — Task.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", got);
}
