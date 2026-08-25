//! The Obsidian Local REST API adapter: `write` is a `PUT`, `read` a `GET`,
//! both on `/vault/{path}`, reached through `ports.Store` (the wrapper idiom
//! -- `.store()` is `Store.from`, same as every other real implementation).
//! `write-node`/`build-project-index` call `write` directly on the concrete
//! type, bypassing the port -- the same pattern this file's own two Bard
//! siblings (`BardGraphStore`/`BardVaultStore`) already use for their real
//! callers.
//!
//! `read`/`list`/`search` exist for a different reason than "the agent
//! wants to browse vault content" -- that stays on the `obsidian` MCP
//! server directly, with no reason to go through this binary at all. These
//! three exist because `Store.from(ObsidianStore, self)` needs all four
//! methods to compile the moment anything calls `.store()`, and
//! `frontmatter` is the first real caller: a compiled command doing an
//! internal read (and, for `set`, a read-modify-write) on one file, which
//! never exposes the note's body to the agent's context at all -- the
//! opposite case from browsing.
//!
//! **`curl`, not `std.http`**: the plugin's certificate carries an IP SAN
//! and no DNS name, which `std.crypto.tls` has no path for. One spawn per
//! call is affordable here specifically because
//! this runs per *node* (tens per namespace), not per *file* like `vocab`/`rank`.

const std = @import("std");
const ports = @import("ports");
const process = @import("../process.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = ports.Store;

pub const ObsidianStore = struct {
    gpa: Allocator,
    /// `https://127.0.0.1:{port}`, built once.
    base: []const u8,
    /// The plugin's own CA, from `~/.claude/obsidian-local-rest-api-ca.pem`.
    cert_path: []const u8,
    api_key: []const u8,
    /// `synapse/{repo}@{branch}`, prefixed onto every node name so callers
    /// pass a title, never a vault path. Resolved once by the constructor,
    /// so two resolutions can't disagree.
    ///
    /// Empty means "no prefix at all" -- `node` is then a full vault-relative
    /// path itself, addressing any note in the vault rather than one code
    /// namespace. `frontmatter` opens a store this way: the notes it
    /// edits (task notes, design notes) live outside `synapse/{repo}@{branch}/`
    /// entirely, so a namespace-scoped store could never reach them.
    namespace: []const u8,

    /// Copies all three strings; `deinit` frees them. Borrowing made every
    /// caller responsible for outliving the store and all three got it
    /// wrong the same way -- caught only by the Linux container's
    /// `DebugAllocator`, silent on macOS.
    pub fn init(
        gpa: Allocator,
        port_number: u16,
        cert_path: []const u8,
        api_key: []const u8,
        namespace: []const u8,
    ) !ObsidianStore {
        const base = try std.fmt.allocPrint(gpa, "https://127.0.0.1:{d}", .{port_number});
        errdefer gpa.free(base);
        const cert = try gpa.dupe(u8, cert_path);
        errdefer gpa.free(cert);
        const key = try gpa.dupe(u8, api_key);
        errdefer gpa.free(key);
        const ns = try gpa.dupe(u8, namespace);
        return .{
            .gpa = gpa,
            .base = base,
            .cert_path = cert,
            .api_key = key,
            .namespace = ns,
        };
    }

    pub fn deinit(self: *ObsidianStore) void {
        self.gpa.free(self.base);
        self.gpa.free(self.cert_path);
        self.gpa.free(self.api_key);
        self.gpa.free(self.namespace);
    }

    /// `Authorization: Bearer …`, built per call.
    fn authHeader(self: *ObsidianStore, gpa: Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{self.api_key});
    }

    fn nodeUrl(self: *ObsidianStore, gpa: Allocator, node: []const u8) ![]u8 {
        const owned_path: ?[]u8 = if (self.namespace.len == 0)
            null
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.namespace, node });
        defer if (owned_path) |p| gpa.free(p);
        const vault_path: []const u8 = owned_path orelse node;

        const encoded = try encodePath(gpa, vault_path);
        defer gpa.free(encoded);
        return std.fmt.allocPrint(gpa, "{s}/vault/{s}", .{ self.base, encoded });
    }

    /// The wrapper idiom: `Store.from` generates the `*anyopaque`
    /// cast from `ObsidianStore` alone, so it can never disagree with
    /// `.ptr` the way a hand-written vtable literal could.
    pub fn store(self: *ObsidianStore) Store {
        return Store.from(ObsidianStore, self);
    }

    /// A PUT, reporting the status in `WriteResult` rather than collapsing
    /// it to a plain error -- `write-node`'s failure line
    /// (`PUT failed (500): <body>`) needs the real number, and `Store`'s
    /// shared `write` signature carries it precisely so every implementation
    /// can report a rejection this way, not just this one.
    pub fn write(self: *ObsidianStore, io: Io, node: []const u8, body: []const u8) anyerror!Store.WriteResult {
        const gpa = self.gpa;
        const url = try self.nodeUrl(gpa, node);
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        // `--data-binary @-` on stdin, not inline: an argument list is
        // bounded and a node can run to megabytes. `-w '\n%{http_code}'`
        // with no `-o` puts the body, a newline, and the status all on stdout.
        const res = try process.run(io, gpa, &.{
            "curl",          "-s",
            "-w",            "\n%{http_code}",
            "-X",            "PUT",
            "--cacert",      self.cert_path,
            "-H",            auth,
            "-H",            "Content-Type: text/markdown",
            "--data-binary", "@-",
            url,
        }, .{ .stdin = body });
        defer gpa.free(res.stderr);
        defer gpa.free(res.stdout);
        if (!res.ok()) return .{ .accepted = false, .status = 0, .body = try gpa.dupe(u8, "") };

        const trimmed = std.mem.trimEnd(u8, res.stdout, " \t\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const status_text = if (nl) |at| trimmed[at + 1 ..] else trimmed;
        const payload = if (nl) |at| trimmed[0..at] else "";
        const status = std.fmt.parseInt(u16, status_text, 10) catch 0;
        return .{
            .accepted = status >= 200 and status < 300,
            .status = status,
            .body = try gpa.dupe(u8, payload),
        };
    }

    /// A GET, same `-w '\n%{http_code}'` shape as `write`'s PUT. `null` for
    /// a 404 -- the port's own documented "doesn't exist yet" answer, not an
    /// error -- and `error.VaultUnreachable` for anything else that isn't a
    /// clean 2xx: a spawn/connection failure (`!res.ok()`) or an unexpected
    /// status alike, since neither means "the node doesn't exist," and only
    /// the caller of `read` can decide what a genuine failure should do.
    pub fn read(self: *ObsidianStore, gpa: Allocator, io: Io, node: []const u8) anyerror!?[]u8 {
        const url = try self.nodeUrl(gpa, node);
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        const res = try process.run(io, gpa, &.{
            "curl",     "-s",
            "-w",       "\n%{http_code}",
            "-X",       "GET",
            "--cacert", self.cert_path,
            "-H",       auth,
            url,
        }, .{});
        defer gpa.free(res.stderr);
        defer gpa.free(res.stdout);
        if (!res.ok()) return error.VaultUnreachable;

        const trimmed = std.mem.trimEnd(u8, res.stdout, " \t\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const status_text = if (nl) |at| trimmed[at + 1 ..] else trimmed;
        const payload = if (nl) |at| trimmed[0..at] else "";
        const status = std.fmt.parseInt(u16, status_text, 10) catch 0;

        if (status == 404) return null;
        if (status < 200 or status >= 300) return error.VaultUnreachable;
        return try gpa.dupe(u8, payload);
    }

    /// `GET /vault/{namespace}/`, this store's own directory listing --
    /// `{"files": [...]}`, subdirectories suffixed `/` (there are none under
    /// a real namespace directory, but a defensive filter costs nothing).
    /// Every real caller of `read`/`write` addresses a node by this same
    /// bare, namespace-relative name, so `list`'s own output has to match --
    /// confirmed live against the real API before writing this, not assumed
    /// from documentation.
    pub fn list(self: *ObsidianStore, gpa: Allocator, io: Io) anyerror![]const []const u8 {
        const encoded_ns = try encodePath(gpa, self.namespace);
        defer gpa.free(encoded_ns);
        const url = try std.fmt.allocPrint(gpa, "{s}/vault/{s}/", .{ self.base, encoded_ns });
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        const res = try process.run(io, gpa, &.{
            "curl",     "-s",
            "-w",       "\n%{http_code}",
            "-X",       "GET",
            "--cacert", self.cert_path,
            "-H",       auth,
            url,
        }, .{});
        defer gpa.free(res.stderr);
        defer gpa.free(res.stdout);
        if (!res.ok()) return error.VaultUnreachable;

        const trimmed = std.mem.trimEnd(u8, res.stdout, " \t\r\n");
        const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const status_text = if (nl) |at| trimmed[at + 1 ..] else trimmed;
        const payload = if (nl) |at| trimmed[0..at] else "";
        const status = std.fmt.parseInt(u16, status_text, 10) catch 0;
        if (status < 200 or status >= 300) return error.VaultUnreachable;

        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |n| gpa.free(n);
            out.deinit(gpa);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch
            return error.VaultUnreachable;
        defer parsed.deinit();
        const files = switch (parsed.value) {
            .object => |o| switch (o.get("files") orelse return try out.toOwnedSlice(gpa)) {
                .array => |a| a,
                else => return try out.toOwnedSlice(gpa),
            },
            else => return try out.toOwnedSlice(gpa),
        };
        for (files.items) |item| {
            const name = switch (item) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.endsWith(u8, name, "/")) continue; // no subdirs under a real namespace
            try out.append(gpa, try gpa.dupe(u8, name));
        }
        return out.toOwnedSlice(gpa);
    }

    /// `POST /search/simple/?query=...&contextLength=...`, vault-wide by
    /// construction -- filtered here to this store's own namespace and
    /// re-keyed to the same bare node name `read`/`write`/`list` use, so a
    /// caller can pass a `Store.Hit.node` straight into `read` without
    /// knowing this is REST underneath. Response shape (`filename`, `score`,
    /// `matches: [{context}]`) confirmed live against the real API, not
    /// assumed: only the first match's context is kept per file, the same
    /// one-line-per-hit simplification `BardGraphStore.search` already uses.
    pub fn search(self: *ObsidianStore, gpa: Allocator, io: Io, query: []const u8) anyerror![]const Store.Hit {
        const encoded_q = try encodePath(gpa, query);
        defer gpa.free(encoded_q);
        const url = try std.fmt.allocPrint(
            gpa,
            "{s}/search/simple/?query={s}&contextLength=80",
            .{ self.base, encoded_q },
        );
        defer gpa.free(url);
        const auth = try self.authHeader(gpa);
        defer gpa.free(auth);

        const res = try process.run(io, gpa, &.{
            "curl", "-s", "-X", "POST", "--cacert", self.cert_path, "-H", auth, url,
        }, .{});
        defer gpa.free(res.stderr);
        defer gpa.free(res.stdout);
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

        const prefix = try std.fmt.allocPrint(gpa, "{s}/", .{self.namespace});
        defer gpa.free(prefix);

        for (results.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const filename = switch (obj.get("filename") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.startsWith(u8, filename, prefix)) continue; // outside this namespace
            const bare = filename[prefix.len..];

            const score: f32 = switch (obj.get("score") orelse .null) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => 0,
            };

            const context = ctx: {
                const matches = switch (obj.get("matches") orelse .null) {
                    .array => |a| a,
                    else => break :ctx "",
                };
                if (matches.items.len == 0) break :ctx "";
                const first = switch (matches.items[0]) {
                    .object => |o| o,
                    else => break :ctx "",
                };
                break :ctx switch (first.get("context") orelse .null) {
                    .string => |s| s,
                    else => "",
                };
            };

            try out.append(gpa, .{
                .node = try gpa.dupe(u8, bare),
                .score = score,
                .context = try gpa.dupe(u8, context),
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Percent-encode each path segment, leaving `/` alone. Node titles
/// routinely contain spaces and em dashes, which must survive as separators.
///
/// Unreserved set from RFC 3986: `A-Z a-z 0-9 - . _ ~`. Everything else is
/// escaped byte by byte, including UTF-8 bytes above 0x7F (an em dash
/// becomes `%E2%80%94`).
pub fn encodePath(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (path) |c| {
        if (c == '/' or isUnreserved(c)) {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex(c >> 4), hex(c & 0x0f) });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

fn hex(nibble: u8) u8 {
    return "0123456789ABCDEF"[nibble];
}

const testing = std.testing;

// `Store.from(ObsidianStore, self)` needs all four methods to exist on the
// type to compile at all -- but only the moment something actually calls
// `.store()`. Nothing did, for the whole life of this file, until this
// test: a clean `zig build` alone never proved `store()` compiled, since
// Zig's lazy analysis skips a function body nothing references. This test
// is that reference, exercised against the real fake-curl fixture end to
// end -- not just "it compiles," every op's real output is checked too.
test "ObsidianStore.store() compiles, and every op round-trips through the real fixture" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/synapse/repo@main");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const curl_log = try std.fmt.allocPrint(gpa, "{s}/curl.log", .{root});
    defer gpa.free(curl_log);

    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("FAKE_CURL_VAULT_DIR", vault);
    try env.put("FAKE_CURL_LOG", curl_log);

    // Same "fake curl ahead of the real one on PATH" setup
    // `cmd_test_support.zig` uses -- an absolute entry, since the fake
    // `git`/`curl` scripts strip their own directory from PATH by
    // exact-matching its real absolute location.
    var fake_bin_dir = try std.Io.Dir.cwd().openDir(testing.io, "tests/fixtures/fake-bin", .{});
    defer fake_bin_dir.close(testing.io);
    var fake_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(testing.io, &fake_bin_buf)];
    const real_path = env.get("PATH") orelse "";
    const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
    defer gpa.free(fake_bin);
    try env.put("PATH", fake_bin);

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, 27124, "/dev/null", "test-key", "synapse/repo@main");
    defer os_store.deinit();
    var store = os_store.store();

    const wr = try store.write(io, "Foo.md", "---\ntitle: Foo\n---\nbody\n");
    try testing.expect(wr.accepted);

    const got = (try store.read(gpa, io, "Foo.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Foo\n---\nbody\n", got);

    try testing.expectEqual(@as(?[]u8, null), try store.read(gpa, io, "Nope.md"));

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
}

// `frontmatter` opens a store with an empty namespace so it can reach
// any note in the vault, not just one repo's code-graph nodes -- this pins
// that `node` is then used as-is, with no `namespace/` prefix added.
test "an empty namespace addresses a node by its full vault-relative path, unprefixed" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "vault/tasks/synapse");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const vault = try std.fmt.allocPrint(gpa, "{s}/vault", .{root});
    defer gpa.free(vault);
    const curl_log = try std.fmt.allocPrint(gpa, "{s}/curl.log", .{root});
    defer gpa.free(curl_log);

    var env = try std.process.Environ.createMap(testing.environ, gpa);
    defer env.deinit();
    try env.put("FAKE_CURL_VAULT_DIR", vault);
    try env.put("FAKE_CURL_LOG", curl_log);

    var fake_bin_dir = try std.Io.Dir.cwd().openDir(testing.io, "tests/fixtures/fake-bin", .{});
    defer fake_bin_dir.close(testing.io);
    var fake_bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fake_bin_abs = fake_bin_buf[0..try fake_bin_dir.realPath(testing.io, &fake_bin_buf)];
    const real_path = env.get("PATH") orelse "";
    const fake_bin = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ fake_bin_abs, real_path });
    defer gpa.free(fake_bin);
    try env.put("PATH", fake_bin);

    var block = try env.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    var io_threaded: std.Io.Threaded = .init(gpa, .{ .environ = .{ .block = block } });
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var os_store = try ObsidianStore.init(gpa, 27124, "/dev/null", "test-key", "");
    defer os_store.deinit();
    var store = os_store.store();

    const wr = try store.write(io, "tasks/synapse/sb-037 — Task.md", "---\ntitle: Task\n---\nbody\n");
    try testing.expect(wr.accepted);

    // Landed at the exact vault-relative path, no `synapse/repo@main/` (or
    // any other) prefix inserted.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "vault/tasks/synapse/sb-037 — Task.md", gpa, .limited(1 << 20));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", on_disk);

    const got = (try store.read(gpa, io, "tasks/synapse/sb-037 — Task.md")).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("---\ntitle: Task\n---\nbody\n", got);
}

test "each segment is encoded and the separators survive" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "synapse/repo@main/Foo Node.md");
    defer gpa.free(got);
    try testing.expectEqualStrings("synapse/repo%40main/Foo%20Node.md", got);
}

test "an em dash becomes three escapes, byte by byte" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "World — entity_component_resource core.md");
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "World%20%E2%80%94%20entity_component_resource%20core.md",
        got,
    );
}

test "the unreserved set is left alone" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "a-b_c.d~e/F0");
    defer gpa.free(got);
    try testing.expectEqualStrings("a-b_c.d~e/F0", got);
}

test "a node name needing no escaping still round-trips unchanged" {
    const gpa = testing.allocator;
    const got = try encodePath(gpa, "synapse/fw-core@master/Index.md");
    defer gpa.free(got);
    try testing.expectEqualStrings("synapse/fw-core%40master/Index.md", got);
}
